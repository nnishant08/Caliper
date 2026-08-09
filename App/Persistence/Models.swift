import Foundation
import NutritionKit
import SwiftData

// The models below are the seed of the schema. They exist at M0 because the
// container split needs real members on both sides of the boundary for the
// separation test to be meaningful rather than vacuously true. All are models we
// keep — nothing here is a placeholder to be deleted later.
//
// Every synced property carries a default value. That is not style: SwiftData
// backed by CloudKit requires every attribute to be optional or defaulted, and
// forbids `#Unique` entirely, because uniqueness cannot be enforced across
// devices. Violating either fails at container initialisation, not at compile
// time, so it is worth stating in a comment next to the models it constrains.

/// User-owned settings. Syncs via the user's own CloudKit private database.
@Model
final class UserSettings {

    /// The hour at which the user's logging day begins. See `DayBoundaryPolicy`.
    var dayStartHour: Int = DayBoundaryPolicy.defaultDayStartHour

    /// The zone used to resolve day keys for entries written from this device.
    ///
    /// Stored as an identifier rather than a `TimeZone` because the zone
    /// database changes underneath us and an unresolvable identifier must be a
    /// visible error, not a silent GMT fallback.
    var timeZoneIdentifier: String = "UTC"

    /// When the day-start hour last changed.
    ///
    /// Day keys are resolved once, at write time, and never recomputed — a user
    /// who moves their boundary from midnight to 4am does not have last month's
    /// intake means shift underneath targets that were already issued against
    /// them. This timestamp is what lets Settings offer an explicit, auditable
    /// "re-bucket history" action instead of doing it silently.
    var dayStartHourChangedAt: Date?

    init(dayStartHour: Int = DayBoundaryPolicy.defaultDayStartHour, timeZoneIdentifier: String = "UTC") {
        self.dayStartHour = dayStartHour
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// An observation of the day-boundary policy in force on a particular logging day.
///
/// Written when a day is first opened — its first log entry, or the first app
/// launch that resolves into it — and only when the policy differs from the
/// previous observation, so this table stays tiny.
///
/// It exists because day length is not derivable from the log entries alone. A
/// day with no entries still has a duration, and the expenditure estimate
/// divides by real elapsed time rather than a count of day keys (see
/// `DayDurations`). Without a record of which zone and day-start hour applied,
/// a window containing a flight cannot be measured at all.
///
/// App-owned and therefore synced: a new device must be able to reconstruct the
/// durations behind estimates the user has already seen.
@Model
final class DayBoundaryRecord {

    /// The `DayIndex.rawValue` this observation applies from.
    var dayIndex: Int = 0

    var dayStartHour: Int = DayBoundaryPolicy.defaultDayStartHour

    var timeZoneIdentifier: String = "UTC"

    init(dayIndex: Int, dayStartHour: Int, timeZoneIdentifier: String) {
        self.dayIndex = dayIndex
        self.dayStartHour = dayStartHour
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    var snapshot: DayBoundarySnapshot {
        DayBoundarySnapshot(
            dayIndex: DayIndex(rawValue: dayIndex),
            dayStartHour: dayStartHour,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}

/// The persisted `HKAnchoredObjectQuery` anchor for one HealthKit sample type.
///
/// Local-only, for two reasons that happen to agree. Guideline 5.1.3 keeps
/// HealthKit-derived state off iCloud; and an anchor is meaningless on another
/// device anyway, since HealthKit anchors are not portable. A synced anchor
/// would cause a new device to skip every sample recorded before the sync.
@Model
final class HealthImportAnchor: LocalOnlyModel {

    #Unique<HealthImportAnchor>([\.sampleTypeIdentifier])

    /// The `HKSampleType` identifier this anchor belongs to.
    var sampleTypeIdentifier: String = ""

    /// The archived `HKQueryAnchor`.
    var anchorData: Data?

    var lastSyncedAt: Date?

    init(sampleTypeIdentifier: String) {
        self.sampleTypeIdentifier = sampleTypeIdentifier
    }
}
