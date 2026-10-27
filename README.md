# Headroom

A small macOS menu bar app that shows how much of your coding-agent subscription limits you have used, and
helps you **run Claude Code on several Claude accounts**. It covers **Claude**, **Codex**, **Antigravity**,
**Z.ai** and **OpenRouter**. It is inspired by [OpenUsage](https://github.com/robinebers/openusage) but does
much less, on purpose.

**Several Claude accounts.** Got a Max plan and a $20 Pro, or a work and a personal account? Headroom shows
every account's limits side by side, and lets your Claude Code sessions run their **subagents on whichever
other account has room**. Claude uses them exactly like its built-in subagents; when no account has room it
falls back to the built-in ones. Each subagent is plain Claude Code signed in to that account: nothing is
proxied or rewritten. See [Several Claude accounts](#several-claude-accounts).

The menu bar item shows every provider side by side, in the order set in Settings: its logo with what is
left of the Session, the Weekly, or both stacked (OpenRouter shows its credit balance). With several Claude
accounts, it shows each one's name and what is left. Providers that
aren't set up are left out. Click it to open the panel: every limit window with a meter of what is left (blue,
yellow from 20% left, red from 10% left) and when it resets, plus a small ↺ count of the limit resets an
account can spend (Claude reset grants, Codex reset credits; hover for when they expire). OpenRouter's section
expands to show spend per key.

On a Mac with a notch, macOS hides a menu bar item that doesn't fit next to it. If Headroom is missing,
⌘-drag other items out of the way, or turn off providers you don't need in Settings.

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Command Line Tools are enough; no Xcode project)

## Build and run

```sh
./script/build_app.sh     # release build → dist/Headroom.app (ad-hoc signed)
open dist/Headroom.app
```

For development, `swift run Headroom` starts the app without a bundle (launch at login and notifications
are then unavailable). `swift run Headroom --print` fetches every provider once and prints the result.
`swift test` runs the mapping and account tests.

## Providers

| Provider | Where Headroom reads credentials |
| --- | --- |
| Claude | Claude Code's keychain item (`Claude Code-credentials`), else `~/.claude/.credentials.json`. Run `claude` if the login expired. Shows Session, Weekly and model-scoped weekly limits such as Fable. More accounts: **Add account** in Settings (see below). |
| Codex | `~/.codex/auth.json` (or `$CODEX_HOME`, `~/.config/codex`), else the Codex keychain item. Sign in with `codex`. |
| Antigravity | **Sign in with Google** in Settings (Headroom's own login), else the token Antigravity keeps in the keychain (`gemini` / `antigravity`). Expired access tokens are renewed from the refresh token and kept in memory only. Shows Session, Weekly, Argon Weekly (when Google reports it) and the Claude pool. |
| Z.ai | **Sign in** in Settings opens a z.ai window; the web session is kept in Headroom's keychain item. Falls back to `~/.config/zai/key.json` or `ZAI_API_KEY` / `GLM_API_KEY`. |
| OpenRouter | API key saved in Settings, or `OPENROUTER_API_KEY`. A management key also lists usage for every key. |

Headroom only reads usage. It never changes another app's state, with one exception: when the Codex
access token is about to expire or is rejected, Headroom refreshes it as the Codex CLI does and writes the new
tokens back into `auth.json`, changing only the token fields and `last_refresh`. A keychain-based Codex login
is never refreshed. Headroom's own logins (Antigravity, Z.ai, OpenRouter) live in keychain items under the
service `Headroom`.

## Several Claude accounts

Every account is a Claude Code sign-in of its own. Main is the one you already have (`~/.claude`). Each other
account lives in `~/.claude-accounts/<name>` (`CLAUDE_CONFIG_DIR`), which links to your settings, skills,
agents, commands, hooks, plugins and CLAUDE.md in `~/.claude`, so it behaves the same; only its sign-in and
its sessions are its own.

- **Add account** (Settings → Claude accounts) with a short name, for example "Pro". Headroom opens Terminal on
  Claude Code in that account's folder; sign in there (type `/login` if it doesn't ask). Claude Code keeps
  and renews that sign-in itself, and Headroom reads the account's usage from it. When it has expired
  because the account wasn't used for a while, Headroom starts Claude Code on that account with no prompt,
  which renews it without using any of its limits. If that fails, run
  `CLAUDE_CONFIG_DIR=~/.claude-accounts/<name> claude` again.
- **The panel and the menu bar** show every account's limits, in the order set in Settings.
- **Run subagents on accounts with room** (Settings) installs Headroom's Claude Code plugin for all your
  sessions (`claude plugin install headroom@headroom --scope user`, from a marketplace folder inside
  Headroom.app, so it updates with the app). Claude keeps using its built-in `Agent` tool as usual. When
  another of your accounts has room, Claude Code creates a real native subagent and Headroom runs its work there:
  - Claude Code owns the task, transcript row, foreground/background controls, report delivery and lifetime.
    Headroom answers the agent's model step with its remote report, without a model request on the session's
    account. Foreground calls wait normally; ctrl+b sends them to the background. Background reports keep
    `claude -p` alive after its input ends and reach SDK hosts, including the desktop app. `SendMessage`,
    `TaskStop` and `ListAgents` use the native agent's id and Claude Code's own handling. Follow-ups resume
    the remote session on the same account, folder (its worktree with `isolation: "worktree"`) and agent
    type. Claude Code queues messages received while it works and resumes it with them.
  - It runs `claude -p` in the session's folder with the same parameters (`subagent_type`, `model`, `effort`,
    `isolation`), your MCP servers (from `~/.claude.json`, passed with `--mcp-config`) and the session's
    permission mode. "Ask each time" becomes auto mode, since nobody can be asked there.
  - The status line shows "1 agent on Pro"; a pane, **Agents on other accounts** (`/agents-elsewhere`), lists
    each agent's latest steps.
  - Some calls go to the built-in tool untouched, on purpose: forks (they run on the session's own context
    and its prompt cache), named teammates, workflow agents, remote agents, calls from subagents, and any
    call when no other account has room.
  - Anything else that doesn't work as expected is an error, never a quiet switch to the built-in agent: an
    Agent field the plugin doesn't know yet, an agent type the other account lacks, a runner that fails or
    ends without a report. Claude gets the error and tells you.
  - The first session on a new Claude Code version runs a self-test on another account: it starts an
    agent the way a ready process starts it, continues it, and stops one (two one-line Haiku answers). If
    any step fails, the status line says what broke until a later version passes.
  - The native transcript keeps the remote final report. Remote steps and tool results stay in Headroom's
    pane and logs; they are not replayed as native tool calls. The pane shows remote tool use;
    Claude Code's counter counts native calls only. See the
    [native task adapter](docs/claude-accounts.md#native-task-adapter-2026-10-27) for the API checks and live tests.
- **Ready processes.** Claude Code takes about 11 s to start. So when you send a prompt, the plugin asks
  Headroom to start one on the account a subagent would use, in that folder, waiting for its prompt; an Agent
  call on that account and folder with the same agent type takes it over and skips the wait: Headroom switches
  it to the call's model and permission mode first. Its first step then comes after about 2 s; a cold start
  takes 8 to 70 s. Headroom keeps at most two, each about 300 MB plus your MCP
  servers, and lets them go after 10 minutes unused or when it quits. A runner takes the process's pipes
  over a socket, so the agent keeps going if Headroom quits.
- **Which account takes a subagent:** never the session's own account; only accounts below both thresholds
  (90% of the Session and of the Weekly limit by default, set in Settings); among those, the one with the
  most room. Usage comes from what the app last read (every few minutes), else from the account's sign-in;
  when that is rate limited, a reading up to 30 minutes old is used. If an account answers "limit reached"
  before doing anything, it counts as full for 10 minutes and the next one takes the task.
- **Plans differ in models.** If an account's plan doesn't include the model asked for (a Pro plan has no
  Fable, for example), the subagent runs there with Sonnet, and Headroom remembers it.
- A subagent never starts subagents on yet another account. Decisions are logged in
  `~/Library/Logs/Headroom/subagents.log`; each agent's steps in
  `~/Library/Application Support/Headroom/agents/<agentId>.log`.
- Running two paid subscriptions side by side is your call; every request is made by Claude Code itself,
  signed in to the account it bills.

## Agents on other providers

**Settings → Agents** is a list of your own agent types, each on a provider and model of its own: Codex,
Z.ai, OpenRouter, Antigravity, or your other Claude accounts. Each has a name, a description (what it is
for: Claude reads it to choose), a provider, a model from that provider's list, and an effort, either fixed
or decided by Claude on each call. Turn one off to hide it.

Turn on **Save Claude usage** to ask Claude to delegate substantial implementation, exploration, reviews
and research to Headroom agents first, choosing by their descriptions. Claude works itself or uses built-in
subagents when no Headroom agent fits. Off by default; changes apply from the next prompt.

- Claude sees the enabled ones beside its built-in agent types, as `headroom:<name>` with their description
  and where they run, and calls them with its built-in `Agent` tool. The plugin reads the list on every
  prompt, so edits apply from the next turn of every session.
- Such an agent always runs on its provider: never as a built-in agent, never somewhere else. When the
  provider can't take it (signed out, out of usage, a model or effort it lacks), the call fails and Claude
  says why.
- It behaves like the agents on other Claude accounts above: the same row and transcript, foreground or
  background, `SendMessage` (on the same provider, model and session, even if the list changed since),
  `TaskStop`, `ListAgents`, and Open in Terminal on the provider's own session.
- They run only from the main session's `Agent` tool: not as forks, teammates or from inside a subagent.

## Behaviour

- Refreshes every 5 minutes, when the panel opens and on ⌘R. After a failure it retries after 60 s and keeps
  showing the last good data with a warning icon (hover it for the error).
- A provider shows **Outdated** after 10 minutes without a successful refresh.
- Settings (gear icon): enable, disable and reorder providers, what the menu bar shows, Claude accounts,
  other accounts (Antigravity, Z.ai, OpenRouter), launch at login, and notifications.
- Notifications: one alert when a Session or Weekly window reaches 100%, once per reset.
- Limit resets: Claude's reset grants are checked at most once an hour per account; Codex's reset credits
  with every refresh.

## License

MIT. The provider logos come from [OpenUsage](https://github.com/robinebers/openusage) (MIT).
