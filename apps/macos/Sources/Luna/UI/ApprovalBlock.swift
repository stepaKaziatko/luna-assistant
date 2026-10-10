import SwiftUI

/// Чей запрос показывает блок: задача Luna (карточка диалога) или сессия агента, запущенная не Luna (плитка,
/// карточка и окно сессии). Внешний вид один; различается только то, куда уходит ответ.
enum ApprovalSubject: Hashable {
    case task(id: String)
    case session(id: String)
}

/// Ждущий ответа человека: кто и какой запрос.
struct PendingApproval: Equatable {
    let subject: ApprovalSubject
    let approval: ApprovalRequest
}

/// Блок подтверждения: что исполнитель или агент собирается сделать и две кнопки — «Разрешить»
/// и «Отклонить». Рисуется из `ApprovalRequest` (`TaskInfo.approval`, `AgentSession.approval`) и ничего не знает об инструментах: `summary`, `target`
/// и `detail` — строки от ядра, показываются как текст, не Markdown и не ссылками. Кнопки — над подробностями,
/// чтобы быть видными без прокрутки; разрешение даётся только кликом: клавиш-сокращений у кнопок нет.
/// Фон — как у поля продолжения, своей чёрной фигуры у блока нет. Команда shell показывается целиком
/// отдельной прокручиваемой областью под кнопками: человек разрешает именно её, а не подпись агента.
struct ApprovalBlock: View {
    let subject: ApprovalSubject
    let approval: ApprovalRequest

    @EnvironmentObject private var state: AppState

    /// Ответ уже ушёл ядру, снимка ещё нет: кнопки неактивны, повторный клик не уходит.
    private var isPending: Bool { state.approvalPending.contains(approval.id) }

    private var presentation: ApprovalPresentation { ApprovalPresentation(approval) }

    var body: some View {
        let presentation = presentation
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: presentation.summary)
                    .font(.system(size: 13, weight: .semibold))
                if let target = presentation.inlineTarget {
                    Text(verbatim: target)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(target)
                }
                Spacer(minLength: 8)
                Button("Отклонить") { state.answerApproval(subject, allow: false) }
                    .controlSize(.small)
                    .disabled(isPending)
                Button("Разрешить") { state.answerApproval(subject, allow: true) }
                    .controlSize(.small)
                    .disabled(isPending)
            }
            if let command = presentation.command {
                CommandText(command: command)
            }
            if let detail = presentation.detail {
                Text(verbatim: detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Другие задачи и сессии тоже ждут ответа: строка ведёт к самой ранней из них. Сама карточка не переключается.
            if let others = ApprovalPresentation.othersLine(state.otherPendingApprovals(than: subject).count) {
                Button(others) { state.openNextApproval(after: subject) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Открыть следующий запрос подтверждения")
            }
            if let error = state.approvalError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Что показывает блок подтверждения; считается из `ApprovalRequest` без отрисовки, чтобы проверяться `swift test`.
struct ApprovalPresentation: Equatable {
    /// Одна строка о действии.
    let summary: String
    /// Над чем действие — в строке с кнопками, в две строки с обрезкой посередине: путь файла.
    let inlineTarget: String?
    /// Команда shell — ровно `target`: без обрезки, без схлопывания строк и пробелов; показывается отдельной областью.
    let command: String?
    /// Подробности под действием; пустые не показываются.
    let detail: String?

    /// Строка «ещё N ждут подтверждения» о других ждущих задачах и сессиях; nil — других нет.
    static func othersLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let verb = count % 10 == 1 && count % 100 != 11 ? "ждёт" : "ждут"
        return "ещё \(count) \(verb) подтверждения"
    }

    init(_ approval: ApprovalRequest) {
        summary = approval.summary
        if approval.kind == .shell {
            command = approval.target
            inlineTarget = nil
        } else {
            command = nil
            inlineTarget = approval.target
        }
        detail = approval.detail.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Команда shell целиком: моноширинно, переводы строк сохранены, длинные строки переносятся, текст выделяется.
/// Высота — по содержимому, но не больше `maxHeight` (около одиннадцати строк); дальше — прокрутка с видимой полосой.
/// Кнопки остаются над областью и видны без прокрутки.
struct CommandText: View {
    let command: String

    /// Предел высоты области: около одиннадцати строк моноширинного текста 12 pt с отступами.
    static let maxHeight: CGFloat = 170

    @State private var contentHeight: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// Полосы прокрутки macOS в режиме «при прокрутке» скрыты, пока область стоит, — и человек не видит, что
    /// команда длиннее показанного. Тогда блок рисует свою неподвижную полосу; при постоянных полосах — системную.
    private var drawsOwnScroller: Bool { NSScroller.preferredScrollerStyle == .overlay }

    private var height: CGFloat { min(max(contentHeight, 24), Self.maxHeight) }

    var body: some View {
        ScrollView(.vertical) {
            Text(verbatim: command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                    contentHeight = frame.height
                    offset = -frame.minY
                }
        }
        .coordinateSpace(name: Self.space)
        .scrollIndicators(drawsOwnScroller ? .hidden : .visible)
        .frame(height: height)
        .overlay(alignment: .topTrailing) {
            if drawsOwnScroller, let thumb = Self.thumb(content: contentHeight, visible: height, offset: offset) {
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: 4, height: thumb.height)
                    .offset(x: -3, y: thumb.y)
                    .allowsHitTesting(false)
            }
        }
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private static let space = "approval-command"

    /// Положение и высота бегунка полосы прокрутки; nil — всё помещается, полосы нет.
    static func thumb(content: CGFloat, visible: CGFloat, offset: CGFloat) -> (y: CGFloat, height: CGFloat)? {
        guard content > visible + 0.5, visible > 0 else { return nil }
        let inset: CGFloat = 3
        let track = visible - inset * 2
        let height = max(track * visible / content, 16)
        let progress = min(max(offset / (content - visible), 0), 1)
        return (inset + (track - height) * progress, height)
    }
}
