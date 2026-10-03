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

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    delegate.handleHID(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Starts a new session that opens the app after this process has exited.
/// `open` while this process is still running only activates it, and the following
/// terminate then leaves nothing running.
private func spawnRelaunch(bundlePath: String) {
    let command = "sleep 0.7; /usr/bin/open -g \(shellQuote(bundlePath))"
    var pid: pid_t = 0
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    var argv = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
    defer {
        for pointer in argv { free(pointer) }
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&actions)
    }
    argv.withUnsafeMutableBufferPointer { buffer in
        _ = posix_spawn(&pid, "/bin/sh", &actions, &attr, buffer.baseAddress, environ)
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
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var trustTimer: Timer?
    private var sampleTimer: Timer?
    private var gestureOpen = false
    private var buttonWasDown = false
    private var activity: NSObjectProtocol?
    private var gesture = SelectionGesture()
    private var secureGesture = false
    private var copyGeneration = 0
    private var enabled = true
    private var lastCopied: String?
    private var lastStatus = ""
    private var lastDebug = "none"
    private lazy var copiedTooltip = CopiedTooltip()

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

        let sampler = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.samplePointer()
        }
        RunLoop.main.add(sampler, forMode: .common)
        sampleTimer = sampler
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
        spawnRelaunch(bundlePath: Bundle.main.bundleURL.path)
        NSApp.terminate(nil)
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
        if eventTap == nil && globalMonitor == nil {
            if !startEventTap() {
                startNSEventMonitors()
            }
        }
        if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        updateIcon()
    }

    /// Session-level listen tap. Locations match the pointer the apps see, including trackpad drags.
    private func startEventTap() -> Bool {
        let events: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        var mask: CGEventMask = 0
        for event in events {
            mask |= 1 << event.rawValue
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        return true
    }

    private func startNSEventMonitors() {
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
    }

    private func stopMonitoring() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            self.eventTapSource = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        gestureOpen = false
        buttonWasDown = false
    }

    fileprivate func handleHID(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        let cocoa = cocoaPoint(fromQuartz: event.location)
        let clicks = max(Int(event.getIntegerValueField(.mouseEventClickState)), 1)
        let optionDown = event.flags.contains(.maskAlternate)
        switch type {
        case .leftMouseDown:
            notePointer(.down, at: cocoa, clickCount: clicks, optionDown: optionDown)
        case .leftMouseDragged:
            notePointer(.drag, at: cocoa, clickCount: clicks, optionDown: optionDown)
        case .leftMouseUp:
            notePointer(.up, at: cocoa, clickCount: clicks, optionDown: optionDown)
        default:
            break
        }
    }

    private func handle(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let clicks = max(event.clickCount, 1)
        let optionDown = event.modifierFlags.contains(.option)
        switch event.type {
        case .leftMouseDown:
            notePointer(.down, at: point, clickCount: clicks, optionDown: optionDown)
        case .leftMouseDragged:
            notePointer(.drag, at: point, clickCount: clicks, optionDown: optionDown)
        case .leftMouseUp:
            notePointer(.up, at: point, clickCount: clicks, optionDown: optionDown)
        default:
            break
        }
    }

    /// While the button is down, measure the live cursor so a drag still counts when dragged
    /// events are missing. Three-finger drag and tap-to-click set the left button too.
    private func samplePointer() {
        guard enabled else { return }
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let point = NSEvent.mouseLocation
        let optionDown = NSEvent.modifierFlags.contains(.option)
        if down {
            if gestureOpen {
                if optionDown {
                    gesture.noteOptionHeld()
                }
                gesture.mouseDragged(to: point)
            }
            buttonWasDown = true
        } else if buttonWasDown {
            buttonWasDown = false
            if gestureOpen {
                notePointer(.up, at: point, clickCount: max(gesture.clickCount, 1), optionDown: optionDown)
            }
        }
    }

    private enum PointerPhase {
        case down
        case drag
        case up
    }

    private func notePointer(_ phase: PointerPhase, at point: CGPoint, clickCount: Int, optionDown: Bool) {
        guard enabled else { return }
        switch phase {
        case .down:
            beginPointer(at: point, clickCount: clickCount, optionDown: optionDown)
        case .drag:
            if !gestureOpen {
                beginPointer(at: point, clickCount: 1, optionDown: optionDown)
            } else if optionDown {
                gesture.noteOptionHeld()
            }
            gesture.mouseDragged(to: point)
        case .up:
            guard gestureOpen else { return }
            if optionDown {
                gesture.noteOptionHeld()
            }
            gesture.mouseUp(at: point, clickCount: clickCount)
            gestureOpen = false
            finishPointer(at: point)
        }
    }

    private func beginPointer(at point: CGPoint, clickCount: Int, optionDown: Bool) {
        if clickCount <= 1 {
            copyGeneration += 1
        }
        let target = SelectionReader.target(atQuartzPoint: quartzPoint(fromCocoa: point))
        if clickCount <= 1 {
            secureGesture = target.isSecure
        } else if target.isSecure {
            secureGesture = true
        }
        let existing = clickCount <= 1 ? (target.selectedText ?? "") : ""
        gesture.mouseDown(at: point, clickCount: clickCount, selectedText: existing)
        // mouseDown clears the flag on a new click, so record Option after that.
        if optionDown {
            gesture.noteOptionHeld()
        }
        gestureOpen = true
        buttonWasDown = true
    }

    private func finishPointer(at point: CGPoint) {
        guard gesture.isHighlight else {
            lastDebug = "ignored clicks=\(gesture.clickCount) travel=\(travelText)"
            publishStatus()
            return
        }
        // Return before any pasteboard write or Command-C. A highlight copies only when Option was held.
        if !gesture.optionHeld {
            lastDebug = "no-option"
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
        if consume(immediate, gesture: finished, generation: generation, cocoaPoint: point, allowCommandC: false) {
            return
        }
        lastDebug = "waiting clicks=\(finished.clickCount) travel=\(travelText)"
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
    }

    private var travelText: String {
        String(format: "%.1f", gesture.travel)
    }

    private func copySettledSelection(
        generation: Int,
        gesture: SelectionGesture,
        cocoaPoint: CGPoint,
        allowCommandC: Bool
    ) {
        guard enabled, generation == copyGeneration else { return }
        let target = SelectionReader.target(atQuartzPoint: quartzPoint(fromCocoa: cocoaPoint))
        if consume(target, gesture: gesture, generation: generation, cocoaPoint: cocoaPoint, allowCommandC: allowCommandC) {
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
        cocoaPoint: CGPoint,
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
                writeClipboard(text, near: cocoaPoint)
            } else {
                lastDebug = "unchanged"
                publishStatus()
            }
            return true
        }
        if case .text = target, allowCommandC {
            copyWithCommandC(generation: generation, gesture: gesture, cocoaPoint: cocoaPoint)
            return true
        }
        return false
    }

    private func copyWithCommandC(generation: Int, gesture: SelectionGesture, cocoaPoint: CGPoint) {
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
            self.showCopiedTooltip(near: cocoaPoint)
            self.logger.info("Copied selection with Command-C (\(copied.count, privacy: .public) characters)")
            self.publishStatus()
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

    private func writeClipboard(_ text: String, near cocoaPoint: CGPoint) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == text {
            lastCopied = text
            lastDebug = "copied"
            showCopiedTooltip(near: cocoaPoint)
            publishStatus()
            return
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        lastCopied = text
        lastDebug = "copied"
        showCopiedTooltip(near: cocoaPoint)
        logger.info("Copied selection (\(text.count, privacy: .public) characters)")
        publishStatus()
    }

    private func showCopiedTooltip(near cocoaPoint: CGPoint) {
        let quartz = quartzPoint(fromCocoa: cocoaPoint)
        let tail = SelectionReader.selectionTail(atQuartzPoint: quartz).map { self.cocoaPoint(fromQuartz: $0) } ?? cocoaPoint
        copiedTooltip.show(at: tail)
    }

    private func quartzPoint(fromCocoa point: CGPoint) -> CGPoint {
        ScreenCoordinates.quartzPoint(fromCocoa: point, primaryHeight: primaryScreenHeight)
    }

    private func cocoaPoint(fromQuartz point: CGPoint) -> CGPoint {
        ScreenCoordinates.quartzPoint(fromCocoa: point, primaryHeight: primaryScreenHeight)
    }

    private var primaryScreenHeight: CGFloat {
        let screens = NSScreen.screens
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        return primary?.frame.height ?? 0
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
            "monitoring=\(globalMonitor != nil || eventTap != nil)",
            "tap=\(eventTap != nil)",
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

/// Floating “copied” label shown at the end of a highlight. It ignores clicks so it never blocks the next selection.
private final class CopiedTooltip {
    private let panel: NSPanel
    private var hideTimer: Timer?
    private var generation = 0

    init() {
        let label = NSTextField(labelWithString: "copied")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 3
        let size = NSSize(
            width: label.frame.width + horizontalPadding * 2,
            height: label.frame.height + verticalPadding * 2
        )
        label.frame = NSRect(x: horizontalPadding, y: verticalPadding, width: label.frame.width, height: label.frame.height)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 6
        container.addSubview(label)

        panel = NSPanel(
            contentRect: container.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = container
    }

    func show(at anchor: CGPoint) {
        generation += 1
        let shown = generation
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = TooltipPlacement.origin(anchor: anchor, size: size, visibleRect: visible)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self, self.generation == shown else { return }
            self.panel.orderOut(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }
}
