import XCTest
@testable import CycleJames

final class SmokeTests: XCTestCase {
    func test_targetCompilesAndImports() {
        XCTAssertEqual(AppSettings.defaultFTP, 200)
    }
}
