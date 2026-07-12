import AppKit
import XCTest
@testable import ClipFlow

@MainActor
final class AppCoordinatorAccessibilityTests: XCTestCase {
    func testStatusButtonExposesClipFlowAccessibilityContract() async {
        let coordinator = try! await AppCoordinator.performanceFixture()
        coordinator.start()

        let button = try! XCTUnwrap(coordinator.statusButtonForTesting)
        XCTAssertEqual(button.accessibilityLabel(), "ClipFlow")
        XCTAssertEqual(button.accessibilityHelp(), "Open ClipFlow clipboard history")
        XCTAssertEqual(button.accessibilityValue() as? String, "active")
    }

    func testLeftClickAndHotkeyToggleTheSameQuickPanelPopover() async {
        let coordinator = try! await AppCoordinator.performanceFixture()
        coordinator.start()

        coordinator.simulateStatusButtonClickForTesting(type: .leftMouseUp)
        XCTAssertTrue(coordinator.isQuickPanelShownForTesting)

        coordinator.simulateGlobalHotkeyForTesting()
        XCTAssertFalse(coordinator.isQuickPanelShownForTesting)
    }

    func testRightClickBuildsStatusMenuWithoutShowingQuickPanel() async {
        let coordinator = try! await AppCoordinator.performanceFixture()
        coordinator.start()

        coordinator.simulateStatusButtonClickForTesting(type: .rightMouseUp)

        XCTAssertFalse(coordinator.isQuickPanelShownForTesting)
        XCTAssertEqual(
            coordinator.statusMenuTitlesForTesting,
            ["Open History", "Settings", "Pause Monitoring", "About ClipFlow", "Quit ClipFlow"]
        )
    }

    func testMainMenuOwnsSettingsAndQuitShortcuts() async {
        let coordinator = try! await AppCoordinator.performanceFixture()
        coordinator.start()

        let appMenu = try! XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let shortcuts = Dictionary(uniqueKeysWithValues: appMenu.items.filter {
            !$0.isSeparatorItem
        }.map {
            ($0.title, $0.keyEquivalent)
        })

        XCTAssertEqual(shortcuts["Settings…"], ",")
        XCTAssertEqual(shortcuts["Quit ClipFlow"], "q")
    }

    func testSettingsAndQuitMenuItemsRouteThroughCoordinatorActions() async {
        let coordinator = try! await AppCoordinator.performanceFixture()
        coordinator.start()

        coordinator.performSettingsMenuItemForTesting()
        XCTAssertEqual(coordinator.openSettingsCountForTesting, 1)

        coordinator.performQuitMenuItemForTesting()
        XCTAssertEqual(coordinator.quitRequestCountForTesting, 1)
    }
}
