import Foundation

// MARK: - Keys of the island
//
// The island is driven from the keyboard once its panel is the key window (a hotkey that opens a
// page, or a click). Everything that decides what a key does lives here, as plain values and pure
// functions, so that it is tested without a window (`scripts/test-island-keys.sh`):
//
//  * `IslandKeyTable` — the one table of bindings. The local monitor of `IslandWindowController`
//    resolves a key through it, the `?` hint draws its rows, Settings → Shortcuts lists it, and
//    `ShortcutLogic.islandShortcuts` is built from it: they cannot disagree.
//  * `IslandGrid`, `AgentsSelection` — moving over the tiles of the Agents page.
//  * `ApprovalKeys`, `QuestionKeys`, `AnswerKeyChoice` — the two-step answer: a key picks a button
//    or a variant, ↩ sends it, and the pick belongs to the request that was on screen.
//  * `PageHotkey` — what a page hotkey (⌃⌥S, ⌃⌥P) does.
//
// Nothing here knows AppKit: the monitor turns an `NSEvent` into an `IslandKeyInput`.

// MARK: - Input

/// Virtual key codes (`kVK_*`, the same as `NSEvent.keyCode`).
enum IslandKeyCode {
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let `return`: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let delete: UInt16 = 51
    static let space: UInt16 = 49
    static let escape: UInt16 = 53

    /// Digit row: key code → digit.
    static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
}

/// A key press as the monitor sees it.
struct IslandKeyInput: Equatable {
    var keyCode: UInt16
    /// Only the four modifier bits (`ShortcutSpec.cmdBit` …); caps lock, fn, numeric pad are cut off.
    var modifiers: UInt
    var isRepeat: Bool = false
    /// What the key types with the modifiers on: only "?" is told apart by it (no fixed key code).
    var character: String = ""
}

// MARK: - Where a key is pressed

/// What the island shows when a key arrives: one value, decided from the page and from what
/// can be answered on it.
enum IslandKeyArea: CaseIterable, Hashable {
    /// The Agents page.
    case agents
    /// The page of an agent with nothing to answer.
    case agentPage
    /// The page of an agent whose permission request waits at the head of the queue.
    case agentPageApproval
    /// The page of an agent with a question.
    case agentPageQuestion
    /// The card of a permission request.
    case approvalCard
    /// The card of a question.
    case questionCard
    /// The "Active tabs" page.
    case tabs
    case github
    case chat
    case wardrobe
    /// Every other page: mail, search, settings, the transient ones.
    case other

    static func of(page: IslandView, answer: IslandAnswerTarget) -> IslandKeyArea {
        switch page {
        case .agents:    return .agents
        case .agentPreview:
            switch answer {
            case .none:     return .agentPage
            case .approval: return .agentPageApproval
            case .question: return .agentPageQuestion
            }
        case .approval:  return .approvalCard
        case .question:  return .questionCard
        case .overview:  return .tabs
        case .github:    return .github
        case .prompt:    return .chat
        case .wardrobe:  return .wardrobe
        default:         return .other
        }
    }

    static let everywhere = Set(IslandKeyArea.allCases)
    static let agentPages: Set<IslandKeyArea> = [.agentPage, .agentPageApproval, .agentPageQuestion]
    static let approvals: Set<IslandKeyArea> = [.approvalCard, .agentPageApproval]
    static let questions: Set<IslandKeyArea> = [.questionCard, .agentPageQuestion]
}

/// What can be answered with the keys on the page that is on screen, by the id of the request.
enum IslandAnswerTarget: Equatable {
    case none
    /// The permission request at the head of the queue.
    case approval(id: UUID, offersAlways: Bool)
    /// The question the app holds.
    case question(id: UUID)

    var requestId: UUID? {
        switch self {
        case .none: return nil
        case .approval(let id, _), .question(let id): return id
        }
    }
}

// MARK: - Commands

enum IslandGridStep: Equatable { case left, right, up, down }

/// What a key asks the island to do while a question is on screen. The question panel owns the
/// state of the answer (which variants are marked, which question of several), so it runs these.
enum QuestionKey: Equatable {
    /// Up / left = -1, down / right = +1.
    case move(Int)
    /// 1…4: pick the N-th variant. Never sends.
    case digit(Int)
    /// Space: mark / unmark in a multiple choice.
    case toggle
    /// ↩: send the picked variant, go on, or open the "Other…" field.
    case confirm
}

enum IslandKeyCommand: Equatable {
    // The keys the island has always had (all with ⌘).
    case cyclePill(Int)
    case pillNumber(Int)
    case moveCard(Int)
    case openCardItem
    case toggleDiff
    case sendMessage
    case newConversation
    case openSettings
    case togglePin
    // The Agents page and the page of an agent.
    case moveTile(IslandGridStep)
    case openSelectedAgent
    case jumpToAgent
    /// From the page of an agent to the list.
    case back
    /// To the home page.
    case home
    // The answer.
    case approvalMove(Int)
    case approvalConfirm
    case question(QuestionKey)
    // GitHub.
    case githubMove(IslandGridStep)
    case githubOpen
    case toggleHelp

    /// The command of a digit key: the binding has a placeholder, the digit comes from the key.
    func withDigit(_ n: Int) -> IslandKeyCommand {
        switch self {
        case .pillNumber:        return .pillNumber(n)
        case .question(.digit):  return .question(.digit(n))
        default:                 return self
        }
    }
}

// MARK: - The table

/// How a key is told: a key code, one of several, a digit of the digit row, or a typed character.
enum IslandKeyMatch: Equatable {
    case code(UInt16)
    case codes([UInt16])
    case digits(ClosedRange<Int>)
    case character(String)

    func matches(_ input: IslandKeyInput) -> (hit: Bool, digit: Int?) {
        switch self {
        case .code(let c):    return (input.keyCode == c, nil)
        case .codes(let cs):  return (cs.contains(input.keyCode), nil)
        case .digits(let r):
            if let d = IslandKeyCode.digits[input.keyCode], r.contains(d) { return (true, d) }
            return (false, nil)
        case .character(let s): return (input.character == s, nil)
        }
    }
}

/// The blocks Settings and the hint draw the table in.
enum IslandKeyGroup: String, CaseIterable {
    case everywhere, agents, agentPage, answers, tabs, github, chat

    /// Key of the title in `Localizable.xcstrings`.
    var titleKey: String { "shortcut.island.group.\(rawValue)" }
}

struct IslandKeyBinding {
    /// How the key is written for a person: "⌘→", "1 – 4".
    let display: String
    let match: IslandKeyMatch
    /// Exactly these modifiers (of ⌘ ⌃ ⌥ ⇧), no more and no fewer.
    let modifiers: UInt
    let areas: Set<IslandKeyArea>
    /// nil: the key is shown in the table but handled elsewhere (⎋ goes down the responder chain).
    let command: IslandKeyCommand?
    /// Key of the description in `Localizable.xcstrings`.
    let descriptionKey: String
    let group: IslandKeyGroup
    /// Whether holding the key repeats the command. An action (↩, Space, ⌘↩) never does.
    let repeatable: Bool

    /// A key without ⌘ ⌃ ⌥ is typing as far as a text field is concerned: it is ours only when no
    /// text is being edited.
    var yieldsToText: Bool {
        modifiers & (ShortcutSpec.cmdBit | ShortcutSpec.ctrlBit | ShortcutSpec.optBit) == 0
    }
}

struct IslandKeyContext: Equatable {
    var page: IslandView
    var answer: IslandAnswerTarget = .none
    /// The first responder of the panel edits text (a field, the chat, the "Other…" field).
    var firstResponderIsText: Bool = false

    var area: IslandKeyArea { .of(page: page, answer: answer) }
}

/// One row of the table for a person: keys joined, one description.
struct IslandKeyRow: Equatable {
    let keys: String
    let descriptionKey: String
    let group: IslandKeyGroup
}

enum IslandKeyTable {

    private static let cmd = ShortcutSpec.cmdBit
    private static let none: UInt = 0
    private static let shift = ShortcutSpec.shiftBit

    private static func bind(_ display: String, _ match: IslandKeyMatch, _ mods: UInt = 0,
                             _ areas: Set<IslandKeyArea>, _ command: IslandKeyCommand?,
                             _ descriptionKey: String, _ group: IslandKeyGroup,
                             repeatable: Bool = false) -> IslandKeyBinding {
        IslandKeyBinding(display: display, match: match, modifiers: mods, areas: areas, command: command,
                         descriptionKey: descriptionKey, group: group, repeatable: repeatable)
    }

    private static let enter = IslandKeyMatch.codes([IslandKeyCode.return, IslandKeyCode.keypadEnter])

    /// Every key of the island. The order is the order of the rows in Settings and in the hint.
    /// Two bindings never share a key in the same area (tested).
    static let bindings: [IslandKeyBinding] = {
        let all = IslandKeyArea.everywhere
        let L = IslandKeyCode.left, R = IslandKeyCode.right, U = IslandKeyCode.up, D = IslandKeyCode.down
        var t: [IslandKeyBinding] = []

        // Everywhere: the keys the island has always had. They all carry ⌘ and work with the focus in a field too.
        t += [
            bind("⌘→", .code(R), cmd, all, .cyclePill(+1), "shortcut.island.next-prev", .everywhere, repeatable: true),
            bind("⌘←", .code(L), cmd, all, .cyclePill(-1), "shortcut.island.next-prev", .everywhere, repeatable: true),
            bind("⌘1 – ⌘9", .digits(1...9), cmd, all, .pillNumber(0), "shortcut.island.by-number", .everywhere, repeatable: true),
            bind("⌘↓", .code(D), cmd, all, .moveCard(+1), "shortcut.island.nav-items", .everywhere, repeatable: true),
            bind("⌘↑", .code(U), cmd, all, .moveCard(-1), "shortcut.island.nav-items", .everywhere, repeatable: true),
            bind("⌘O", .code(31), cmd, all, .openCardItem, "shortcut.island.open", .everywhere),
            bind("⌘E", .code(14), cmd, [.tabs], .toggleDiff, "shortcut.island.diff", .tabs),
            bind("⌘↩", enter, cmd, [.chat], .sendMessage, "shortcut.island.send", .chat),
            bind("⌘K", .code(40), cmd, [.chat], .newConversation, "shortcut.island.new-convo", .chat),
            bind("⌘,", .code(43), cmd, all, .openSettings, "shortcut.island.settings", .everywhere),
            bind("⌘P", .code(35), cmd, all, .togglePin, "shortcut.island.pin", .everywhere),
            // ⎋ stays with the responder chain (a field or a card first, then the island closes).
            bind("⎋", .code(IslandKeyCode.escape), none, all, nil, closeDescriptionKey, .everywhere),
            bind("?", .character("?"), shift, all, .toggleHelp, "shortcut.island.help", .everywhere),
        ]

        // The Agents page.
        t += [
            bind("←", .code(L), none, [.agents], .moveTile(.left), "shortcut.island.tile-select", .agents, repeatable: true),
            bind("→", .code(R), none, [.agents], .moveTile(.right), "shortcut.island.tile-select", .agents, repeatable: true),
            bind("↑", .code(U), none, [.agents], .moveTile(.up), "shortcut.island.tile-select", .agents, repeatable: true),
            bind("↓", .code(D), none, [.agents], .moveTile(.down), "shortcut.island.tile-select", .agents, repeatable: true),
            bind("↩", enter, none, [.agents], .openSelectedAgent, "shortcut.island.agent-open", .agents),
            bind("⌘↩", enter, cmd, [.agents], .jumpToAgent, "shortcut.island.agent-jump", .agents),
        ]

        // The page of an agent.
        t += [
            bind("⌫", .code(IslandKeyCode.delete), none, IslandKeyArea.agentPages, .back, "shortcut.island.back-list", .agentPage),
            bind("⌘↩", enter, cmd, IslandKeyArea.agentPages, .jumpToAgent, "shortcut.island.agent-jump", .agentPage),
        ]

        // A permission request: Deny / Allow / Always, then ↩.
        t += [
            bind("←", .code(L), none, IslandKeyArea.approvals, .approvalMove(-1), "shortcut.island.approval-choose", .answers, repeatable: true),
            bind("→", .code(R), none, IslandKeyArea.approvals, .approvalMove(+1), "shortcut.island.approval-choose", .answers, repeatable: true),
            bind("↩", enter, none, IslandKeyArea.approvals, .approvalConfirm, "shortcut.island.approval-confirm", .answers),
        ]

        // A question: the variants and "Other…" in one list, then ↩.
        t += [
            bind("←", .code(L), none, IslandKeyArea.questions, .question(.move(-1)), "shortcut.island.question-choose", .answers, repeatable: true),
            bind("↑", .code(U), none, IslandKeyArea.questions, .question(.move(-1)), "shortcut.island.question-choose", .answers, repeatable: true),
            bind("→", .code(R), none, IslandKeyArea.questions, .question(.move(+1)), "shortcut.island.question-choose", .answers, repeatable: true),
            bind("↓", .code(D), none, IslandKeyArea.questions, .question(.move(+1)), "shortcut.island.question-choose", .answers, repeatable: true),
            bind("1 – 4", .digits(1...4), none, IslandKeyArea.questions, .question(.digit(0)), "shortcut.island.question-digit", .answers),
            bind("Space", .code(IslandKeyCode.space), none, IslandKeyArea.questions, .question(.toggle), "shortcut.island.question-toggle", .answers),
            bind("↩", enter, none, IslandKeyArea.questions, .question(.confirm), "shortcut.island.question-confirm", .answers),
        ]

        // Active tabs.
        t += [
            bind("←", .code(L), none, [.tabs], .cyclePill(-1), "shortcut.island.next-prev", .tabs, repeatable: true),
            bind("→", .code(R), none, [.tabs], .cyclePill(+1), "shortcut.island.next-prev", .tabs, repeatable: true),
            bind("↓", .code(D), none, [.tabs], .moveCard(+1), "shortcut.island.nav-items", .tabs, repeatable: true),
            bind("↑", .code(U), none, [.tabs], .moveCard(-1), "shortcut.island.nav-items", .tabs, repeatable: true),
            bind("↩", enter, none, [.tabs], .openCardItem, "shortcut.island.open", .tabs),
        ]

        // GitHub.
        t += [
            bind("←", .code(L), none, [.github], .githubMove(.left), "shortcut.island.github-select", .github, repeatable: true),
            bind("→", .code(R), none, [.github], .githubMove(.right), "shortcut.island.github-select", .github, repeatable: true),
            bind("↑", .code(U), none, [.github], .githubMove(.up), "shortcut.island.github-select", .github, repeatable: true),
            bind("↓", .code(D), none, [.github], .githubMove(.down), "shortcut.island.github-select", .github, repeatable: true),
            bind("↩", enter, none, [.github], .githubOpen, "shortcut.island.github-open", .github),
        ]

        // Back to the home page: from the pages that are one level down.
        t += [
            bind("⌫", .code(IslandKeyCode.delete), none, [.tabs, .github, .wardrobe], .home,
                 "shortcut.island.back-home", .tabs),
        ]
        return t
    }()

    /// What a key does in `context`, nil when it is not ours (or must not act now): the key then
    /// goes on to whoever would have it without the island — a text field, a button, the chain.
    static func resolve(_ input: IslandKeyInput, context: IslandKeyContext) -> IslandKeyCommand? {
        let area = context.area
        let mods = input.modifiers & ShortcutSpec.modMask
        for binding in bindings {
            guard let command = binding.command, binding.areas.contains(area),
                  binding.modifiers == mods else { continue }
            let (hit, digit) = binding.match.matches(input)
            guard hit else { continue }
            // Typing: a field gets its keys.
            if binding.yieldsToText && context.firstResponderIsText { return nil }
            // Holding a key never repeats an action.
            if input.isRepeat && !binding.repeatable { return nil }
            return digit.map { command.withDigit($0) } ?? command
        }
        return nil
    }

    /// Pages that show a text field to type in: the chat, the mail draft, and the question and the
    /// page of an agent (the "Other…" field). On the others a field editor with
    /// the keyboard is a hidden field, not typing.
    static func pageHasTextInput(_ page: IslandView) -> Bool {
        switch page {
        case .prompt, .mail, .question, .agentPreview: return true
        default: return false
        }
    }

    // MARK: Rows for people

    /// The rows of the table, a binding per key merged with its siblings of the same
    /// description and block: "⌘→ / ⌘←". `area` keeps only the rows that work on that area.
    /// В строке «Закрыть» рядом с `⎋` — глобальное «Свернуть шторку» из настроек (`⎋ / ⌘⎋`).
    static func rows(area: IslandKeyArea? = nil) -> [IslandKeyRow] {
        rows(area: area, collapseKeys: ShortcutLogic.collapseIslandKeys)
    }

    /// Описание строки «Закрыть»: к ней приписывается сочетание «Свернуть шторку».
    static let closeDescriptionKey = "shortcut.island.close"

    /// То же с явным сочетанием «Свернуть шторку» (nil — выключено): тест не зависит от настроек.
    /// Само сочетание в `bindings` не входит — его ловит Carbon, а не монитор острова.
    static func rows(area: IslandKeyArea?, collapseKeys: String?) -> [IslandKeyRow] {
        var rows = tableRows(area: area)
        if let extra = collapseKeys, !extra.isEmpty,
           let i = rows.firstIndex(where: { $0.descriptionKey == closeDescriptionKey }) {
            let old = rows[i]
            if !old.keys.split(separator: "/").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(extra) {
                rows[i] = IslandKeyRow(keys: old.keys + " / " + extra, descriptionKey: old.descriptionKey, group: old.group)
            }
        }
        return rows
    }

    private static func tableRows(area: IslandKeyArea?) -> [IslandKeyRow] {
        var rows: [IslandKeyRow] = []
        for binding in bindings where area.map({ binding.areas.contains($0) }) ?? true {
            let shown = binding.display
            if let i = rows.firstIndex(where: { $0.descriptionKey == binding.descriptionKey && $0.group == binding.group }) {
                let old = rows[i]
                if !old.keys.split(separator: "/").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(shown) {
                    rows[i] = IslandKeyRow(keys: old.keys + " / " + shown,
                                           descriptionKey: old.descriptionKey, group: old.group)
                }
            } else {
                rows.append(IslandKeyRow(keys: shown, descriptionKey: binding.descriptionKey, group: binding.group))
            }
        }
        return rows
    }

    /// Rows of one block, in table order.
    static func rows(in group: IslandKeyGroup) -> [IslandKeyRow] {
        rows().filter { $0.group == group }
    }
}

// MARK: - Tiles of the Agents page

enum IslandGrid {
    static let columns = 4

    /// The tile a step leads to, over `count` tiles in rows of `columns`. Nothing wraps around.
    /// - No tile picked: → and ↓ pick the first (the one that needs you most), ← and ↑ the last.
    /// - ← and → step by one tile, from the end of a row to the start of the next.
    /// - ↓ steps a row; below an incomplete last row it falls on its last tile; from the last row it stays.
    /// - ↑ steps a row back; from the first row it stays.
    /// - A pick outside the list (a session closed meanwhile) is clamped before the step.
    static func move(selection: Int?, step: IslandGridStep, count: Int, columns: Int = IslandGrid.columns) -> Int? {
        guard count > 0, columns > 0 else { return nil }
        guard let selection else {
            switch step {
            case .right, .down: return 0
            case .left, .up:    return count - 1
            }
        }
        let cur = max(0, min(count - 1, selection))
        switch step {
        case .left:  return max(0, cur - 1)
        case .right: return min(count - 1, cur + 1)
        case .up:    return cur - columns >= 0 ? cur - columns : cur
        case .down:
            if cur + columns < count { return cur + columns }
            return cur / columns < (count - 1) / columns ? count - 1 : cur
        }
    }
}

/// The pick on the Agents page lives by the id of the session, not by position: the order of the
/// tiles changes as the sessions change, the pick stays on the same agent.
enum AgentsSelection {
    /// The pick that is still there: nil when its session is gone.
    static func reconcile(_ id: String?, ids: [String]) -> String? {
        guard let id, ids.contains(id) else { return nil }
        return id
    }

    static func move(id: String?, step: IslandGridStep, ids: [String]) -> String? {
        let current = reconcile(id, ids: ids).flatMap { ids.firstIndex(of: $0) }
        return IslandGrid.move(selection: current, step: step, count: ids.count).map { ids[$0] }
    }

    /// Шаг по плиткам, разложенным группами («По проектам», LUNA-75): каждая группа на экране
    /// начинается с нового ряда по `columns` плиток.
    /// - Одна группа (или без группировки) — ровно `move(id:step:ids:)`.
    /// - ← и → — по сплошному порядку групп, как раньше: с конца группы на начало следующей.
    /// - ↑ и ↓ — на ряд выше или ниже на экране, через заголовок группы тоже; столбец сохраняется,
    ///   у короткого ряда шаг попадает на его последнюю плитку. С первого ряда ↑ и с последнего ↓
    ///   выбор стоит на месте.
    static func move(id: String?, step: IslandGridStep, sections: [[String]],
                     columns: Int = IslandGrid.columns) -> String? {
        let sections = sections.filter { !$0.isEmpty }
        let ids = sections.flatMap { $0 }
        guard sections.count > 1, columns > 0 else { return move(id: id, step: step, ids: ids) }
        guard let current = reconcile(id, ids: ids) else { return move(id: nil, step: step, ids: ids) }
        switch step {
        case .left, .right:
            return move(id: current, step: step, ids: ids)
        case .up, .down:
            let rows = sections.flatMap { section in
                stride(from: 0, to: section.count, by: columns).map {
                    Array(section[$0..<min($0 + columns, section.count)])
                }
            }
            guard let row = rows.firstIndex(where: { $0.contains(current) }),
                  let column = rows[row].firstIndex(of: current) else { return current }
            let target = step == .up ? row - 1 : row + 1
            guard rows.indices.contains(target) else { return current }
            return rows[target][min(column, rows[target].count - 1)]
        }
    }
}

// MARK: - GitHub page

/// The row picked on the GitHub page: its column (my PRs, to review, CI) and the row in it.
struct GitHubKeyPick: Equatable {
    var column: Int
    var row: Int
}

enum GitHubKeys {
    /// The pick after a step, over columns with `counts` rows. Empty columns are skipped by ← and
    /// →; ↑ and ↓ clamp inside the column. Nothing picked: the first arrow picks the first row of
    /// the first column that has rows. Nothing at all to pick: nil.
    static func move(pick: GitHubKeyPick?, step: IslandGridStep, counts: [Int]) -> GitHubKeyPick? {
        guard let firstFilled = counts.firstIndex(where: { $0 > 0 }) else { return nil }
        guard let pick, pick.column >= 0, pick.column < counts.count, counts[pick.column] > 0 else {
            return GitHubKeyPick(column: firstFilled, row: 0)
        }
        let rows = counts[pick.column]
        let row = max(0, min(rows - 1, pick.row))
        switch step {
        case .up:   return GitHubKeyPick(column: pick.column, row: max(0, row - 1))
        case .down: return GitHubKeyPick(column: pick.column, row: min(rows - 1, row + 1))
        case .left, .right:
            let delta = step == .right ? 1 : -1
            var column = pick.column + delta
            while column >= 0, column < counts.count {
                if counts[column] > 0 { return GitHubKeyPick(column: column, row: min(row, counts[column] - 1)) }
                column += delta
            }
            return GitHubKeyPick(column: pick.column, row: row)
        }
    }
}

// MARK: - The two-step answer

/// A pick made with the keys, bound to the request that was on screen. A request that is gone,
/// replaced by another, or a question that moved on makes the pick void: ↩ then does nothing.
struct AnswerKeyChoice: Equatable {
    /// `AgentRequest.id` of the permission request, the id of the held question.
    var requestId: UUID
    /// The question of several that was on screen (0 for a permission request).
    var questionIndex: Int = 0
    /// Approval: the button (`ApprovalKeys.buttons`). Question: the row (variants, then "Other…").
    var index: Int

    /// Whether this pick is for the request on screen now.
    func isValid(for target: IslandAnswerTarget, questionIndex current: Int = 0) -> Bool {
        target.requestId == requestId && current == questionIndex
    }
}

enum ApprovalButton: Equatable {
    case deny, allow, always

    /// The word the hook gets (`HookServer.sendApprovalDecision`).
    var decision: String {
        switch self {
        case .deny: return "deny"
        case .allow: return "allow"
        case .always: return "always"
        }
    }
}

enum ApprovalKeys {
    /// The buttons in the order they stand on screen. "Always" only where the agent honours it.
    static func buttons(offersAlways: Bool) -> [ApprovalButton] {
        offersAlways ? [.deny, .allow, .always] : [.deny, .allow]
    }

    /// The pick after ← / →. With nothing picked the first arrow stands on Deny, the safe side,
    /// whichever way it points. A pick made for another request is dropped first.
    static func move(choice: AnswerKeyChoice?, delta: Int, target: IslandAnswerTarget) -> AnswerKeyChoice? {
        guard case .approval(let id, let offersAlways) = target else { return nil }
        let count = buttons(offersAlways: offersAlways).count
        if let choice, choice.isValid(for: target), choice.index < count {
            return AnswerKeyChoice(requestId: id, index: max(0, min(count - 1, choice.index + delta)))
        }
        return AnswerKeyChoice(requestId: id, index: 0)
    }

    /// The answer ↩ sends: nil without a pick, with a pick of another request, or when nothing
    /// can be answered. The id is the one the pick was made for and the screen still shows.
    static func confirm(choice: AnswerKeyChoice?, target: IslandAnswerTarget) -> (decision: String, id: UUID)? {
        guard case .approval(let id, let offersAlways) = target,
              let choice, choice.isValid(for: target) else { return nil }
        let list = buttons(offersAlways: offersAlways)
        guard choice.index >= 0, choice.index < list.count else { return nil }
        return (list[choice.index].decision, id)
    }
}

enum QuestionKeys {
    /// What ↩ and Space ask the question panel to do.
    enum Effect: Equatable {
        case none
        /// Single choice: answer with the variant (the panel goes on to the next question or sends).
        case answer(option: Int)
        /// Multiple choice: mark / unmark the variant.
        case toggle(option: Int)
        /// Multiple choice: "Next" / "Send".
        case advance
        /// Open the "Other…" field.
        case openOther
    }

    /// Rows of the list: the variants, then "Other…".
    static func rowCount(options: Int) -> Int { options + 1 }

    static func isOther(row: Int, options: Int) -> Bool { row == options }

    /// The row after a step up / left (-1) or down / right (+1): the first arrow stands on the
    /// first variant, then it clamps at both ends.
    static func move(row: Int?, delta: Int, options: Int) -> Int {
        guard let row else { return 0 }
        return max(0, min(rowCount(options: options) - 1, row + delta))
    }

    /// The row a digit picks: the N-th variant, nothing past the last one. A digit only picks.
    static func digit(_ n: Int, options: Int) -> Int? {
        n >= 1 && n <= options ? n - 1 : nil
    }

    static func confirm(row: Int?, options: Int, multiSelect: Bool, hasMarks: Bool) -> Effect {
        guard let row, row >= 0, row < rowCount(options: options) else { return .none }
        if isOther(row: row, options: options) { return .openOther }
        if multiSelect { return hasMarks ? .advance : .none }
        return .answer(option: row)
    }

    static func space(row: Int?, options: Int, multiSelect: Bool) -> Effect {
        guard multiSelect, let row, row >= 0, row < options else { return .none }
        return .toggle(option: row)
    }
}

// MARK: - Page hotkeys

/// What a hotkey that opens a page does. A person who presses it wants to be on that page with
/// the keyboard in the island; pressing it again on the page puts the island away.
enum PageHotkey {
    enum Plan: Equatable {
        /// Fold the island.
        case collapse
        /// The page is up but the panel is not the key window (it opened by itself, under the
        /// cursor): only take the keyboard, do not close it.
        case takeKeyboard
        /// Open the island on the page and take the keyboard.
        case open(IslandView)
    }

    static func plan(target: IslandView, view: IslandView, mode: IslandMode, panelIsKey: Bool) -> Plan {
        if mode == .expanded && view == target {
            return panelIsKey ? .collapse : .takeKeyboard
        }
        // From the page of an agent the Agents hotkey leads to the list. The request that waits
        // stays in its queue: opening a page never answers it or lets it go.
        return .open(target)
    }
}
