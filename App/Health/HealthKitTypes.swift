import HealthKit

/// The complete, declarative list of HealthKit types Caliper touches.
///
/// Declared as data rather than assembled at the call site so that the
/// permission request, the sync code and the tests all read from one list.
/// Guideline-wise this also keeps us honest about §8: we request exactly what
/// appears here, and over-requesting is a common rejection.
enum HealthKitTypes {

    // MARK: - Read

    /// Types Caliper reads.
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    /// `HKQuantityTypeIdentifier.activeEnergyBurned` IS DELIBERATELY ABSENT.
    ///
    /// Active energy must never enter the calorie budget. Not as a bonus, not
    /// behind a setting, not "just for display next to the target".
    ///
    /// The reason is not conservatism, it is double-counting. Caliper infers
    /// expenditure from the relationship between logged intake and the weight
    /// trend (see NutritionKit). Activity is *already inside that relationship*:
    /// a user who trains hard loses more weight at a given intake, and the
    /// estimate rises to meet it. Adding a wearable's active-energy figure on
    /// top credits the same exercise twice. That is the precise mechanism by
    /// which MyFitnessPal turns a 45-minute session worth ~260 kcal into a
    /// 520 kcal allowance, and it is the single most common way an adaptive
    /// calorie target silently stops working.
    ///
    /// `HealthKitTypeBoundaryTests` fails the build if this type is ever added.
    /// If you are reading this because that test just failed: the test is right.
    /// ─────────────────────────────────────────────────────────────────────────
    ///
    /// Workouts are read for *context* — the activity timeline shows that
    /// Tuesday's boxing class happened — and are explicitly labelled in the UI
    /// as not adjusting the target. Resting energy is read for the cold-start
    /// prior and for display, never as a budget input.
    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKQuantityType(.bodyMass),
            HKQuantityType(.stepCount),
            HKQuantityType(.heartRate),
            HKQuantityType(.basalEnergyBurned),
            HKObjectType.workoutType()
        ]
        types.insert(HKCategoryType(.sleepAnalysis))
        return types
    }

    /// Types explicitly forbidden from `readTypes`, enforced by test.
    ///
    /// A list rather than a single entry because the same double-counting
    /// argument applies to any pre-computed energy-expenditure figure a device
    /// hands us.
    static let forbiddenReadTypeIdentifiers: Set<String> = [
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
        HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
        HKQuantityTypeIdentifier.appleMoveTime.rawValue
    ]

    // MARK: - Write

    /// Types Caliper writes, so that Activity rings and other apps stay
    /// consistent with what the user logged here.
    static var writeTypes: Set<HKSampleType> {
        [
            HKQuantityType(.bodyMass),
            HKQuantityType(.dietaryEnergyConsumed),
            HKQuantityType(.dietaryProtein),
            HKQuantityType(.dietaryCarbohydrates),
            HKQuantityType(.dietaryFatTotal),
            HKQuantityType(.dietaryFiber),
            HKQuantityType(.dietarySugar),
            HKQuantityType(.dietarySodium),
            HKObjectType.workoutType()
        ]
    }
}
