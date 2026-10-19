import Foundation

/// True when a parsed ~/.claude/settings.json routes Claude Code SessionStart events to Luna.
///
/// Kept free of file access so it can be tested on fixtures instead of the real settings file.
/// The hook is recognised by the command text: whatever Luna writes runs a script named
/// luna-hook (~/.claude/luna/luna-hook, or the copy in Application Support). Entries of
/// other tools, including the hook of the project Luna was taken from, are not ours.
func lunaHooksPresent(inSettings settings: [String: Any]) -> Bool {
    guard let hooks = settings["hooks"] as? [String: Any],
          let sessionStart = hooks["SessionStart"] as? [[String: Any]] else { return false }
    return sessionStart.contains { group in
        (group["hooks"] as? [[String: Any]])?.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return command.contains("luna-hook")
        } ?? false
    }
}
