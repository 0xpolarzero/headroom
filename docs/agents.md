# Agents on other providers — design

Status: built on the `agents-on-providers` branch, 2026-10-27. Codex and Antigravity verified live; Z.ai and OpenRouter need an inference key to verify. Research behind it: [docs/research/](research/) (A: Claude Code side,
B: Codex, C: Z.ai and OpenRouter, D: Antigravity).

## What Claude sees

Nothing new to learn. Headroom's enabled agents show up as agent types next to the built-in ones
(`headroom:codex-deep`, `headroom:glm`, …), each with its one-line role. Claude calls the built-in `Agent`
tool with that `subagent_type`; the row, Show transcript, background, `SendMessage`, `TaskStop`,
`ListAgents` and Open in Terminal work as they do for agents on other Claude accounts today.

`model` can't carry providers: the Agent schema only accepts `sonnet | opus | haiku | fable`. The agent type
picks the provider and model; the call's `model` is ignored (or rejected if it conflicts) for Headroom types.

## The Agents list (Settings)

**Save Claude usage** (off by default) asks Claude to delegate substantial implementation, exploration,
reviews and research to Headroom agents first, choosing by description, even when a description says to
prefer built-in Claude subagents. Claude works itself or uses built-in agents only when none fits.
The catalog stores this as `saveClaude`; older catalogs decode it as false.

One global list. Each entry:

| Field | Notes |
| --- | --- |
| name | Becomes the agent type. Stable slug. |
| description | The role Claude reads ("Second opinion on tricky bugs"). Also sent to the backend as instructions. |
| provider | Claude account pool, Codex, Z.ai, OpenRouter (Antigravity: see below). |
| model | Picked from the provider's live list (Codex `model/list`, OpenRouter `/api/v1/models` filtered to tool use, Z.ai fixed list). |
| effort | Preset (fixed level) or dynamic (use the call's `effort`, mapped per provider; levels the model lacks are an error, not a silent clamp). |
| enabled | Off hides the type; calls already in flight, or stale ones, get a clear "disabled" error. |

Headroom writes the list as a revisioned catalog in Application Support. Credentials never go in it.

## How it reaches Claude Code

The mod API has what's needed (research A §3): `$.agent.register({name, description, prompt, model})`
registers `headroom:<name>` for the session, and `agent.offer` hides disabled types. The plugin syncs the
catalog on session start and before each prompt, so changes apply from the next turn. Claude Code 2.1.310
snapshots its agent definitions before those prompt hooks: a newly registered type otherwise fails
with `Agent type '…' not found` for one turn. The plugin recovers only that exact core error after
permission checks, running the enabled definition through Headroom. Other errors stay errors.

Usage saving adds one named block through `prompt.context`, leaving the shared system prompt intact.
Claude renders context before prompt-submit hooks, so the context hook reads the catalog itself and
invalidates that cached answer for the next prompt. The next prompt reads toggle changes in running sessions; unchanged text
preserves the model's prompt cache. Turning it off omits the block.
See the [mod API declarations](https://github.com/anthropics/claude-code/blob/main/mods/types/claude-code.d.ts),
`prompt.context` and `ui.invalidate`.

Live verification (2026-10-27): the enabled mode selected `headroom:gemini` for a read-only exploration.
An on/off context check in one running Pro session used local `/context` commands, with zero model
requests, and logged the instruction followed by its absence. Total: two Haiku model turns.
[Evidence](research/G-save-claude-usage-evidence.jsonl).

Verified live: re-registering a type under the same name doesn't re-announce a changed description to
Claude. The plugin puts the current enabled catalog in the Agent tool's description (`tool.describe`) and
invalidates it on each revision. This also exposes new types before the native listing catches up. See
[the live verification](research/F-agent-registration-live.md). Fallback if the API is missing: generated files in `~/.claude/agents/headroom/`
(watched every 2 s), but they run natively if the plugin is absent, so they can't guarantee routing alone.

## Routing rules

- A Headroom type always goes to its provider: never the built-in agent, never another account. The
  exclusions that apply today (forks, teammates, nested calls…) become errors for Headroom types.
- Out of room, signed out, model not on the plan → an error that says which and when it resets.
- The run keeps the provider, model, effort and session id it started with; `SendMessage` continues there even
  if the entry was edited since.
- Other agent types keep today's behaviour (opportunistic other-Claude-account, then built-in).

## Backends

Two runners cover four providers.

**1. Claude Code runner (exists).** Claude accounts as today, plus any Anthropic-compatible endpoint:
- Z.ai: `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`, `ANTHROPIC_AUTH_TOKEN=<Coding Plan API key>`,
  GLM model ids for every model role. Effort maps to GLM low/high/max. Needs a Coding Plan **API key**: the
  web session Headroom keeps can't do inference. Ask for the key in Settings first; creating it through the
  console's private API comes later, if ever.
- OpenRouter: `ANTHROPIC_BASE_URL=https://openrouter.ai/api`, a regular (not management) key, model pinned to an
  OpenRouter id. Non-Claude models through Claude Code are unproven: mark each model "tested" only after a
  tracer run passes.
- Each provider gets its own `CLAUDE_CONFIG_DIR` (`~/.claude-accounts/zai`, …) with its own settings (no
  symlinked settings: they'd carry the user's env), and the runner scrubs every inherited `ANTHROPIC_*`
  variable before setting the provider's. Warm processes are keyed by provider and profile too: a live
  process can't change endpoint.
- New error classes: Z.ai business codes 1308/1310/1316–1321 (window exhausted) vs 1302/1305 (throttling);
  OpenRouter 402 (credit). Today's runner treats neither correctly.
- Free later: Kimi, DeepSeek, MiniMax use the same path.

**2. Codex runner (new).** `codex app-server --listen stdio://`, not `codex exec` (research B §1): it streams
items, lists models with their efforts, resumes and interrupts threads, and reports rate limits and typed
errors (`usageLimitExceeded`, …). Borrow from the bridge fork: JSON-RPC transport, lifecycle races, thread
persistence, wait logic (B §2, with the bugs to leave behind). Mapping:
- Items → transcript: commands → `Bash: …`, file changes, MCP calls, web search as tool rows; agent messages
  as text; the reasoning summary and plan as text. Final answer = the turn's final-phase message.
- Permission modes → sandbox + approval (default and auto → workspace-write + auto review, as a Claude
  agent's default becomes auto; acceptEdits → workspace-write; plan → read-only; bypass → full access).
  Antigravity likewise: default, acceptEdits and auto → accept-edits; plan → plan. Approval requests nobody can answer are declined,
  never left hanging.
- The user's MCP servers are translated from `~/.claude.json` into per-thread config overrides, except
  servers Codex already configures itself (`config/read`), which keep Codex's entry (LCU needs its Codex adapter); the role
  goes in `developerInstructions`; CLAUDE.md content is passed explicitly (Codex only reads AGENTS.md).
- Open in Terminal: `cd <cwd> && CODEX_HOME=<home> codex resume <threadId>` (stop the runner's copy first).
- Worktree isolation: Headroom creates the worktree before `thread/start`.

**3. Antigravity: through the official `agy` CLI as a child process (the user decided to go ahead; no OAuth token reuse).** `agy -p --output-format stream-json` would work technically (research D §4),
but Google's current FAQ calls wrapping `agy` in third-party coding agents unsupported on consumer plans,
its terms ban reusing the Antigravity OAuth, and it has banned accounts for this before. A Google forum
moderator said the opposite; that conflict is still open. Revisit once Google answers it in writing. Gemini
CLI no longer runs on consumer subscriptions. Separately: Headroom's usage reading already uses Antigravity's
OAuth client and User-Agent, which those same terms cover. Worth reviewing.

## Order of work

1. Catalog + Settings list + `$.agent.register` + routing rules, using the Claude account pool as the only
   provider. Proves registration, live edits, disable and errors with no new backend.
2. Z.ai and OpenRouter on the Claude Code runner (config dirs, env scrub, warm-pool keys, error classes).
3. Codex runner.
4. Antigravity if and when Google's policy allows it.

Each backend ships after a tracer run passes: Read/Bash/Edit, warm start, continue, stop, transcript, Open in
Terminal, and a quota-exhausted error.
