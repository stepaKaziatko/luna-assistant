# Luna — third-party agent integration

Any tool that can write to a Unix domain socket (macOS, Linux) or a named pipe (Windows) can send events to Luna and have its own pill next to Claude Code.

## The `luna_agent` field

Add the optional field `luna_agent` to any hook JSON payload. Luna will create a pill labelled with the agent name and route all events to it.

**Validation:** the name must match `^[a-z0-9-]{1,24}$` (lowercase letters, digits and hyphens, 1–24 characters). An absent or invalid name routes the event to the Claude Code pill instead.

## Hook command (macOS)

Configure your tool to call the Luna relay with `--agent <your-name>` after the hook executable:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "/path/to/luna-hook --agent my-tool" }
    ]
  }
}
```

The shell wrapper passes `"$@"` to the Python relay, which extracts the agent name and injects it into the payload before forwarding to Luna.

## Hook command (Windows)

Same pattern with the Windows relay:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "C:\\path\\to\\luna-hook.exe --agent my-tool" }
    ]
  }
}
```

## Hook command (Linux)

Same pattern with the Linux relay. Luna copies the relay to `~/.local/share/luna/bin/luna-hook` at startup.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "/path/to/luna-hook --agent my-tool" }
    ]
  }
}
```

## Payload format

The relay adds `luna_agent` to the JSON it forwards. You can also add it yourself if you talk to the socket directly:

```json
{
  "hook_event_name": "UserPromptSubmit",
  "session_id": "my-session-1",
  "luna_agent": "my-tool",
  "prompt": "Running task…"
}
```

Send newline-terminated JSON to the socket:
- **macOS (GitHub build):** `~/Library/Application Support/Luna/luna.sock`
- **macOS (App Store build):** `~/Library/Containers/dev.luna.LunaPhone/Data/luna.sock`
- **Windows:** `\\.\pipe\luna-<user-SID>`
- **Linux:** `$XDG_RUNTIME_DIR/luna.sock` (usually `/run/user/<uid>/luna.sock`). Only your own user account can connect.

## Supported events

All standard Claude Code hook events are supported, **except `PermissionRequest`**:
approval cards are not yet implemented for third-party agents (only Claude Code gets
one). A `PermissionRequest` from an external agent is answered immediately with no
decision, so the relay writes nothing and the agent re-asks in its terminal.
Approval support for other agents will be added with Codex support.

The pill lifecycle:

| Event | Effect |
|---|---|
| `SessionStart` | Creates the pill (if absent), sets state to idle |
| `UserPromptSubmit` | State → thinking; prompt shown in ticker |
| `PreToolUse` | State → working; tool label shown in ticker |
| `PostToolUse` / `PostToolUseFailure` | State → working |
| `Notification` | Rate-limit or question state if applicable |
| `Stop` | State → finished for 5 s; active declared pills (catalog + checked in Settings) reset to idle — all others are removed |
| `StopFailure` | State → error |
| `SessionEnd` | Active declared pills (catalog + checked in Settings) reset to idle — all others are removed |
| `SubagentStart` / `SubagentStop` | Step added to ticker |

## Declared pills

A **declared pill** is a catalog entry (`PillCatalog.swift`) that has been enabled in **Settings → Active pills**. When a session ends for a declared pill, the pill stays visible and resets to idle instead of disappearing.

A catalog pill that is not checked in Settings behaves like any other agent: it gets an automatic pill when a session starts, and that pill is removed when the session ends.

The GitHub build exposes Gemini CLI (`agent_gemini`), Antigravity (`agent_antigravity`),
GitHub Copilot CLI (`agent_copilot`), Muse Code (`agent_muse`), OpenCode (`agent_opencode`),
Amp (`agent_amp`) and Hermes (`agent_hermes`) in Settings → Active pills. Cursor (`agent_cursor`) and Codex
(`agent_codex`, GitHub build only) are there too — their pills can be declared and set as
the main pill. Their sessions are followed like any other: Claude Code in Cursor and Codex both
send approval and question cards to the notch, and every session of them shows on the Agents page.

Claude Desktop (`agent_claude-desktop`, every build) is there as well. Claude Code sessions started from the Claude desktop app's Code tab carry `CLAUDE_CODE_ENTRYPOINT=claude-desktop`; the relay tags them `luna_agent: claude-desktop` on its own (an explicit `--agent` still wins), so nothing extra is installed. Declare the pill to keep it after the session ends; the ↗ button opens the Claude app.

## The Agents page

The second tab of the island header lists the live agent sessions, one tile per session — not
per pill, so two Claude Code sessions in two projects under one VS Code are two tiles. A tile
shows the agent's Luna, the project (the agent's own name for a third-party agent, which sends no
`cwd`), the agent and the app it runs in (icon from the `bundle_id` of the event), the last five
steps as icons (newest on the right) and a status line.

| State | Tile |
|---|---|
| Waits for you (a permission request or a question the notch holds) | first, orange frame, "Waiting: permission Bash" / "Waiting: question" |
| Error (`StopFailure`) | red frame |
| Turn finished (`Stop`, Gemini's `AfterAgent`) | green frame and a green mark on the avatar until the agent has been looked at, then quiet (a calm avatar, "Turn finished · 5 min ago" stays as text) |
| Working (`UserPromptSubmit`, `PreToolUse`…) | blue frame, the last step as the status |
| Open, no turn (`SessionStart`, `Interrupt`) | quiet |

Where the data comes from: the hook events in this document (`PillSessionRegistry` still decides
what a turn-ending event may do to a pill; `AgentSessionBook` in `AgentSessions.swift` keeps the
sessions and their steps). "Waits for you" is read off the approval queue and the question on the
card when the tiles are built, so it goes away on its own when the request is answered, times out
or is taken back by the agent.

"Finished, not seen" (`finishedUnseen`) goes off when the agent is looked at: its page is shown, "Go to
the agent" is done for it, or the Agents page is left (for everyone it showed). Hovering the notch and
the block under the cursor is not a look. Everything follows the flag, not the phase: the frame, the
avatar (`AgentLook.botState`), the mini on the notch and the "Finished" counter at the top of the Agents
page (`AgentsSummary`), which counts only unseen turns. The next turn that ends is news again. Only requests the notch actually holds count: a terminal session
asks the notch only with "Answer questions and permissions from terminal sessions" on, and a
third-party agent never does.

A session leaves the page on `SessionEnd`, after two hours without an event between turns
(some agents never send `SessionEnd`), or after twelve hours at the latest; a turn that sends
nothing for 30 minutes no longer counts as working. A `Stop` of a session Luna never heard
start creates no tile. Claude Code in an editor or terminal Luna does not know (JetBrains,
Windsurf…) is ignored, as everywhere.

## The agent preview

A click on a tile opens the preview page of that session (`AgentPreviewView.swift`; `AppState.openAgent(id:)`
is the single entry point, `⌃⌥A` still opens the card of the waiting request). Back leads to the
list. The page follows the session by its tile id: when the session ends it says "Session closed".

- **Left:** the agent's Luna, the project, the agent and its host app, the folder, the status and
  the last answer of a finished turn. **Right:** the last 20 steps of the session (the tile shows
  the last five) — or, when the session waits, its question or request.
- **One queue, not two.** The page owns no queue. A permission request is read off
  `HookServer.approvals` (`AppState.agentRequests`), a question off the one the card holds
  (`pendingQuestion`, with `pendingQuestionId` and `pendingQuestionOwner`). An answer goes through
  the same `sendApprovalDecision(_:for:)` / `sendQuestionAnswers(_:for:)` as the card's, **with the
  id of the request on screen**; the server accepts it only while that id is still the current
  one (`QuestionHolder`, `ApprovalQueue.accepts(decisionFor:)`). Answering on the card takes the
  buttons off the page and the other way round; a second click or a click on a request that is
  gone does nothing and does not move you off the page. The order does not change: only the head
  of the queue is answered, a request behind it shows "In the queue: 2 of 3". A request that
  arrives while the page is open still brings its card forward, as before.
- **After the answer.** Answered on the card (or gone while its card is on screen), the island folds into
  the notch — or shows the next waiting request, which the queue picks as before; gone without an answer,
  a note shows for three seconds first. The page of an agent stays and says the request is gone; on any
  other page you stay where you are. Only when the island cannot fold (a mail draft by voice holds it) does
  it go home rather than show an empty card. One pure rule, `IslandHome.afterRequest`.
- **Same buttons.** "Always" is hidden for Codex, Copilot CLI and Muse Code by one function
  (`ApprovalChoices`) used by the card and the page. A session whose requests Luna does not get
  (a terminal session with the terminal setting off, an observed-only agent) says so instead of
  showing buttons.

### Keyboard

The page of Agents, the page of an agent and the cards of a request and of a question are driven with
the keys once the island has the keyboard (a page hotkey — `⌃⌥S` Agents, `⌃⌥P` Active pills, `⌃⌥A` the
waiting request, `⌃⌥Space` the chat — or a click). The user's app stays the active one; `⎋` folds the
island and the keys go back to it. `⌘⎋` ("Collapse the island", `ShortcutAction.collapseIsland`) folds
it from any app without the keyboard: a Carbon hotkey registered only while the island is expanded
(`ShortcutLogic.registersWhileExpandedOnly`, switched by the island's mode), so while it is folded `⌘⎋`
stays with other apps (in VS Code it focuses the input of Claude Code). A waiting request stays in the
queue. It can be changed or switched off in Settings → Shortcuts; the `?` hint shows it next to `⎋`. All keys are one table (`IslandKeys.swift`, `IslandKeyTable`) that the
monitor, the `?` hint and Settings → Shortcuts read; the pure parts are tested without a window
(`scripts/test-island-keys.sh`).

- **Agents:** the arrows pick a tile (rows of four, nothing wraps; the pick is kept by session id, so it
  follows its agent and goes with it), `↩` opens the page of the picked agent, `⌘↩` goes to its window.
  **Page of an agent:** `⌫` back to the list (the tile stays picked), `⌘↩` goes to the agent.
- **Answering takes two steps.** Arrows (or a digit in a question) pick a button or a variant — the first
  arrow on a permission request lands on Deny — and `↩` sends the pick. `↩` with nothing picked, a held
  key, or a pick made for a request that is no longer the one on screen sends nothing: the pick carries
  the id of the request (and the number of the question) and is void as soon as either changes. The answer
  goes through the same `sendApprovalDecision(_:for:)` / `sendQuestionAnswers(_:for:)` as a click, with that
  id. In a multiple choice `Space` marks a variant and `↩` goes on or sends once something is marked; `↩` on
  "Other…" opens the field (the field then has the keys). A digit only picks; it no longer answers at once.
- `⌫` is not bound on the cards of a request or a question: leaving a question card hands the question
  back to its terminal.
- A text field with the keyboard keeps its keys (the chat, "Other…", the mail draft), but only on a page
  that shows one: the chat field no longer keeps the keyboard while the chat is not the page on screen.

### Go to the agent

The button on the page is the only place where Luna hands the focus to another app, on a click
(`AgentJump.open`; the plan is a pure function, `AgentJumpPlan`). The island folds afterwards.

| Host of the session | What happens |
|---|---|
| VS Code, VS Code Insiders, VSCodium | The **project root** of the session is opened in that app (its window with the folder comes up), then `<scheme>://anthropic.claude-code/open?session=<id>` makes the extension reveal the session's tab in that window. The link goes once the editor is in front and its top window changed (`AgentJumpPlan.linkReady`), at the latest after 1.5 s. Editor not running: the folder only, no link — the link would start the session again in a new tab. The scheme is from a fixed list and the id must be a UUID; otherwise only the folder is opened. |
| Cursor | The folder only: Claude Code and the agent of Cursor reach Luna under the same pill and cannot be told apart. |
| Terminal.app, iTerm2 | The app is activated and the tab with the session's tty is selected through AppleScript (build from GitHub only). macOS asks for the **Automation** permission the first time you press the button, never at launch; without it the app is only activated and the page says where to allow it (System Settings → Privacy & Security → Automation). |
| Other terminals (Warp, Ghostty, kitty, Alacritty, WezTerm…) | The app is activated; they have no scripting for tabs. |
| Claude desktop, Codex desktop | The app is activated; Luna does not open a session in it (the session id of the desktop app is not the one of the hook). |
| Unknown host | The project folder in Finder; with no folder known, the button is off. |

**Which folder.** VS Code raises an existing window only for the exact folder that window has open; a
subfolder or a worktree the agent `cd`-ed into opens a new window. So the jump opens the project root,
not the current `cwd`: `CLAUDE_PROJECT_DIR` of the hook's environment (the relay puts it into the event as
`project_dir`), or, for agents that do not set it, the `cwd` of the first event Luna saw. The book keeps it
once (`AgentSessionWho.projectDir`) and later events do not move it. Left as they are: a window opened on
another folder or on a multi-root `.code-workspace` — VS Code opens a new window then (Luna does not
read the windows of other apps, so it cannot know which folders they have open).

**Seen.** The jump is a look at the agent: like opening its page, it takes the "finished, not seen"
mark off that session (`AppState.goToAgent` → `HookServer.markAgentsSeen(for:)`).

The tty is found by Luna itself: the pid of the process on the other end of the hook's socket
(`LOCAL_PEERPID`), then the nearest process up the parent chain that has a terminal
(`ProcessTTY.swift`). The installed `luna-hook` is not touched. A hook that only fires and forgets
may be gone by the time Luna looks, so the tty is learned from the first event that finds it alive
(a permission request or a question always does, other events do within a few tool calls) and kept
for the session; until then "Go to the agent" only activates Terminal or iTerm2. Only a checked
`/dev/ttysN` ever reaches an AppleScript; the folder, the project name and the session id never do.
The App Store build has no AppleScript: it activates the app or opens the folder.

### Open the session in another app

"Open in…" — the icon next to "Go to the agent" (GitHub build only) — continues a Claude Code session
(`integration_claude`, a UUID session id) in another app than the one it runs in. The plan is a pure
function (`AgentHandoffPlan`, `scripts/test-agent-handoff.sh`); `AgentHandoff` only opens a folder and a
link through `NSWorkspace` and puts a command on the pasteboard — no process, no script, no new macOS
permission. Nothing but the session id and the project folder leaves Luna.

| Target | What Luna opens | Status |
|---|---|---|
| VS Code | The project root (`AgentJumpPlan.folder(of:)`), then `vscode://anthropic.claude-code/open?session=<uuid>` — the same "folder → link" step as "Go to the agent" (`AgentJump.openFolderThenLink`), up to 10 s when VS Code was not running. Needs the Claude Code extension (folder names in `~/.vscode/extensions`). The session must belong to the workspace of the focused window, otherwise VS Code starts a new conversation | Link *documented*; the `session` check of the extension *verified* in its code |
| Claude Desktop | `claude://resume?session=<uuid>` — the link `claude --desktop --resume` opens ("importing CLI session"); Desktop continues the same conversation | *Verified* in the code of the CLI 2.1.296 and Claude.app 1.49585; not documented, the format may change |
| Terminal | Nothing is opened: `cd '<folder>' && claude --resume <uuid>` goes to the pasteboard (the folder in single quotes, `'` as `'\''`) | `claude --resume` *documented* |

**Why it waits for `SessionEnd`.** Every session on the agent page is open in its own process: the tile
lives until `SessionEnd`. VS Code answers an open conversation with "This conversation is still open
somewhere else… Open here anyway" (*documented*), and the Desktop link does not check it at all — it would
make a second copy writing to the same conversation (*verified* in Claude.app: only its own `/resume`
checks ownership). So a click only sets a pending handoff (`AgentHandoffBook`, memory only): the page says
"Close the session in <host> — Luna will open it in <target>" with "Cancel", and the target opens on the
`SessionEnd` hook event of that session (`HookServer.recordAgentEvent` → `AppState.agentHandoffEvent`).
A new turn of the session (`UserPromptSubmit`, `PreToolUse`…) cancels it, so does "Cancel", 5 minutes
without `SessionEnd` (one delayed task, no polling) and quitting Luna; a second click replaces the first. A
session that drops off the list for silence (no `SessionEnd`) never opens. That the VS Code extension sends
`SessionEnd` when its tab is closed is an *assumption*, checked by hand.

Not offered: while the agent works or waits for an answer; the app the session already runs in (that is
"Go to the agent"); apps that are not installed; sessions of Claude Desktop itself (whether VS Code finds
them is not verified); other agents, anonymous sessions (no UUID). VS Code without a valid, existing
project folder is disabled; Claude Desktop does not need the folder.

### Launch an agent

"Launch agent" on the prompt page (next to the project chip, Claude Code by subscription, GitHub build
only) hands a task to the app where the person works with Claude Code. Luna does not start the agent
itself: the task is typed into a new chat in the project folder, the person sends it with Enter in that
app, and from then on the session reaches Luna through the hooks like any other. The plan is a pure
function (`AgentLaunchPlan`, `scripts/test-agent-launch.sh`); `AgentLaunch` only opens a folder and links
through `NSWorkspace` — no process, no script, no new macOS permission, nothing written to the settings of
other apps. The task goes into the link and nowhere else; nothing reaches a model before the person's Enter.

| Target | What Luna opens | Needs |
|---|---|---|
| VS Code | The project folder in VS Code, then `vscode://anthropic.claude-code/open?prompt=<task>` once the window with the folder is in front — the same "folder → link" step as "Go to the agent" (`AgentJump.openFolderThenLink`), waiting up to 10 s when VS Code was not running. VS Code decodes the query of a link once itself (`URI.parse`) and the extension parses the rest with `URLSearchParams`, so the task is percent-encoded twice. | VS Code and the Claude Code extension (a folder `anthropic.claude-code-<version>` in the extensions folder of VS Code; only the folder names are read) |
| Terminal | `claude-cli://open?cwd=<folder>&q=<task>`: Claude Code opens a window of the terminal where `claude` was last run, with `claude` in the folder and the task typed in ("Prompt from an external link"). | The handler `claude-cli://` (`~/Applications/Claude Code URL Handler.app`), registered by Claude Code after the first prompt in an interactive `claude` |
| Claude Desktop | `claude://code/new?folder=<folder>&q=<task>` — a new Code session in the folder. | Claude Desktop, signed in |

Refused, with the reason on the button: no project, an empty task, a task over 5000 UTF-16 units (the limit
of `q` in `claude-cli://`; never cut silently), a folder that is not absolute, has control characters or a
`..` segment, a folder that is gone or not readable. Every value is percent-encoded with only the RFC 3986
unreserved characters left as they are, so `&`, `=`, `+`, `#`, newlines and non-ASCII text survive.

**Ways to launch an agent — research (LUNA-77).** Marks: *verified* — checked on a Mac (claude 2.1.296,
the VS Code extension 2.1.304, VS Code 1.141.1, Claude.app 1.49585) or read in the code of the handler;
*documented* — official documentation only; *assumption* — not checked.

| Way | How | Luna sees it (hooks) | Open the chat later | Status |
|---|---|---|---|---|
| VS Code tab with the task typed in | Folder, then `vscode://anthropic.claude-code/open?prompt=` (not sent; the link goes to the focused window) | Yes, host `com.microsoft.VSCode` | There; "Go to the agent" | Shipped. Link format verified in the extension (`handleUri`); double decoding verified in VS Code (`URI.parse`) |
| Terminal via `claude-cli://` | `claude-cli://open?cwd=&q=` (not sent; `q` ≤ 5000) | Yes, with a tty | There | Shipped. Handler verified on a Mac; format documented |
| Claude Desktop | `claude://code/new?folder=&q=` | Hooks of `~/.claude/settings.json` apply in Desktop (documented) | There | Shipped. `folder` read in the code of Claude.app; `q` together with `folder` is an assumption |
| Codex app | `codex://new?path=&prompt=`, `codex://threads/<id>` | Assumption | `codex://threads/<id>` | Not done: Codex not installed, nothing verified |
| Background `claude --bg` | A session kept by the supervisor of Claude Code; `claude agents --json` for the state | Assumption | `claude attach <id>` in a terminal only | Not done: needs a trusted folder (verified: refused "Workspace not trusted"), a new `claude` process outside `ClaudeCLIChat.swift` |
| Background `claude -p` as a child of Luna | `--session-id <uuid>` in the project folder | Yes, but the host would be Luna (assumption) | After the turn: VS Code `?session=`, `claude --desktop --resume <id>`, `claude --resume <id>` | Not done: skips the trust dialog, dies with Luna, changes the invariant on the `claude` process |
| Interactive `claude` in Terminal/iTerm2 via AppleScript | `do script "cd … && claude …"` | Yes, with a tty | There | Not done: types commands into a terminal; `claude-cli://` gives the same without it |
| Claude Agent SDK | Node or Python | — | — | Rejected: a third-party dependency |

## The notch and the block under the cursor

The resting island (the "notch") speaks for the agents. Its right wing shows one little Luna per
session that has news, the one that waits for you first; the left Luna takes her mood from the
kind of news that wins. Both come from one pure model, `AgentNotchSummary` (`AgentNotch.swift`),
a function of `AppState.agentSessions` that is rebuilt only when the sessions change.

- **News and priority.** Waits for you > error > turn finished and not looked at > working. A
  session that waits and works at once counts as waiting, once. A finished turn that has been
  seen, and an open session with no turn, are quiet: no mini, no light. The priority is written in
  one place (`AgentNotchSummary.dominant`).
- **The wing.** Up to four cells; with more sessions, three minis and a "+N" cell (a digit, "9+"
  above nine). A mini is one session, not one pill. Waiting is bigger, ringed and lit, and
  pulses once a second; the marks differ by shape as well as colour (bell, triangle, tick). The
  integrations of "Active pills" are no longer drawn on the notch (they stay on the "Active pills" page).
- **The mood of the big Luna** in the compact island is that of the first session of the winning
  kind (`AppState.islandBotState`); with no news, and in every open island, it is as before.
- **Held on screen.** While a session waits, failed or finished unseen, the notch does not fall to
  its hidden size on the 60 s timer (`IslandStateMachine.holdsCompact`); this blocks nothing else.
  Working alone does not hold it. When the news is gone, the usual 60 s start.
- **Seen.** A finished turn stops being news when the Agents page was shown and left, or when the
  page of that agent is shown (`AgentSessionBook.markFinishedSeen(for:)`). Hovering is not looking.
- **The block under the cursor.** Keep the pointer on the resting island for 450 ms and the same
  black figure grows downward: counters, "All agents" and a tile for each of the most urgent
  sessions (all of them up to four, otherwise three and "+N"). It folds 500 ms after the pointer
  leaves the figure, and at once on a click or when the island opens. No block with "Open on hover"
  on (that opens the whole island), with no sessions, while Luna is dragged, in voice mode, or
  while a request card waits. When and where is `AgentPeek.swift` (`AgentPeekPolicy`,
  `AgentPeekLayout`), fed by the pointer poll that already runs: no timer of its own.
- **Clicks.** A tile opens the page of that agent, "+N" and "All agents" the Agents page; a click
  on the notch itself opens the island as before. The click is read from the layout by
  `IslandWindowController` and swallowed there: the panel never takes the key, and the app you work
  in stays active.
- **Cost.** Wing and block are still pictures; the only motion is the waiting pulse, one step a
  second, off with the screen and while the island is hidden. `apps/macos/scripts/measure-cpu.sh`
  measures a running Luna (it refuses a sleeping or locked screen). Each change of the summary
  writes one line to `~/Library/Logs/Luna/luna.log`: `notch: waiting=… error=… finished=… working=… minis=…`.

## Real-world examples

### Gemini CLI (macOS)

Luna supports Gemini CLI out of the box via **Settings → Gemini CLI → Install hooks**.
The installer writes to `~/.gemini/settings.json` and uses `--agent gemini` so
Gemini sessions get their own pill. The relay translates Gemini event names to canonical
Luna events automatically.

| Gemini CLI event | Canonical event |
|---|---|
| `BeforeTool` | `PreToolUse` |
| `AfterTool` | `PostToolUse` |
| `BeforeAgent` | `UserPromptSubmit` |
| `AfterAgent` | `Stop` |

`AfterModel` is not installed — it fires on every response chunk and would flood the island.

### Antigravity — `agy` (macOS)

Luna supports Antigravity out of the box via **Settings → Antigravity → Install hooks**.
The installer writes to `~/.gemini/config/hooks.json` (timeouts in seconds) and uses
`--agent antigravity`. The relay translates `toolCall.name` / `conversationId` to the
island's `tool_name` / `session_id`.

| Antigravity event | Canonical event |
|---|---|
| `PreInvocation` | `UserPromptSubmit` |
| `PreToolUse` | `PreToolUse` |
| `PostToolUse` | `PostToolUse` |
| `PostInvocation` | `PostToolUse` |
| `Stop` | `Stop` |

### GitHub Copilot CLI (macOS)

Luna supports Copilot CLI out of the box via **Settings → GitHub Copilot CLI Hooks → Install hooks**.
The installer writes to `~/.copilot/hooks/luna.json` and uses `--agent copilot`.
Copilot CLI uses camelCase event names and `{"bash":"…","timeoutSec":N}` entries.
Copilot CLI is fail-closed on `permissionRequest`: the relay always outputs valid JSON
and returns `{"permissionDecision":"ask"}` on timeout so Copilot re-prompts in the terminal.
Luna shows a real Allow / Deny card for Copilot approval requests.

| Copilot CLI event | Canonical event |
|---|---|
| `sessionStart` | `SessionStart` |
| `userPromptSubmitted` | `UserPromptSubmit` |
| `preToolUse` | `PreToolUse` |
| `permissionRequest` | `PermissionRequest` |
| `postToolUse` | `PostToolUse` |
| `agentStop` | `Stop` |
| `sessionEnd` | `SessionEnd` |
| `notification` | `Notification` |

### Muse Code (macOS)

Luna supports Muse Code out of the box via **Settings → Muse Code Hooks → Install hooks**.
The installer merges into `~/.config/muse/settings.json` and uses `--agent muse`.
Muse uses PascalCase event names. Luna shows a real Allow / Deny card for Muse approval requests.

| Muse Code event | Canonical event |
|---|---|
| `SessionStart` | `SessionStart` |
| `UserPromptSubmit` | `UserPromptSubmit` |
| `PreToolUse` | `PreToolUse` |
| `PermissionRequest` | `PermissionRequest` |
| `PostToolUse` | `PostToolUse` |
| `Stop` | `Stop` |
| `SessionEnd` | `SessionEnd` |

### OpenCode (macOS)

Luna supports OpenCode via **Settings → OpenCode Plugin → Install plugin**.
The installer writes a JS plugin to `~/.config/opencode/plugins/luna.js`.
The plugin maps OpenCode event types to canonical Luna names and forwards them fire-and-forget; OpenCode is never blocked.

| OpenCode event | Canonical event |
|---|---|
| `session.created` | `SessionStart` |
| `session.idle` | `Stop` |
| `session.error` | `StopFailure` |
| `session.deleted` | `SessionEnd` |
| `tool.execute.before` | `PreToolUse` |
| `tool.execute.after` | `PostToolUse` |
| `permission.asked` | `PermissionRequest` |

### Amp (macOS)

Luna supports Amp via **Settings → Amp Plugin → Install plugin**.
The installer writes a TypeScript plugin to `~/.config/amp/plugins/luna.ts`.
The `tool.call` handler returns `{ action: 'allow' }` so Amp always proceeds; all events are forwarded display-only.

| Amp event | Canonical event |
|---|---|
| `session.start` | `SessionStart` |
| `agent.start` | `UserPromptSubmit` |
| `tool.call` | `PreToolUse` |
| `tool.result` | `PostToolUse` |
| `agent.end` | `Stop` |

### Hermes Agent (macOS)

Luna supports Hermes via **Settings → Agents → Hermes → Install plugin**.
The installer writes a Python plugin to `~/.hermes/plugins/luna/` and enables it in
`~/.hermes/config.yaml`. The plugin uses `on_session_start` (sends the platform when running
via the gateway), `post_llm_call` (sends the final response), and a `pre_approval_request`
observer hook that fires a `⏳ Approval pending in Hermes` step in the notch.
Approving from the notch requires `register_approval_transport`, which is not yet available
in Hermes 0.15.x; the Approvals toggle activates automatically once Hermes exposes it.
Every event is fire-and-forget: if the app is closed or unreachable, nothing is sent and Hermes carries on, handling approvals itself.

| Hermes event | Canonical event |
|---|---|
| `on_session_start` | `SessionStart` |
| `post_llm_call` | `Stop` |
| `pre_approval_request` | `PreToolUse` (observer only, shows "⏳ Approval pending in Hermes") |

### Any other tool

Follow the generic pattern: call `luna-hook --agent <your-name> <EventName>` (macOS),
`luna-hook.exe --agent <your-name> <EventName>` (Windows)
or `~/.local/share/luna/bin/luna-hook --agent <your-name> <EventName>` (Linux)
and let the relay forward the event.

## Quick test (Linux)

With Luna running:

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"hello","luna_agent":"demo"}' \
  | ~/.local/share/luna/bin/luna-hook --agent demo
```

A "demo" pill should appear in the island.

## Quick test (macOS)

With Luna running:

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"hello","luna_agent":"demo"}' \
  | /bin/sh ~/Library/Application\ Support/Luna/luna-hook --agent demo
```

A "demo" pill should appear in the island.
