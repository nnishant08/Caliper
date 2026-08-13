/// Named physiological and policy constants used by the trend, expenditure and
/// target-issuance maths.
///
/// Every number the engine relies on lives here rather than inline, so that a
/// reviewer can audit the entire set of assumptions in one screen and so that
/// tuning one never requires grepping for a float literal.
public enum PhysiologyConstants {

    // MARK: - Tissue energy

    /// Kilocalories per kilogram of body tissue change.
    ///
    /// The conventional figure, from the assumption that a kilogram of adipose
    /// tissue carries roughly 7700 kcal. It is an approximation: real tissue
    /// change during a cut is a mix of fat, lean mass, glycogen and the water
    /// bound to it, and the true coefficient drifts with the composition of the
    /// change. We accept the approximation because the weight *trend*, not the
    /// raw scale reading, is what feeds it — the smoothing absorbs most of the
    /// water noise that would otherwise make this constant's error visible.
    ///
    /// Do not replace this with a "more accurate" per-user coefficient without
    /// evidence. A tunable here is a tunable that can be wrong in a direction
    /// the user cannot audit.
    public static let kilocaloriesPerKilogramOfTissue: Double = 7700

    // MARK: - Weight trend

    /// Smoothing factor for the exponentially weighted moving average of scale weight.
    ///
    /// At 0.1 a single weigh-in contributes 10% of its deviation to the trend,
    /// giving a half-life of roughly 6.6 days — slow enough to absorb a salt-and-
    /// carbohydrate water spike, fast enough that a genuine whoosh shows up
    /// inside a week.
    public static let trendSmoothingAlpha: Double = 0.1

    // MARK: - Expenditure window

    /// Default rolling window, in days, for the expenditure estimate.
    public static let defaultExpenditureWindowDays: Int = 14

    /// Extended rolling window, in days, used once enough history exists.
    public static let extendedExpenditureWindowDays: Int = 28

    /// Days of data below which the observed estimate is treated as unstable and
    /// the Mifflin–St Jeor prior dominates.
    public static let unstableEstimateThresholdDays: Int = 10

    /// Days of data at which the estimate is considered fully observed and the
    /// prior's weight has decayed to zero.
    ///
    /// Three to four weeks, per the brief. The shrinkage between
    /// `unstableEstimateThresholdDays` and here is what stops a new user seeing
    /// a number that swings by hundreds of kilocalories a day.
    public static let fullyObservedThresholdDays: Int = 28

    // MARK: - Target safety clamps

    /// The deficit is never allowed to exceed this fraction of estimated expenditure.
    public static let maximumDeficitFractionOfExpenditure: Double = 0.25

    /// Target intake is never allowed below this multiple of estimated BMR.
    public static let minimumIntakeAsMultipleOfBasalRate: Double = 1.1

    // MARK: - Macronutrient policy

    /// Protein target range, grams per kilogram of goal bodyweight.
    public static let proteinGramsPerKilogramRange: ClosedRange<Double> = 1.8...2.2

    /// Fat floor, grams per kilogram of goal bodyweight.
    public static let fatGramsPerKilogramFloor: Double = 0.6

    // MARK: - Energy density

    /// Kilocalories per gram, by macronutrient. Atwater general factors.
    public static let kilocaloriesPerGramOfProtein: Double = 4
    public static let kilocaloriesPerGramOfCarbohydrate: Double = 4
    public static let kilocaloriesPerGramOfFat: Double = 9

    // MARK: - Data hygiene

    /// A day whose logged intake falls below this fraction of the issued target
    /// is treated as incompletely logged and excluded from the intake mean.
    ///
    /// The exclusion is never silent — see `Docs/DECISIONS.md`, ADR-0007. A day
    /// dropped without the user being told is worse than a day counted wrong,
    /// because only one of those two is something they can correct.
    public static let incompleteDayIntakeFractionThreshold: Double = 0.5
}
