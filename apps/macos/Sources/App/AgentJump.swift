import AppKit

// MARK: - Jump to the agent: the executor
//
// The one place where Luna hands the focus to another app on its own accord, and only for an
// explicit click on "Go to the agent" (`AgentPreviewView`). What to do is decided by
// `AgentJumpPlan` (pure, tested); this file carries it out with `NSWorkspace` and, for the
// tabs of Terminal.app and iTerm2, an AppleScript that holds only a checked tty.
//
// macOS asks for the "Automation" permission the first time the script talks to Terminal or
// iTerm2 — at this click, never at launch. Without it the app is activated without the tab
// and a hint says where to allow it. The App Store build has no AppleScript: it activates the
// app or opens the folder.

/// What the page tells after a jump that did not go all the way.
enum AgentJumpHint: Equatable {
    /// Terminal or iTerm2 may not be controlled yet: the app was activated without the tab.
    case needsAutomation(appName: String)
    /// This terminal has no scripting dictionary: only the app is in front.
    case tabUnavailable(appName: String)
    /// The folder of the project is gone.
    case folderMissing
    /// There is nothing to go to.
    case unavailable
}

/// A hint of a jump, for the session it was made to.
struct AgentJumpNote: Equatable {
    let sessionId: String
    let hint: AgentJumpHint
}

@MainActor
enum AgentJump {

    typealias Completion = @MainActor (AgentJumpHint?) -> Void

    /// Brings the session's window or tab forward. `completion` is called on the main actor once
    /// the outcome is known (an AppleScript runs in the background): nil means nothing to tell.
    static func open(_ session: AgentSessionInfo, completion: @escaping Completion) {
        let plan = AgentJumpPlan.make(pill: session.pill, sessionId: session.key.session, who: session.who)
        switch plan.action {
        case .editor(let bundleId, let folder, let link):
            openEditor(bundleId: bundleId, folder: folder, link: link, completion: completion)
        case .terminalTab(let terminal, let tty, let folder):
            openTerminalTab(terminal, tty: tty, folder: folder, completion: completion)
        case .activate(let bundleId, let folder):
            let hint: AgentJumpHint? = ClaudeHost.isTerminal(bundleId: bundleId)
                ? .tabUnavailable(appName: AgentHostApps.name(for: bundleId) ?? bundleId) : nil
            activate(bundleId: bundleId, orReveal: folder) { completion($0 ?? hint) }
        case .revealFolder(let folder):
            completion(reveal(folder: folder))
        case .unavailable:
            completion(.unavailable)
        }
    }

    // MARK: Editors

    private static func openEditor(bundleId: String, folder: String?, link: URL?,
                                   completion: @escaping Completion) {
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) else {
            // The editor is not installed (any more): the folder in Finder is the next best thing.
            completion(folder.map(reveal(folder:)) ?? .unavailable)
            return
        }
        let folderURL = folder.flatMap { isDirectory($0) ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // The link of the extension, if the plan has one. The scheme is checked once more here:
        // nothing but the editors' own schemes is ever opened.
        let session: URL? = link.flatMap { url in
            guard let scheme = url.scheme, AgentEditors.allowedSchemes.contains(scheme) else { return nil }
            return url
        }

        if let folderURL {
            workspace.open([folderURL], withApplicationAt: appURL, configuration: configuration) { _, error in
                if let error { jumpLog("Go to agent: the editor did not open the folder: \(error.localizedDescription)") }
                guard let session else { return }
                // The window with the folder is up: the extension opens the tab in it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let again = NSWorkspace.OpenConfiguration()
                    again.activates = true
                    NSWorkspace.shared.open([session], withApplicationAt: appURL, configuration: again) { _, error in
                        if let error { jumpLog("Go to agent: the session link was not opened: \(error.localizedDescription)") }
                    }
                }
            }
            completion(nil)
        } else if let session {
            workspace.open([session], withApplicationAt: appURL, configuration: configuration, completionHandler: nil)
            completion(folder == nil ? nil : .folderMissing)
        } else {
            workspace.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
            completion(folder == nil ? nil : .folderMissing)
        }
    }

    // MARK: Terminals

    private static func openTerminalTab(_ terminal: AgentJumpPlan.ScriptableTerminal, tty: String, folder: String?,
                                        completion: @escaping Completion) {
        #if !APPSTORE
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == terminal.bundleId }
        guard running, let source = AgentTerminalScript.source(for: terminal, tty: tty) else {
            // Not running: there is no tab to select. Start it, or show the folder.
            activate(bundleId: terminal.bundleId, orReveal: folder, completion: completion)
            return
        }
        let name = terminal.displayName
        Task.detached(priority: .userInitiated) {
            let outcome = runScript(source)
            await MainActor.run {
                switch outcome {
                case .selected, .tabNotFound:
                    completion(nil)
                case .noPermission:
                    // The script did not even activate the app.
                    jumpLog("Go to agent: no Automation permission for \(name)")
                    activate(bundleId: terminal.bundleId, orReveal: nil) { _ in
                        completion(.needsAutomation(appName: name))
                    }
                case .failed(let code):
                    jumpLog("Go to agent: the script for \(name) failed (\(code))")
                    activate(bundleId: terminal.bundleId, orReveal: nil) { _ in completion(nil) }
                }
            }
        }
        #else
        activate(bundleId: terminal.bundleId, orReveal: folder, completion: completion)
        #endif
    }

    #if !APPSTORE
    /// Runs the script off the main thread: the first call waits for the person to answer the
    /// system dialog.
    private nonisolated static func runScript(_ source: String) -> AgentTerminalScript.Outcome {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        return AgentTerminalScript.outcome(errorNumber: error == nil ? nil : (code ?? -1),
                                           result: result?.stringValue)
    }
    #endif

    private nonisolated static func jumpLog(_ message: String) { appendAppLog("luna.log", message) }

    // MARK: Apps and folders

    /// Brings an app forward, launching it if needed. A host that is not installed any more shows
    /// the folder instead.
    private static func activate(bundleId: String, orReveal folder: String?,
                                 completion: @escaping Completion) {
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications.contains { $0.bundleIdentifier == bundleId }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) else {
            completion(folder.map(reveal(folder:)) ?? .unavailable)
            return
        }
        // Not running and a folder is known: starting a terminal with no session says less
        // than the project folder.
        if !running, let folder, isDirectory(folder) {
            completion(reveal(folder: folder))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
        completion(nil)
    }

    /// The project folder in Finder.
    @discardableResult
    private static func reveal(folder: String) -> AgentJumpHint? {
        guard isDirectory(folder) else { return .folderMissing }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder, isDirectory: true)])
        return nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
