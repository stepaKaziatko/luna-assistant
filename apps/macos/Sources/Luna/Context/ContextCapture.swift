import AppKit

/// Снимает контекст приложения, с которым пользователь работал в момент вызова панели.
enum ContextCapture {
    struct Target: Sendable {
        let app: AppInfo
        let pid: pid_t
    }

    /// Выделение длиннее этого обрезаем: в запрос столько не поместится.
    static let maxSelectionLength = 20_000

    /// Панели Luna не активируют приложение, поэтому активным остаётся приложение пользователя.
    @MainActor
    static func frontmostApp() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleId = app.bundleIdentifier else { return nil }
        return Target(app: AppInfo(bundleId: bundleId, name: app.localizedName ?? bundleId), pid: app.processIdentifier)
    }

    /// Асинхронная часть захвата: страница браузера, заголовок окна, выделенный текст.
    static func details(for target: Target) async -> CapturedContext.Details {
        async let page = BrowserProbe.read(bundleId: target.app.bundleId, pid: target.pid)

        var details = CapturedContext.Details()
        if AccessibilityProbe.isTrusted {
            let pid = target.pid
            let read = await _Concurrency.Task.detached(priority: .userInitiated) {
                AccessibilityProbe.read(pid: pid)
            }.value
            details.title = read.windowTitle
            switch read.selection {
            case .text(let text): details.selection = text
            case .empty: break
            case .unavailable: details.selection = await ClipboardProbe.copySelection(pid: pid)
            }
            details.selection = details.selection.flatMap(clean)
        } else {
            details.issues.append(.accessibility)
        }

        switch await page {
        case .page(let url, let title):
            details.url = url
            // Заголовок вкладки точнее заголовка окна: без суффикса с именем браузера.
            if let title { details.title = title }
        case .notAuthorized:
            details.issues.append(.automation(appName: target.app.name))
        case .none:
            break
        }
        return details
    }

    private static func clean(_ selection: String) -> String? {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(maxSelectionLength))
    }
}
