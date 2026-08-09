import SwiftData
import Testing
@testable import Caliper

/// Guards the App Store Guideline 5.1.3 boundary: no HealthKit-derived record
/// may reach iCloud.
///
/// This suite is the reason `LocalOnlyModel` exists. A comment saying "don't put
/// HealthKit data in the synced store" is worth very little in six months; a red
/// CI job is worth a great deal.
@Suite("Model separation (Guideline 5.1.3)")
struct ModelSeparationTests {

    @Test("no local-only model appears in the synced schema")
    func syncedSchemaContainsNoLocalOnlyModels() {
        let offenders = CaliperModelContainer.syncedTypes.filter { type in
            type is any LocalOnlyModel.Type
        }

        #expect(
            offenders.isEmpty,
            """
            \(offenders) is marked LocalOnlyModel but sits in the synced store.
            HealthKit-derived data must not be stored in iCloud (Guideline 5.1.3).
            Move it to CaliperModelContainer.localOnlyTypes.
            """
        )
    }

    @Test("every model in the local-only store is marked as such")
    func localStoreContainsOnlyMarkedModels() {
        // The inverse direction matters too. An app-owned model quietly parked
        // in the local store would not sync, and the user would lose it on a new
        // device with no error anywhere.
        let unmarked = CaliperModelContainer.localOnlyTypes.filter { type in
            !(type is any LocalOnlyModel.Type)
        }

        #expect(
            unmarked.isEmpty,
            "\(unmarked) is in the local-only store but is not marked LocalOnlyModel."
        )
    }

    @Test("the two stores are disjoint")
    func storesAreDisjoint() {
        let syncedNames = Set(CaliperModelContainer.syncedTypes.map { String(describing: $0) })
        let localNames = Set(CaliperModelContainer.localOnlyTypes.map { String(describing: $0) })

        #expect(syncedNames.isDisjoint(with: localNames))
        #expect(syncedNames.count + localNames.count == CaliperModelContainer.allTypes.count)
    }

    @Test("both stores are non-empty, so the checks above are not vacuous")
    func storesAreNonEmpty() {
        #expect(!CaliperModelContainer.syncedTypes.isEmpty)
        #expect(!CaliperModelContainer.localOnlyTypes.isEmpty)
    }

    @Test("the container builds with CloudKit disabled")
    func containerBuildsLocally() throws {
        _ = try CaliperModelContainer.make(cloudKitEnabled: false, inMemory: true)
    }
}
