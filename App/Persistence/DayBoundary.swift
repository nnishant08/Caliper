import Foundation
import NutritionKit

/// How a wall-clock instant is assigned to a logging day.
///
/// Two things make this non-trivial, and both were called out before any log
/// data exists, because retrofitting them afterwards is a migration:
///
/// - **Lifters log at 1am.** A 00:00 boundary puts the last meal of Tuesday
///   evening onto Wednesday, which corrupts both Tuesday's remaining-macros
///   readout and Wednesday's intake mean. `dayStartHour` moves the boundary.
/// - **People travel.** The same instant is a different local day depending on
///   where the user is standing. The resolved day is the one they experienced,
///   so resolution happens at write time, in the zone they were in.
struct DayBoundaryPolicy: Equatable, Sendable {

    /// The hour at which a new logging day begins, in the user's local zone.
    ///
    /// Constrained to 0...11: a boundary at or after midday would mean a single
    /// calendar date maps to two logging days, which no part of the trend or
    /// expenditure maths is prepared for.
    let dayStartHour: Int

    /// The zone the user is standing in.
    let timeZone: TimeZone

    static let defaultDayStartHour = 0
    static let permittedDayStartHours = 0...11

    init(dayStartHour: Int, timeZone: TimeZone) throws {
        guard Self.permittedDayStartHours.contains(dayStartHour) else {
            throw DayBoundaryError.dayStartHourOutOfRange(dayStartHour)
        }
        self.dayStartHour = dayStartHour
        self.timeZone = timeZone
    }

    /// Rebuilds a policy from its persisted form.
    ///
    /// Fails loudly on an unknown zone identifier rather than falling back to
    /// GMT. A silent fallback would re-bucket a traveller's history by up to a
    /// day, and the resulting shift in the intake mean would be invisible.
    init(dayStartHour: Int, timeZoneIdentifier: String) throws {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw DayBoundaryError.unknownTimeZone(timeZoneIdentifier)
        }
        try self.init(dayStartHour: dayStartHour, timeZone: zone)
    }
}

enum DayBoundaryError: Error, Equatable {
    case dayStartHourOutOfRange(Int)
    case unknownTimeZone(String)
    case unresolvableInstant(Date)
    case unresolvableDay(Int)
    case unorderedBoundaryRecords
}

/// A proleptic Gregorian calendar date, with no zone and no time attached.
///
/// A named type rather than a tuple so that `year`, `month` and `day` cannot be
/// silently transposed at a call site.
struct CivilDate: Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int
}

/// Converts an instant into the `DayIndex` that NutritionKit's window arithmetic
/// operates on.
///
/// This is the *only* place in Caliper where `Calendar` meets the logging model.
/// NutritionKit has no access to `Calendar` or `TimeZone` at all, by design: its
/// test suite runs on Linux, where swift-corelibs-foundation's calendar
/// behaviour diverges from Darwin's. Keeping resolution here means the
/// expenditure engine cannot be green on Linux and wrong on device, because it
/// never performs calendar arithmetic in the first place. The macOS CI job then
/// covers this file specifically.
struct DayKeyResolver {

    private let calendar: Calendar
    private let dayStartHour: Int

    init(policy: DayBoundaryPolicy) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = policy.timeZone
        self.calendar = calendar
        self.dayStartHour = policy.dayStartHour
    }

    /// The logging day `instant` falls into under this policy.
    ///
    /// Throws rather than returning a best guess. A log entry with a wrong day
    /// key is worse than one that failed to save, because the user can see the
    /// second one happen.
    func dayIndex(for instant: Date) throws -> DayIndex {
        // Calendar's only job here is to answer "what local civil date and hour
        // was it?". Everything after that is integer arithmetic on a proleptic
        // Gregorian calendar.
        //
        // The anchor is deliberately the civil date 1970-01-01, not "the start
        // of the local day containing the Unix epoch". Anchoring on a local
        // instant looks equivalent and is not: the anchor would then move when
        // the user's time zone changes, shifting *every* index in their history
        // by a day the first time they flew east. Anchoring on the civil date
        // means a given `DayIndex` is the same calendar date everywhere, so a
        // traveller's series stays continuous and comparable.
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: instant)

        guard
            let year = components.year,
            let month = components.month,
            let day = components.day,
            let hour = components.hour
        else {
            throw DayBoundaryError.unresolvableInstant(instant)
        }

        var dayNumber = Self.daysFromCivil(year: year, month: month, day: day)

        // The boundary rule stated directly: an entry before the day-start hour
        // belongs to the previous date. Expressed as a comparison on the local
        // wall-clock hour rather than by subtracting hours from the instant,
        // because the subtraction approach is ambiguous across a DST transition
        // — on a 23-hour day, "four hours earlier" is not "four wall-clock hours
        // earlier", and the two disagree about which date a 03:30 entry is in.
        if hour < dayStartHour {
            dayNumber -= 1
        }

        return DayIndex(rawValue: dayNumber)
    }

    /// The instant at which `day` begins under this policy.
    ///
    /// The inverse of `dayIndex(for:)`, and the basis of every duration
    /// question: a logging day is not 24 hours, it is whatever elapses between
    /// its own start and the next day's start under whatever policy was in force
    /// at each end. See `DaySeam`.
    func startInstant(of day: DayIndex) throws -> Date {
        let civil = Self.civilFromDays(day.rawValue)

        var components = DateComponents()
        components.year = civil.year
        components.month = civil.month
        components.day = civil.day
        components.hour = dayStartHour
        components.minute = 0
        components.second = 0

        // `date(from:)` resolves a wall-clock time that does not exist — a
        // day-start hour falling inside a spring-forward gap — to the first
        // instant after the gap. That is the behaviour we want: the day starts
        // when the clock reaches it.
        guard let instant = calendar.date(from: components) else {
            throw DayBoundaryError.unresolvableDay(day.rawValue)
        }
        return instant
    }

    /// Days from 1970-01-01 to the given proleptic Gregorian civil date.
    ///
    /// Howard Hinnant's `days_from_civil`, which is exact for the full range of
    /// `Int` and involves no date library at all. Used in preference to
    /// `Calendar.dateComponents(_:from:to:)` because it needs no reference
    /// `Date`, and therefore cannot acquire a dependency on the time zone the
    /// user happened to be in when the reference was constructed.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        // Shift the year so that March is month 0 and the leap day falls at the
        // end of the shifted year, which removes the leap-year special case.
        let shiftedYear = year - (month <= 2 ? 1 : 0)
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400                                  // [0, 399]
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1 // [0, 365]
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear

        // 719468 is the number of days from 0000-03-01 to 1970-01-01.
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The proleptic Gregorian civil date `days` after 1970-01-01.
    ///
    /// Hinnant's `civil_from_days`, the exact inverse of `daysFromCivil`.
    static func civilFromDays(_ days: Int) -> CivilDate {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097                                            // [0, 146096]
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)    // [0, 365]
        let shiftedMonth = (5 * dayOfYear + 2) / 153                                      // [0, 11]
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1                            // [1, 31]
        let month = shiftedMonth + (shiftedMonth < 10 ? 3 : -9)                           // [1, 12]

        return CivilDate(year: year + (month <= 2 ? 1 : 0), month: month, day: day)
    }
}
