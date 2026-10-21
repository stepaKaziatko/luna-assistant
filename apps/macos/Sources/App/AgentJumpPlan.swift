import Foundation

// MARK: - Jump to the agent: the plan
//
// "Go to the agent" brings the window or the tab where a session runs to the front. What to
// do depends only on data the session already carries (host app, folder, terminal device,
// session id), so the decision is a pure function here, free of AppKit, and the executor
// (`AgentJump`) only carries it out. Everything that ends up in a URL or in an AppleScript
// passes the checks in this file first — a session id, a folder or a tty comes from the
// outside (the hook payload) and is never trusted as it is.
// Tested without a window by `scripts/test-agent-jump.sh`.

// MARK: - Plan

struct AgentJumpPlan: Equatable, Sendable {

    /// A terminal whose tabs can be told apart by tty through its AppleScript dictionary.
    enum ScriptableTerminal: String, Equatable, Sendable {
        case terminal = "com.apple.Terminal"
        case iTerm    = "com.googlecode.iterm2"

        var bundleId: String { rawValue }
        var displayName: String { self == .terminal ? "Terminal" : "iTerm2" }
    }

    enum Action: Equatable, Sendable {
        /// An editor: open the project folder in it (it raises the window that has the folder
        /// open), then, when the extension of the agent is known, the link to the session tab.
        case editor(bundleId: String, folder: String?, sessionLink: URL?)
        /// Terminal.app or iTerm2: activate and select the tab with this tty.
        case terminalTab(ScriptableTerminal, tty: String, folder: String?)
        /// Any other app that hosts the session (Warp, Ghostty, kitty…): activate only.
        case activate(bundleId: String, folder: String?)
        /// The host is unknown: the project folder in Finder.
        case revealFolder(String)
        /// Nothing to go to.
        case unavailable
    }

    let action: Action

    /// The plan for a session.
    ///
    /// - Parameters:
    ///   - pill: the pill of the session (`integration_claude`, `agent_cursor`, `agent_codex`…).
    ///   - sessionId: `AgentSessionKey.session`; a key made of pill and cwd is not an id.
    static func make(pill: String, sessionId: String, who: AgentSessionWho) -> AgentJumpPlan {
        let folder = folder(of: who)
        let host = who.hostBundleId
        // Агент, которого Luna запустила в фоне (LUNA-80): окна у него нет, переходить некуда.
        if host == AgentHost.lunaBackground { return AgentJumpPlan(action: .unavailable) }

        if let editor = AgentEditors.editor(bundleId: host) {
            return AgentJumpPlan(action: .editor(
                bundleId: host, folder: folder,
                sessionLink: sessionLink(editor: editor, pill: pill, sessionId: sessionId)))
        }
        if let terminal = ScriptableTerminal(rawValue: host) {
            if let tty = validTTY(who.tty) {
                return AgentJumpPlan(action: .terminalTab(terminal, tty: tty, folder: folder))
            }
            return AgentJumpPlan(action: .activate(bundleId: host, folder: folder))
        }
        if !host.isEmpty {
            return AgentJumpPlan(action: .activate(bundleId: host, folder: folder))
        }
        if let folder { return AgentJumpPlan(action: .revealFolder(folder)) }
        return AgentJumpPlan(action: .unavailable)
    }

    var isAvailable: Bool { action != .unavailable }

    /// Папка перехода: корень проекта сессии, а не её текущая папка. VS Code поднимает своё окно,
    /// только если открываемая папка совпадает с папкой окна в точности; подпапка или worktree,
    /// куда агент сделал `cd`, открыла бы новое окно. Без корня — `cwd`.
    static func folder(of who: AgentSessionWho) -> String? {
        validFolder(who.projectDir) ?? validFolder(who.cwd)
    }

    // MARK: Editor steps

    /// Один шаг перехода в редактор. Шага «новая сессия» нет и быть не может: Luna только
    /// открывает папку (редактор поднимает окно с ней) и ссылку на уже идущую сессию.
    enum EditorStep: Equatable, Sendable {
        /// Открыть папку проекта в редакторе: он поднимает окно, где она открыта.
        case openFolder(String)
        /// Ссылка расширения на сессию — когда редактор стал активным (см. `linkReady`).
        case openSessionLink(URL)
        /// Только поднять или запустить сам редактор.
        case activateApp
    }

    /// Шаги перехода в редактор. `folder` — существующая папка проекта (nil, если её нет),
    /// `link` — ссылка на сессию, `editorRunning` — запущен ли редактор. Не запущен — вкладки
    /// этой сессии в нём нет, а ссылка подняла бы её заново: тогда только папка.
    static func editorSteps(folder: String?, link: URL?, editorRunning: Bool) -> [EditorStep] {
        let session = editorRunning ? link : nil
        if let folder {
            return [.openFolder(folder)] + (session.map { [.openSessionLink($0)] } ?? [])
        }
        if let session { return [.openSessionLink(session)] }
        return [.activateApp]
    }

    /// Сколько ждать, пока редактор поднимет окно с папкой, прежде чем отправить ссылку всё равно.
    static let linkWaitLimit: TimeInterval = 1.5

    /// Можно ли отправлять ссылку на сессию. Ссылку редактор отдаёт последнему активному окну,
    /// поэтому она уходит, когда редактор впереди и его верхнее окно сменилось (поднялось окно с
    /// папкой). `topWindowBefore` / `topWindowNow` — номер верхнего окна редактора до открытия
    /// папки и сейчас. Окно не сменилось (нужное и так было сверху) — ссылка уйдёт по
    /// `linkWaitLimit`.
    static func linkReady(editorFrontmost: Bool, topWindowBefore: Int?, topWindowNow: Int?) -> Bool {
        guard editorFrontmost, let now = topWindowNow else { return false }
        return now != topWindowBefore
    }

    // MARK: Session link

    /// The pills whose agent is Claude Code running under an editor with its extension. The Claude
    /// Code of Cursor reaches Luna under the Cursor pill together with the agent of Cursor itself
    /// and cannot be told from it, so Cursor gets the folder only; the other agents have no tab
    /// to link to.
    static let linkablePills: Set<String> = ["integration_claude"]

    /// `<scheme>://anthropic.claude-code/open?session=<uuid>`, or nil when any part is not trusted.
    static func sessionLink(editor: AgentEditors.Editor, pill: String, sessionId: String) -> URL? {
        guard linkablePills.contains(pill),
              AgentEditors.allowedSchemes.contains(editor.scheme),
              isUUID(sessionId) else { return nil }
        var parts = URLComponents()
        parts.scheme = editor.scheme
        parts.host = AgentEditors.extensionId
        parts.path = "/open"
        parts.queryItems = [URLQueryItem(name: "session", value: sessionId)]
        return parts.url
    }

    // MARK: Checks

    /// `8-4-4-4-12` hex digits and nothing else: no `&`, space, `;` or quote can get in.
    static func isUUID(_ text: String) -> Bool {
        let lengths = [8, 4, 4, 4, 12]
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == lengths.count else { return false }
        for (group, length) in zip(groups, lengths) {
            guard group.utf8.count == length,
                  group.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) })
            else { return false }
        }
        return true
    }

    /// `/dev/ttys` and one to four digits. This string goes into an AppleScript, so nothing else
    /// passes.
    static func validTTY(_ text: String) -> String? {
        let prefix = "/dev/ttys"
        guard text.hasPrefix(prefix) else { return nil }
        let digits = text.dropFirst(prefix.count)
        guard (1...4).contains(digits.utf8.count),
              digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return text
    }

    /// An absolute path without control characters; nil for everything else (including "").
    static func validFolder(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.count <= 1024,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        return path
    }
}

// MARK: - Editors

/// The editors a session can run in, and the URL scheme each answers to.
enum AgentEditors {
    struct Editor: Equatable, Sendable {
        let name: String
        let scheme: String
    }

    /// Schemes Luna agrees to open — never taken from a payload, never built from a name.
    static let allowedSchemes: Set<String> =
        ["vscode", "vscode-insiders", "vscodium", "cursor", "windsurf"]

    /// The extension of Claude Code answers to this authority in every editor.
    static let extensionId = "anthropic.claude-code"

    private static let byBundleId: [String: Editor] = [
        "com.microsoft.VSCode":          Editor(name: "VS Code", scheme: "vscode"),
        "com.microsoft.VSCodeInsiders":  Editor(name: "VS Code Insiders", scheme: "vscode-insiders"),
        "com.vscodium":                  Editor(name: "VSCodium", scheme: "vscodium"),
        "com.vscodium.codium":           Editor(name: "VSCodium", scheme: "vscodium"),
        "com.todesktop.230313mzl4w4u92": Editor(name: "Cursor", scheme: "cursor"),
        "com.exafunction.windsurf":      Editor(name: "Windsurf", scheme: "windsurf"),
    ]

    static func editor(bundleId: String) -> Editor? { byBundleId[bundleId] }
}

// MARK: - AppleScript

/// The scripts that select a tab, and the reading of what comes back. Only a checked tty is ever
/// put into a script text.
enum AgentTerminalScript {

    /// The marker the script returns when it selected a tab.
    static let selected = "selected"
    /// The marker for "no tab has this tty": not an error, the app is in front anyway.
    static let notFound = "notfound"

    /// The script for the tty, or nil when it is not a valid device name.
    static func source(for terminal: AgentJumpPlan.ScriptableTerminal, tty: String) -> String? {
        guard let tty = AgentJumpPlan.validTTY(tty) else { return nil }
        switch terminal {
        case .terminal:
            return """
            tell application id "com.apple.Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            return "\(selected)"
                        end if
                    end repeat
                end repeat
                return "\(notFound)"
            end tell
            """
        case .iTerm:
            return """
            tell application id "com.googlecode.iterm2"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                tell w to select t
                                tell t to select s
                                return "\(selected)"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "\(notFound)"
            end tell
            """
        }
    }

    enum Outcome: Equatable, Sendable {
        /// The tab with the tty is selected.
        case selected
        /// The app is in front, but no tab has this tty (closed, or the terminal moved on).
        case tabNotFound
        /// Apple Events to the app are not allowed (-1743): the app is activated without the tab.
        case noPermission
        /// The script failed for another reason.
        case failed(Int)
    }

    /// Apple Events error "not authorized to send Apple events to this application".
    static let noPermissionCode = -1743

    /// `errorNumber` is the `NSAppleScript` error number, nil when the script ran;
    /// `result` is the string it returned.
    static func outcome(errorNumber: Int?, result: String?) -> Outcome {
        if let code = errorNumber {
            return code == noPermissionCode ? .noPermission : .failed(code)
        }
        return result == selected ? .selected : .tabNotFound
    }
}
