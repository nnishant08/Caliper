import Foundation
import NutritionKit
import Testing
@testable import Caliper

/// Darwin-side date tests.
///
/// NutritionKit deliberately cannot see `Calendar` or `TimeZone`, so this file is
/// where the entire calendar risk of the app is concentrated. It runs on the
/// macOS CI job, not the Linux one, because Darwin Foundation is the
/// implementation that ships to users.
@Suite("Day key resolution")
struct DayKeyResolverTests {

    private func instant(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: iso), "unparseable fixture: \(iso)")
    }

    private func resolver(hour: Int = 0, zone: String) throws -> DayKeyResolver {
        DayKeyResolver(policy: try DayBoundaryPolicy(dayStartHour: hour, timeZoneIdentifier: zone))
    }

    // MARK: - Anchoring

    @Test("the epoch is day zero in UTC")
    func epochIsDayZero() throws {
        let resolver = try resolver(zone: "UTC")
        let day = try resolver.dayIndex(for: instant("1970-01-01T00:00:00Z"))
        #expect(day == DayIndex(rawValue: 0))
    }

    @Test("a day later is one index later")
    func consecutiveDays() throws {
        let resolver = try resolver(zone: "UTC")
        let first = try resolver.dayIndex(for: instant("2026-08-09T09:00:00Z"))
        let second = try resolver.dayIndex(for: instant("2026-08-10T09:00:00Z"))
        #expect(first.days(to: second) == 1)
    }

    // MARK: - Day-start hour

    @Test("a 1am entry belongs to the previous day under a 4am boundary")
    func lateNightEntryBelongsToPreviousDay() throws {
        // The lifter case from the brief: a meal at 01:00 Wednesday is part of
        // Tuesday's log, not the start of Wednesday's.
        let midnight = try resolver(hour: 0, zone: "Australia/Sydney")
        let fourAM = try resolver(hour: 4, zone: "Australia/Sydney")

        let lateNight = try instant("2026-08-12T01:00:00+10:00")

        let underMidnight = try midnight.dayIndex(for: lateNight)
        let underFourAM = try fourAM.dayIndex(for: lateNight)

        #expect(underFourAM.days(to: underMidnight) == 1, "the 4am boundary should pull this back a day")
    }

    @Test("a 9am entry is unaffected by a 4am boundary")
    func morningEntryUnaffected() throws {
        let midnight = try resolver(hour: 0, zone: "Australia/Sydney")
        let fourAM = try resolver(hour: 4, zone: "Australia/Sydney")
        let morning = try instant("2026-08-12T09:00:00+10:00")

        #expect(try midnight.dayIndex(for: morning) == (try fourAM.dayIndex(for: morning)))
    }

    @Test("a day-start hour at or after midday is rejected", arguments: [12, 13, 23, -1])
    func invalidDayStartHourThrows(hour: Int) {
        #expect(throws: DayBoundaryError.self) {
            try DayBoundaryPolicy(dayStartHour: hour, timeZoneIdentifier: "UTC")
        }
    }

    @Test("an unknown time zone identifier is an error, not a GMT fallback")
    func unknownTimeZoneThrows() {
        #expect(throws: DayBoundaryError.unknownTimeZone("Mars/Olympus_Mons")) {
            try DayBoundaryPolicy(dayStartHour: 0, timeZoneIdentifier: "Mars/Olympus_Mons")
        }
    }

    // MARK: - Daylight saving

    @Test("days remain one index apart across a spring-forward transition")
    func springForwardIsNotAnOffByOne() throws {
        // America/Los_Angeles, 2026-03-08: 02:00 jumps to 03:00, so this local
        // day is 23 hours long. Any implementation that divides elapsed seconds
        // by 86400 breaks here.
        let resolver = try resolver(zone: "America/Los_Angeles")
        let before = try resolver.dayIndex(for: instant("2026-03-07T12:00:00-08:00"))
        let during = try resolver.dayIndex(for: instant("2026-03-08T12:00:00-07:00"))
        let after = try resolver.dayIndex(for: instant("2026-03-09T12:00:00-07:00"))

        #expect(before.days(to: during) == 1)
        #expect(during.days(to: after) == 1)
    }

    @Test("days remain one index apart across a fall-back transition")
    func fallBackIsNotAnOffByOne() throws {
        // 2026-11-01 in America/Los_Angeles is 25 hours long.
        let resolver = try resolver(zone: "America/Los_Angeles")
        let before = try resolver.dayIndex(for: instant("2026-10-31T12:00:00-07:00"))
        let during = try resolver.dayIndex(for: instant("2026-11-01T12:00:00-08:00"))
        let after = try resolver.dayIndex(for: instant("2026-11-02T12:00:00-08:00"))

        #expect(before.days(to: during) == 1)
        #expect(during.days(to: after) == 1)
    }

    @Test("a year of local noons increments by exactly one day each time")
    func aYearOfNoonsIsStrictlyMonotonic() throws {
        // The broad sweep. Two DST transitions, twelve month boundaries and a
        // leap-year edge all fall inside this range; if the resolver is wrong
        // anywhere in it, this fails with the offending date.
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let resolver = try resolver(zone: "America/Los_Angeles")
        var current = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))
        )
        var previousIndex = try resolver.dayIndex(for: current)

        for _ in 0..<400 {
            current = try #require(calendar.date(byAdding: .day, value: 1, to: current))
            let index = try resolver.dayIndex(for: current)
            #expect(previousIndex.days(to: index) == 1, "broke at \(current)")
            previousIndex = index
        }
    }

    // MARK: - Travel

    @Test("the same instant resolves differently either side of the date line")
    func travellerSeesDifferentLocalDays() throws {
        // 2026-08-09 18:00 in Los Angeles is already 2026-08-10 in Tokyo. The
        // day a user experienced is the one their entry belongs to, which is why
        // resolution happens at write time in the zone they were standing in and
        // is then frozen.
        let losAngeles = try resolver(zone: "America/Los_Angeles")
        let tokyo = try resolver(zone: "Asia/Tokyo")
        let moment = try instant("2026-08-09T18:00:00-07:00")

        let laDay = try losAngeles.dayIndex(for: moment)
        let tokyoDay = try tokyo.dayIndex(for: moment)

        #expect(laDay.days(to: tokyoDay) == 1)
    }

    @Test("zones west of GMT still anchor the epoch consistently")
    func negativeOffsetZonesAnchorConsistently() throws {
        // 1970-01-01T00:00Z is 1969-12-31 in Los Angeles, so the epoch instant
        // must resolve to day -1 there. A resolver that anchored on the UTC epoch
        // rather than the local one would return 0 and put every subsequent day
        // off by one for that user.
        let resolver = try resolver(zone: "America/Los_Angeles")
        #expect(try resolver.dayIndex(for: instant("1970-01-01T00:00:00Z")) == DayIndex(rawValue: -1))
    }
}
