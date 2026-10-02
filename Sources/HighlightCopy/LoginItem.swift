import Foundation
import ServiceManagement

/// Starts Highlight Copy at login. `SMAppService` is the supported path. Ad-hoc menu-bar apps
/// often cannot register that way, so a LaunchAgent is the fallback. The agent restarts the
/// process after a crash and stays stopped after Quit.
enum LoginItem {
    static let label = "com.joshzandman.HighlightCopy"
    static let defaultsKey = "launchAtLogin"
    private(set) static var lastError: String?

    static var wantsLaunchAtLogin: Bool {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func setWantsLaunchAtLogin(_ wants: Bool) {
        UserDefaults.standard.set(wants, forKey: defaultsKey)
        do {
            if wants {
                try enable()
            } else {
                try disable()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func sync() {
        guard wantsLaunchAtLogin else { return }
        do {
            try enable()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    static var statusLabel: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requires-approval"
        case .notRegistered:
            return launchAgentPlistExists ? "launch-agent" : "not-registered"
        case .notFound:
            return launchAgentPlistExists ? "launch-agent" : "not-found"
        @unknown default:
            return launchAgentPlistExists ? "launch-agent" : "unknown"
        }
    }

    static var menuStateIsOn: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return wantsLaunchAtLogin && launchAgentPlistExists
        }
    }

    static func enable() throws {
        // The running agent already covers login and crash restart. Do not bootout
        // that job from inside itself, or launchd will kill this process.
        if launchAgentIsLoaded {
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            if launchAgentPlistExists {
                try removeLaunchAgent()
            }
            return
        case .requiresApproval:
            return
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }

        do {
            try SMAppService.mainApp.register()
        } catch {
            try installAndBootstrapLaunchAgent()
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            if launchAgentPlistExists {
                try removeLaunchAgent()
            }
        case .requiresApproval:
            return
        default:
            try installAndBootstrapLaunchAgent()
        }
    }

    static func disable() throws {
        if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
        try removeLaunchAgent()
    }

    private static var startedByLaunchd: Bool {
        getppid() == 1
    }

    private static var launchAgentPlistExists: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static func installAndBootstrapLaunchAgent() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw LoginItemError.notAnAppBundle
        }
        guard let executable = Bundle.main.executableURL else {
            throw LoginItemError.notAnAppBundle
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: plistURL, options: .atomic)
        if launchAgentIsLoaded || startedByLaunchd {
            return
        }
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["enable", "\(domain)/\(label)"])
        let bootstrap = runLaunchctl(["bootstrap", domain, plistURL.path])
        if bootstrap != 0 && !launchAgentIsLoaded {
            throw LoginItemError.launchctlFailed(bootstrap)
        }
    }

    private static func removeLaunchAgent() throws {
        let domain = "gui/\(getuid())"
        if startedByLaunchd {
            // bootout would terminate the running agent. Disable future launches instead.
            _ = runLaunchctl(["disable", "\(domain)/\(label)"])
        } else {
            _ = runLaunchctl(["bootout", "\(domain)/\(label)"])
        }
        if launchAgentPlistExists {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static var launchAgentIsLoaded: Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum LoginItemError: LocalizedError {
    case notAnAppBundle
    case launchctlFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .notAnAppBundle:
            return "Launch at login needs the installed Highlight Copy app."
        case .launchctlFailed(let code):
            return "Could not install the login item (launchctl exited \(code))."
        }
    }
}
