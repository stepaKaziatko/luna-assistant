import Foundation

// Живой прогон агента в проекте (LUNA-80): настоящий `claude`, модель haiku, три коротких хода.
// Изоляция, как в опытах аналитика: временная папка проекта, хук-регистратор через `--settings`,
// `--setting-sources project` (настройки пользователя с настоящим `luna-hook` не читаются) и вторым
// барьером `LUNA_CHAT_SESSION` в окружении (при нём настоящий релей молчит). Сокет Luna и
// `~/.claude/settings.json` не трогаются. Аргументы — из `ClaudeAgentArguments.build`, как в
// приложении; изоляционные флаги добавляет только этот тест.

@main
enum ClaudeAgentRunLiveTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        guard let executable = CLIResolver.executable(.claude) else { print("  ✗ claude не найден"); exit(1) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let project = root.appendingPathComponent("project")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let events = root.appendingPathComponent("events.jsonl")
        let decision = root.appendingPathComponent("decision")

        // Хук-регистратор: пишет событие и на PermissionRequest отвечает по файлу decision.
        let hook = root.appendingPathComponent("recorder.sh")
        let script = """
        #!/bin/sh
        input=$(cat)
        printf '%s\\n' "$input" >> '\(events.path)'
        case "$input" in
          *PermissionRequest*)
            if [ "$(cat '\(decision.path)')" = allow ]; then
              printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
            else
              printf '{}'
            fi ;;
        esac
        exit 0
        """
        try? script.write(to: hook, atomically: true, encoding: .utf8)
        chmod(hook.path, 0o755)
        let entry: [[String: Any]] = [["hooks": [["type": "command", "command": hook.path, "timeout": 30]]]]
        let names = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd"]
        let settings = ["hooks": Dictionary(uniqueKeysWithValues: names.map { ($0, entry) })]
        let settingsFile = root.appendingPathComponent("settings.json")
        try? JSONSerialization.data(withJSONObject: settings).write(to: settingsFile)

        var environment = ClaudeAgentEnvironment.build(base: ProcessInfo.processInfo.environment, executable: executable)
        environment[LunaChatSessions.environmentKey] = "live-test"   // только тест: релей Luna молчит

        func turn(_ prompt: String, id: String, resume: Bool, allow: Bool) -> (lines: [[String: Any]], status: Int32) {
            try? (allow ? "allow" : "none").write(to: decision, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ClaudeAgentArguments.build(model: "haiku", sessionID: id, resume: resume)
                + ["--settings", settingsFile.path, "--setting-sources", "project"]
            process.currentDirectoryURL = project
            process.environment = environment
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return ([], -1) }
            try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = data.split(separator: 0x0A).compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
            }
            return (lines, process.terminationStatus)
        }

        func hookEvents() -> [[String: Any]] {
            let text = (try? String(contentsOf: events, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }

        print("Разрешено хуком")
        let id = UUID().uuidString.lowercased()
        let allowed = turn("Use the Bash tool to run exactly: touch created.txt — then reply DONE.", id: id, resume: false, allow: true)
        let requests = hookEvents().filter { $0["hook_event_name"] as? String == "PermissionRequest" }
        check("PermissionRequest Bash пришёл хуку с переданным session_id",
              requests.contains { $0["session_id"] as? String == id && $0["tool_name"] as? String == "Bash" })
        check("ответ allow → файл создан",
              FileManager.default.fileExists(atPath: project.appendingPathComponent("created.txt").path))
        check("ход закончился без ошибки", allowed.status == 0)

        print("Ответ хука без решения")
        let denyId = UUID().uuidString.lowercased()
        let denied = turn("Use the Bash tool to run exactly: touch denied.txt — then reply DONE.", id: denyId, resume: false, allow: false)
        let result = denied.lines.last { $0["type"] as? String == "result" }
        let denials = (result?["permission_denials"] as? [[String: Any]]) ?? []
        check("permission_denials содержит Bash", denials.contains { $0["tool_name"] as? String == "Bash" })
        check("файла нет", !FileManager.default.fileExists(atPath: project.appendingPathComponent("denied.txt").path))

        print("Продолжение")
        let next = turn("Reply with the single word: ok", id: id, resume: true, allow: true)
        let ids = Set(next.lines.compactMap { $0["session_id"] as? String })
        check("--resume → тот же session_id", ids == [id])
        check("хуки хода продолжения — тот же session_id",
              hookEvents().filter { $0["hook_event_name"] as? String == "UserPromptSubmit" }
                .compactMap { $0["session_id"] as? String }.filter { $0 == id }.count == 2)

        print(failures == 0 ? "\nAll live agent checks passed" : "\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
