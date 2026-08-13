import Foundation
import Testing
@testable import NutritionKit

@Suite("DayIndex")
struct DayIndexTests {

    @Test("advancing forwards and backwards is symmetric")
    func advanceIsSymmetric() {
        let day = DayIndex(rawValue: 20_000)
        #expect(day.advanced(by: 7).advanced(by: -7) == day)
        #expect(day.advanced(by: 0) == day)
    }

    @Test("days(to:) is signed and antisymmetric")
    func daysToIsSigned() {
        let earlier = DayIndex(rawValue: 100)
        let later = DayIndex(rawValue: 114)
        #expect(earlier.days(to: later) == 14)
        #expect(later.days(to: earlier) == -14)
        #expect(earlier.days(to: earlier) == 0)
    }

    @Test("ordering follows the underlying day count")
    func ordering() {
        #expect(DayIndex(rawValue: 1) < DayIndex(rawValue: 2))
        #expect(!(DayIndex(rawValue: 2) < DayIndex(rawValue: 2)))
        #expect(max(DayIndex(rawValue: 5), DayIndex(rawValue: 3)) == DayIndex(rawValue: 5))
    }

    @Test("a window of length n ends on the receiver and spans n days")
    func windowSpansInclusiveRange() throws {
        let today = DayIndex(rawValue: 20_000)
        let window = try #require(today.window(length: 14))

        #expect(window.upperBound == today)
        #expect(window.lowerBound == DayIndex(rawValue: 19_987))
        #expect(window.count == 14)
    }

    @Test("a single-day window contains only the receiver")
    func singleDayWindow() throws {
        let today = DayIndex(rawValue: 42)
        let window = try #require(today.window(length: 1))

        #expect(window.lowerBound == today)
        #expect(window.upperBound == today)
        #expect(window.count == 1)
    }

    @Test("a non-positive window length yields nil rather than trapping", arguments: [0, -1, -14])
    func nonPositiveWindowIsNil(length: Int) {
        #expect(DayIndex(rawValue: 20_000).window(length: length) == nil)
    }

    @Test("Strideable lets a window be iterated as a sequence of days")
    func windowIsIterable() throws {
        let window = try #require(DayIndex(rawValue: 10).window(length: 3))
        #expect(Array(window).map(\.rawValue) == [8, 9, 10])
    }

    @Test("day indices survive a Codable round trip")
    func codableRoundTrip() throws {
        // Persisted on every log entry, so a representation change is a migration.
        let original = DayIndex(rawValue: -3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DayIndex.self, from: data)
        #expect(decoded == original)
    }

    @Test("indices before the epoch are representable")
    func preEpochIsRepresentable() {
        // Not a real logging case, but the type must not quietly assume positivity:
        // a user can back-date an entry, and the trend decay subtracts freely.
        let preEpoch = DayIndex(rawValue: -1)
        #expect(preEpoch < DayIndex(rawValue: 0))
        #expect(preEpoch.days(to: DayIndex(rawValue: 0)) == 1)
    }
}
