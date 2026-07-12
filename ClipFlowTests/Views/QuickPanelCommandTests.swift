import XCTest
@testable import ClipFlow

@MainActor
final class QuickPanelCommandTests: XCTestCase {
    func testReturnCopiesSelectionAndRequestsClose() async {
        let harness = await QuickPanelHarness.make(contents: ["one", "two"])
        harness.store.setSelection(harness.items[1].id, for: .quickPanel)

        await harness.handler.handle(.copySelection)

        XCTAssertEqual(harness.pasteboard.writtenText, "two")
        XCTAssertEqual(harness.coordinator.closeCount, 1)
        XCTAssertEqual(harness.coordinator.copyFeedback, [.copied])
    }

    func testClipboardWriteFailureKeepsPanelOpenAndPublishesRetryableBanner() async {
        let harness = await QuickPanelHarness.make(contents: ["one"], pasteboardResult: false)
        harness.store.setSelection(harness.items[0].id, for: .quickPanel)

        await harness.handler.handle(.copySelection)

        XCTAssertEqual(harness.pasteboard.writtenText, "one")
        XCTAssertEqual(harness.coordinator.closeCount, 0)
        XCTAssertEqual(harness.coordinator.copyFeedback, [])
        XCTAssertEqual(harness.store.banner?.code, .clipboardWrite)
        XCTAssertEqual(harness.store.banner?.recoveryAction, .retry(surface: .quickPanel))
    }

    func testReadOnlyCopyClosesPanelAndShowsMetadataWarningFeedback() async {
        let harness = await QuickPanelHarness.make(
            contents: ["one"],
            startup: .readOnlyRecovery(
                databaseURL: URL(fileURLWithPath: "/tmp/clipflow.sqlite3"),
                backupURL: URL(fileURLWithPath: "/tmp/clipflow.sqlite3.backup"),
                errorCode: "readonly"
            )
        )
        harness.store.setSelection(harness.items[0].id, for: .quickPanel)

        await harness.handler.handle(.copySelection)

        XCTAssertEqual(harness.pasteboard.writtenText, "one")
        XCTAssertEqual(harness.coordinator.closeCount, 1)
        XCTAssertEqual(harness.coordinator.copyFeedback, [.copiedWithMetadataWarning])
        XCTAssertEqual(harness.store.banner?.code, .databaseReadOnly)
    }

    func testEscapeClearsSearchBeforeClosing() async {
        let harness = await QuickPanelHarness.make(contents: ["one"])
        await harness.store.updateQuery(
            .quickPanel(searchText: "query", favoritesOnly: false),
            for: .quickPanel
        )

        await harness.handler.handle(.escape)
        XCTAssertEqual(harness.store.session(for: .quickPanel).query.searchText, "")
        XCTAssertEqual(harness.coordinator.closeCount, 0)

        await harness.handler.handle(.escape)
        XCTAssertEqual(harness.coordinator.closeCount, 1)
    }

    func testCommandReturnOpensSelectedItemInLibrary() async {
        let harness = await QuickPanelHarness.make(contents: ["one"])
        harness.store.setSelection(harness.items[0].id, for: .quickPanel)

        await harness.handler.handle(.openSelectionInLibrary)

        XCTAssertEqual(harness.coordinator.openedLibraryID, harness.items[0].id)
    }

    func testMoveCommandsRespectVisibleBoundaries() async {
        let harness = await QuickPanelHarness.make(contents: ["oldest", "middle", "newest"])
        XCTAssertEqual(harness.store.session(for: .quickPanel).selectedItemID, harness.items[2].id)

        await harness.handler.handle(.moveUp)
        XCTAssertEqual(harness.store.session(for: .quickPanel).selectedItemID, harness.items[2].id)

        await harness.handler.handle(.moveDown)
        XCTAssertEqual(harness.store.session(for: .quickPanel).selectedItemID, harness.items[1].id)

        await harness.handler.handle(.moveDown)
        XCTAssertEqual(harness.store.session(for: .quickPanel).selectedItemID, harness.items[0].id)

        await harness.handler.handle(.moveDown)
        XCTAssertEqual(harness.store.session(for: .quickPanel).selectedItemID, harness.items[0].id)
    }

    func testToggleFavoriteAndDeleteMutateSelectedVisibleItem() async {
        let harness = await QuickPanelHarness.make(contents: ["one", "two"])
        let selectedID = harness.items[1].id
        harness.store.setSelection(selectedID, for: .quickPanel)

        await harness.handler.handle(.toggleFavorite)
        XCTAssertTrue(harness.store.session(for: .quickPanel).items[0].isFavorite)

        await harness.handler.handle(.deleteSelection)
        let session = harness.store.session(for: .quickPanel)
        XCTAssertFalse(session.items.contains { $0.id == selectedID })
        XCTAssertNotNil(harness.store.pendingDeletes[selectedID])
    }

    func testCommandFFocusesSearchAndCommandShiftFFocusesList() async {
        let harness = await QuickPanelHarness.make(contents: ["one"])

        await harness.handler.handle(.focusSearch)
        XCTAssertEqual(harness.focusSearchCount, 1)
        XCTAssertEqual(harness.focusListCount, 0)

        await harness.handler.handle(.moveDown)
        XCTAssertEqual(harness.focusListCount, 1)
    }
}

@MainActor
private final class QuickPanelHarness {
    let repository: InMemoryRepository
    let pasteboard: FakePasteboardWriter
    let store: ClipboardStore
    let coordinator: RecordingQuickPanelCoordinator
    let handler: QuickPanelCommandHandler
    let items: [ClipboardItem]
    private(set) var focusSearchCount = 0
    private(set) var focusListCount = 0

    private init(
        repository: InMemoryRepository,
        pasteboard: FakePasteboardWriter,
        store: ClipboardStore,
        coordinator: RecordingQuickPanelCoordinator,
        handler: QuickPanelCommandHandler,
        items: [ClipboardItem]
    ) {
        self.repository = repository
        self.pasteboard = pasteboard
        self.store = store
        self.coordinator = coordinator
        self.handler = handler
        self.items = items
    }

    static func make(
        contents: [String],
        pasteboardResult: Bool = true,
        startup: RepositoryStartup = .readWrite(DatabasePreparation(
            schemaVersion: 2,
            searchMode: .parameterizedContains,
            recoveredCategories: [],
            backupURL: nil
        ))
    ) async -> QuickPanelHarness {
        let repository = InMemoryRepository()
        let pasteboard = FakePasteboardWriter(result: pasteboardResult)
        let store = makeStore(
            repository: repository,
            pasteboard: pasteboard,
            startup: startup,
            sleeper: ManualSleeper()
        )
        let baseDate = Date(timeIntervalSince1970: 100)
        var items: [ClipboardItem] = []
        for (index, content) in contents.enumerated() {
            let item = ClipboardItem(
                content: content,
                timestamp: baseDate.addingTimeInterval(TimeInterval(index))
            )
            await repository.seed(item)
            items.append(item)
        }
        await store.start()
        store.setSelection(store.session(for: .quickPanel).items.first?.id, for: .quickPanel)
        let coordinator = RecordingQuickPanelCoordinator()
        let handler = QuickPanelCommandHandler(store: store, coordinator: coordinator)
        let harness = QuickPanelHarness(
            repository: repository,
            pasteboard: pasteboard,
            store: store,
            coordinator: coordinator,
            handler: handler,
            items: items
        )
        handler.focusSearch = { harness.focusSearchCount += 1 }
        handler.focusList = { harness.focusListCount += 1 }
        return harness
    }
}

@MainActor
private final class RecordingQuickPanelCoordinator: QuickPanelCoordinating {
    private(set) var closeCount = 0
    private(set) var openedLibraryID: UUID?
    private(set) var settingsCount = 0
    private(set) var copyFeedback: [CopyOutcome] = []

    func closeQuickPanel() {
        closeCount += 1
    }

    func openLibrary(selectedID: UUID?) {
        openedLibraryID = selectedID
    }

    func openSettings() {
        settingsCount += 1
    }

    func showCopyFeedback(_ outcome: CopyOutcome) {
        copyFeedback.append(outcome)
    }
}
