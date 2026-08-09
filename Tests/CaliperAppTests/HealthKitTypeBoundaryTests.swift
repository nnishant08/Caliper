import HealthKit
import Testing
@testable import Caliper

/// The §4 negative requirement, made mechanical.
///
/// "Never read active energy into the calorie budget" is the kind of rule that
/// survives exactly as long as the person who wrote it remembers why. This suite
/// is how it survives longer.
@Suite("HealthKit type boundary")
struct HealthKitTypeBoundaryTests {

    @Test("active energy is never requested for reading")
    func activeEnergyIsNotRead() {
        let requested = Set(HealthKitTypes.readTypes.map(\.identifier))
        let forbidden = HealthKitTypes.forbiddenReadTypeIdentifiers
        let violations = requested.intersection(forbidden)

        #expect(
            violations.isEmpty,
            """
            \(violations) was added to HealthKitTypes.readTypes.

            Caliper infers expenditure from intake versus weight trend. Activity
            is already captured in that relationship. Reading a device's
            active-energy figure back in double-counts every workout — the exact
            failure that makes MyFitnessPal report ~520 kcal for a session worth
            ~260. If a feature genuinely needs this data for display only, it
            still does not belong in this set; add a separate, clearly named set
            that the budget code cannot see.
            """
        )
    }

    @Test("resting energy is read, and is not confused with active energy")
    func restingEnergyIsRead() {
        // Basal energy is legitimate: it feeds the cold-start prior and the
        // display, not the budget. Asserting it stays present stops a future
        // over-correction from stripping both.
        let requested = Set(HealthKitTypes.readTypes.map(\.identifier))
        #expect(requested.contains(HKQuantityTypeIdentifier.basalEnergyBurned.rawValue))
    }

    @Test("the read set is limited to types the app actually uses")
    func readSetIsMinimal() {
        // Guideline 5.1.1 / §8: over-requesting HealthKit permissions is a
        // common rejection. Body mass, workouts, steps, sleep, heart rate,
        // resting energy — six, per the brief.
        #expect(HealthKitTypes.readTypes.count == 6)
    }

    @Test("dietary writes cover the macros the app logs")
    func writeSetCoversMacros() {
        let written = Set(HealthKitTypes.writeTypes.map(\.identifier))
        let required = [
            HKQuantityTypeIdentifier.dietaryEnergyConsumed,
            .dietaryProtein,
            .dietaryCarbohydrates,
            .dietaryFatTotal
        ].map(\.rawValue)

        for identifier in required {
            #expect(written.contains(identifier), "missing write type \(identifier)")
        }
    }

    @Test("body mass is both read and written")
    func bodyMassIsBidirectional() {
        // Bidirectional by design, which is also why M5's importer must filter
        // out samples whose source is Caliper itself — otherwise our own writes
        // return through the anchored query and duplicate the weigh-in series.
        let read = Set(HealthKitTypes.readTypes.map(\.identifier))
        let written = Set(HealthKitTypes.writeTypes.map(\.identifier))
        let bodyMass = HKQuantityTypeIdentifier.bodyMass.rawValue

        #expect(read.contains(bodyMass))
        #expect(written.contains(bodyMass))
    }
}
