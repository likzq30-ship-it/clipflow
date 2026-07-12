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

    func testSettingsWindowReceivesTheLiveClipboardStore() async {
        let coordinator = try! await AppCoordinator.performanceFixture()
        coordinator.start()
        await coordinator.waitForEnvironmentForTesting()

        coordinator.performSettingsMenuItemForTesting()

        let settingsStore = try! XCTUnwrap(coordinator.settingsStoreForTesting)
        let environmentStore = try! XCTUnwrap(coordinator.environmentStoreForTesting)
        XCTAssertTrue(settingsStore === environmentStore)

        settingsStore.pauseMonitoring(.indefinitely)
        XCTAssertEqual(environmentStore.monitoringPause, .indefinitely)

        settingsStore.resumeMonitoring()
        XCTAssertEqual(environmentStore.monitoringPause, .active)
    }

    func testLibraryShowsReadOnlyRecoveryBannerWithRevealAction() async {
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipflow.sqlite3.backup")
        let coordinator = try! await AppCoordinator.performanceFixture(
            startup: .readOnlyRecovery(
                databaseURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("clipflow.sqlite3"),
                backupURL: backupURL,
                errorCode: "SQLITE_READONLY"
            )
        )
        coordinator.start()
        await coordinator.waitForEnvironmentForTesting()

        coordinator.openLibrary(selectedID: nil)

        let presentation = try! XCTUnwrap(coordinator.libraryRecoveryPresentationForTesting)
        XCTAssertEqual(presentation.code, .databaseReadOnly)
        XCTAssertEqual(presentation.recoveryAction, .revealBackup(backupURL))
        XCTAssertTrue(coordinator.libraryRecoveryBannerIsUndismissableForTesting)
    }

    func testQuickPanelReadyProbeWaitsForPopoverAndViewReadiness() async {
        let coordinator = try! await AppCoordinator.performanceFixture()
        coordinator.beginQuickPanelReadyProbeForTesting()

        coordinator.markQuickPanelViewReadyForTesting()
        XCTAssertTrue(coordinator.hasPendingQuickPanelReadyProbeForTesting)

        coordinator.markQuickPanelPopoverShownForTesting()
        XCTAssertFalse(coordinator.hasPendingQuickPanelReadyProbeForTesting)
    }
}
