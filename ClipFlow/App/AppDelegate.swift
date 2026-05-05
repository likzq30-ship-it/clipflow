import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var settingsWindow: NSWindow?
    var clipboardMonitor: ClipboardMonitor?
    var ollamaService: OllamaService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupMainMenu()
        setupStatusItem()
        setupHotkey()
        setupServices()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        appMenu.addItem(NSMenuItem(title: "关于 ClipFlow", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "退出 ClipFlow", action: #selector(quitApp), keyEquivalent: "q"))

        NSApplication.shared.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipFlow")
            image?.isTemplate = true
            button.image = image
            button.title = ""
        }

        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePopover)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupServices() {
        clipboardMonitor = ClipboardMonitor.shared
        ollamaService = OllamaService.shared
    }

    private func setupHotkey() {
        let hotkeyService = HotkeyService.shared
        hotkeyService.onHotkeyPressed = { [weak self] in
            self?.togglePopoverFromHotkey()
        }
    }

    private func togglePopoverFromHotkey() {
        if let popover = popover {
            if popover.isShown {
                closePopover()
            } else {
                showPopover()
            }
        } else {
            createAndShowPopover()
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton?) {
        let event = NSApp.currentEvent

        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            if let popover = popover {
                if popover.isShown {
                    closePopover()
                } else {
                    showPopover()
                }
            } else {
                createAndShowPopover()
            }
        }
    }

    private func createAndShowPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 750, height: 520)
        popover?.behavior = .transient
        popover?.animates = true

        let contentView = ContentView(
            clipboardMonitor: ClipboardMonitor.shared,
            ollamaService: OllamaService.shared
        )

        popover?.contentViewController = NSHostingController(rootView: contentView)
        showPopover()
    }

    private func showPopover() {
        if popover == nil {
            createAndShowPopover()
            return
        }

        if let button = statusItem?.button {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "设置", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func openSettingsWindow() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipFlow 设置"
        window.center()
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                hotkeyService: HotkeyService.shared,
                ollamaService: OllamaService.shared,
                isOpen: Binding(
                    get: { false },
                    set: { _ in window.close() }
                )
            )
        )
        window.isReleasedWhenClosed = false
        window.delegate = WindowDelegate(onClose: { [weak self] in
            self?.settingsWindow = nil
        })

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

class WindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
