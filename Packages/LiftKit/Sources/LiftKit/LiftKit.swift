/// LiftKit — sets, reps, load, e1RM, volume, routines.
///
/// Deliberately empty at M0. The lift log is built at M6; this package exists
/// from the start only to fix the module boundary in place before there is any
/// code to entangle. See `Package.swift` for why that boundary matters.
///
/// When M6 begins, the same two rules that govern NutritionKit apply here: no
/// UIKit, no SwiftUI, no HealthKit, and no `Calendar`/`TimeZone` — a training
/// session belongs to a `DayIndex` resolved by the app, exactly like a meal does.
public enum LiftKit {

    /// Present so the module is not empty and the target is provably linkable in CI.
    public static let moduleName = "LiftKit"
}
