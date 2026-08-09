import Foundation
import NutritionKit

/// The boundary policy observed to be in force on a given logging day.
///
/// A plain value rather than the `@Model`, so seam analysis is testable without
/// a SwiftData container. `DayBoundaryRecord` converts to one.
struct DayBoundarySnapshot: Equatable, Sendable {
    let dayIndex: DayIndex
    let dayStartHour: Int
    let timeZoneIdentifier: String
}

/// A logging day whose length departs materially from 24 hours.
struct DaySeam: Equatable, Sendable {

    enum Cause: Equatable, Sendable {
        case timeZoneChange(from: String, to: String)
        case dayStartHourChange(from: Int, to: Int)
        case both(zoneFrom: String, zoneTo: String, hourFrom: Int, hourTo: Int)
        /// Same policy at both ends, so the change came from the zone itself.
        case daylightSaving
    }

    let dayIndex: DayIndex
    let duration: TimeInterval
    let cause: Cause

    /// Signed: positive for a long day, negative for a short one.
    var deviation: TimeInterval { duration - DayDurations.standardDay }
}

/// Answers how long logging days actually were.
///
/// ## Why this exists
///
/// `DayIndex` keys resolve once and never recompute (ADR-0008), which is right
/// for target integrity but means a change to the resolution rule produces a day
/// of anomalous length:
///
/// - Moving the day-start hour from 00:00 to 04:00 makes one 28-hour day.
/// - Flying Sydney → London drops the UTC offset by nine hours in August and
///   eleven in January, making one day of 33 to 35 hours. Flying back does the
///   reverse: a 13- to 15-hour day.
/// - Every user gets a 23-hour and a 25-hour day each year from daylight saving.
///
/// ## Why duration rather than exclusion
///
/// The obvious fix is to treat a seam day like an under-logged one: drop it from
/// the intake mean, keep it in the weight-delta window. That is worse than it
/// looks, for two reasons.
///
/// First, it under-counts. A 35-hour day's intake was really eaten, and the
/// weight change over the window reflects it. Excluding the day and imputing the
/// mean understates total intake while the weight delta still contains it — the
/// estimate is pulled down from both directions at once.
///
/// Second, the natural detection rule — "flag when the UTC offset changes" —
/// fires on every daylight-saving transition, so every user in a DST country
/// would lose two days a year from the intake mean to correct a one-hour
/// distortion that is far inside the noise the EWMA already absorbs.
///
/// The exact fix is cheaper than either. The expenditure identity is
/// `mean_intake − TDEE = Δweight × 7700 / elapsed`, and `elapsed` is *time*, not
/// a count of day keys. A window containing a Sydney → London seam spans 14 days
/// and 11 hours, and the user genuinely expended 14.46 days' worth of energy
/// across it. Using real elapsed time as the denominator handles seams, DST and
/// ordinary days with one subtraction and no special cases — and it needs no
/// detection at all.
///
/// Seam *detection* therefore serves the UI, not the maths: a 35-hour day should
/// be labelled as one, because a user who sees 3,400 kcal against a 2,500 target
/// deserves to be told the day was 35 hours long rather than left to conclude
/// they blew out. Equally, the short return leg must not be reported as
/// under-logging — it would be the app telling the user something untrue about
/// their own behaviour.
enum DayDurations {

    static let standardDay: TimeInterval = 24 * 3600

    /// How far from 24 hours a day must fall before it is surfaced as a seam.
    ///
    /// Two hours, chosen to sit above every daylight-saving shift in current use
    /// — one hour almost everywhere, thirty minutes on Lord Howe Island — and
    /// far below a timezone seam, which is at minimum several hours. A DST day
    /// is 4% off standard, which is inside the noise the trend smoothing already
    /// absorbs and not worth telling the user about.
    static let seamThreshold: TimeInterval = 2 * 3600

    // MARK: - Boundaries

    /// The instant `day` began, under whichever policy was in force then.
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
    static func duration(of day: DayIndex, given snapshots: [DayBoundarySnapshot]) throws -> TimeInterval {
        let start = try startInstant(of: day, given: snapshots)
        let end = try startInstant(of: day.advanced(by: 1), given: snapshots)
        return end.timeIntervalSince(start)
    }

    /// Real elapsed time across an inclusive range of logging days.
    ///
    /// This is the denominator the expenditure estimate divides by. For a window
    /// with no seams it equals `window.count` days exactly; with a seam it does
    /// not, and that difference is the whole point.
    static func elapsed(
        across window: ClosedRange<DayIndex>,
        given snapshots: [DayBoundarySnapshot]
    ) throws -> TimeInterval {
        let start = try startInstant(of: window.lowerBound, given: snapshots)
        let end = try startInstant(of: window.upperBound.advanced(by: 1), given: snapshots)
        return end.timeIntervalSince(start)
    }

    // MARK: - Seams

    /// Days within the window whose length departs from 24 hours by more than
    /// `seamThreshold`, for disclosure in the UI.
    static func seams(in window: ClosedRange<DayIndex>, given snapshots: [DayBoundarySnapshot]) throws -> [DaySeam] {
        var seams: [DaySeam] = []

        for day in window {
            let duration = try duration(of: day, given: snapshots)
            guard abs(duration - standardDay) >= seamThreshold else { continue }

            guard
                let before = try policy(on: day, given: snapshots),
                let after = try policy(on: day.advanced(by: 1), given: snapshots)
            else {
                throw DayBoundaryError.unresolvableDay(day.rawValue)
            }

            seams.append(
                DaySeam(dayIndex: day, duration: duration, cause: cause(from: before, to: after))
            )
        }

        return seams
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
            // The policy is unchanged, so the zone moved underneath it.
            return .daylightSaving
        }
    }

    // MARK: - Policy lookup

    /// The policy in force on `day`: the most recent observation at or before it.
    ///
    /// Policy is carried forward rather than recorded daily. A day on which the
    /// user neither logged nor opened the app has no observation of its own, and
    /// the honest assumption is that nothing changed. If they did in fact fly
    /// that day, the seam surfaces on the day the change is first observed —
    /// off by at most the gap, and a day with no entries is already excluded
    /// from the intake mean for being incompletely logged.
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
