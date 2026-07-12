import AppKit
import SwiftUI

enum QuickPanelCommand: Equatable {
    case moveUp
    case moveDown
    case copySelection
    case openSelectionInLibrary
    case toggleFavorite
    case deleteSelection
    case focusSearch
    case escape
}

@MainActor
final class QuickPanelCommandHandler {
    let store: ClipboardStore
    private weak var coordinator: (any QuickPanelCoordinating)?
    var focusSearch: () -> Void = {}
    var focusList: () -> Void = {}

    init(
        store: ClipboardStore,
        coordinator: any QuickPanelCoordinating,
        focusSearch: @escaping () -> Void = {},
        focusList: @escaping () -> Void = {}
    ) {
        self.store = store
        self.coordinator = coordinator
        self.focusSearch = focusSearch
        self.focusList = focusList
    }

    func handle(_ command: QuickPanelCommand) async {
        switch command {
        case .moveUp:
            focusList()
            moveSelection(by: -1)
        case .moveDown:
            focusList()
            moveSelection(by: 1)
        case .copySelection:
            await copySelection()
        case .openSelectionInLibrary:
            coordinator?.openLibrary(selectedID: selectedVisibleID())
        case .toggleFavorite:
            guard let id = selectedVisibleID() else { return }
            await store.toggleFavorite(id: id)
        case .deleteSelection:
            guard let id = selectedVisibleID() else { return }
            await store.delete(id: id)
        case .focusSearch:
            focusSearch()
        case .escape:
            await escape()
        }
    }
}

private extension QuickPanelCommandHandler {
    func selectedVisibleID() -> UUID? {
        let session = store.session(for: .quickPanel)
        guard let selectedID = session.selectedItemID,
              session.items.contains(where: { $0.id == selectedID }) else {
            return session.items.first?.id
        }
        return selectedID
    }

    func moveSelection(by delta: Int) {
        let session = store.session(for: .quickPanel)
        guard !session.items.isEmpty else {
            store.setSelection(nil, for: .quickPanel)
            return
        }

        guard let selectedID = session.selectedItemID,
              let currentIndex = session.items.firstIndex(where: { $0.id == selectedID }) else {
            store.setSelection(session.items.first?.id, for: .quickPanel)
            return
        }

        let nextIndex = min(max(currentIndex + delta, 0), session.items.count - 1)
        store.setSelection(session.items[nextIndex].id, for: .quickPanel)
    }

    func copySelection() async {
        guard let id = selectedVisibleID() else { return }
        let outcome = await store.copy(id: id, recoverySurface: .quickPanel)
        switch outcome {
        case .copied, .copiedWithMetadataWarning:
            coordinator?.closeQuickPanel()
            coordinator?.showCopyFeedback(outcome)
        case .clipboardWriteFailed:
            break
        }
    }

    func escape() async {
        let session = store.session(for: .quickPanel)
        if !session.query.searchText.isEmpty {
            await store.updateQuery(
                .quickPanel(
                    searchText: "",
                    favoritesOnly: session.query.scope == .favorites
                ),
                for: .quickPanel
            )
            return
        }
        coordinator?.closeQuickPanel()
    }
}

struct QuickPanelKeyboardBridge: NSViewRepresentable {
    let onCommand: (QuickPanelCommand) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommand: onCommand)
    }

    func makeNSView(context: Context) -> KeyboardView {
        let view = KeyboardView(onCommand: onCommand)
        context.coordinator.installIfNeeded(for: view)
        return view
    }

    func updateNSView(_ nsView: KeyboardView, context: Context) {
        nsView.onCommand = onCommand
        context.coordinator.onCommand = onCommand
    }

    static func dismantleNSView(_ nsView: KeyboardView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var onCommand: (QuickPanelCommand) -> Void
        private weak var view: KeyboardView?
        private var monitor: Any?

        init(onCommand: @escaping (QuickPanelCommand) -> Void) {
            self.onCommand = onCommand
        }

        func installIfNeeded(for view: KeyboardView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let view = self.view,
                      view.window != nil,
                      view.window == NSApp.keyWindow,
                      let command = Self.command(for: event) else {
                    return event
                }
                if Self.shouldLetTextInputHandle(event) {
                    return event
                }
                self.onCommand(command)
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private static func shouldLetTextInputHandle(_ event: NSEvent) -> Bool {
            guard NSApp.keyWindow?.firstResponder is NSTextView else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let noCommandModifier = !flags.contains(.command)
            return noCommandModifier && (event.keyCode == 51 || event.keyCode == 117)
        }

        fileprivate static func command(for event: NSEvent) -> QuickPanelCommand? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasCommand = flags.contains(.command)
            let hasShift = flags.contains(.shift)
            switch event.keyCode {
            case 126:
                return .moveUp
            case 125:
                return .moveDown
            case 36:
                return hasCommand ? .openSelectionInLibrary : .copySelection
            case 3:
                return hasCommand && hasShift ? .moveDown : (hasCommand ? .focusSearch : nil)
            case 51, 117:
                return .deleteSelection
            case 53:
                return .escape
            default:
                return nil
            }
        }
    }

    final class KeyboardView: NSView {
        var onCommand: (QuickPanelCommand) -> Void

        init(onCommand: @escaping (QuickPanelCommand) -> Void) {
            self.onCommand = onCommand
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if let command = Coordinator.command(for: event) {
                onCommand(command)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
