import Foundation

@main
enum ClaudeHookDetectionTests {
    static func settings(_ json: String) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        return (object as? [String: Any]) ?? [:]
    }

    static func main() {
        // Installed: the hook Luna writes into ~/.claude/luna
        precondition(lunaHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"$HOME/.claude/luna/luna-hook"}]}]}}
        """)))

        // Installed: the script of the build outside the App Store, in Application Support
        precondition(lunaHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"/bin/sh \\"/Users/me/Library/Application Support/Luna/luna-hook\\""}]}]}}
        """)))

        // Installed: our hook sits alongside somebody else's
        precondition(lunaHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[
          {"hooks":[{"type":"command","command":"/usr/local/bin/other-tool"}]},
          {"hooks":[{"type":"command","command":"$HOME/.claude/luna/luna-hook"}]}]}}
        """)))

        // Not installed: other tools only — the case that showed "Key not configured"
        precondition(!lunaHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"$HOME/.vibe-island/bin/vibe-island-bridge"},
          {"type":"command","command":"python3 /Users/me/.claude/skills/harness/hook.py"}]}]}}
        """)))

        // Not installed: hooks for other events do not count
        precondition(!lunaHooksPresent(inSettings: settings("""
        {"hooks":{"PreToolUse":[{"hooks":[
          {"type":"command","command":"$HOME/.claude/luna/luna-hook"}]}]}}
        """)))

        // Not installed: a hook of the project Luna was taken from is somebody else's
        precondition(!lunaHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"$HOME/.claude/coucou/nb-hook"}]}]}}
        """)))

        // Malformed or empty settings never crash, and never read as installed
        precondition(!lunaHooksPresent(inSettings: settings("{}")))
        precondition(!lunaHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[]}}
        """)))
        precondition(!lunaHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[{"type":"command"}]}]}}
        """)))
        precondition(!lunaHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":"not-an-array"}}
        """)))
        precondition(!lunaHooksPresent(inSettings: settings("""
        {"hooks":"not-an-object"}
        """)))

        print("Claude hook detection: 11 cases passed")
    }
}
