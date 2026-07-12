import XCTest
@testable import ClipFlow

@MainActor
final class QuickPanelPerformanceTests: XCTestCase {
    func testWarmQuickPanelPresentationP95() async throws {
        let coordinator = try await AppCoordinator.performanceFixture()
        coordinator.start()
        await coordinator.waitForEnvironmentForTesting()
        await coordinator.presentQuickPanelAndWaitUntilReadyForTesting()
        coordinator.closeQuickPanelForTesting()

        let durations = await measureMainActorDurations(iterations: 20) {
            await coordinator.presentQuickPanelAndWaitUntilReadyForTesting()
            coordinator.closeQuickPanelForTesting()
        }

        XCTAssertLessThan(percentile95(durations), 0.200)
    }
}
