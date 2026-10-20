import Foundation

// Запуск агента из Luna (LUNA-77): план без окна — шаги по целям, кодирование задачи так, как
// её раскодируют настоящие обработчики ссылок, отказы, меню целей, признак расширения.

@main
enum AgentLaunchTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let folder = "/Users/me/shop"

    static func plan(_ target: AgentLaunchTarget, folder: String? = folder, state: ChatProjectFolder? = nil,
                     text: String) -> AgentLaunchPlan? {
        if case .success(let plan) = AgentLaunchPlan.make(target: target, folder: folder, folderState: state, text: text) {
            return plan
        }
        return nil
    }

    static func refusal(_ target: AgentLaunchTarget = .terminal, folder: String? = folder,
                        state: ChatProjectFolder? = nil, text: String) -> AgentLaunchRefusal? {
        if case .failure(let refusal) = AgentLaunchPlan.make(target: target, folder: folder, folderState: state, text: text) {
            return refusal
        }
        return nil
    }

    static func link(_ plan: AgentLaunchPlan?) -> URL? {
        for step in plan?.steps ?? [] { if case .openURL(let url) = step { return url } }
        return nil
    }

    // MARK: Как разбирают ссылку настоящие обработчики

    /// `URLSearchParams` из JavaScript: пары через `&`, имя и значение через первый `=`, `+` —
    /// пробел, затем раскодирование. Так читают запрос расширение VS Code (`handleUri`), обработчик
    /// `claude-cli://` и Claude Desktop.
    static func searchParams(_ query: String) -> [(String, String)] {
        query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let plus = s.replacingOccurrences(of: "+", with: " ")
                return plus.removingPercentEncoding ?? plus
            }
            return (decode(parts[0]), parts.count > 1 ? decode(parts[1]) : "")
        }
    }

    /// Что видит расширение VS Code: VS Code сам раскодирует запрос ссылки (`URI.parse` →
    /// `percentDecode`), расширение отдаёт остаток `URLSearchParams`.
    static func vscodeParams(_ url: URL) -> [(String, String)] {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        return searchParams(raw.removingPercentEncoding ?? raw)
    }

    /// Что видят `claude-cli://` и Claude Desktop: `new URL(...).searchParams` — одно раскодирование.
    static func cliParams(_ url: URL) -> [(String, String)] {
        searchParams(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
    }

    static func main() {
        // ── шаги по целям ────────────────────────────────────────────────────
        print("\nSteps by target")
        do {
            let vs = plan(.vscode, text: "Почини тесты")
            check("VS Code: the folder first, then the link",
                  vs?.steps.count == 2 && vs?.steps.first == .openFolder(folder))
            let url = link(vs)
            check("VS Code: scheme from AgentEditors.allowedSchemes",
                  url?.scheme.map { AgentEditors.allowedSchemes.contains($0) } == true)
            check("VS Code: vscode://anthropic.claude-code/open",
                  url?.scheme == "vscode" && url?.host == "anthropic.claude-code" && url?.path == "/open")
            let params = url.map(vscodeParams) ?? []
            check("VS Code: exactly one parameter, prompt",
                  params.count == 1 && params.first?.0 == "prompt" && params.first?.1 == "Почини тесты")
            check("VS Code: the raw query is one prompt=… with no & in it",
                  url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
                    .map { $0.hasPrefix("prompt=") && !$0.contains("&") } == true)

            let term = plan(.terminal, text: "Почини тесты")
            check("Terminal: a single step, the link", term?.steps.count == 1)
            let t = link(term)
            check("Terminal: claude-cli://open", t?.scheme == "claude-cli" && t?.host == "open")
            let tp = t.map(cliParams) ?? []
            check("Terminal: exactly two parameters, cwd and q",
                  tp.map(\.0) == ["cwd", "q"] && tp.first?.1 == folder && tp.last?.1 == "Почини тесты")

            let desk = plan(.claudeDesktop, text: "Почини тесты")
            check("Claude Desktop: a single step, the link", desk?.steps.count == 1)
            let d = link(desk)
            check("Claude Desktop: claude://code/new",
                  d?.scheme == "claude" && d?.host == "code" && d?.path == "/new")
            let dp = d.map(cliParams) ?? []
            check("Claude Desktop: folder and q",
                  dp.map(\.0) == ["folder", "q"] && dp.first?.1 == folder && dp.last?.1 == "Почини тесты")

            check("the plan keeps the target and the folder",
                  desk?.target == .claudeDesktop && desk?.folder == folder)
            check("only the three schemes of the plan",
                  AgentLaunchPlan.allowedSchemes == ["vscode", "claude-cli", "claude"]
                  && AgentLaunchTarget.allCases.allSatisfy { AgentLaunchPlan.allowedSchemes.contains($0.scheme) })
            check("bundle ids: VS Code and Claude Desktop; the terminal has none",
                  AgentLaunchTarget.vscode.bundleId == "com.microsoft.VSCode"
                  && AgentLaunchTarget.claudeDesktop.bundleId == "com.anthropic.claudefordesktop"
                  && AgentLaunchTarget.terminal.bundleId == nil)
        }

        // ── кодирование ──────────────────────────────────────────────────────
        print("\nEncoding")
        do {
            let tricky = "a b & c=d #e ?f +g 100% Привет 👋🏽 \"q\" 'x' /p\\q;r"
            let multi = "строка 1\nстрока 2"
            let path = "/Users/me/My Projects/магазин & co #1"
            for text in [tricky, multi] {
                let name = text == multi ? "newlines" : "symbols"
                let vs = link(plan(.vscode, folder: path, text: text))
                check("VS Code: \(name) reach the extension intact",
                      vs.map(vscodeParams).map { $0.count == 1 && $0[0] == ("prompt", text) } == true)
                for target in [AgentLaunchTarget.terminal, .claudeDesktop] {
                    let url = link(plan(target, folder: path, text: text))
                    let params = url.map(cliParams) ?? []
                    check("\(target): \(name) and the path reach the handler intact",
                          params.count == 2 && params[0].1 == path && params[1].1 == text)
                    // Разбор обратно средствами Foundation даёт то же.
                    let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                    check("\(target): \(name): URLComponents gives back the text and the path",
                          items.count == 2 && items[0].value == path && items[1].value == text)
                }
            }
            let t = link(plan(.terminal, text: multi))?.absoluteString ?? ""
            check("a newline becomes %0A", t.contains("1%0A"))
            let raw = link(plan(.terminal, text: tricky))?.absoluteString ?? ""
            check("no raw & from the text in the link (only the one between cwd and q)",
                  raw.components(separatedBy: "&").count == 2)
            check("+ is encoded, not left to become a space", raw.contains("%2Bg"))
            let vraw = link(plan(.vscode, text: tricky))?.absoluteString ?? ""
            check("VS Code: & of the text is encoded twice (%2526)", vraw.contains("%2526") && !vraw.contains("&"))
            check("surrounding spaces and newlines are trimmed",
                  link(plan(.terminal, text: "  \n задача \n ")).map(cliParams)?.last?.1 == "задача")
        }

        // ── отказы ───────────────────────────────────────────────────────────
        print("\nRefusals")
        do {
            check("no project", refusal(folder: nil, text: "x") == .noProject)
            check("empty text", refusal(text: "") == .emptyText)
            check("spaces only", refusal(text: "  \n\t ") == .emptyText)
            let limit = AgentLaunchPlan.maxTextLength
            check("exactly 5000 characters go", plan(.terminal, text: String(repeating: "a", count: limit)) != nil)
            check("5001 characters do not", refusal(text: String(repeating: "a", count: limit + 1)) == .textTooLong)
            check("the length is counted like the handler does (UTF-16): 2500 emoji go, 2501 do not",
                  plan(.terminal, text: String(repeating: "😀", count: limit / 2)) != nil
                  && refusal(text: String(repeating: "😀", count: limit / 2 + 1)) == .textTooLong)
            for bad in ["", "relative/path", "~/shop", "/Users/me/\u{07}shop", "/Users/me/sh\nop",
                        "/Users/me/../other", "/Users/me/shop/..", "/../etc"] {
                check("invalid folder \(bad.debugDescription)", refusal(folder: bad, text: "x") == .invalidFolder)
            }
            check("a name with dots is not a .. segment", plan(.terminal, folder: "/Users/me/my..shop", text: "x") != nil)
            check("missing folder", refusal(state: .missing, text: "x") == .folderMissing)
            check("no access", refusal(state: .noAccess, text: "x") == .folderNoAccess)
            check("ready folder goes", plan(.vscode, state: .ready(claudeMD: true, agentsMD: false), text: "x") != nil)
            check("every target refuses the same way",
                  AgentLaunchTarget.allCases.allSatisfy { refusal($0, text: " ") == .emptyText })
            check("refusal() agrees with make()",
                  AgentLaunchPlan.refusal(folder: folder, text: "") == .emptyText
                  && AgentLaunchPlan.refusal(folder: folder, text: "x") == nil)
        }

        // ── меню целей ───────────────────────────────────────────────────────
        print("\nMenu")
        do {
            let all = AgentLaunchApps(vscode: true, vscodeExtension: true, terminalHandler: true, claudeDesktop: true)
            func targets(_ apps: AgentLaunchApps, _ last: String?) -> [AgentLaunchTarget] {
                AgentLaunchMenu.items(apps: apps, last: last).map(\.target)
            }
            check("default order: VS Code, Terminal, Claude Desktop",
                  targets(all, nil) == [.vscode, .terminal, .claudeDesktop])
            check("the last chosen goes first",
                  targets(all, "claudeDesktop") == [.claudeDesktop, .vscode, .terminal]
                  && targets(all, "terminal") == [.terminal, .vscode, .claudeDesktop])
            check("an unknown saved value: the default order",
                  targets(all, "codex") == [.vscode, .terminal, .claudeDesktop] && targets(all, "") == targets(all, nil))
            check("only installed: no VS Code, no Claude Desktop",
                  targets(AgentLaunchApps(terminalHandler: true), nil) == [.terminal])
            check("the last chosen that is not installed is not shown",
                  targets(AgentLaunchApps(terminalHandler: true), "vscode") == [.terminal])
            let noExt = AgentLaunchMenu.items(apps: AgentLaunchApps(vscode: true, terminalHandler: true), last: nil)
            check("VS Code without the extension: shown, disabled, says why",
                  noExt.first == AgentLaunchMenu.Item(target: .vscode, blocked: .noVSCodeExtension) && !noExt[0].isEnabled)
            let noHandler = AgentLaunchMenu.items(apps: AgentLaunchApps(claudeDesktop: true), last: nil)
            check("Terminal without the claude-cli handler: shown, disabled, says why",
                  noHandler.first == AgentLaunchMenu.Item(target: .terminal, blocked: .noTerminalHandler))
            check("nothing ready: the menu says what to install",
                  AgentLaunchMenu.nothingToLaunch(AgentLaunchMenu.items(apps: AgentLaunchApps(), last: nil))
                  && AgentLaunchMenu.nothingToLaunch(AgentLaunchMenu.items(apps: AgentLaunchApps(vscode: true), last: nil))
                  && !AgentLaunchMenu.nothingToLaunch(noHandler))
            check("the UserDefaults key", AgentLaunchMenu.defaultsKey == "agentLaunchTarget")
        }

        // ── признак расширения ───────────────────────────────────────────────
        print("\nExtension")
        do {
            check("anthropic.claude-code-<version>-<platform>",
                  AgentLaunchMenu.hasClaudeCodeExtension(["ms-python.python-2024.1.0", "anthropic.claude-code-2.1.304-darwin-arm64"]))
            check("anthropic.claude-code-<version>", AgentLaunchMenu.hasClaudeCodeExtension(["anthropic.claude-code-2.1.0"]))
            check("an empty list: no", !AgentLaunchMenu.hasClaudeCodeExtension([]))
            check("other names: no",
                  !AgentLaunchMenu.hasClaudeCodeExtension(["anthropic.claude-code", "anthropic.claude-code-helper-1.0.0",
                                                          "someone.anthropic.claude-code-1.0.0", "extensions.json", ".obsolete"]))
        }

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll agent launch tests passed")
    }
}
