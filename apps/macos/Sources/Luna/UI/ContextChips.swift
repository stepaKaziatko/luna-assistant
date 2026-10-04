import AppKit
import SwiftUI

/// Иконки приложений по bundle id. Поиск приложения на диске не мгновенный, поэтому с кэшем.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(bundleId: String) -> NSImage? {
        if let cached = cache[bundleId] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleId] = icon
        return icon
    }
}

struct AppIconView: View {
    let bundleId: String
    var size: CGFloat = 14

    var body: some View {
        if let icon = AppIcons.icon(bundleId: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "macwindow")
        }
    }
}

/// Иконка приложения и короткая подпись источника задачи: домен, заголовок окна или имя приложения.
struct SourceLabel: View {
    let source: TaskContext

    var body: some View {
        HStack(spacing: 5) {
            if let app = source.app { AppIconView(bundleId: app.bundleId) }
            Text(source.sourceLabel ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct Chip<Content: View>: View {
    var onRemove: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 5) {
            content
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Убрать")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.white.opacity(0.1), in: Capsule())
    }
}

/// Чипы захваченного контекста в панели ввода: источник, выделение и подсказки о недостающих разрешениях.
struct ContextChips: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            if let source = state.context?.source {
                Chip(onRemove: state.dismissSource) {
                    SourceLabel(source: source)
                }
                .frame(maxWidth: 240)
                .fixedSize()
                .help(source.url ?? source.title ?? source.app?.name ?? "")
            }
            if let selection = state.context?.selection {
                Chip(onRemove: state.dismissSelection) {
                    Image(systemName: "text.quote").foregroundStyle(.secondary)
                    Text(selection.preview(limit: 40)).lineLimit(1)
                }
                .help(selection.preview(limit: 600))
            }
            ForEach(state.captureIssues, id: \.self) { issue in
                IssueChip(issue: issue)
            }
        }
    }
}

private struct IssueChip: View {
    let issue: CaptureIssue

    @EnvironmentObject private var state: AppState

    var body: some View {
        Chip(onRemove: onHide) {
            Button(action: { state.resolve(issue) }) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                    Text(title)
                }
                .foregroundStyle(.orange)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .help(explanation)
    }

    /// Подсказку про Accessibility можно скрыть насовсем: без выделения Luna остаётся рабочей.
    private var onHide: (() -> Void)? {
        issue == .accessibility ? { state.hideAccessibilityHint() } : nil
    }

    private var title: String {
        switch issue {
        case .accessibility: "Выделение: дать доступ"
        case .automation(let appName): "\(appName): дать доступ"
        }
    }

    private var explanation: String {
        switch issue {
        case .accessibility:
            "Чтобы видеть выделенный текст и заголовок окна, Luna нужен «Универсальный доступ» в настройках конфиденциальности."
        case .automation(let appName):
            "Чтобы видеть адрес страницы, разрешите Luna управлять «\(appName)»: Настройки → Конфиденциальность → Автоматизация."
        }
    }
}
