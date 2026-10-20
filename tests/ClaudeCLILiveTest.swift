import Foundation

// Живой прогон: настоящий `claude`, модель haiku, один короткий вопрос по подписке.
@main
enum ClaudeCLILiveTest {
    static func main() async {
        guard let executable = CLIResolver.executable(.claude) else {
            print("  ✗ claude не найден"); exit(1)
        }
        let status = await ClaudeAuthProbe.check()
        print("  статус входа: \(status)")
        let request = ClaudeCLIRequest(
            executable: executable,
            prompt: "Reply with the single word: ok",
            systemPrompt: "You are a test. Answer with one word.",
            model: "haiku",
            sessionID: UUID().uuidString.lowercased(),
            resume: false,
            workingDirectory: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("chat"),
            environment: CLIResolver.environment(base: ProcessInfo.processInfo.environment, executable: executable))
        let result = await ClaudeCLIProcess().run(request) { _ in }
        switch result {
        case .success(let text) where !text.isEmpty:
            print("  ✓ ответ получен: \(text.prefix(40))")
        default:
            print("  ✗ \(result)"); exit(1)
        }

        // Вопрос в проекте (LUNA-75): без --safe-mode Claude Code сам читает CLAUDE.md папки проекта.
        let project = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("project")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try? "# Test project\n\nThe project codeword is ZEBRA-42. When asked for the codeword, reply with it.\n"
            .write(to: project.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        var inProject = ClaudeCLIRequest(
            executable: executable,
            prompt: "What is the project codeword? Reply with the codeword only.",
            systemPrompt: "You are a test. Answer briefly.",
            model: "haiku",
            sessionID: UUID().uuidString.lowercased(),
            resume: false,
            workingDirectory: project,
            environment: CLIResolver.environment(base: ProcessInfo.processInfo.environment, executable: executable))
        inProject.inProject = true
        let projectResult = await ClaudeCLIProcess().run(inProject) { _ in }
        switch projectResult {
        case .success(let text) where text.contains("ZEBRA-42"):
            print("  ✓ в проекте ответ называет кодовое слово из CLAUDE.md: \(text.prefix(40))")
        default:
            print("  ✗ в проекте: \(projectResult)"); exit(1)
        }
    }
}
