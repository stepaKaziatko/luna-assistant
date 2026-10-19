import Foundation

@main
enum IslandKeysTests {

    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") }
        else  { print("  ✗ \(label)"); failures += 1 }
    }

    // Key codes and modifiers, as the monitor gets them.
    static let L = IslandKeyCode.left, R = IslandKeyCode.right, D = IslandKeyCode.down, U = IslandKeyCode.up
    static let ret = IslandKeyCode.return, bs = IslandKeyCode.delete, sp = IslandKeyCode.space, esc = IslandKeyCode.escape
    static let cmd = ShortcutSpec.cmdBit, shift = ShortcutSpec.shiftBit, opt = ShortcutSpec.optBit, ctrl = ShortcutSpec.ctrlBit

    static func key(_ code: UInt16, _ mods: UInt = 0, rep: Bool = false, char: String = "") -> IslandKeyInput {
        IslandKeyInput(keyCode: code, modifiers: mods, isRepeat: rep, character: char)
    }

    static func ctx(_ page: IslandView, _ answer: IslandAnswerTarget = .none, text: Bool = false) -> IslandKeyContext {
        IslandKeyContext(page: page, answer: answer, firstResponderIsText: text)
    }

    static let reqA = UUID(), reqB = UUID()
    static let approval = IslandAnswerTarget.approval(id: reqA, offersAlways: true)
    static let question = IslandAnswerTarget.question(id: reqA)

    static func resolve(_ k: IslandKeyInput, _ c: IslandKeyContext) -> IslandKeyCommand? {
        IslandKeyTable.resolve(k, context: c)
    }

    static func main() {
        table()
        resolution()
        grid()
        selection()
        github()
        approvalKeys()
        questionKeys()
        pageHotkey()
        print(failures == 0 ? "\nIslandKeys: all cases passed" : "\nIslandKeys: \(failures) FAILED")
        if failures > 0 { exit(1) }
    }

    // MARK: Table

    static func table() {
        print("\nThe table")
        // Everything the island had before is still in it, with the same words.
        let before: [(String, String)] = [
            ("⌘→ / ⌘←", "shortcut.island.next-prev"), ("⌘1 – ⌘9", "shortcut.island.by-number"),
            ("⌘↓ / ⌘↑", "shortcut.island.nav-items"), ("⌘O", "shortcut.island.open"),
            ("⌘E", "shortcut.island.diff"), ("⌘↩", "shortcut.island.send"), ("⌘K", "shortcut.island.new-convo"),
            ("⌘,", "shortcut.island.settings"), ("⌘P", "shortcut.island.pin"), ("⎋", "shortcut.island.close"),
        ]
        // Таблица сама по себе — без глобального «Свернуть шторку» (его сочетание приписывается к «Закрыть»).
        let table = IslandKeyTable.rows(area: nil, collapseKeys: nil)
        for (keys, desc) in before {
            check("old row \(keys) is in the table", table.contains { $0.keys == keys && $0.descriptionKey == desc })
        }
        let rows = IslandKeyTable.rows()
        check("by default the close row also shows ⌘⎋ (LUNA-68)",
              rows.contains { $0.keys == "⎋ / ⌘⎋" && $0.descriptionKey == "shortcut.island.close" })
        check("with the action off the close row is ⎋ alone",
              table.contains { $0.keys == "⎋" && $0.descriptionKey == "shortcut.island.close" })
        check("the hint of a page shows ⌘⎋ next to ⎋ too",
              IslandKeyTable.rows(area: .agents, collapseKeys: "⌘⎋").contains { $0.keys == "⎋ / ⌘⎋" })
        check("apart from the close row the rows do not depend on the action",
              zip(rows, table).allSatisfy { $0.descriptionKey == $1.descriptionKey
                  && ($0.keys == $1.keys || $0.descriptionKey == "shortcut.island.close") })
        check("every binding has a description key and a group",
              IslandKeyTable.bindings.allSatisfy { $0.descriptionKey.hasPrefix("shortcut.island.") && !$0.areas.isEmpty })
        check("ShortcutLogic.islandShortcuts is the table", ShortcutLogic.islandShortcuts.map(\.key) == rows.map(\.keys))

        // No key means two things in one area: try every key, every modifier set, every area.
        var clashes: [String] = []
        let modSets: [UInt] = [0, cmd, shift, opt, ctrl, cmd | shift, cmd | opt, ctrl | opt]
        for area in IslandKeyArea.allCases {
            for code in UInt16(0)..<128 {
                for mods in modSets {
                    for char in ["", "?"] {
                        let input = key(code, mods, char: char)
                        let hits = IslandKeyTable.bindings.filter { b in
                            b.areas.contains(area) && b.modifiers == mods && b.match.matches(input).hit
                        }
                        // Pairs that deliberately share a key (⌫ is "back" on one page and "home" on others) never share an area.
                        if hits.count > 1 { clashes.append("\(area) \(code) \(mods) \(char)") }
                    }
                }
            }
        }
        check("no two bindings share a key in one area (\(clashes.prefix(3)))", clashes.isEmpty)

        // Rows of a hint are the keys that work there.
        let agentRows = IslandKeyTable.rows(area: .agents).map(\.descriptionKey)
        check("the hint of the Agents page lists tile selection and open",
              agentRows.contains("shortcut.island.tile-select") && agentRows.contains("shortcut.island.agent-open"))
        check("the hint of the Agents page does not list answer keys",
              !agentRows.contains("shortcut.island.approval-confirm"))
        check("every group has a row", IslandKeyGroup.allCases.allSatisfy { !IslandKeyTable.rows(in: $0).isEmpty })
    }

    // MARK: Resolution

    static func resolution() {
        print("\nResolution")
        // Typing in a field: bare keys are the field's.
        let bare: [UInt16] = [ret, bs, L, R, U, D, sp, 18, 19, 20, 21]
        for page in [IslandView.agents, .agentPreview, .overview, .prompt, .question, .approval] {
            for code in bare {
                let c = ctx(page, page == .question ? question : (page == .approval ? approval : .none), text: true)
                check("text focus: key \(code) on \(page) is not ours", resolve(key(code), c) == nil)
            }
        }
        check("text focus: ? is typed", resolve(key(44, shift, char: "?"), ctx(.prompt, text: true)) == nil)
        check("text focus: ⌘↩ still sends the chat message",
              resolve(key(ret, cmd), ctx(.prompt, text: true)) == .sendMessage)
        check("text focus: ⌘← still switches the tab", resolve(key(L, cmd), ctx(.prompt, text: true)) == .cyclePill(-1))

        // A field editor that holds the keyboard on a page without a field (a hidden chat field) is not typing.
        check("the chat, the mail draft, a question and the page of an agent have a field to type in",
              [IslandView.prompt, .mail, .question, .agentPreview].allSatisfy(IslandKeyTable.pageHasTextInput))
        check("the Agents page, the cards, Active tabs and GitHub have none",
              [IslandView.agents, .approval, .overview, .github, .wardrobe, .empty].allSatisfy { !IslandKeyTable.pageHasTextInput($0) })

        // Holding a key never repeats an action.
        check("↩ held on the Agents page does nothing", resolve(key(ret, rep: true), ctx(.agents)) == nil)
        check("↩ held on an approval does nothing", resolve(key(ret, rep: true), ctx(.approval, approval)) == nil)
        check("↩ held on a question does nothing", resolve(key(ret, rep: true), ctx(.question, question)) == nil)
        check("Space held on a question does nothing", resolve(key(sp, rep: true), ctx(.question, question)) == nil)
        check("⌘↩ held on the page of an agent does nothing", resolve(key(ret, cmd, rep: true), ctx(.agentPreview)) == nil)
        check("⌘↩ held in the chat does nothing", resolve(key(ret, cmd, rep: true), ctx(.prompt)) == nil)
        check("⌫ held does nothing", resolve(key(bs, rep: true), ctx(.agentPreview)) == nil)
        check("an arrow held keeps moving", resolve(key(R, rep: true), ctx(.agents)) == .moveTile(.right))

        // A modifier that is not in the table spoils the key.
        check("⌥↩ is not ours", resolve(key(ret, opt), ctx(.agents)) == nil)
        check("⇧⌫ is not ours", resolve(key(bs, shift), ctx(.agentPreview)) == nil)
        check("⌃← is not ours", resolve(key(L, ctrl), ctx(.agents)) == nil)
        check("⌘⇧→ is not ours", resolve(key(R, cmd | shift), ctx(.agents)) == nil)
        check("⇧→ is not ours", resolve(key(R, shift), ctx(.agents)) == nil)

        // ⌫
        check("⌫ on the page of an agent goes to the list", resolve(key(bs), ctx(.agentPreview)) == .back)
        check("⌫ on the page of an agent with a request goes to the list",
              resolve(key(bs), ctx(.agentPreview, approval)) == .back
              && resolve(key(bs), ctx(.agentPreview, question)) == .back)
        for page in [IslandView.overview, .github, .wardrobe] {
            check("⌫ on \(page) goes home", resolve(key(bs), ctx(page)) == .home)
        }
        check("⌫ on the home page does nothing", resolve(key(bs), ctx(.agents)) == nil)
        for page in [IslandView.prompt, .mail, .searching, .settings, .result, .note, .recap] {
            check("⌫ on \(page) does nothing", resolve(key(bs), ctx(page)) == nil)
        }
        check("⌫ on the approval card does nothing", resolve(key(bs), ctx(.approval, approval)) == nil)
        check("⌫ on the question card does nothing (the question would go back to the terminal)",
              resolve(key(bs), ctx(.question, question)) == nil)

        // ⎋ is not taken by the table: it goes down the responder chain.
        for page in IslandView.allCases {
            check("⎋ on \(page) is not taken", resolve(key(esc), ctx(page)) == nil)
        }
        check("⎋ is still in the table for the hint", IslandKeyTable.rows().contains { $0.keys.hasPrefix("⎋") })

        // ?
        for page in IslandView.allCases {
            check("? on \(page) shows the hint", resolve(key(44, shift, char: "?"), ctx(page)) == .toggleHelp)
        }
        check("/ without Shift is not the hint", resolve(key(44, 0, char: "/"), ctx(.agents)) == nil)

        // The Agents page
        check("→ moves the pick", resolve(key(R), ctx(.agents)) == .moveTile(.right))
        check("↓ moves the pick", resolve(key(D), ctx(.agents)) == .moveTile(.down))
        check("↩ opens the picked agent", resolve(key(ret), ctx(.agents)) == .openSelectedAgent)
        check("keypad enter is ↩", resolve(key(IslandKeyCode.keypadEnter), ctx(.agents)) == .openSelectedAgent)
        check("⌘↩ goes to the picked agent", resolve(key(ret, cmd), ctx(.agents)) == .jumpToAgent)
        check("⌘↩ goes to the agent of the page",
              resolve(key(ret, cmd), ctx(.agentPreview)) == .jumpToAgent
              && resolve(key(ret, cmd), ctx(.agentPreview, approval)) == .jumpToAgent
              && resolve(key(ret, cmd), ctx(.agentPreview, question)) == .jumpToAgent)
        check("↩ on the page of an agent without a request does nothing", resolve(key(ret), ctx(.agentPreview)) == nil)
        check("arrows on the page of an agent without a request do nothing", resolve(key(R), ctx(.agentPreview)) == nil)
        check("⌘↩ on a card does not jump",
              resolve(key(ret, cmd), ctx(.approval, approval)) == nil && resolve(key(ret, cmd), ctx(.question, question)) == nil)

        // The answers
        for (page, target) in [(IslandView.approval, approval), (.agentPreview, approval)] {
            check("← on \(page) with a request steps the pick", resolve(key(L), ctx(page, target)) == .approvalMove(-1))
            check("→ on \(page) with a request steps the pick", resolve(key(R), ctx(page, target)) == .approvalMove(+1))
            check("↩ on \(page) with a request confirms", resolve(key(ret), ctx(page, target)) == .approvalConfirm)
        }
        for (page, target) in [(IslandView.question, question), (.agentPreview, question)] {
            check("arrows on \(page) with a question step the pick",
                  resolve(key(L), ctx(page, target)) == .question(.move(-1))
                  && resolve(key(U), ctx(page, target)) == .question(.move(-1))
                  && resolve(key(R), ctx(page, target)) == .question(.move(+1))
                  && resolve(key(D), ctx(page, target)) == .question(.move(+1)))
            check("digits on \(page) pick, they do not send",
                  resolve(key(19), ctx(page, target)) == .question(.digit(2)))
            check("Space on \(page) marks", resolve(key(sp), ctx(page, target)) == .question(.toggle))
            check("↩ on \(page) confirms", resolve(key(ret), ctx(page, target)) == .question(.confirm))
        }
        check("5 is not a variant key", resolve(key(23), ctx(.question, question)) == nil)
        check("digits outside a question are not ours", resolve(key(19), ctx(.agents)) == nil)

        // Active tabs
        check("← on Active tabs is the previous pill", resolve(key(L), ctx(.overview)) == .cyclePill(-1))
        check("→ on Active tabs is the next pill", resolve(key(R), ctx(.overview)) == .cyclePill(+1))
        check("↓ and ↑ on Active tabs walk the list",
              resolve(key(D), ctx(.overview)) == .moveCard(+1) && resolve(key(U), ctx(.overview)) == .moveCard(-1))
        check("↩ on Active tabs opens the picked row", resolve(key(ret), ctx(.overview)) == .openCardItem)

        // What was there before keeps working, everywhere, as before
        for page in [IslandView.agents, .overview, .prompt, .agentPreview, .question, .approval, .github, .settings] {
            let c = ctx(page)
            check("⌘→ on \(page)", resolve(key(R, cmd), c) == .cyclePill(+1))
            check("⌘← on \(page)", resolve(key(L, cmd), c) == .cyclePill(-1))
            check("⌘↓ on \(page)", resolve(key(D, cmd), c) == .moveCard(+1))
            check("⌘↑ on \(page)", resolve(key(U, cmd), c) == .moveCard(-1))
            check("⌘O on \(page)", resolve(key(31, cmd), c) == .openCardItem)
            check("⌘, on \(page)", resolve(key(43, cmd), c) == .openSettings)
            check("⌘P on \(page)", resolve(key(35, cmd), c) == .togglePin)
        }
        for (code, n) in IslandKeyCode.digits {
            check("⌘\(n) switches to the pill \(n)", resolve(key(code, cmd), ctx(.agents)) == .pillNumber(n))
        }
        check("⌘E only on Active tabs", resolve(key(14, cmd), ctx(.overview)) == .toggleDiff && resolve(key(14, cmd), ctx(.agents)) == nil)
        check("⌘↩ sends in the chat", resolve(key(ret, cmd), ctx(.prompt)) == .sendMessage)
        check("⌘K starts a new conversation in the chat",
              resolve(key(40, cmd), ctx(.prompt)) == .newConversation && resolve(key(40, cmd), ctx(.agents)) == nil)
    }

    // MARK: Grid

    static func grid() {
        print("\nTiles")
        typealias G = IslandGrid
        check("nothing picked: → and ↓ pick the first",
              G.move(selection: nil, step: .right, count: 6) == 0 && G.move(selection: nil, step: .down, count: 6) == 0)
        check("nothing picked: ← and ↑ pick the last",
              G.move(selection: nil, step: .left, count: 6) == 5 && G.move(selection: nil, step: .up, count: 6) == 5)
        check("→ steps by one", G.move(selection: 1, step: .right, count: 6) == 2)
        check("→ from the end of a row goes to the start of the next", G.move(selection: 3, step: .right, count: 6) == 4)
        check("← from the start of a row goes to the end of the previous", G.move(selection: 4, step: .left, count: 6) == 3)
        check("→ clamps at the last tile", G.move(selection: 5, step: .right, count: 6) == 5)
        check("← clamps at the first tile", G.move(selection: 0, step: .left, count: 6) == 0)
        check("↓ steps a row", G.move(selection: 1, step: .down, count: 10) == 5)
        check("↓ under an incomplete last row falls on its last tile", G.move(selection: 3, step: .down, count: 6) == 5)
        check("↓ under an incomplete last row, another column", G.move(selection: 2, step: .down, count: 5) == 4)
        check("↓ from the last row stays", G.move(selection: 5, step: .down, count: 6) == 5 && G.move(selection: 4, step: .down, count: 6) == 4)
        check("↑ steps a row back", G.move(selection: 6, step: .up, count: 10) == 2)
        check("↑ from the first row stays", G.move(selection: 2, step: .up, count: 10) == 2)
        check("no tiles: nothing", G.move(selection: nil, step: .right, count: 0) == nil && G.move(selection: 0, step: .down, count: 0) == nil)
        for step in [IslandGridStep.left, .right, .up, .down] {
            check("one tile: \(step) is always 0", G.move(selection: nil, step: step, count: 1) == 0 && G.move(selection: 0, step: step, count: 1) == 0)
        }
        check("a pick past the end (a session closed) is clamped", G.move(selection: 9, step: .left, count: 3) == 1)
        check("a full last row: ↓ from the middle row", G.move(selection: 1, step: .down, count: 8) == 5)
        check("three tiles in one row: ↓ stays", G.move(selection: 1, step: .down, count: 3) == 1)
    }

    static func selection() {
        print("\nPick by session")
        let ids = ["a", "b", "c", "d", "e"]
        check("a pick that is there stays", AgentsSelection.reconcile("c", ids: ids) == "c")
        check("a pick of a closed session is dropped", AgentsSelection.reconcile("z", ids: ids) == nil)
        check("no pick stays none", AgentsSelection.reconcile(nil, ids: ids) == nil)
        let reordered = ["e", "c", "a", "b", "d"]
        check("the order changed: still the same session", AgentsSelection.reconcile("c", ids: reordered) == "c")
        check("a step moves by position in the current order", AgentsSelection.move(id: "c", step: .right, ids: reordered) == "a")
        check("a step with a closed session starts over", AgentsSelection.move(id: "z", step: .right, ids: ids) == "a")
        check("no sessions: no pick", AgentsSelection.move(id: nil, step: .down, ids: []) == nil)
        check("↓ moves a row by id", AgentsSelection.move(id: "a", step: .down, ids: ids) == "e")
    }

    static func github() {
        print("\nGitHub")
        typealias K = GitHubKeys
        check("nothing picked: any arrow picks the first row of the first filled column",
              K.move(pick: nil, step: .down, counts: [0, 2, 3]) == GitHubKeyPick(column: 1, row: 0))
        check("nothing to pick: nil", K.move(pick: nil, step: .right, counts: [0, 0, 0]) == nil)
        check("→ goes to the next column, the row is kept",
              K.move(pick: GitHubKeyPick(column: 0, row: 1), step: .right, counts: [3, 3, 1]) == GitHubKeyPick(column: 1, row: 1))
        check("→ skips an empty column",
              K.move(pick: GitHubKeyPick(column: 0, row: 0), step: .right, counts: [2, 0, 2]) == GitHubKeyPick(column: 2, row: 0))
        check("→ into a shorter column clamps the row",
              K.move(pick: GitHubKeyPick(column: 0, row: 2), step: .right, counts: [3, 1, 1]) == GitHubKeyPick(column: 1, row: 0))
        check("→ at the last column stays",
              K.move(pick: GitHubKeyPick(column: 2, row: 0), step: .right, counts: [3, 1, 1]) == GitHubKeyPick(column: 2, row: 0))
        check("← at the first column stays",
              K.move(pick: GitHubKeyPick(column: 0, row: 1), step: .left, counts: [3, 1, 1]) == GitHubKeyPick(column: 0, row: 1))
        check("↓ clamps at the last row",
              K.move(pick: GitHubKeyPick(column: 1, row: 1), step: .down, counts: [3, 2, 1]) == GitHubKeyPick(column: 1, row: 1))
        check("↑ clamps at the first row",
              K.move(pick: GitHubKeyPick(column: 1, row: 0), step: .up, counts: [3, 2, 1]) == GitHubKeyPick(column: 1, row: 0))
        check("a pick in a column that became empty starts over",
              K.move(pick: GitHubKeyPick(column: 0, row: 0), step: .down, counts: [0, 2, 1]) == GitHubKeyPick(column: 1, row: 0))
    }

    // MARK: Approval

    static func approvalKeys() {
        print("\nPermission request")
        typealias A = ApprovalKeys
        check("buttons in screen order with Always", A.buttons(offersAlways: true) == [.deny, .allow, .always])
        check("buttons without Always", A.buttons(offersAlways: false) == [.deny, .allow])
        let t = approval
        let first = A.move(choice: nil, delta: +1, target: t)
        check("the first arrow right stands on Deny", first == AnswerKeyChoice(requestId: reqA, index: 0))
        check("the first arrow left stands on Deny too", A.move(choice: nil, delta: -1, target: t)?.index == 0)
        let allow = A.move(choice: first, delta: +1, target: t)
        check("then → is Allow", allow?.index == 1)
        let always = A.move(choice: allow, delta: +1, target: t)
        check("then → is Always", always?.index == 2)
        check("→ clamps at Always", A.move(choice: always, delta: +1, target: t)?.index == 2)
        check("← clamps at Deny", A.move(choice: first, delta: -1, target: t)?.index == 0)
        let noAlways = IslandAnswerTarget.approval(id: reqA, offersAlways: false)
        check("without Always → clamps at Allow", A.move(choice: allow, delta: +1, target: noAlways)?.index == 1)

        check("↩ without a pick sends nothing", A.confirm(choice: nil, target: t) == nil)
        let sent = A.confirm(choice: first, target: t)
        check("↩ on Deny sends deny for the request on screen", sent?.decision == "deny" && sent?.id == reqA)
        check("↩ on Allow sends allow", A.confirm(choice: allow, target: t)?.decision == "allow")
        check("↩ on Always sends always", A.confirm(choice: always, target: t)?.decision == "always")

        // The pick belongs to the request it was made on.
        check("the head changed to B: the pick of A is void",
              A.confirm(choice: allow, target: .approval(id: reqB, offersAlways: true)) == nil)
        check("the request was taken off: the pick is void", A.confirm(choice: allow, target: .none) == nil)
        check("the request became a question: the pick is void", A.confirm(choice: allow, target: .question(id: reqA)) == nil)
        check("an arrow after the head changed starts over on Deny",
              A.move(choice: always, delta: +1, target: .approval(id: reqB, offersAlways: true))
              == AnswerKeyChoice(requestId: reqB, index: 0))
        check("a pick on Always is void where Always is not offered",
              A.confirm(choice: always, target: noAlways) == nil)
        check("nothing to answer: arrows pick nothing", A.move(choice: nil, delta: +1, target: .none) == nil)
        check("a question is not answered with the approval keys", A.move(choice: nil, delta: +1, target: question) == nil)
        check("a pick of another question number is void",
              AnswerKeyChoice(requestId: reqA, questionIndex: 1, index: 0).isValid(for: question, questionIndex: 0) == false)
        check("a pick of the same question number is valid",
              AnswerKeyChoice(requestId: reqA, questionIndex: 1, index: 0).isValid(for: question, questionIndex: 1))
    }

    // MARK: Question

    static func questionKeys() {
        print("\nQuestion")
        typealias Q = QuestionKeys
        check("three variants make four rows", Q.rowCount(options: 3) == 4)
        check("the first arrow stands on the first variant", Q.move(row: nil, delta: +1, options: 3) == 0 && Q.move(row: nil, delta: -1, options: 3) == 0)
        check("→ walks the variants and then Other…", Q.move(row: 2, delta: +1, options: 3) == 3 && Q.isOther(row: 3, options: 3))
        check("→ clamps at Other…", Q.move(row: 3, delta: +1, options: 3) == 3)
        check("← clamps at the first variant", Q.move(row: 0, delta: -1, options: 3) == 0)
        check("2 picks the second variant", Q.digit(2, options: 3) == 1)
        check("4 with three variants picks nothing", Q.digit(4, options: 3) == nil)
        check("0 picks nothing", Q.digit(0, options: 3) == nil)

        check("↩ without a pick does nothing", Q.confirm(row: nil, options: 3, multiSelect: false, hasMarks: false) == .none)
        check("↩ on a variant answers it (single)", Q.confirm(row: 1, options: 3, multiSelect: false, hasMarks: false) == .answer(option: 1))
        check("↩ on Other… opens the field", Q.confirm(row: 3, options: 3, multiSelect: false, hasMarks: false) == .openOther)
        check("↩ on Other… opens the field (multiple)", Q.confirm(row: 3, options: 3, multiSelect: true, hasMarks: true) == .openOther)
        check("↩ without marks does nothing (multiple)", Q.confirm(row: 1, options: 3, multiSelect: true, hasMarks: false) == .none)
        check("↩ with marks goes on (multiple)", Q.confirm(row: 1, options: 3, multiSelect: true, hasMarks: true) == .advance)
        check("a pick past the rows does nothing", Q.confirm(row: 7, options: 3, multiSelect: false, hasMarks: false) == .none)
        check("Space marks the variant (multiple)", Q.space(row: 1, options: 3, multiSelect: true) == .toggle(option: 1))
        check("Space on Other… marks nothing", Q.space(row: 3, options: 3, multiSelect: true) == .none)
        check("Space in a single choice does nothing", Q.space(row: 1, options: 3, multiSelect: false) == .none)
        check("Space without a pick does nothing", Q.space(row: nil, options: 3, multiSelect: true) == .none)
        // A digit never produces an answer: it can only pick a row.
        check("digits give a row, not an effect", Q.digit(1, options: 2) == 0)
    }

    // MARK: Page hotkeys

    static func pageHotkey() {
        print("\nPage hotkeys")
        typealias P = PageHotkey
        check("on the page and key: closes", P.plan(target: .agents, view: .agents, mode: .expanded, panelIsKey: true) == .collapse)
        check("on the page but not key: only takes the keyboard",
              P.plan(target: .agents, view: .agents, mode: .expanded, panelIsKey: false) == .takeKeyboard)
        check("from the page of an agent: the list, not closing",
              P.plan(target: .agents, view: .agentPreview, mode: .expanded, panelIsKey: true) == .open(.agents))
        check("from the chat: the page opens", P.plan(target: .overview, view: .prompt, mode: .expanded, panelIsKey: true) == .open(.overview))
        check("hidden island opens on the page", P.plan(target: .overview, view: .agents, mode: .hidden, panelIsKey: false) == .open(.overview))
        check("compact island opens on the page", P.plan(target: .agents, view: .agents, mode: .compact, panelIsKey: false) == .open(.agents))
        check("a stale page behind a folded island does not close it",
              P.plan(target: .agents, view: .agents, mode: .hidden, panelIsKey: true) == .open(.agents))
        check("a waiting request is a page like any other: open the page",
              P.plan(target: .agents, view: .approval, mode: .expanded, panelIsKey: true) == .open(.agents))
    }
}
