import AppKit
import ApplicationServices
import Darwin
import HighlightCopyCore
import os

private var instanceLockFD: Int32 = -1

/// Menu-bar agent. Mouse clicks, trackpad clicks, tap-to-click, and three-finger drags all
/// arrive as left-mouse down, drag, and up, so one monitor covers both devices.
@main
enum HighlightCopyMain {
    static func main() {
        acquireInstanceLock()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = AppDelegate.shared
        app.run()
    }
}

private func releaseInstanceLock() {
    if instanceLockFD >= 0 {
        flock(instanceLockFD, LOCK_UN)
        close(instanceLockFD)
        instanceLockFD = -1
    }
}

private func acquireInstanceLock() {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/HighlightCopy", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fd = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        exit(0)
    }
    instanceLockFD = fd
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()

    private let logger = Logger(subsystem: "com.joshzandman.HighlightCopy", category: "copy")
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var trustTimer: Timer?
    private var activity: NSObjectProtocol?
    private var gesture = SelectionGesture()
    private var secureGesture = false
    private var copyGeneration = 0
    private var enabled = true
    private var lastCopied: String?
    private var lastStatus = ""
    private var lastDebug = "none"

    /// Some apps, especially browsers, publish the selection shortly after pointer-up.
    private let settleDelays: [TimeInterval] = [0.12, 0.25]

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Copy selected text on pointer up"
        )
        ProcessInfo.processInfo.disableAutomaticTermination("Listening for text selections")
        ProcessInfo.processInfo.disableSuddenTermination()

        setupStatusItem()
        requestAccessibility(openSettings: false)
        LoginItem.sync()
        startMonitoringIfNeeded()
        publishStatus()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.startMonitoringIfNeeded()
            self?.publishStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMonitoring()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        releaseInstanceLock()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        let symbol = enabled ? "doc.on.clipboard" : "pause.circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Highlight Copy")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = image == nil ? "HC" : ""
        if AXIsProcessTrusted() {
            statusItem.button?.toolTip = enabled ? "Highlight Copy" : "Highlight Copy is paused"
        } else {
            statusItem.button?.toolTip = "Highlight Copy needs access in Device Control and Data Access"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let pause = NSMenuItem(
            title: enabled ? "Pause" : "Resume",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        let login = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = LoginItem.menuStateIsOn ? .on : .off
        menu.addItem(login)
        if LoginItem.statusLabel == "requires-approval" {
            let approval = NSMenuItem(
                title: "Approve Login Item in Settings…",
                action: #selector(openLoginItemsSettings),
                keyEquivalent: ""
            )
            approval.target = self
            menu.addItem(approval)
        }
        if let error = LoginItem.lastError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if AXIsProcessTrusted() {
            let title = (enabled && globalMonitor == nil)
                ? "Access is on. Quit and reopen if copying has not started."
                : "Access: On"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let item = NSMenuItem(
                title: "Open Device Control and Data Access…",
                action: #selector(promptAccessibility),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            let hint = NSMenuItem(
                title: "If the switch is on, turn it off and on again.",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)
        }

        if let lastCopied {
            let item = NSMenuItem(title: "Last copy: \(preview(lastCopied))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let relaunch = NSMenuItem(title: "Relaunch", action: #selector(relaunch), keyEquivalent: "")
        relaunch.target = self
        menu.addItem(relaunch)
        let quit = NSMenuItem(title: "Quit Highlight Copy", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if enabled {
            startMonitoringIfNeeded()
        } else {
            stopMonitoring()
            copyGeneration += 1
        }
        updateIcon()
        publishStatus()
    }

    @objc private func toggleLogin() {
        LoginItem.setWantsLaunchAtLogin(!LoginItem.menuStateIsOn)
        publishStatus()
    }

    @objc private func promptAccessibility() {
        // Opening during menu tracking never switches System Settings to the right page.
        openSettingsURL("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
    }

    private func requestAccessibility(openSettings: Bool) {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if openSettings {
            openSettingsURL("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        }
        startMonitoringIfNeeded()
        publishStatus()
    }

    @objc private func openLoginItemsSettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    @objc private func relaunch() {
        releaseInstanceLock()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", Bundle.main.bundleURL.path]
        do {
            try process.run()
        } catch {
            logger.error("Could not relaunch: \(error.localizedDescription, privacy: .public)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// `open` is deferred so the status-item menu can finish closing. On this macOS version the
    /// privacy permission list is titled Device Control and Data Access; the anchor is still
    /// Privacy_Accessibility.
    private func openSettingsURL(_ value: String) {
        DispatchQueue.main.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [value]
            do {
                try process.run()
            } catch {
                guard let url = URL(string: value) else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open(url, configuration: configuration)
            }
        }
    }

    private func startMonitoringIfNeeded() {
        guard enabled else {
            updateIcon()
            return
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
        updateIcon()
    }

    private func stopMonitoring() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard enabled else { return }
        let point = cocoaScreenPoint(event)
        switch event.type {
        case .leftMouseDown:
            copyGeneration += 1
            let target = SelectionReader.target(atQuartzPoint: quartzPoint(fromCocoa: point))
            if event.clickCount <= 1 {
                secureGesture = target.isSecure
            } else if target.isSecure {
                secureGesture = true
            }
            let existing = event.clickCount <= 1 ? (target.selectedText ?? "") : ""
            gesture.mouseDown(at: point, clickCount: event.clickCount, selectedText: existing)
        case .leftMouseDragged:
            gesture.mouseDragged(to: point)
        case .leftMouseUp:
            gesture.mouseUp(at: point, clickCount: event.clickCount)
            guard gesture.isHighlight else {
                lastDebug = "ignored"
                publishStatus()
                return
            }
            if secureGesture {
                lastDebug = "secure"
                publishStatus()
                return
            }
            copyGeneration += 1
            let generation = copyGeneration
            let finished = gesture
            let immediate = SelectionReader.target(atQuartzPoint: quartzPoint(fromCocoa: point))
            if consume(immediate, gesture: finished, generation: generation, allowCommandC: false) {
                return
            }
            lastDebug = "waiting"
            publishStatus()
            for (index, delay) in settleDelays.enumerated() {
                let allowCommandC = index == settleDelays.count - 1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.copySettledSelection(
                        generation: generation,
                        gesture: finished,
                        cocoaPoint: point,
                        allowCommandC: allowCommandC
                    )
                }
            }
        default:
            break
        }
    }

    private func copySettledSelection(
        generation: Int,
        gesture: SelectionGesture,
        cocoaPoint: CGPoint,
        allowCommandC: Bool
    ) {
        guard enabled, generation == copyGeneration else { return }
        let target = SelectionReader.target(atQuartzPoint: quartzPoint(fromCocoa: cocoaPoint))
        if consume(target, gesture: gesture, generation: generation, allowCommandC: allowCommandC) {
            return
        }
        if allowCommandC {
            lastDebug = "no-text"
            publishStatus()
        }
    }

    /// Copies exposed selected text. Command-C is only a last resort for a text control that
    /// reports no selected text, such as some browser pages. Window drags and secure fields never use it.
    @discardableResult
    private func consume(
        _ target: CopyTarget,
        gesture: SelectionGesture,
        generation: Int,
        allowCommandC: Bool
    ) -> Bool {
        guard enabled, generation == copyGeneration else { return true }
        if target.isSecure {
            lastDebug = "secure"
            publishStatus()
            return true
        }
        if let text = target.selectedText {
            if CopyDecision.shouldCopy(gesture: gesture, selectedText: text) {
                writeClipboard(text)
            } else {
                lastDebug = "unchanged"
                publishStatus()
            }
            return true
        }
        if case .text = target, allowCommandC {
            copyWithCommandC(generation: generation, gesture: gesture)
            return true
        }
        return false
    }

    private func copyWithCommandC(generation: Int, gesture: SelectionGesture) {
        let pasteboard = NSPasteboard.general
        let beforeCount = pasteboard.changeCount
        let beforeString = pasteboard.string(forType: .string)
        postCommandC()
        lastDebug = "command-c"
        publishStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.enabled, generation == self.copyGeneration else { return }
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != beforeCount else {
                self.lastDebug = "command-c-unchanged"
                self.publishStatus()
                return
            }
            let copied = pasteboard.string(forType: .string) ?? ""
            guard CopyDecision.shouldCopy(gesture: gesture, selectedText: copied) else {
                pasteboard.clearContents()
                if let beforeString {
                    pasteboard.setString(beforeString, forType: .string)
                }
                self.lastDebug = "command-c-restored"
                self.publishStatus()
                return
            }
            self.lastCopied = copied
            self.lastDebug = "copied"
            self.statusItem.button?.toolTip = "Copied \(copied.count) characters"
            self.logger.info("Copied selection with Command-C (\(copied.count, privacy: .public) characters)")
            self.publishStatus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.updateIcon()
            }
        }
    }

    private func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func writeClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == text {
            lastCopied = text
            lastDebug = "copied"
            publishStatus()
            return
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        lastCopied = text
        lastDebug = "copied"
        statusItem.button?.toolTip = "Copied \(text.count) characters"
        logger.info("Copied selection (\(text.count, privacy: .public) characters)")
        publishStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.updateIcon()
        }
    }

    /// Global monitors report a screen point and have no window. Local monitors report a window point.
    private func cocoaScreenPoint(_ event: NSEvent) -> CGPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func quartzPoint(fromCocoa point: CGPoint) -> CGPoint {
        let screens = NSScreen.screens
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        return ScreenCoordinates.quartzPoint(fromCocoa: point, primaryHeight: primary?.frame.height ?? 0)
    }

    private func accessibilityProbe() -> String {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        return "\(error.rawValue)"
    }

    private func preview(_ text: String) -> String {
        let flat = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        if flat.count <= 48 { return flat }
        return String(flat.prefix(48)) + "…"
    }

    private func publishStatus() {
        let line = [
            "trusted=\(AXIsProcessTrusted())",
            "ax=\(accessibilityProbe())",
            "enabled=\(enabled)",
            "monitoring=\(globalMonitor != nil)",
            "login=\(LoginItem.statusLabel)",
            "pid=\(getpid())",
            "last=\(lastDebug)",
        ].joined(separator: "\n") + "\n"
        guard line != lastStatus else { return }
        lastStatus = line
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HighlightCopy", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try line.write(to: directory.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
        } catch {
            logger.error("Could not write status: \(error.localizedDescription, privacy: .public)")
        }
    }
}
