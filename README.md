# Headroom

A small macOS menu bar app that shows how much of your coding-agent subscription limits you have used, and
helps you **run Claude Code on several Claude accounts**. It covers **Claude**, **Codex**, **Antigravity**,
**Z.ai** and **OpenRouter**. It is inspired by [OpenUsage](https://github.com/robinebers/openusage) but does
much less, on purpose.

**Several Claude accounts.** Got a Max plan and a $20 Pro, or a work and a personal account? Headroom gives
each account its own Claude app window, signed in to that account, so its Code-tab sessions run entirely on
it. It shows every account's limits side by side and marks the one to use for your next session, so you spend
the cheap plan first and move on before it runs out. Settings, skills, hooks and plugins stay shared; only the
sessions are per account. Nothing is proxied or rewritten: every window is the official app with a normal
sign-in. See [Several Claude accounts](#several-claude-accounts).

The menu bar item shows every provider side by side, in the order set in Settings: its logo with what is
left of the Session, the Weekly, or both stacked (OpenRouter shows its credit balance). With several Claude
accounts, it shows each one's name and what is left, the one for new sessions in a filled tag. Providers that
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

Each Claude account gets its own copy of the Claude app, signed in to that account, so its Code-tab sessions
run entirely as that account. Nothing is relayed or rewritten: each copy is the official app with a normal
sign-in. Headroom opens the copies, shows every account's limits and says which one to use for new sessions.

- **Add account** (Settings → Claude accounts) with a short name, for example "Pro". Headroom opens a new
  Claude window with its own data folder (`~/Library/Application Support/Claude-Pro`, through the app's
  `--user-data-dir`). To sign it in, quit your main Claude app first: the sign-in link goes to whichever copy is
  open. Sign in in the new window, then reopen your main app with its **Open** button in Headroom.
- **Sign in in Terminal** once per account. Headroom opens Terminal on `claude` with the account's own config
  folder (`~/.claude-accounts/Pro`); Claude Code signs in and keeps that login itself. Headroom reads its usage
  from it, the same way it reads your main account from `~/.claude`. If that sign-in isn't used for a long
  time it expires; run `claude` there again.
- **Open / Show** brings an account's window forward or starts it. Use these rather than the Dock icon: macOS
  sees every copy as the same app, so the Dock only reaches whichever copy is already running.
- **What is shared:** everything Claude Code reads from `~/.claude` (settings, hooks, skills, agents,
  plugins, CLAUDE.md, MCP servers, memory), because every copy runs Claude Code on it. The terminal folders
  link the same items. Session presets are kept the same in every copy (written to copies that aren't
  running, so a change shows up in the others once they have been closed and reopened).
- **What is separate:** each copy's list of sessions, and what Anthropic keeps per account (chats,
  Customize, connectors, Remote Control).
- **Which account for new sessions:** the first in your order below 85% of its Session or Weekly limit (75%,
  95% or "its limit" in Settings). The menu bar shows each account's name and what is left, with a filled
  name tag on that account. A notification says when it changes. A running session stays where it is.
- Running two paid subscriptions side by side is your call; nothing here moves a session between accounts.

## Behaviour

- Refreshes every 5 minutes, when the panel opens and on ⌘R. After a failure it retries after 60 s and keeps
  showing the last good data with a warning icon (hover it for the error).
- A provider shows **Outdated** after 10 minutes without a successful refresh.
- Settings (gear icon): enable, disable and reorder providers, what the menu bar shows, Claude accounts,
  other accounts (Antigravity, Z.ai, OpenRouter), launch at login, and notifications.
- Notifications: one alert when a Session or Weekly window reaches 100%, once per reset, and one when new
  Claude sessions should move to another account.
- Limit resets: Claude's reset grants are checked at most once an hour per account; Codex's reset credits
  with every refresh.

## License

MIT. The provider logos come from [OpenUsage](https://github.com/robinebers/openusage) (MIT).
