# Headroom

A small macOS menu bar app that shows how much of your coding-agent subscription limits you have used.
It covers **Claude**, **Codex**, **Antigravity**, **Z.ai** and **OpenRouter**. It is inspired by [OpenUsage](https://github.com/robinebers/openusage) but does much less, on purpose.

The menu bar item shows every provider side by side, in the order set in Settings: its logo with what is
left of the Session, the Weekly, or both stacked (OpenRouter shows its credit balance). Providers that aren't
set up are left out. Click it to open the panel: every limit window with a meter of what is left (blue, yellow
from 20% left, red from 10% left) and when it resets. OpenRouter's section expands to show spend per key.

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
`swift test` runs the mapping, routing and relay tests.

## Providers

| Provider | Where Headroom reads credentials |
| --- | --- |
| Claude | Claude Code's keychain item (`Claude Code-credentials`), else `~/.claude/.credentials.json`. Run `claude` if the login expired. Shows Session, Weekly and model-scoped weekly limits such as Fable. More accounts: **Add account** in Settings (see below). |
| Codex | `~/.codex/auth.json` (or `$CODEX_HOME`, `~/.config/codex`), else the Codex keychain item. Sign in with `codex`. |
| Antigravity | **Sign in with Google** in Settings (Headroom's own login), else the token Antigravity keeps in the keychain (`gemini` / `antigravity`). Expired access tokens are renewed from the refresh token and kept in memory only. Shows Session, Weekly, Argon Weekly (when Google reports it) and the Claude pool. |
| Z.ai | **Sign in** in Settings opens a z.ai window; the web session is kept in Headroom's keychain item. Falls back to `~/.config/zai/key.json` or `ZAI_API_KEY` / `GLM_API_KEY`. |
| OpenRouter | API key saved in Settings, or `OPENROUTER_API_KEY`. A management key also lists usage for every key. |

Headroom only reads usage. It never changes another app's state, with two exceptions. When the Codex
access token is about to expire or is rejected, Headroom refreshes it as the Codex CLI does and writes the new
tokens back into `auth.json`, changing only the token fields and `last_refresh`. A keychain-based Codex login
is never refreshed. And while **Switch Claude Code between accounts** is on, Headroom adds three keys to
`~/.claude/settings.json` (below). Headroom's own logins (Antigravity, Z.ai, OpenRouter, extra Claude
accounts) live in keychain items under the service `Headroom`.

## Several Claude accounts

Connect more Claude accounts and put them in an order, for example a $20 Pro first and Max second. With
**Switch Claude Code between accounts** on, new Claude Code sessions start on the first account that has room
left, and the list is used again once the first one resets. Nothing in the Claude app changes: its sign-in,
sessions and settings stay as they are.

- **Sessions stay put while their cache is warm.** Moving a running session to another account would make
  that account read the whole conversation again at full price, since the prompt cache belongs to the account.
  So a session keeps its account until that account runs out (the one case where it has to move) or until it
  has been idle longer than its cache lasts (1 hour for Claude Code's main loop). Then it is placed again for
  free, which is how it gets back to the first account after a reset. Subagents share their session's
  account.
- **New sessions skip a busy account.** Once an account reaches 85% of its Session or Weekly limit (75%, 95%
  or "its limit" in Settings), new sessions start on the next one. The rest is kept for the sessions already
  running there, so they're less likely to be moved.

- **Main** is the account the Claude app (and the terminal `claude`) is signed in to. It is always in the list,
  needs no extra sign-in, and requests for it go out with Claude Code's own token.
- **Add account** signs another account in through the system's sign-in sheet in private mode, so it can't
  pick up the account your browser is signed in to. An email address, if given, is filled in for you. The login
  is kept in the keychain and refreshed by Headroom.
- **How the switch happens.** The toggle sets `HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS` and `NO_PROXY` in
  `~/.claude/settings.json` and starts a relay on `127.0.0.1:47812` (a LaunchAgent,
  `dev.polarzero.headroom.relay`, logs in `~/Library/Logs/Headroom/relay.log`). Every connection is tunnelled
  untouched, except Claude Code's own connections to `api.anthropic.com`: the relay decrypts them with a local
  CA that only Claude Code trusts, through `NODE_EXTRA_CA_CERTS`, and that only covers `api.anthropic.com`. It
  never goes into the system keychain. Each `/v1/messages` request gets the token of the account that should
  take it, and the account ID in its metadata is changed to match. A "limit reached" answer is retried on the
  next account, so Claude Code sees a normal reply. Everything else (settings, plugins, Remote Control) stays
  on the Claude app's account.
- **Which sessions take part.** Claude Code sessions started after the toggle. Sessions already running pick up
  the proxy too, but they don't trust the CA, so they only get the tunnel and keep their own account.
- **Extra usage.** An account that would be billed extra usage past its limit counts as out, unless you allow it
  in its menu in Settings.
- **The panel** lists the accounts in order, with a dot on the one new sessions start on, how many sessions
  each one has, when a used-up one comes back, and the last switch. The menu bar shows the account new
  sessions use, marked with its plan ("Pro", "Max") or its place in the order when plans repeat, and "Out"
  when every account is out. A notification says when new sessions change account and when a running session had to move.
- **Turning it off** blanks the keys (running sessions drop the proxy within seconds), removes them a minute
  later, and the relay stops by itself after 30 idle minutes. `Headroom --routing on|off` does the same from a
  terminal.
- While it is on, the relay has to keep running: without it, Claude Code and the tools it starts can't reach
  the network. launchd restarts it if it crashes.

Anthropic's terms allow several accounts but forbid "bypassing any of our systems or protective measures".
Switching automatically to get past usage limits can be read that way, so the switch is off until you turn it
on. Headroom also signs accounts in with Claude Code's own OAuth client. Details and the research behind this
are in [docs/claude-accounts.md](docs/claude-accounts.md).

## Behaviour

- Refreshes every 5 minutes, when the panel opens and on ⌘R. After a failure it retries after 60 s and keeps
  showing the last good data with a warning icon (hover it for the error).
- A provider shows **Outdated** after 10 minutes without a successful refresh.
- Settings (gear icon): enable, disable and reorder providers, what the menu bar shows, Claude accounts and
  switching, other accounts (Antigravity, Z.ai, OpenRouter), launch at login, and notifications.
- Notifications: one alert when a Session or Weekly window reaches 100%, once per reset.

## License

MIT. The provider logos come from [OpenUsage](https://github.com/robinebers/openusage) (MIT).
