import Foundation

struct CoreLaunch {
    let node: URL
    let entry: URL
    let environment: [String: String]
}

enum CoreLocatorError: LocalizedError {
    case entryNotFound
    case nodeNotFound

    var errorDescription: String? {
        switch self {
        case .entryNotFound: "Не найдено ядро (core/dist/main.js). Выполните `npm run build`."
        case .nodeNotFound: "Не найден Node.js. Установите Node 22+ или задайте LUNA_NODE."
        }
    }
}

/// Находит Node и точку входа ядра и собирает окружение для его запуска.
enum CoreLocator {
    private static let fallbackDirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.volta/bin",
    ]

    static func locate() throws -> CoreLaunch {
        var environment = ProcessInfo.processInfo.environment
        guard let entry = findEntry(environment: environment) else { throw CoreLocatorError.entryNotFound }

        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + fallbackDirs
        var node = environment["LUNA_NODE"].flatMap(executable) ?? find("node", in: dirs)
        if node == nil, let shellPath = loginShellPath() {
            // Приложение из Finder получает урезанный PATH; настоящий знает только shell пользователя (nvm и т.п.).
            dirs = shellPath.split(separator: ":").map(String.init) + dirs
            node = find("node", in: dirs)
        }
        guard let node else { throw CoreLocatorError.nodeNotFound }

        // Ядро ищет по этому PATH CLI исполнителей.
        environment["PATH"] = unique(dirs).joined(separator: ":")
        return CoreLaunch(node: node, entry: entry, environment: environment)
    }

    private static func findEntry(environment: [String: String]) -> URL? {
        let files = FileManager.default
        if let override = environment["LUNA_CORE_ENTRY"] {
            return files.fileExists(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("core/main.js"),
           files.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Разработка: бинарник лежит внутри репозитория (.build/… или build/Luna.app/…).
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            guard let current = dir else { break }
            let candidate = current.appendingPathComponent("core/dist/main.js")
            if files.fileExists(atPath: candidate.path) { return candidate }
            dir = current.path == "/" ? nil : current.deletingLastPathComponent()
        }
        return nil
    }

    private static func find(_ name: String, in dirs: [String]) -> URL? {
        dirs.lazy.compactMap { executable($0 + "/" + name) }.first
    }

    private static func executable(_ path: String) -> URL? {
        FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// PATH из интерактивного login-shell пользователя. Маркеры отсекают то, что печатают rc-файлы.
    private static func loginShellPath() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "printf '__LUNA_PATH__%s__LUNA_END__' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let collected = LockedData()
        output.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        guard (try? process.run()) != nil else { return nil }
        if exited.wait(timeout: .now() + 5) == .timedOut { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil

        let text = String(decoding: collected.value, as: UTF8.self)
        guard let start = text.range(of: "__LUNA_PATH__"),
              let end = text.range(of: "__LUNA_END__", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
