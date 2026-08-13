import SwiftData

/// Marks a model that must **never** reach iCloud.
///
/// App Store Review Guideline 5.1.3 forbids storing HealthKit-sourced data in
/// iCloud. Caliper's CloudKit backup therefore carries only records the app
/// itself owns — logged foods, user foods, lift sets, settings — while anything
/// read out of HealthKit stays on the device and is re-read from HealthKit on a
/// new device.
///
/// Conforming to this protocol is not what enforces the rule. What enforces it
/// is `CaliperModelContainer`, which keeps local-only types in a
/// `ModelConfiguration` with `cloudKitDatabase: .none`, and
/// `ModelSeparationTests`, which fails the build if a `LocalOnlyModel` ever
/// appears in the synced schema. The protocol exists so that check has something
/// unambiguous to test against.
///
/// A second, quieter reason this split is load-bearing: SwiftData forbids
/// `#Unique` and `@Attribute(.unique)` on CloudKit-backed stores, because
/// uniqueness cannot be enforced across devices. The HealthKit sync in M5 needs
/// exactly that constraint to dedupe on sample UUID. Because HealthKit records
/// are local-only anyway, the compliance requirement and the technical
/// constraint point the same way — local-only models get real uniqueness, synced
/// models get explicit fetch-before-insert.
protocol LocalOnlyModel: PersistentModel {}
