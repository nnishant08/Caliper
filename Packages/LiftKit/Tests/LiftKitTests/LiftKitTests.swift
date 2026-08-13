import Testing
@testable import LiftKit

@Suite("LiftKit")
struct LiftKitModuleTests {

    /// A placeholder until M6. Its only job is to keep the target in the CI
    /// graph, so that the day the lift log is written the harness already exists.
    @Test("the module builds and links")
    func moduleLinks() {
        #expect(LiftKit.moduleName == "LiftKit")
    }
}
