import Foundation
import NutritionKit
import Testing
@testable import Caliper

/// Seam days: logging days whose real length departs from 24 hours because the
/// resolution rule changed underneath them.
///
/// The maths that consumes these lands at M4. What is tested here is the
/// measurement — and, as much, the honesty of the measurement when the app was
/// not open across the change, which is the likely case for a flight.
@Suite("Day seams")
struct DaySeamTests {

    /// 2026-08-10, comfortably clear of any transition in either zone.
    private let tripStart = 20_675

    private func day(_ raw: Int) -> DayIndex { DayIndex(rawValue: raw) }

    private func observation(_ dayOffset: Int, hour: Int = 0, zone: String) -> DayBoundarySnapshot {
        DayBoundarySnapshot(
            dayIndex: day(tripStart + dayOffset),
            dayStartHour: hour,
            timeZoneIdentifier: zone
        )
    }

    /// The app opened on every day in `range` — the ordinary case for a daily
    /// logging app, and the case in which seams can be pinned to a single day.
    private func openedDaily(_ range: ClosedRange<Int>, hour: Int = 0, zone: String) -> [DayBoundarySnapshot] {
        range.map { observation($0, hour: hour, zone: zone) }
    }

    // MARK: - Ordinary days

    @Test("an ordinary day is exactly 24 hours")
    func ordinaryDay() throws {
        let observations = openedDaily(0...5, zone: "Australia/Sydney")
        #expect(try DayDurations.duration(of: day(tripStart + 1), given: observations) == DayDurations.standardDay)
    }

    @Test("a window with no seams elapses exactly its day count")
    func windowWithoutSeams() throws {
        let observations = openedDaily(0...14, zone: "Australia/Sydney")
        let window = day(tripStart)...day(tripStart + 13)

        #expect(try DayDurations.elapsed(across: window, given: observations) == 14 * DayDurations.standardDay)
        #expect(try DayDurations.seams(in: window, given: observations).isEmpty)
        #expect(try DayDurations.uncertainDays(given: observations).isEmpty)
    }

    // MARK: - Travel, app opened either side

    @Test("Sydney to London stretches one day, pinned when the app was opened daily")
    func outboundLegObservedDaily() throws {
        // Sydney in August is UTC+10; London is UTC+1. Nine hours of offset lost.
        let observations = openedDaily(0...2, zone: "Australia/Sydney")
            + openedDaily(3...6, zone: "Europe/London")

        let seams = try DayDurations.seams(in: day(tripStart)...day(tripStart + 6), given: observations)

        #expect(seams.count == 1)
        #expect(seams[0].attribution == .observed(day(tripStart + 2)))
        #expect(seams[0].deviation == 9 * 3600)
        #expect(seams[0].duration == DayDurations.standardDay + 9 * 3600)
        #expect(seams[0].cause == .timeZoneChange(from: "Australia/Sydney", to: "Europe/London"))
    }

    @Test("London back to Sydney shortens one day")
    func returnLegIsAShortDay() throws {
        // The direction the brief did not mention, and the one that matters most
        // for copy: a 15-hour day looks exactly like a day of under-logging. If
        // it were reported as such, the app would be telling the user something
        // untrue about their own behaviour.
        let observations = openedDaily(0...2, zone: "Europe/London")
            + openedDaily(3...6, zone: "Australia/Sydney")

        let seams = try DayDurations.seams(in: day(tripStart)...day(tripStart + 6), given: observations)

        #expect(seams.count == 1)
        #expect(seams[0].deviation == -9 * 3600)
        #expect(seams[0].duration == DayDurations.standardDay - 9 * 3600)
    }

    @Test("a round trip inside one window cancels exactly")
    func roundTripCancels() throws {
        let observations = openedDaily(0...2, zone: "Australia/Sydney")
            + openedDaily(3...9, zone: "Europe/London")
            + openedDaily(10...14, zone: "Australia/Sydney")
        let window = day(tripStart)...day(tripStart + 13)

        let seams = try DayDurations.seams(in: window, given: observations)
        #expect(seams.count == 2)
        #expect(seams[0].deviation == -seams[1].deviation)

        // Out and back inside one window, so the window elapses its nominal
        // length after all. The distortion is real only when a single leg falls
        // inside the window.
        #expect(try DayDurations.elapsed(across: window, given: observations) == 14 * DayDurations.standardDay)
    }

    @Test("a single outbound leg inside the window shifts elapsed time")
    func oneLegShiftsElapsedTime() throws {
        let observations = openedDaily(0...2, zone: "Australia/Sydney")
            + openedDaily(3...14, zone: "Europe/London")
        let window = day(tripStart)...day(tripStart + 13)

        let elapsed = try DayDurations.elapsed(across: window, given: observations)
        #expect(elapsed == 14 * DayDurations.standardDay + 9 * 3600)

        // Dividing by 14 rather than 14.375 overstates the per-day figures by
        // ~2.7%: about 70 kcal a day on a 2,600 kcal expenditure, sustained for a
        // fortnight, in the direction that quietly stalls a cut.
        let error = elapsed / (14 * DayDurations.standardDay)
        #expect(error > 1.02 && error < 1.03)
    }

    // MARK: - Travel with the app unopened — the actual flight case

    @Test("a change across an unobserved gap is not pinned to a guessed day")
    func unobservedGapIsNotPinned() throws {
        // Flew on the 11th, next opened the app on the 14th. We know a nine-hour
        // seam happened; we do not know which day absorbed it, and the app must
        // not claim otherwise.
        let observations = openedDaily(0...1, zone: "Australia/Sydney")
            + openedDaily(4...8, zone: "Europe/London")

        let seams = try DayDurations.seams(in: day(tripStart)...day(tripStart + 8), given: observations)

        #expect(seams.count == 1)
        #expect(seams[0].attribution == .somewhereIn(day(tripStart + 1)...day(tripStart + 3)))
        #expect(seams[0].isPreciselyAttributed == false)
        #expect(seams[0].duration == nil, "no single day can be named, so none is offered")

        // The total is still known exactly — it is only the attribution that is not.
        #expect(seams[0].deviation == 9 * 3600)
    }

    @Test("days inside an unobserved change are reported as uncertain")
    func unobservedDaysAreUncertain() throws {
        let observations = openedDaily(0...1, zone: "Australia/Sydney")
            + openedDaily(4...8, zone: "Europe/London")

        let uncertain = try DayDurations.uncertainDays(given: observations)
        #expect(uncertain == [day(tripStart + 2)...day(tripStart + 3)])
    }

    @Test("a gap with no policy change creates no uncertainty")
    func gapWithoutChangeIsCertain() throws {
        // Not opening the app for a week is normal and tells us nothing except
        // that nothing was observed to change. It must not poison the window.
        let observations = openedDaily(0...1, zone: "Australia/Sydney")
            + openedDaily(9...14, zone: "Australia/Sydney")

        #expect(try DayDurations.uncertainDays(given: observations).isEmpty)
        #expect(try DayDurations.seams(in: day(tripStart)...day(tripStart + 14), given: observations).isEmpty)
    }

    @Test("elapsed time is exact across an unobserved seam when both endpoints are known")
    func elapsedIsExactDespiteUnobservedSeam() throws {
        // The property that makes uncertainty tolerable: the denominator depends
        // only on the two endpoints, not on where inside the window the change
        // fell. The flight day was never observed and the answer is still right.
        let sparse = openedDaily(0...1, zone: "Australia/Sydney")
            + openedDaily(4...14, zone: "Europe/London")
        let dense = openedDaily(0...2, zone: "Australia/Sydney")
            + openedDaily(3...14, zone: "Europe/London")
        let window = day(tripStart)...day(tripStart + 13)

        let fromSparse = try DayDurations.elapsed(across: window, given: sparse)
        let fromDense = try DayDurations.elapsed(across: window, given: dense)

        #expect(fromSparse == fromDense)
        #expect(fromSparse == 14 * DayDurations.standardDay + 9 * 3600)
    }

    @Test("a window starting inside an uncertain run is refused, not mis-divided")
    func uncertainStartIsRefused() throws {
        let observations = openedDaily(0...1, zone: "Australia/Sydney")
            + openedDaily(6...14, zone: "Europe/London")
        let window = day(tripStart + 3)...day(tripStart + 13)

        #expect(throws: DayBoundaryError.self) {
            try DayDurations.elapsed(across: window, given: observations)
        }
    }

    @Test("anchoring widens the window back to a day whose policy is known")
    func anchoringWidensToCertainty() throws {
        let observations = openedDaily(0...1, zone: "Australia/Sydney")
            + openedDaily(6...14, zone: "Europe/London")
        let window = day(tripStart + 3)...day(tripStart + 13)

        let anchored = try DayDurations.anchor(window, given: observations)

        #expect(anchored.lowerBound == day(tripStart + 1), "the last observed day before the gap")
        #expect(anchored.upperBound == window.upperBound)
        // And now it computes rather than refusing.
        #expect(try DayDurations.elapsed(across: anchored, given: observations) > 0)
    }

    @Test("anchoring leaves a certain window untouched")
    func anchoringIsIdentityWhenCertain() throws {
        let observations = openedDaily(0...14, zone: "Australia/Sydney")
        let window = day(tripStart + 3)...day(tripStart + 13)
        #expect(try DayDurations.anchor(window, given: observations) == window)
    }

    // MARK: - Day-start hour

    @Test("moving the day start from midnight to 4am produces one 28-hour day")
    func dayStartHourChangeLengthensOneDay() throws {
        let observations = openedDaily(0...4, hour: 0, zone: "Australia/Sydney")
            + openedDaily(5...9, hour: 4, zone: "Australia/Sydney")

        let seams = try DayDurations.seams(in: day(tripStart)...day(tripStart + 9), given: observations)

        #expect(seams.count == 1)
        #expect(seams[0].duration == DayDurations.standardDay + 4 * 3600)
        #expect(seams[0].cause == .dayStartHourChange(from: 0, to: 4))
    }

    @Test("moving the day start back to midnight produces one 20-hour day")
    func dayStartHourChangeShortensOneDay() throws {
        let observations = openedDaily(0...4, hour: 4, zone: "Australia/Sydney")
            + openedDaily(5...9, hour: 0, zone: "Australia/Sydney")

        let seams = try DayDurations.seams(in: day(tripStart)...day(tripStart + 9), given: observations)
        #expect(seams.count == 1)
        #expect(seams[0].duration == DayDurations.standardDay - 4 * 3600)
    }

    // MARK: - Daylight saving

    @Test("a daylight-saving transition is measured but not reported as a seam")
    func daylightSavingIsNotASeam() throws {
        // 2026-03-29 in Europe/London: 01:00 becomes 02:00, a 23-hour day. The
        // naive detection rule — "flag when the UTC offset changes" — fires here,
        // and would cost every user in a DST country two days a year to correct a
        // distortion of one hour in twenty-four.
        let springForward = try dayIndex(of: "2026-03-29T12:00:00+01:00", zone: "Europe/London")
        let observations = (-3...3).map { offset in
            DayBoundarySnapshot(
                dayIndex: springForward.advanced(by: offset),
                dayStartHour: 0,
                timeZoneIdentifier: "Europe/London"
            )
        }

        #expect(try DayDurations.duration(of: springForward, given: observations) == DayDurations.standardDay - 3600)
        #expect(
            try DayDurations.seams(
                in: springForward.advanced(by: -2)...springForward.advanced(by: 2),
                given: observations
            ).isEmpty,
            "a one-hour shift is below the seam threshold"
        )
    }

    @Test("elapsed time still counts the daylight-saving hour")
    func daylightSavingIsCountedInElapsedTime() throws {
        // Not reported, but not ignored either. The window is genuinely an hour
        // shorter and the denominator must say so.
        let springForward = try dayIndex(of: "2026-03-29T12:00:00+01:00", zone: "Europe/London")
        let observations = (-7...8).map { offset in
            DayBoundarySnapshot(
                dayIndex: springForward.advanced(by: offset),
                dayStartHour: 0,
                timeZoneIdentifier: "Europe/London"
            )
        }
        let window = springForward.advanced(by: -6)...springForward.advanced(by: 7)

        #expect(try DayDurations.elapsed(across: window, given: observations) == 14 * DayDurations.standardDay - 3600)
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

    @Test("unordered observations are rejected")
    func unorderedRecordsThrow() {
        let observations = [observation(5, zone: "Europe/London"), observation(0, zone: "Australia/Sydney")]
        #expect(throws: DayBoundaryError.unorderedBoundaryRecords) {
            try DayDurations.duration(of: self.day(self.tripStart + 6), given: observations)
        }
    }

    @Test("a day before any observation is an error, not a guess")
    func missingPolicyThrows() {
        let observations = openedDaily(0...5, zone: "Australia/Sydney")
        #expect(throws: DayBoundaryError.self) {
            try DayDurations.duration(of: self.day(self.tripStart - 1), given: observations)
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
