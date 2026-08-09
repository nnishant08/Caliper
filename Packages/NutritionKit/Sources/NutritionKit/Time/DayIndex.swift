/// A calendar-independent identifier for a single logging day.
///
/// `rawValue` is the count of whole days since 1970-01-01 in the user's
/// *resolved local day space* — that is, after their configured day-start hour
/// and the time zone they were standing in have already been applied.
///
/// The resolution from a wall-clock instant to a `DayIndex` deliberately does
/// **not** live here. It lives in the app layer (`DayKeyResolver`), runs on
/// Darwin Foundation, and is persisted alongside every log entry. This package
/// never sees a `Date`, a `Calendar` or a `TimeZone`, which is what lets the
/// expenditure engine be tested identically on Linux and on device.
///
/// Consequences worth knowing before you use this type:
///
/// - Day indices are **dense but not necessarily contiguous in wall-clock
///   terms**. A user who flies Los Angeles → Tokyo skips a local day; a user who
///   flies the other way can experience two ~30-hour eating windows that resolve
///   to adjacent indices. Window arithmetic here stays correct because it counts
///   indices, not elapsed seconds — but any code that assumes "14 indices ==
///   14 × 86400 seconds" is wrong, and the trend decay is where that matters.
/// - A `DayIndex` is assigned once, at write time, and never recomputed. If the
///   user changes their day-start hour, history does not silently re-bucket
///   underneath a target that was already issued against it.
public struct DayIndex: Hashable, Sendable, Codable {

    /// Whole days since 1970-01-01 in the user's resolved local day space.
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The number of days from this day to `other`. Positive when `other` is later.
    ///
    /// Spelled out as well as satisfying `Strideable` because `days(to:)` reads
    /// unambiguously at call sites in the expenditure engine, where `distance`
    /// could plausibly be read as a mass or an energy.
    public func days(to other: DayIndex) -> Int {
        other.rawValue - rawValue
    }
}

extension DayIndex: Comparable {
    public static func < (lhs: DayIndex, rhs: DayIndex) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension DayIndex: Strideable {

    /// The day `offset` days after this one. Negative offsets move backwards.
    public func advanced(by offset: Int) -> DayIndex {
        DayIndex(rawValue: rawValue + offset)
    }

    public func distance(to other: DayIndex) -> Int {
        days(to: other)
    }
}

extension DayIndex: CustomStringConvertible {
    public var description: String {
        "day(\(rawValue))"
    }
}

extension DayIndex {

    /// The half-open window of `length` days ending on, and including, this day.
    ///
    /// `DayIndex(rawValue: 100).window(length: 3)` covers days 98, 99 and 100.
    /// Returns `nil` for a non-positive length rather than trapping, because the
    /// window length is a tunable constant that a future settings screen could
    /// plausibly feed a bad value into.
    public func window(length: Int) -> ClosedRange<DayIndex>? {
        guard length > 0 else { return nil }
        return advanced(by: -(length - 1))...self
    }
}
