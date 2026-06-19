import XCTest
@testable import CycleJames

final class ReviewPromptTests: XCTestCase {
    func test_doesNotPromptOnFirstTwoRides() {
        XCTAssertFalse(ReviewPrompt.shouldRequest(afterCompletedCount: 1))
        XCTAssertFalse(ReviewPrompt.shouldRequest(afterCompletedCount: 2))
    }
    func test_promptsFromThirdRideOnward() {
        XCTAssertTrue(ReviewPrompt.shouldRequest(afterCompletedCount: 3))
        XCTAssertTrue(ReviewPrompt.shouldRequest(afterCompletedCount: 7))
    }
}
