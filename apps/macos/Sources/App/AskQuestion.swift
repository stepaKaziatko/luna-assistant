import Foundation

// MARK: - AskUserQuestion model (Foundation-only, testable)

struct AskQuestionOption: Equatable {
    var label: String
    var description: String
}

struct AskQuestionItem: Equatable {
    var question: String    // full question text
    var header: String      // ≤12 chars; used as section label
    var options: [AskQuestionOption]   // 2–4 choices
    var multiSelect: Bool
}

// MARK: - The question the app holds

/// The one question the app holds open for an answer: its socket and who asked. Pure state, no
/// I/O — `HookServer` owns the sockets and the timers and drives this value on the main actor.
///
/// Every question gets an id when it is held, and an answer is accepted only together with the id
/// of the question the surface that answers had on screen. Two surfaces show the same question
/// (the card and the preview page), so a second answer, a click on a stale button or an answer
/// to a question that has been displaced by a newer one arrives with an id that is no longer
/// current and is refused — with no effect on anything else.
struct QuestionHolder: Equatable, Sendable {

    struct Held: Equatable, Sendable {
        let id: UUID
        /// The luna-hook connection kept open until the answer.
        let fd: Int32
        /// `AgentSessionKey.id` of the session that asks.
        let ownerId: String
    }

    private(set) var current: Held? = nil

    var fd: Int32 { current?.fd ?? -1 }
    var isHolding: Bool { current != nil }

    func isCurrent(_ id: UUID) -> Bool { current?.id == id }

    /// Holds a new question; the question held before, if any, is displaced and returned.
    mutating func hold(fd: Int32, ownerId: String, id: UUID = UUID()) -> (held: Held, displaced: Held?) {
        let displaced = current
        let held = Held(id: id, fd: fd, ownerId: ownerId)
        current = held
        return (held, displaced)
    }

    /// Takes the question out to answer it. Only the current question can be taken, and only
    /// once: a stale id, a second call and a call with nothing held give nil.
    mutating func claim(id: UUID) -> Held? {
        guard let held = current, held.id == id else { return nil }
        current = nil
        return held
    }

    /// Takes the question out whatever its id: the surface left the screen, the agent hung
    /// up or the time ran out.
    @discardableResult
    mutating func release() -> Held? {
        let held = current
        current = nil
        return held
    }

    /// Takes the question out only if the socket is still the one it was held with: a timer or a
    /// hang-up of a displaced question must not touch the question that came after it.
    @discardableResult
    mutating func release(fd: Int32) -> Held? {
        guard let held = current, held.fd == fd else { return nil }
        current = nil
        return held
    }
}

/// Island height of the pending question, readable from the nonisolated `islandSize`. Written on the main actor only.
enum QuestionLayout {
    nonisolated(unsafe) static var height: CGFloat?
    /// The same for the preview page of the session that asks: its text column is narrower.
    nonisolated(unsafe) static var previewHeight: CGFloat?
}

extension AskQuestionItem {
    /// True when at least one option carries a description: the card then lists options vertically.
    var hasDescriptions: Bool { options.contains { !$0.description.isEmpty } }
}

struct AskQuestion: Equatable {
    var questions: [AskQuestionItem]   // 1–4 questions

    /// Island height that fits the tallest question without truncation (rough estimate, text wraps at ~500 pt).
    var estimatedIslandHeight: CGFloat { estimatedHeight(textWidth: 500) }

    /// Island height of the preview page that shows this question: the text column is the width
    /// of the island less the column that says who asks, and the page has a header of its own.
    var estimatedPreviewHeight: CGFloat { min(max(estimatedHeight(textWidth: 380) + 28, 240), 560) }

    private func estimatedHeight(textWidth: CGFloat) -> CGFloat {
        func lines(_ text: String, charWidth: CGFloat) -> CGFloat {
            max(1, (CGFloat(text.count) * charWidth / textWidth).rounded(.up))
        }
        let tallest = questions.map { item -> CGFloat in
            var h: CGFloat = 20 + lines(item.question, charWidth: 7) * 17 + 64
            if !item.header.isEmpty { h += 14 }
            if item.hasDescriptions {
                for opt in item.options {
                    h += 34 + (opt.description.isEmpty ? 0 : lines(opt.description, charWidth: 6.4) * 14)
                }
                h += 40   // "Other…" row
            } else {
                h += item.options.count >= 3 ? 74 : 40
            }
            if item.multiSelect { h += 34 }
            return h
        }.max() ?? 160
        return min(max(tallest, 160), 560)
    }

    // MARK: - Parse from tool_input dict
    // Returns nil if the payload is malformed (fallback → Allow/Deny card).
    static func parse(toolInput: [String: Any]) -> AskQuestion? {
        guard let rawQs = toolInput["questions"] as? [[String: Any]],
              !rawQs.isEmpty, rawQs.count <= 4 else { return nil }
        var items: [AskQuestionItem] = []
        for raw in rawQs {
            guard let question = raw["question"] as? String, !question.isEmpty,
                  let rawOpts = raw["options"] as? [[String: Any]],
                  rawOpts.count >= 2, rawOpts.count <= 4 else { return nil }
            var opts: [AskQuestionOption] = []
            for opt in rawOpts {
                guard let label = opt["label"] as? String, !label.isEmpty else { return nil }
                let desc = opt["description"] as? String ?? ""
                opts.append(AskQuestionOption(label: label, description: desc))
            }
            let rawHeader = raw["header"] as? String ?? ""
            let header = String(rawHeader.prefix(12))
            let multi = raw["multiSelect"] as? Bool ?? false
            items.append(AskQuestionItem(question: question, header: header, options: opts, multiSelect: multi))
        }
        return AskQuestion(questions: items)
    }

    // MARK: - Build answers dict
    // selections[i] = list of labels selected for question[i].
    // Single-select / Other…: one label → String value (Claude Code 2.1.85+).
    // Multi-select: array of labels → [String] value (Claude Code 2.1.136+).
    static func buildAnswers(questions: [AskQuestionItem], selections: [[String]]) -> [String: Any] {
        var answers: [String: Any] = [:]
        for (i, item) in questions.enumerated() {
            guard i < selections.count, !selections[i].isEmpty else { continue }
            if item.multiSelect {
                answers[item.question] = selections[i]          // array for multi-select
            } else {
                answers[item.question] = selections[i][0]       // string for single-select
            }
        }
        return answers
    }
}
