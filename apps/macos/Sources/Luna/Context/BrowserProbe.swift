import Foundation

/// URL и заголовок активной вкладки браузера через Apple Events (JXA).
enum BrowserProbe {
    enum Family: Equatable {
        case safari
        case chromium
    }

    enum Outcome: Equatable, Sendable {
        case page(url: String, title: String?)
        /// Нет открытой страницы, браузер не ответил вовремя или скрипт завершился ошибкой.
        case none
        /// Пользователь запретил Luna управлять этим браузером (Настройки → Автоматизация).
        case notAuthorized
    }

    /// У браузеров на Chromium общий словарь сценариев. Firefox сценарии не поддерживает.
    private static let families: [String: Family] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "org.chromium.Chromium": .chromium,
        "ru.cryptopro.chromium-gost": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        "ru.yandex.desktop.yandex-browser": .chromium,
    ]

    static func family(bundleId: String) -> Family? {
        families[bundleId]
    }

    /// JXA-скрипт печатает URL и заголовок двумя строками либо ничего, если страницы нет.
    /// Браузер адресуем по pid, а не по bundle id: у пользователя может работать несколько
    /// экземпляров (например, headless Chrome от инструментов автоматизации).
    static func script(pid: pid_t, family: Family) -> String {
        switch family {
        case .safari:
            """
            (() => {
                const app = Application(\(pid));
                if (app.documents.length === 0) return "";
                const page = app.documents[0];
                const url = page.url();
                return url ? url + "\\n" + page.name() : "";
            })()
            """
        case .chromium:
            """
            (() => {
                const app = Application(\(pid));
                if (app.windows.length === 0) return "";
                const tab = app.windows[0].activeTab;
                return tab.url() + "\\n" + tab.title();
            })()
            """
        }
    }

    static func parse(status: Int32, output: String, errorOutput: String) -> Outcome {
        guard status == 0 else {
            // errAEEventNotPermitted: пользователь отклонил запрос на управление приложением.
            return errorOutput.contains("-1743") ? .notAuthorized : .none
        }
        let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let url = lines.first?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return .none }
        let title = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return .page(url: url, title: title.isEmpty ? nil : title)
    }

    /// При первом обращении к браузеру macOS спрашивает у пользователя разрешение; пока он не ответил,
    /// скрипт висит — поэтому ждём недолго, а URL подхватится при следующем вызове панели.
    static func read(bundleId: String, pid: pid_t, timeout: TimeInterval = 2) async -> Outcome {
        guard let family = family(bundleId: bundleId) else { return .none }
        let source = script(pid: pid, family: family)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(source, timeout: timeout))
            }
        }
    }

    private static func run(_ source: String, timeout: TimeInterval) -> Outcome {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return .none }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .none
        }

        // Вывод — пара коротких строк, в буфер pipe он помещается целиком.
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorText = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return parse(status: process.terminationStatus, output: text, errorOutput: errorText)
    }
}
