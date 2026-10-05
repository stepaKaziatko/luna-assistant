import AppKit

/// Переход к окну, в котором идёт сессия агента. Это явное действие пользователя,
/// поэтому приложение-хозяин активируется — единственное место, где Luna отдаёт фокус сама.
enum AgentJump {
    /// Схемы ссылок на сессию, которые Luna согласна открыть: только редакторы с расширением агента.
    static let allowedSchemes: Set<String> = ["vscode", "vscode-insiders", "vscodium", "cursor", "windsurf"]

    enum Plan: Equatable {
        /// Открыть папку в редакторе (он поднимает окно, где она уже открыта), затем — вкладку сессии.
        case editor(app: URL, folder: URL, session: URL?)
        /// Активировать терминал и выбрать вкладку по её tty.
        case terminal(app: URL?, tty: String?)
        /// Хозяин неизвестен: показать папку проекта в Finder.
        case folder(URL)
    }

    static func plan(for session: AgentSession) -> Plan {
        let host = session.host
        let app = host.appPath.map { URL(fileURLWithPath: $0) }
        switch host.kind {
        case .ide:
            guard let app else { return .folder(URL(fileURLWithPath: session.cwd)) }
            return .editor(app: app, folder: URL(fileURLWithPath: host.workspace ?? session.cwd), session: sessionURL(session))
        case .terminal:
            return .terminal(app: app, tty: host.tty.flatMap(validTTY))
        case .unknown:
            if let app { return .terminal(app: app, tty: nil) }
            return .folder(URL(fileURLWithPath: session.cwd))
        }
    }

    static func open(_ session: AgentSession) {
        switch plan(for: session) {
        case .editor(let app, let folder, let sessionURL):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration) { _, error in
                guard error == nil, let sessionURL else { return }
                // Ссылку получает последнее активное окно редактора — даём ему время подняться.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSWorkspace.shared.open(sessionURL) }
            }
        case .terminal(let app, let tty):
            activate(app)
            if let app, let tty, let script = tabScript(appName: app.deletingPathExtension().lastPathComponent, tty: tty) {
                run(script)
            }
        case .folder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Ссылка приходит из ядра, но открывается в системе — принимаем только знакомые схемы.
    static func sessionURL(_ session: AgentSession) -> URL? {
        guard let raw = session.openUrl, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return nil }
        return url
    }

    /// tty подставляется в сценарий — пропускаем только имена устройств терминала.
    static func validTTY(_ tty: String) -> String? {
        tty.range(of: #"^/dev/ttys?[0-9]{1,4}$"#, options: .regularExpression) != nil ? tty : nil
    }

    /// AppleScript, выбирающий вкладку с данным tty. Терминалы без такого словаря просто активируются.
    static func tabScript(appName: String, tty: String) -> String? {
        switch appName {
        case "Terminal":
            """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        case "iTerm", "iTerm2":
            """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default: nil
        }
    }

    private static func activate(_ app: URL?) {
        guard let app else { return }
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
        if let running {
            running.activate(options: [.activateAllWindows])
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Нет разрешения «Автоматизация» — сценарий молча не сработает, терминал уже активирован.
    private static func run(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }
}
