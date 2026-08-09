import Foundation
import SwiftData

/// Builds Caliper's SwiftData stack as **two stores with disjoint schemas**.
///
/// This is the mechanism that makes App Store Guideline 5.1.3 compliance
/// structural rather than a matter of remembering. HealthKit-derived records
/// live in a configuration with `cloudKitDatabase: .none` and physically cannot
/// reach iCloud; app-owned records live in the synced configuration.
///
/// Adding a model means adding it to exactly one of the two arrays below. Adding
/// a `LocalOnlyModel` to `syncedTypes` fails `ModelSeparationTests` in CI, which
/// is a great deal cheaper than discovering it in an App Review rejection.
enum CaliperModelContainer {

    /// App-owned records. Backed up to the user's own CloudKit private database.
    ///
    /// Nothing HealthKit-sourced belongs here. Ever.
    static let syncedTypes: [any PersistentModel.Type] = [
        UserSettings.self
    ]

    /// Device-local records. Never leave the device; re-derived from HealthKit
    /// on a new install.
    static let localOnlyTypes: [any PersistentModel.Type] = [
        HealthImportAnchor.self
    ]

    static var allTypes: [any PersistentModel.Type] {
        syncedTypes + localOnlyTypes
    }

    /// - Parameter cloudKitEnabled: whether the synced store attaches to CloudKit.
    ///   Defaults to `false` until the iCloud entitlement is provisioned — a
    ///   container asking for `.automatic` without the entitlement fails at
    ///   initialisation, which would make the app unlaunchable on a machine
    ///   without a signing team. Flipping this on is a one-line change once the
    ///   Apple Developer Program membership and CloudKit container exist.
    /// - Parameter inMemory: for tests.
    static func make(cloudKitEnabled: Bool = false, inMemory: Bool = false) throws -> ModelContainer {
        let synced: ModelConfiguration
        let local: ModelConfiguration

        if inMemory {
            // CloudKit is never attached to an in-memory store: there is nothing
            // to sync, and asking for it would make the test suite depend on an
            // entitlement.
            synced = ModelConfiguration(
                "Synced",
                schema: Schema(syncedTypes),
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            local = ModelConfiguration(
                "Local",
                schema: Schema(localOnlyTypes),
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else {
            let directory = try storeDirectory()
            synced = ModelConfiguration(
                "Synced",
                schema: Schema(syncedTypes),
                url: directory.appending(path: "Synced.store"),
                cloudKitDatabase: cloudKitEnabled ? .automatic : .none
            )
            local = ModelConfiguration(
                "Local",
                schema: Schema(localOnlyTypes),
                url: directory.appending(path: "Local.store"),
                // Not a default, and not to be "tidied up" into one. This is the
                // 5.1.3 boundary. See LocalOnlyModel.swift.
                cloudKitDatabase: .none
            )
        }

        return try ModelContainer(
            for: Schema(allTypes),
            configurations: synced, local
        )
    }

    /// Where the two stores live.
    ///
    /// Named configurations do not get their containing directory created for
    /// them the way the default unnamed store does, and a fresh install has no
    /// Application Support directory — which surfaces as a wall of
    /// `Sandbox access to file-write-create denied` from Core Data at first
    /// launch. `create: true` is what prevents that.
    private static func storeDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}
