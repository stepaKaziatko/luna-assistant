import Foundation

@main
enum AskQuestionTests {

    static var failures = 0

    static func check(_ label: String, _ got: String, _ expected: String) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got.debugDescription)")
            print("    expected: \(expected.debugDescription)")
            failures += 1
        }
    }

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        let opt1: [String: Any] = ["label": "Postgres", "description": "Full-text search"]
        let opt2: [String: Any] = ["label": "Meilisearch", "description": ""]
        let opt3: [String: Any] = ["label": "Algolia", "description": "Managed search"]

        // ── parse ──────────────────────────────────────────────────────────────
        print("AskQuestion.parse")

        let single: [String: Any] = ["questions": [
            ["question": "Which search engine?", "header": "Search", "options": [opt1, opt2, opt3], "multiSelect": false]
        ]]
        let parsed = AskQuestion.parse(toolInput: single)
        checkTrue("single question parses",           parsed != nil)
        checkTrue("question text",                    parsed?.questions[0].question == "Which search engine?")
        checkTrue("header",                           parsed?.questions[0].header == "Search")
        checkTrue("3 options",                        parsed?.questions[0].options.count == 3)
        checkTrue("multiSelect false",                parsed?.questions[0].multiSelect == false)
        checkTrue("option label",                     parsed?.questions[0].options[0].label == "Postgres")

        // header truncated at 12 chars
        let longHeader: [String: Any] = ["questions": [
            ["question": "Q?", "header": "This is a very long header", "options": [opt1, opt2], "multiSelect": false]
        ]]
        let lh = AskQuestion.parse(toolInput: longHeader)
        checkTrue("header truncated to 12",           lh?.questions[0].header.count == 12)

        // multiSelect true
        let multi: [String: Any] = ["questions": [
            ["question": "Pick features", "header": "Features", "options": [opt1, opt2, opt3], "multiSelect": true]
        ]]
        let mParsed = AskQuestion.parse(toolInput: multi)
        checkTrue("multiSelect true",                 mParsed?.questions[0].multiSelect == true)

        // 4 questions (max)
        let q: [String: Any] = ["question": "Q?", "header": "", "options": [opt1, opt2], "multiSelect": false]
        let four: [String: Any] = ["questions": [q, q, q, q]]
        checkTrue("4 questions parses",               AskQuestion.parse(toolInput: four) != nil)

        // 5 questions → nil (over max)
        let five: [String: Any] = ["questions": [q, q, q, q, q]]
        checkTrue("5 questions → nil",                AskQuestion.parse(toolInput: five) == nil)

        // 1 option → nil (under min)
        let oneOpt: [String: Any] = ["questions": [
            ["question": "Q?", "header": "", "options": [opt1], "multiSelect": false]
        ]]
        checkTrue("1 option → nil",                   AskQuestion.parse(toolInput: oneOpt) == nil)

        // missing question text → nil
        let noQ: [String: Any] = ["questions": [
            ["header": "", "options": [opt1, opt2], "multiSelect": false]
        ]]
        checkTrue("missing question → nil",           AskQuestion.parse(toolInput: noQ) == nil)

        // empty questions array → nil
        checkTrue("empty questions → nil",            AskQuestion.parse(toolInput: ["questions": []]) == nil)

        // missing questions key → nil
        checkTrue("missing questions → nil",          AskQuestion.parse(toolInput: [:]) == nil)

        // option with empty label → nil
        let emptyLabel: [String: Any] = ["questions": [
            ["question": "Q?", "header": "", "options": [["label": "", "description": ""], opt2], "multiSelect": false]
        ]]
        checkTrue("empty option label → nil",         AskQuestion.parse(toolInput: emptyLabel) == nil)

        // ── buildAnswers ───────────────────────────────────────────────────────
        print("AskQuestion.buildAnswers")

        let items = AskQuestion.parse(toolInput: multi)!.questions
        + AskQuestion.parse(toolInput: single)!.questions

        // items[0] = "Pick features" (multiSelect: true), items[1] = "Which search engine?" (multiSelect: false)
        let sel1 = [["Postgres"], ["Meilisearch"]]
        let ans1 = AskQuestion.buildAnswers(questions: items, selections: sel1)
        checkTrue("multi-select single pick → [String]",  (ans1["Pick features"] as? [String]) == ["Postgres"])
        checkTrue("single-select answer → String",        (ans1["Which search engine?"] as? String) == "Meilisearch")

        // Multi-select with multiple picks → [String] array
        let sel2 = [["Postgres", "Algolia"], []]
        let ans2 = AskQuestion.buildAnswers(questions: items, selections: sel2)
        checkTrue("multi-select multiple picks → [String]", (ans2["Pick features"] as? [String]) == ["Postgres", "Algolia"])
        checkTrue("unanswered question omitted",            ans2["Which search engine?"] == nil)

        // Empty selections → empty dict
        let ans3 = AskQuestion.buildAnswers(questions: items, selections: [[], []])
        checkTrue("all empty → empty dict",               ans3.isEmpty)

        // ── island height ──────────────────────────────────────────────────────
        print("\nAskQuestion.estimatedIslandHeight")
        let shortQ = AskQuestionItem(question: "Which one?", header: "", options: [
            AskQuestionOption(label: "A", description: ""), AskQuestionOption(label: "B", description: "")
        ], multiSelect: false)
        let longQ = AskQuestionItem(question: String(repeating: "very long question ", count: 12), header: "Test", options: [
            AskQuestionOption(label: "A", description: String(repeating: "explanation ", count: 12)),
            AskQuestionOption(label: "B", description: "short"),
            AskQuestionOption(label: "C", description: "short"),
            AskQuestionOption(label: "D", description: "short")
        ], multiSelect: true)
        checkTrue("chips only → no descriptions",          !shortQ.hasDescriptions)
        checkTrue("one description → vertical list",       longQ.hasDescriptions)
        checkTrue("short question keeps the 160 pt floor", AskQuestion(questions: [shortQ]).estimatedIslandHeight == 160)
        let tall = AskQuestion(questions: [shortQ, longQ]).estimatedIslandHeight
        checkTrue("tallest question wins, within cap",     tall > 160 && tall <= 560)

        // ── the question the app holds: one id per question ──────────────────────
        print("\nQuestionHolder")
        do {
            var h = QuestionHolder()
            checkTrue("nothing held at first", !h.isHolding && h.fd == -1 && h.current == nil)

            let first = h.hold(fd: 7, ownerId: "integration_claude|a")
            checkTrue("a held question has an id, its socket and its owner",
                      h.isHolding && h.fd == 7 && h.current?.id == first.held.id
                      && h.current?.ownerId == "integration_claude|a" && first.displaced == nil)
            checkTrue("the id is the current one", h.isCurrent(first.held.id))

            // An answer with a stale id is refused and changes nothing.
            let before = h
            checkTrue("an unknown id is refused", h.claim(id: UUID()) == nil)
            checkTrue("a refused answer has no effect", h == before && h.fd == 7)

            // The first answer is accepted; a second one with the same id is not.
            let claimed = h.claim(id: first.held.id)
            checkTrue("the first answer takes the question", claimed?.fd == 7 && !h.isHolding && h.fd == -1)
            checkTrue("a second answer with the same id is refused", h.claim(id: first.held.id) == nil)
            checkTrue("nothing is held after the answer", h.current == nil)

            // A newer question displaces the older: the older id is no longer accepted.
            let a = h.hold(fd: 10, ownerId: "integration_claude|a")
            let b = h.hold(fd: 11, ownerId: "agent_codex|b")
            checkTrue("the older question is displaced and handed back",
                      b.displaced?.id == a.held.id && b.displaced?.fd == 10)
            checkTrue("the older id is not current any more", !h.isCurrent(a.held.id) && h.isCurrent(b.held.id))
            checkTrue("an answer to the displaced question is refused", h.claim(id: a.held.id) == nil)
            checkTrue("the newer question is still held after that", h.fd == 11 && h.current?.ownerId == "agent_codex|b")
            checkTrue("the newer question can be answered", h.claim(id: b.held.id)?.fd == 11)

            // Release: any id, but not a socket that is not the held one.
            let c = h.hold(fd: 20, ownerId: "x|c")
            checkTrue("release(fd:) of another socket does nothing", h.release(fd: 99) == nil && h.fd == 20)
            checkTrue("release(fd:) of the held socket takes it", h.release(fd: 20)?.id == c.held.id && !h.isHolding)
            let d = h.hold(fd: 21, ownerId: "x|d")
            checkTrue("release takes the question whatever its id", h.release()?.id == d.held.id && !h.isHolding)
            checkTrue("a released question cannot be answered", h.claim(id: d.held.id) == nil)
            checkTrue("release with nothing held is nil", h.release() == nil)

            // Two questions get two ids.
            let e = h.hold(fd: 30, ownerId: "x|e"), f = h.hold(fd: 31, ownerId: "x|e")
            checkTrue("every held question has an id of its own", e.held.id != f.held.id)
        }

        // ── preview height ──────────────────────────────────────────────────────
        print("\nPreview height")
        do {
            let shortQ = AskQuestionItem(question: "Which one?", header: "", options: [
                AskQuestionOption(label: "A", description: ""), AskQuestionOption(label: "B", description: "")
            ], multiSelect: false)
            let longQ = AskQuestionItem(question: String(repeating: "very long question ", count: 12), header: "Test", options: [
                AskQuestionOption(label: "A", description: String(repeating: "explanation ", count: 12)),
                AskQuestionOption(label: "B", description: "short"),
                AskQuestionOption(label: "C", description: "short"),
                AskQuestionOption(label: "D", description: "short")
            ], multiSelect: true)
            let q = AskQuestion(questions: [shortQ, longQ])
            checkTrue("a preview is never lower than its page", AskQuestion(questions: [shortQ]).estimatedPreviewHeight == 240)
            checkTrue("a tall question gets room on the preview, within the cap",
                      q.estimatedPreviewHeight >= q.estimatedIslandHeight && q.estimatedPreviewHeight <= 560)
        }

        // ── переводы строк в оценке высоты (LUNA-78) ───────────────────────────
        print("\nОценка высоты: переводы строк")
        do {
            func item(_ text: String) -> AskQuestionItem {
                AskQuestionItem(question: text, header: "", options: [
                    AskQuestionOption(label: "Да", description: ""),
                    AskQuestionOption(label: "Нет", description: ""),
                    AskQuestionOption(label: "Остановиться", description: "")
                ], multiSelect: false)
            }
            // Каждая строка короткая: без учёта \n всё считается одной строкой.
            let lines = (1...6).map { "Пункт \($0)" }
            let flat = AskQuestion(questions: [item(lines.joined(separator: " "))])
            let broken = AskQuestion(questions: [item(lines.joined(separator: "\n"))])
            checkTrue("текст с \\n выше того же текста в одну строку",
                      broken.estimatedIslandHeight > flat.estimatedIslandHeight)
            checkTrue("шесть строк — на пять строк выше одной (17 pt на строку)",
                      broken.estimatedIslandHeight - flat.estimatedIslandHeight == 5 * 17)
            // Пустая строка между абзацами тоже занимает строку.
            let paragraphs = AskQuestion(questions: [item("Абзац один\n\nАбзац два")])
            let twoLines = AskQuestion(questions: [item("Абзац один\nАбзац два")])
            checkTrue("пустая строка между абзацами считается",
                      paragraphs.estimatedIslandHeight - twoLines.estimatedIslandHeight == 17)
            checkTrue("\\n в конце не добавляет строку",
                      AskQuestion(questions: [item("Абзац один\nАбзац два\n")]).estimatedIslandHeight
                      == twoLines.estimatedIslandHeight)
            // \r\n — тот же перевод строки.
            checkTrue("\\r\\n считается как \\n",
                      AskQuestion(questions: [item("Абзац один\r\nАбзац два")]).estimatedIslandHeight
                      == twoLines.estimatedIslandHeight)
            // Описание варианта со строками тоже выше.
            let descFlat = AskQuestionItem(question: "Q?", header: "", options: [
                AskQuestionOption(label: "A", description: "раз два три"),
                AskQuestionOption(label: "B", description: "")
            ], multiSelect: false)
            var descBroken = descFlat
            descBroken.options[0].description = "раз\nдва\nтри"
            checkTrue("описание варианта с \\n выше",
                      AskQuestion(questions: [descBroken]).estimatedIslandHeight
                      > AskQuestion(questions: [descFlat]).estimatedIslandHeight)

            // Вопрос апрува на ~25 строк с абзацами и списками: упирается в потолок, остров не растёт выше.
            var long = "Подтверди план:\n\n"
            for n in 1...10 { long += "- шаг \(n): короткое описание\n" }
            long += "\nРиски:\n"
            for n in 1...10 { long += "• риск \(n)\n" }
            let tallQ = AskQuestion(questions: [item(long)])
            checkTrue("длинный вопрос со строками упирается в потолок 560", tallQ.estimatedIslandHeight == 560)
            checkTrue("и на странице превью — тоже 560", tallQ.estimatedPreviewHeight == 560)
            let huge = AskQuestion(questions: [item(String(repeating: "строка\n", count: 400))])
            checkTrue("потолок не превышается", huge.estimatedIslandHeight == 560 && huge.estimatedPreviewHeight == 560)
        }

        // ── finish ─────────────────────────────────────────────────────────────
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
