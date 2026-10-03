// ============================================================
// TestFeatureSetNaming.swift
// AROParser — which feature sets are tests (ARO-0015 §1)
// ============================================================
//
// A feature set is a test when its business activity ends in `Test` or `Tests`.
// That one sentence decides three separate things, in three different modules:
//
//   * `ARORuntime.TestRunner` picks the feature sets `aro test` runs;
//   * `AROCLI.BuildCommand` strips them out of a shipped binary (§5.3);
//   * `AROCompiler.LLVMCodeGenerator` keeps them in, and drives them, when the
//     build is a test harness (`aro build --tests`, GitLab #694).
//
// The three had their own copies of the predicate. Stripping and harnessing are
// exact complements — a test the build strips but the harness lists would be a
// call to a function that was never emitted — so the rule lives in AROParser,
// the only module all three import.

/// Whether a business activity names a test feature set (ARO-0015 §1).
public enum TestFeatureSetNaming {
    public static func isTest(activity: String) -> Bool {
        activity.hasSuffix("Test") || activity.hasSuffix("Tests")
    }
}
