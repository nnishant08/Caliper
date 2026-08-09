import Testing
@testable import NutritionKit

/// These are not tests of physiology — they are tests of *internal consistency*.
///
/// Every constant here is tunable, and the M4 engine will be tuned against the
/// synthetic users. The failure mode this suite guards is a tuning session that
/// leaves two constants contradicting each other: a window shorter than the
/// stability threshold, a smoothing factor outside the range where the recursion
/// converges, a clamp that can never bind. Each of those produces an engine that
/// still compiles and still returns numbers.
@Suite("PhysiologyConstants")
struct PhysiologyConstantsTests {

    @Test("the smoothing factor is a genuine interpolation weight")
    func smoothingAlphaIsInRange() {
        let alpha = PhysiologyConstants.trendSmoothingAlpha
        #expect(alpha > 0, "alpha of zero freezes the trend at its seed value")
        #expect(alpha < 1, "alpha of one makes the trend equal to raw scale weight")
    }

    @Test("the extended window is longer than the default window")
    func windowsAreOrdered() {
        #expect(
            PhysiologyConstants.extendedExpenditureWindowDays
                > PhysiologyConstants.defaultExpenditureWindowDays
        )
        #expect(PhysiologyConstants.defaultExpenditureWindowDays > 0)
    }

    @Test("the confidence ramp runs from unstable to fully observed")
    func confidenceThresholdsAreOrdered() {
        // If these ever cross, the shrinkage weight leaves [0, 1] and a new user
        // sees the prior extrapolated past the observation instead of blended
        // into it.
        #expect(
            PhysiologyConstants.unstableEstimateThresholdDays
                < PhysiologyConstants.fullyObservedThresholdDays
        )
    }

    @Test("the default window fits inside the confidence ramp")
    func defaultWindowIsUsableBeforeFullConfidence() {
        // The estimate has to be computable while the prior still dominates,
        // otherwise there is nothing to shrink *toward* during weeks two and three.
        #expect(
            PhysiologyConstants.defaultExpenditureWindowDays
                <= PhysiologyConstants.fullyObservedThresholdDays
        )
    }

    @Test("the safety clamps are capable of binding")
    func clampsAreMeaningful() {
        let deficitCap = PhysiologyConstants.maximumDeficitFractionOfExpenditure
        #expect(deficitCap > 0, "a cap of zero forbids any deficit at all")
        #expect(deficitCap < 1, "a cap of one permits a target intake of zero")

        #expect(
            PhysiologyConstants.minimumIntakeAsMultipleOfBasalRate >= 1,
            "a floor below BMR is not a floor"
        )
    }

    @Test("the protein range is ordered and the fat floor is positive")
    func macroPolicyIsCoherent() {
        let protein = PhysiologyConstants.proteinGramsPerKilogramRange
        #expect(protein.lowerBound > 0)
        #expect(protein.lowerBound < protein.upperBound)
        #expect(PhysiologyConstants.fatGramsPerKilogramFloor > 0)
    }

    @Test("the incomplete-day threshold is a fraction of a target, not a multiple")
    func incompleteDayThresholdIsAFraction() {
        let threshold = PhysiologyConstants.incompleteDayIntakeFractionThreshold
        #expect(threshold > 0, "a threshold of zero excludes nothing, including days with no entries")
        #expect(threshold < 1, "a threshold of one excludes every day the user is not exactly on target")
    }

    @Test("tissue energy density is expressed per kilogram, not per pound")
    func tissueConstantIsMetric() {
        // Guards the specific transcription error that would make every estimate
        // wrong by a factor of 2.2 while still looking like a plausible number.
        #expect(PhysiologyConstants.kilocaloriesPerKilogramOfTissue > 7000)
        #expect(PhysiologyConstants.kilocaloriesPerKilogramOfTissue < 8000)
    }

    @Test("Atwater factors are the conventional 4/4/9")
    func atwaterFactors() {
        #expect(PhysiologyConstants.kilocaloriesPerGramOfProtein == 4)
        #expect(PhysiologyConstants.kilocaloriesPerGramOfCarbohydrate == 4)
        #expect(PhysiologyConstants.kilocaloriesPerGramOfFat == 9)
    }
}
