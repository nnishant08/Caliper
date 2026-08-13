import Foundation
import NutritionKit

/// The boundary policy observed on a day the app was actually open.
///
/// An *observation*, not a daily record. Its absence for a given day means the
/// app was not opened that day, which is information in its own right — see
/// `DayDurations` on why "no record" must not be confused with "nothing changed".
///
/// A plain value rather than the `@Model`, so seam analysis is testable without
/// a SwiftData container. `DayBoundaryRecord` converts to one.
struct DayBoundarySnapshot: Equatable, Sendable {
    let dayIndex: DayIndex
    let dayStartHour: Int
    let timeZoneIdentifier: String

    func hasSamePolicy(as other: DayBoundarySnapshot) -> Bool {
        dayStartHour == other.dayStartHour && timeZoneIdentifier == other.timeZoneIdentifier
    }
}

/// A stretch of time whose length departs materially from a whole number of
/// standard days, because the day-resolution rule changed inside it.
struct DaySeam: Equatable, Sendable {

    /// Which day was stretched — or, when the app was not open across the
    /// change, the range of days one of which was.
    enum Attribution: Equatable, Sendable {
        case observed(DayIndex)
        case somewhereIn(ClosedRange<DayIndex>)
    }

    enum Cause: Equatable, Sendable {
        case timeZoneChange(from: String, to: String)
        case dayStartHourChange(from: Int, to: Int)
        case both(zoneFrom: String, zoneTo: String, hourFrom: Int, hourTo: Int)
        /// The policy did not change, so the zone moved underneath it.
        case daylightSaving
    }

    let attribution: Attribution
    let cause: Cause

    /// Signed departure from a whole number of standard days: positive where
    /// time was gained, negative where it was lost.
    let deviation: TimeInterval

    /// The day's real length — available only when a single day can be named.
    var duration: TimeInterval? {
        guard case .observed = attribution else { return nil }
        return DayDurations.standardDay + deviation
    }

    var isPreciselyAttributed: Bool {
        if case .observed = attribution { return true }
        return false
    }
}

/// Answers how long logging days actually were.
///
/// ## Why this exists
///
/// `DayIndex` keys resolve once and never recompute (ADR-0008), which is right
/// for target integrity but means any change to the resolution rule leaves one
/// day of anomalous length:
///
/// - Moving the day-start hour from 00:00 to 04:00 makes one 28-hour day.
/// - Flying Sydney → London drops the UTC offset by nine hours in August and
///   eleven in January, making one day of 33 to 35 hours. Flying back does the
///   reverse: a 13- to 15-hour day.
/// - Every user gets a 23-hour and a 25-hour day each year from daylight saving.
///
/// The expenditure estimate therefore divides by real elapsed time rather than a
/// count of day keys. See ADR-0014.
///
/// ## What an observation is, and what its absence means
///
/// A `DayBoundarySnapshot` is written for each day the app is *opened*, not for
/// each day that passes. That distinction is deliberate, because the seam day is
/// precisely the day the user is least likely to open the app — they are on a
/// plane. If a record were written only when the policy changed, a missing
/// record would be ambiguous between "nothing changed" and "we weren't looking",
/// and the code would have no way to tell a genuine 24-hour day from an
/// unobserved 33-hour one.
///
/// Writing one per active day makes absence mean something: nobody was looking.
/// A change bracketed by a multi-day gap is then reported as
/// `Attribution.somewhereIn` rather than being pinned to a day we are guessing
/// at, and days inside that gap are `uncertainDays`.
///
/// ## The property that makes this tractable
///
/// **Total elapsed time across a window depends only on its two endpoints**, not
/// on where inside it the change happened. `elapsed(across:)` computes
/// `start(lastDay + 1) − start(firstDay)`, so as long as the policy at each
/// endpoint is known, the denominator is exact even if the flight day itself was
/// never observed. In the ordinary case — a window ending today, computed while
/// the app is open — the later endpoint is always known, because the app is
/// open right now.
///
/// What uncertainty costs is therefore narrower than it first appears: not the
/// estimate, but the *attribution* of a seam to a particular day, and the case
/// where the window's own start falls inside an unobserved gap. For the latter,
/// `elapsed(across:)` refuses rather than quietly mis-dividing, and
/// `anchor(_:given:)` widens the window back to a day whose policy is known.
enum DayDurations {

    static let standardDay: TimeInterval = 24 * 3600

    /// How far from standard a stretch must fall before it is surfaced as a seam.
    ///
    /// Two hours, chosen to sit above every daylight-saving shift in current use
    /// — one hour almost everywhere, thirty minutes on Lord Howe Island — and
    /// far below a timezone seam, which is at minimum several hours. A DST day
    /// is 4% off standard, inside the noise the trend smoothing already absorbs
    /// and not worth telling the user about.
    ///
    /// The same threshold governs whether the day's *target* is rescaled
    /// (ADR-0016), so the target changes exactly when the app is willing to
    /// explain why.
    static let seamThreshold: TimeInterval = 2 * 3600

    // MARK: - Boundaries

    /// The instant `day` began, under whichever policy was last observed at or
    /// before it.
    static func startInstant(of day: DayIndex, given snapshots: [DayBoundarySnapshot]) throws -> Date {
        guard let snapshot = try policy(on: day, given: snapshots) else {
            throw DayBoundaryError.unresolvableDay(day.rawValue)
        }
        let policy = try DayBoundaryPolicy(
            dayStartHour: snapshot.dayStartHour,
            timeZoneIdentifier: snapshot.timeZoneIdentifier
        )
        return try DayKeyResolver(policy: policy).startInstant(of: day)
    }

    /// How long `day` lasted: from its own start to the next day's start, each
    /// under the policy in force at that end.
    ///
    /// Only meaningful when neither boundary is uncertain; callers wanting a
    /// guarantee should consult `uncertainDays(given:)` first.
    static func duration(of day: DayIndex, given snapshots: [DayBoundarySnapshot]) throws -> TimeInterval {
        let start = try startInstant(of: day, given: snapshots)
        let end = try startInstant(of: day.advanced(by: 1), given: snapshots)
        return end.timeIntervalSince(start)
    }

    /// Real elapsed time across an inclusive range of logging days — the
    /// denominator the expenditure estimate divides by.
    ///
    /// Throws if either endpoint's policy is uncertain. Refusing is the point:
    /// a silently wrong denominator is the failure this whole mechanism exists
    /// to prevent. Call `anchor(_:given:)` first.
    static func elapsed(
        across window: ClosedRange<DayIndex>,
        given snapshots: [DayBoundarySnapshot]
    ) throws -> TimeInterval {
        let uncertain = try uncertainDays(given: snapshots)
        let endpoints = [window.lowerBound, window.upperBound.advanced(by: 1)]

        for endpoint in endpoints where uncertain.contains(where: { $0.contains(endpoint) }) {
            throw DayBoundaryError.uncertainWindowBoundary(endpoint.rawValue)
        }

        let start = try startInstant(of: window.lowerBound, given: snapshots)
        let end = try startInstant(of: window.upperBound.advanced(by: 1), given: snapshots)
        return end.timeIntervalSince(start)
    }

    /// Widens `window` backwards until its start sits on a day whose policy is
    /// known, so `elapsed(across:)` is exact.
    ///
    /// Only the lower bound can need this. The upper bound of a live window is
    /// today, and the app is open — otherwise nothing would be asking.
    ///
    /// Widening rather than narrowing because a shorter window is a noisier
    /// estimate, and because the days being added are real days with real data;
    /// the only thing that was missing was a record of which zone they were in.
    static func anchor(
        _ window: ClosedRange<DayIndex>,
        given snapshots: [DayBoundarySnapshot]
    ) throws -> ClosedRange<DayIndex> {
        let uncertain = try uncertainDays(given: snapshots)

        guard let containing = uncertain.first(where: { $0.contains(window.lowerBound) }) else {
            return window
        }

        // The day before an uncertain run is, by construction, an observation.
        let anchored = containing.lowerBound.advanced(by: -1)
        return anchored...window.upperBound
    }

    // MARK: - Uncertainty

    /// Runs of days whose boundaries cannot be pinned down, because the policy
    /// changed while the app was not being opened.
    ///
    /// The observation days at either end are certain — we looked on those days.
    /// It is the days between them that could have belonged to either zone.
    static func uncertainDays(given snapshots: [DayBoundarySnapshot]) throws -> [ClosedRange<DayIndex>] {
        try validateOrdering(of: snapshots)

        return zip(snapshots, snapshots.dropFirst()).compactMap { before, after in
            guard !before.hasSamePolicy(as: after) else { return nil }
            guard before.dayIndex.days(to: after.dayIndex) > 1 else { return nil }
            return before.dayIndex.advanced(by: 1)...after.dayIndex.advanced(by: -1)
        }
    }

    // MARK: - Seams

    /// Seams overlapping `window`, for disclosure in the UI.
    ///
    /// Walks consecutive observations rather than individual days, so a change
    /// spanning an unobserved gap yields one seam carrying the true total
    /// deviation, attributed to the range it might have fallen in, rather than a
    /// confident claim about a day nobody watched.
    ///
    /// Seams after the final observation are undetectable — there is no later
    /// vantage point to compare against — and surface on the next app open.
    static func seams(
        in window: ClosedRange<DayIndex>,
        given snapshots: [DayBoundarySnapshot]
    ) throws -> [DaySeam] {
        try validateOrdering(of: snapshots)

        var seams: [DaySeam] = []

        for (before, after) in zip(snapshots, snapshots.dropFirst()) {
            let spanStart = try startInstant(of: before.dayIndex, given: snapshots)
            let spanEnd = try startInstant(of: after.dayIndex, given: snapshots)

            let spannedDays = before.dayIndex.days(to: after.dayIndex)
            let nominal = Double(spannedDays) * standardDay
            let deviation = spanEnd.timeIntervalSince(spanStart) - nominal

            guard abs(deviation) >= seamThreshold else { continue }

            let attribution: DaySeam.Attribution = spannedDays == 1
                ? .observed(before.dayIndex)
                : .somewhereIn(before.dayIndex...after.dayIndex.advanced(by: -1))

            guard overlaps(attribution, window) else { continue }

            seams.append(
                DaySeam(attribution: attribution, cause: cause(from: before, to: after), deviation: deviation)
            )
        }

        return seams
    }

    private static func overlaps(_ attribution: DaySeam.Attribution, _ window: ClosedRange<DayIndex>) -> Bool {
        switch attribution {
        case .observed(let day):
            return window.contains(day)
        case .somewhereIn(let range):
            return range.overlaps(window)
        }
    }

    private static func cause(from before: DayBoundarySnapshot, to after: DayBoundarySnapshot) -> DaySeam.Cause {
        let zoneChanged = before.timeZoneIdentifier != after.timeZoneIdentifier
        let hourChanged = before.dayStartHour != after.dayStartHour

        switch (zoneChanged, hourChanged) {
        case (true, true):
            return .both(
                zoneFrom: before.timeZoneIdentifier,
                zoneTo: after.timeZoneIdentifier,
                hourFrom: before.dayStartHour,
                hourTo: after.dayStartHour
            )
        case (true, false):
            return .timeZoneChange(from: before.timeZoneIdentifier, to: after.timeZoneIdentifier)
        case (false, true):
            return .dayStartHourChange(from: before.dayStartHour, to: after.dayStartHour)
        case (false, false):
            return .daylightSaving
        }
    }

    // MARK: - Policy lookup

    private static func policy(
        on day: DayIndex,
        given snapshots: [DayBoundarySnapshot]
    ) throws -> DayBoundarySnapshot? {
        try validateOrdering(of: snapshots)
        return snapshots.last { $0.dayIndex <= day }
    }

    private static func validateOrdering(of snapshots: [DayBoundarySnapshot]) throws {
        let isOrdered = zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.dayIndex < $1.dayIndex }
        guard isOrdered else { throw DayBoundaryError.unorderedBoundaryRecords }
    }
}
