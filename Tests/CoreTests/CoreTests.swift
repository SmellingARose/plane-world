import Testing
@testable import PWCore

@Test func coreSelfTests() {
    CoreSelfTests.register()
    #expect(SelfTestRegistry.run("core"))
}
