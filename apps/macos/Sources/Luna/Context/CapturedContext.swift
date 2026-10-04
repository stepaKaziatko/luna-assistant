import Foundation

/// Разрешение macOS, которого не хватило при захвате контекста.
enum CaptureIssue: Hashable, Sendable {
    /// Нет доступа к Accessibility: недоступны выделенный текст и заголовок окна.
    case accessibility
    /// Пользователь запретил Luna управлять браузером: недоступны URL и заголовок вкладки.
    case automation(appName: String)
}

/// Контекст, снятый в момент вызова панели ввода, и то, что пользователь из него убрал.
struct CapturedContext: Equatable {
    /// То, что снимается асинхронно, уже после показа панели.
    struct Details: Equatable, Sendable {
        var url: String?
        var title: String?
        var selection: String?
        var issues: [CaptureIssue] = []
    }

    var app: AppInfo
    var details = Details()
    var sourceDismissed = false
    var selectionDismissed = false

    /// Источник запроса: приложение, страница и заголовок — один чип в панели ввода.
    var source: TaskContext? {
        sourceDismissed ? nil : TaskContext(app: app, selection: nil, title: details.title, url: details.url)
    }

    var selection: String? {
        selectionDismissed ? nil : details.selection
    }

    /// То, что уйдёт в ядро вместе с задачей.
    var payload: TaskContext? {
        guard source != nil || selection != nil else { return nil }
        return TaskContext(app: source?.app, selection: selection, title: source?.title, url: source?.url)
    }
}

extension TaskContext {
    /// Короткая подпись источника: домен страницы, иначе заголовок окна, иначе имя приложения.
    var sourceLabel: String? {
        if let host = url.flatMap(Self.host) { return host }
        if let title, !title.isEmpty { return title }
        return app?.name
    }

    private static func host(of url: String) -> String? {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension String {
    /// Однострочный фрагмент для чипа: пробельные символы схлопнуты, длина ограничена.
    func preview(limit: Int) -> String {
        let flat = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? flat.prefix(limit) + "…" : flat
    }
}
