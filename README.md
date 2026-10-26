# Headroom

A small macOS menu bar app that shows how much of your coding-agent subscription limits you have used.
It covers **Claude**, **Codex**, **Antigravity** and **Z.ai**. It is inspired by [OpenUsage](https://github.com/robinebers/openusage) but does much less, on purpose.

Each provider gets its own menu bar item: its logo with the Session %, the Weekly %, or both stacked
(choose in Settings). Providers that aren't set up get no item. Click any item to see every limit window
with a meter (blue, yellow from 80%, red from 90%), how much is used and when it resets.

On a Mac with a notch, macOS hides menu bar items that don't fit next to it. If an item is missing, ⌘-drag
other items out of the way, or use Settings to turn off providers you don't need.

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
`swift test` runs the mapping tests.

## Providers

| Provider | Where Headroom reads credentials |
| --- | --- |
| Claude | Claude Code's keychain item (`Claude Code-credentials`), else `~/.claude/.credentials.json`. Run `claude` if the login expired. |
| Codex | `~/.codex/auth.json` (or `$CODEX_HOME`, `~/.config/codex`), else the Codex keychain item. Sign in with `codex`. |
| Antigravity | Keychain item `gemini` / `antigravity`, written by Antigravity. Open Antigravity if the login expired. |
| Z.ai | API key saved in Settings (Keychain, service `Headroom`), `~/.config/zai/key.json`, or `ZAI_API_KEY` / `GLM_API_KEY`. |

Headroom only reads usage. It never changes another app's state, with one exception: when the Codex
access token is about to expire or is rejected, Headroom refreshes it as the Codex CLI does and writes the new
tokens back into `auth.json`, changing only the token fields and `last_refresh`. A keychain-based Codex login
is never refreshed.

## Behaviour

- Refreshes every 5 minutes, when the panel opens and on ⌘R. After a failure it retries after 60 s and keeps
  showing the last good data with a warning icon (hover it for the error).
- A provider shows **Outdated** after 10 minutes without a successful refresh.
- Settings (gear icon): enable, disable and reorder providers, what the menu bar shows, the Z.ai API key,
  launch at login, and notifications.
- Notifications: one alert when a Session or Weekly window reaches 100%, once per reset.

## License

MIT. The provider logos come from [OpenUsage](https://github.com/robinebers/openusage) (MIT).
