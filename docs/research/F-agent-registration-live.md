# Agent registration in a live Claude Code session

Verified 2026-10-27 with Claude Code 2.1.310, Haiku, and the user-scoped plugin read in place from `/Applications/Headroom.app`. The main Claude account rejected a trivial prompt at its weekly limit; all remaining probes used `CLAUDE_CONFIG_DIR=$HOME/.claude-accounts/Pro`.

## Failure and cause

Adding `probe-new` between messages of one `--input-format stream-json` session failed on the next turn:

```text
Agent type 'headroom:probe-new' not found. Available agents: claude, Explore, general-purpose, headroom:probe-codex, headroom:probe-gemini, Plan
```

The following turn's `system/init.agents` included `headroom:probe-new`. Moving synchronization from `classic.UserPromptSubmit` to `prompt.submit` reproduced the same failure; that experiment was removed.

The installed engine snapshots `agents` in its input context before prompt hooks. `$.agent.register` refreshes the session's definitions, but the current context retains its earlier array. The Agent tool's core dispatch checks that array before raising `agent.spawn`. Thus registration succeeds, but Headroom's spawn interceptor is never reached for the newly added type in that turn. A changed description already reached the next request through `tool.describe`.

Primary evidence: the installed executable at `~/.local/share/claude/versions/2.1.310`; `Q_` resolves `agents:tr(e.agents)`, `JVr` awaits `MWn`/`refreshAgents`, and `qo` reads `e.options.agentDefinitions.activeAgents`. See also the [official mod declarations](https://github.com/anthropics/claude-code/blob/main/mods/types/claude-code.d.ts), `agent.register`, `prompt.submit`, and `ToolCallResult`. Core reports execution failures as `{ isError: true, text, result, ref }`, rather than a hook's `{ deny }`.

## Fix

The Agent tool description now supplements the complete enabled catalog, exposing additions as well as edited descriptions immediately. After core's permission checks, Headroom recovers only the exact missing-type error for an enabled `headroom:` type that has not started. It sends the original request to Headroom's runner, preserving foreground/background behavior. Swift rechecks enablement and resolves the provider; permission refusals and other failures pass through unchanged. Existing types retain the normal `tool.call` → core checks → `agent.spawn` path.

Provider starts and continuations now also write their agent ID, type, provider, model and effort to `~/Library/Logs/Headroom/subagents.log`; per-agent logs retain actual starts and results.

Regression tests cover the native error envelope, permission refusal, and the new type's tool-description supplement. `swift test` passed 91 tests (5 skipped); `claude plugin test ClaudePlugin/headroom` passed 27 tests. The release app was rebuilt, quit, replaced, reopened, and its installed binary/plugin compared byte-for-byte with the build.

## Evidence

The companion [evidence extract](F-agent-registration-evidence.jsonl) retains selected stream-json events and Headroom log lines with their source filenames and line numbers. Full raw streams, debug logs, catalog revisions and the original-state manifest are in `/tmp/headroom-live-20261027-133658`.

The final installed-app verification passed every scenario:

| Scenario | Evidence extract lines | Result |
| --- | --- | --- |
| Fresh-session types and descriptions | 2, 6, 11 | Both types listed; descriptions include their providers, models and low effort. |
| Foreground Codex | 3–5, 48–51, 60 | `headroom:probe-codex` returned `ok` on `gpt-6-luna`. |
| Foreground Gemini | 7–9, 40–43, 61 | `headroom:probe-gemini` returned `ok` on Antigravity's `gemini-3.8-flash-low`. |
| Add between turns | 13–17, 44–47, 62 | `probe-new` returned `ok` immediately; native init still held the old list. |
| Disable between turns | 18–20 | Explicit disabled error; no provider or built-in agent started. |
| Edit description between turns | 22–23 | Claude quoted `Checks violet teapots 731.` from the supplement. |
| Background notification | 25–30, 38, 52–55, 63 | `run_in_background: true`; task notification completed with `ok` on Codex. |
| SendMessage | 32–39, 56–59, 64 | Same Headroom agent continued on Codex and delivered a second `ok` notification. |

Usage: 12 real Claude sessions, 24 user turns and 4 automatic notification turns; 44 model turns including one rejected by the main account's weekly limit. Plugin test processes do not make model calls.

The original catalog was absent; its absence was recorded before any edit. Per the user's updated cleanup instruction, the provided final catalog replaced the probes instead of restoring absence. Its contents match the source except for revision 101, above the maximum probe revision 14. One `Headroom --agent-catalog` call confirmed exactly `argon`, `sol`, `flash`, `gemini`, `terra-cu` (evidence line 65). Flash was not tested live because its Z.ai Coding Plan key is absent.
