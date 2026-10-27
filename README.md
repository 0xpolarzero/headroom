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
  and renews that sign-in itself, and Headroom reads the account's usage from it. If it isn't used for a long
  time it expires; run `CLAUDE_CONFIG_DIR=~/.claude-accounts/<name> claude` again.
- **The panel and the menu bar** show every account's limits, in the order set in Settings.
- **Run subagents on accounts with room** (Settings) registers `Headroom --mcp` with Claude Code for all your
  sessions (`claude mcp add --scope user headroom`). It adds two tools that mirror the built-in ones:
  - **`Agent`** takes the same parameters (`description`, `prompt`, `subagent_type`, `model`, `effort`,
    `isolation`) and returns the agent's final answer and its `agentId`. It runs `claude -p` on the chosen
    account, in the session's folder, in auto permission mode. Several calls in one message run in parallel,
    spread over the accounts.
  - **`SendMessage`** continues such an agent by its `agentId`, on the same account.

  The server tells Claude to prefer these for subagent work. They start fresh, without the conversation, like
  built-in subagents, and can't ask questions.
- **Which account takes a subagent:** never the session's own account; only accounts below both thresholds
  (90% of the Session and of the Weekly limit by default, set in Settings); among those, the one with the
  most room. Usage is read from each account's sign-in, cached for two minutes. If an account answers "limit
  reached" before doing anything, the next one takes the task.
- **Plans differ in models.** If an account's plan doesn't include the model asked for (a Pro plan has no
  Fable, for example), the subagent runs there with Sonnet and its answer says so.
- **When none has room**, `Agent` answers `No other Claude account has room right now. Use built-in subagents.`
  and Claude carries on with its built-in subagents.
- A subagent never starts subagents on yet another account. The other accounts' folders don't share your
  user-level MCP servers (`~/.claude.json`), so subagents there don't have them.
- Running two paid subscriptions side by side is your call; every request is made by Claude Code itself,
  signed in to the account it bills.

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
