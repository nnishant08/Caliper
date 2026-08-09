import Foundation
import NutritionKit
import Testing
@testable import Caliper

/// Seam days: logging days whose real length departs from 24 hours because the
/// resolution rule changed underneath them.
///
/// The maths that consumes these lands at M4. What is tested here is the
/// measurement: that a Sydney → London leg is seen as one long day, that the
/// return leg is seen as one short day rather than as under-logging, that
/// daylight saving does not masquerade as either, and that elapsed window time
/// is exact.
@Suite("Day seams")
struct DaySeamTests {

    private func snapshot(_ day: Int, hour: Int = 0, zone: String) -> DayBoundarySnapshot {
        DayBoundarySnapshot(dayIndex: DayIndex(rawValue: day), dayStartHour: hour, timeZoneIdentifier: zone)
    }

    private func day(_ raw: Int) -> DayIndex { DayIndex(rawValue: raw) }

    /// 2026-08-10, comfortably clear of any transition in either zone.
    private let tripStart = 20_675

    // MARK: - Ordinary days

    @Test("an ordinary day is exactly 24 hours")
    func ordinaryDay() throws {
        let snapshots = [snapshot(tripStart, zone: "Australia/Sydney")]
        let duration = try DayDurations.duration(of: day(tripStart + 1), given: snapshots)
        #expect(duration == DayDurations.standardDay)
    }

    @Test("a window with no seams elapses exactly its day count")
    func windowWithoutSeams() throws {
        let snapshots = [snapshot(tripStart, zone: "Australia/Sydney")]
        let window = day(tripStart)...day(tripStart + 13)
        let elapsed = try DayDurations.elapsed(across: window, given: snapshots)

        #expect(elapsed == 14 * DayDurations.standardDay)
        #expect(try DayDurations.seams(in: window, given: snapshots).isEmpty)
    }

    // MARK: - Travel

    @Test("Sydney to London produces one long day")
    func outboundLegIsALongDay() throws {
        // Sydney in August is UTC+10 (no DST); London is UTC+1 (BST). Losing nine
        // hours of offset stretches the day the change lands on.
        let snapshots = [
            snapshot(tripStart, zone: "Australia/Sydney"),
            snapshot(tripStart + 3, zone: "Europe/London")
        ]

        let seamDay = day(tripStart + 2)
        let duration = try DayDurations.duration(of: seamDay, given: snapshots)

        #expect(duration == DayDurations.standardDay + 9 * 3600)
        #expect(duration > DayDurations.standardDay)
    }

    @Test("London back to Sydney produces one short day")
    func returnLegIsAShortDay() throws {
        // The direction the brief did not mention, and the one that matters more
        // for copy: a 15-hour day looks exactly like a day of under-logging. If
        // it were reported as such, the app would be telling the user something
        // untrue about their own behaviour.
        let snapshots = [
            snapshot(tripStart, zone: "Europe/London"),
            snapshot(tripStart + 3, zone: "Australia/Sydney")
        ]

        let duration = try DayDurations.duration(of: day(tripStart + 2), given: snapshots)

        #expect(duration == DayDurations.standardDay - 9 * 3600)
        #expect(duration < DayDurations.standardDay)
    }

    @Test("a round trip produces exactly two seams that cancel")
    func roundTripSeamsCancel() throws {
        let snapshots = [
            snapshot(tripStart, zone: "Australia/Sydney"),
            snapshot(tripStart + 3, zone: "Europe/London"),
            snapshot(tripStart + 10, zone: "Australia/Sydney")
        ]
        let window = day(tripStart)...day(tripStart + 13)

        let seams = try DayDurations.seams(in: window, given: snapshots)
        #expect(seams.count == 2)
        #expect(seams.map(\.dayIndex) == [day(tripStart + 2), day(tripStart + 9)])

        // Out and back, so the deviations are equal and opposite and the window
        // elapses its nominal length after all. A user who flies away and back
        // inside one window sees no net distortion — which is the reassuring
        // case. The distortion is real when only one leg falls inside the window.
        #expect(seams[0].deviation == -seams[1].deviation)
        let elapsed = try DayDurations.elapsed(across: window, given: snapshots)
        #expect(elapsed == 14 * DayDurations.standardDay)
    }

    @Test("a single outbound leg inside the window shifts elapsed time")
    func oneLegShiftsElapsedTime() throws {
        // The case that actually biases the estimate: the window contains the
        // flight out but not the flight home.
        let snapshots = [
            snapshot(tripStart, zone: "Australia/Sydney"),
            snapshot(tripStart + 3, zone: "Europe/London")
        ]
        let window = day(tripStart)...day(tripStart + 13)

        let elapsed = try DayDurations.elapsed(across: window, given: snapshots)
        #expect(elapsed == 14 * DayDurations.standardDay + 9 * 3600)

        // Dividing by 14 rather than by 14.375 overstates the per-day figures by
        // about 2.7%. On a 2,600 kcal expenditure that is ~70 kcal a day, applied
        // for a fortnight, in the direction that quietly stalls a cut.
        let nominal = elapsed / (14 * DayDurations.standardDay)
        #expect(nominal > 1.02 && nominal < 1.03)
    }

    @Test("the seam names its cause")
    func seamCause() throws {
        let snapshots = [
            snapshot(tripStart, zone: "Australia/Sydney"),
            snapshot(tripStart + 3, zone: "Europe/London")
        ]
        let seams = try DayDurations.seams(in: day(tripStart)...day(tripStart + 5), given: snapshots)

        #expect(seams.count == 1)
        #expect(seams[0].cause == .timeZoneChange(from: "Australia/Sydney", to: "Europe/London"))
    }

    // MARK: - Day-start hour

    @Test("moving the day start from midnight to 4am produces one 28-hour day")
    func dayStartHourChangeLengthensOneDay() throws {
        let snapshots = [
            snapshot(tripStart, hour: 0, zone: "Australia/Sydney"),
            snapshot(tripStart + 5, hour: 4, zone: "Australia/Sydney")
        ]

        let seamDay = day(tripStart + 4)
        let duration = try DayDurations.duration(of: seamDay, given: snapshots)
        #expect(duration == DayDurations.standardDay + 4 * 3600)

        let seams = try DayDurations.seams(in: day(tripStart)...day(tripStart + 9), given: snapshots)
        #expect(seams.count == 1)
        #expect(seams[0].cause == .dayStartHourChange(from: 0, to: 4))
    }

    @Test("moving the day start back to midnight produces one 20-hour day")
    func dayStartHourChangeShortensOneDay() throws {
        let snapshots = [
            snapshot(tripStart, hour: 4, zone: "Australia/Sydney"),
            snapshot(tripStart + 5, hour: 0, zone: "Australia/Sydney")
        ]
        let duration = try DayDurations.duration(of: day(tripStart + 4), given: snapshots)
        #expect(duration == DayDurations.standardDay - 4 * 3600)
    }

    // MARK: - Daylight saving

    @Test("a daylight-saving transition is measured but not reported as a seam")
    func daylightSavingIsNotASeam() throws {
        // 2026-03-29 in Europe/London: 01:00 becomes 02:00, a 23-hour day. The
        // naive detection rule — "flag when the UTC offset changes" — fires here
        // and would cost every user in a DST country two days a year from the
        // intake mean, to correct a 4% distortion the trend smoothing already
        // absorbs.
        let springForward = try dayIndex(of: "2026-03-29T12:00:00+01:00", zone: "Europe/London")
        let snapshots = [snapshot(springForward.rawValue - 5, zone: "Europe/London")]

        let duration = try DayDurations.duration(of: springForward, given: snapshots)
        #expect(duration == DayDurations.standardDay - 3600, "the transition day should be 23 hours")

        let seams = try DayDurations.seams(
            in: springForward.advanced(by: -2)...springForward.advanced(by: 2),
            given: snapshots
        )
        #expect(seams.isEmpty, "a one-hour shift is below the seam threshold")
    }

    @Test("elapsed time still counts the daylight-saving hour")
    func daylightSavingIsCountedInElapsedTime() throws {
        // Not reported, but not ignored either. The window is genuinely an hour
        // shorter and the denominator must say so.
        let springForward = try dayIndex(of: "2026-03-29T12:00:00+01:00", zone: "Europe/London")
        let snapshots = [snapshot(springForward.rawValue - 10, zone: "Europe/London")]
        let window = springForward.advanced(by: -6)...springForward.advanced(by: 7)

        let elapsed = try DayDurations.elapsed(across: window, given: snapshots)
        #expect(elapsed == 14 * DayDurations.standardDay - 3600)
    }

    // MARK: - Invariants

    @Test("day starts round-trip through day-key resolution", arguments: [0, 4, 11])
    func startInstantRoundTrips(hour: Int) throws {
        let policy = try DayBoundaryPolicy(dayStartHour: hour, timeZoneIdentifier: "America/Los_Angeles")
        let resolver = DayKeyResolver(policy: policy)

        for offset in 0..<400 {
            let subject = day(tripStart + offset)
            let start = try resolver.startInstant(of: subject)

            #expect(try resolver.dayIndex(for: start) == subject, "start of \(subject)")
            #expect(
                try resolver.dayIndex(for: start.addingTimeInterval(-1)) == subject.advanced(by: -1),
                "the instant before \(subject) belongs to the previous day"
            )
        }
    }

    @Test("civil date conversion round-trips")
    func civilConversionRoundTrips() {
        for raw in stride(from: -20_000, through: 40_000, by: 7) {
            let civil = DayKeyResolver.civilFromDays(raw)
            let back = DayKeyResolver.daysFromCivil(year: civil.year, month: civil.month, day: civil.day)
            #expect(back == raw)
        }
    }

    @Test("unordered boundary records are rejected")
    func unorderedRecordsThrow() {
        let snapshots = [
            snapshot(tripStart + 5, zone: "Europe/London"),
            snapshot(tripStart, zone: "Australia/Sydney")
        ]
        #expect(throws: DayBoundaryError.unorderedBoundaryRecords) {
            try DayDurations.duration(of: DayIndex(rawValue: self.tripStart + 6), given: snapshots)
        }
    }

    @Test("a day before any recorded policy is an error, not a guess")
    func missingPolicyThrows() {
        let snapshots = [snapshot(tripStart, zone: "Australia/Sydney")]
        #expect(throws: DayBoundaryError.self) {
            try DayDurations.duration(of: DayIndex(rawValue: self.tripStart - 1), given: snapshots)
        }
    }

    // MARK: - Helpers

    private func dayIndex(of iso: String, zone: String) throws -> DayIndex {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let instant = try #require(formatter.date(from: iso))
        let policy = try DayBoundaryPolicy(dayStartHour: 0, timeZoneIdentifier: zone)
        return try DayKeyResolver(policy: policy).dayIndex(for: instant)
    }
}
