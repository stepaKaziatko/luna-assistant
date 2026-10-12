import Foundation

// MARK: - WakePhrase tests (pure functions, no concurrency)

@main
enum WakePhraseTests {

    static var failures = 0

    static func main() {
        // MARK: split — should match

        // Basic wake phrases (no command)
        checkMatch("ok luna",              WakePhrase.split("ok luna"),              cmd: "")
        checkMatch("OK LUNA",              WakePhrase.split("OK LUNA"),              cmd: "")
        checkMatch("okay luna",            WakePhrase.split("okay luna"),            cmd: "")
        checkMatch("ok louna",                WakePhrase.split("ok louna"),                cmd: "")
        checkMatch("ok lu na",             WakePhrase.split("ok lu na"),             cmd: "")
        checkMatch("hey luna",             WakePhrase.split("hey luna"),             cmd: "")
        checkMatch("Hey Luna",             WakePhrase.split("Hey Luna"),             cmd: "")

        // Command extracted from original text (casing/punctuation preserved)
        checkMatch("Okay, Luna, ajoute GitHub",
                   WakePhrase.split("Okay, Luna, ajoute GitHub"),             cmd: "ajoute GitHub")
        checkMatch("ok lunar add github",
                   WakePhrase.split("ok lunar add github"),                    cmd: "add github")
        checkMatch("ok luna ouvre figma",
                   WakePhrase.split("ok luna ouvre figma"),                   cmd: "ouvre figma")

        // Apostrophes, hyphens and accents preserved in command
        checkMatch("OK Luna, mets l'album de Daft Punk",
                   WakePhrase.split("OK Luna, mets l'album de Daft Punk"),   cmd: "mets l'album de Daft Punk")
        checkMatch("ok luna qu'est-ce que fait Claude ?",
                   WakePhrase.split("ok luna qu'est-ce que fait Claude ?"),  cmd: "qu'est-ce que fait Claude ?")

        // Wake anywhere in transcript (word-boundary search)
        checkMatch("euh ok luna mets de la musique",
                   WakePhrase.split("euh ok luna mets de la musique"),        cmd: "mets de la musique")
        checkMatch("la chanson dit ok luna",
                   WakePhrase.split("la chanson dit ok luna"),                cmd: "") // accepted false positive

        // LAST occurrence wins
        checkMatch("ok luna search ok luna play music",
                   WakePhrase.split("ok luna search ok luna play music"),   cmd: "play music")

        // Partial word-by-word delivery
        checkNoMatch("ok alone",             WakePhrase.split("ok"))
        checkMatch("ok luna partial",      WakePhrase.split("ok luna"),              cmd: "")
        checkMatch("ok luna with more",    WakePhrase.split("ok luna mets"),         cmd: "mets")

        // MARK: split — should NOT match
        checkNoMatch("standalone luna",    WakePhrase.split("luna"))
        checkNoMatch("standalone LUNA",    WakePhrase.split("LUNA"))
        checkNoMatch("partial luna ça va", WakePhrase.split("luna ça va"))
        checkNoMatch("luna comment",       WakePhrase.split("luna comment tu vas"))
        checkNoMatch("ok google",            WakePhrase.split("ok google"))
        checkNoMatch("hey siri",             WakePhrase.split("hey siri"))
        checkNoMatch("okkkk luna",         WakePhrase.split("okkkk luna"))
        checkNoMatch("empty",                WakePhrase.split(""))

        // Summary
        if failures == 0 { print("\n\(total)/\(total) tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }

    static var total = 0

    static func checkMatch(_ label: String, _ r: WakePhrase.SplitResult, cmd: String) {
        total += 1
        if !r.matched {
            print("✗  \(label) — expected match, got no match"); failures += 1; return
        }
        if r.command != cmd {
            print("✗  \(label) — matched ✓ but command \"\(r.command)\" ≠ \"\(cmd)\""); failures += 1; return
        }
        print("✓  \(label)")
    }

    static func checkNoMatch(_ label: String, _ r: WakePhrase.SplitResult) {
        total += 1
        if r.matched { print("✗  \(label) — expected no match, got matched (cmd: \"\(r.command)\")"); failures += 1 }
        else         { print("✓  \(label)") }
    }
}
