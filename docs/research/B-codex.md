# B — Codex backend adapter

Use **`codex app-server --listen stdio://`**, owned by Headroom's runner helper. Keep the existing plugin result contract; implement Codex transport and normalization in Swift.

Evidence: local Codex `4607249e43`, bridge `0e7146a`, inspected 2026-10-27; source research, no inference runs. Below, `H` = `/Users/polarzero/code/projects/headroom`, `B` = `/Users/polarzero/code/tools/claude-codex-bridge`, `C` = `/Users/polarzero/code/projects/openai-codex/codex-rs`, `P` = `C/app-server-protocol/src/protocol/v2`. Pointers are relative to these roots. [Official app-server documentation](https://learn.chatgpt.com/docs/app-server) describes this product integration surface.

## 1. Transport and lifecycle

| Requirement | app-server | `exec --json` |
|---|---|---|
| Streaming | Item lifecycle plus text, reasoning, command-output deltas | JSONL `item.started/updated/completed`, turn events; narrower projection |
| Selection | `thread/start`: model, serviceTier; `turn/start`: model, effort, serviceTier | `--model`; config overrides `model_reasoning_effort`, `service_tier` |
| Permissions | Sandbox, approval policy, reviewer; bidirectional approval requests | Defaults to never ask; rejects interactive approval requests |
| Continue | Saved `thread/resume`, then `turn/start`; active `turn/steer` | New `codex exec resume THREAD_ID --json PROMPT` process |
| Stop | `turn/interrupt {threadId,turnId}` | SIGINT, translated internally to turn interruption |
| Picker | Paginated `model/list`: model slug, supported/default efforts, service tiers | No discovery operation in exec's event protocol |
| Usage | Token notifications, rate-limit snapshot RPC and updates, structured errors | Final token usage; JSONL error has message only |
| Warm | Keep initialized process ready for thread creation | Invocation owns one workflow; no equivalent reusable control channel |

Evidence: `P/thread.rs:62,354`; `P/turn.rs:167,293,327`; `P/model.rs:55,119,178`; `C/exec/src/exec_events.rs:11,50,92`; `C/exec/src/lib.rs:566,1113,1218,1983`; `C/config/src/config_toml.rs:376,391`.

Initialize with Headroom client identity, await response, send `initialized`. Start a durable thread (`ephemeral:false`), persist its returned ID/cwd/effective model before starting work. Validate effort/tier against discovery, not hardcoded enums. Catalog visibility does not prove account access. Preserve omitted versus null serviceTier semantics. Pin a supported CLI/schema version; generate bindings/schema with that executable and gate experimental fields.

Keep Headroom's queued SendMessage behavior (`H/ClaudePlugin/headroom/hooks/register.tsx:200`): enqueue while running, start the next turn after completion. Steer is available if intentionally changing that UX; it requires `expectedTurnId` and cannot change effort. TaskStop waits for terminal `interrupted`, rather than treating the interrupt RPC acknowledgement as completion.

## 2. Borrow from the bridge

- **Transport:** `B/src/app-server.ts:45-69,72-142`: one initialization, newline framing, request IDs, separate notifications/server requests, pending-call rejection on failure. Preserve structured RPC errors instead of reducing them to message strings. An ambiguous launch timeout must not trigger blind replay (`:79-82`).
- **Lifecycle races:** `B/src/bridge.ts:130-208,385-442`: deduplicated reattachment, serialized thread controls, notifications arriving before launch acknowledgement, requested versus effective settings. Stop/message routing: `:210-237`.
- **Persistence:** `B/src/bridge.ts:354-369`; `B/src/store.ts:12-30,64-76,94-111`: durable thread metadata, atomic replacement, owner host/PID/start identity. Add a real ownership lock; identity checks alone do not serialize writers.
- **Delivery:** `B/src/bridge.ts:308-314,600-623`: bounded journal, sequence/gap detection, ordered publication. Normalize by item ID; do not copy the thread-wide mixed text/command buffer (`:463-465,579-597`) or incomplete item coverage (`:475-481`).
- **Waiting:** `B/src/wait.ts:24-71`: terminal-state checks, deadlines, missing records and dead/unknown owners. Use runner events normally; retain disk polling for recovery. Waiting timeout is not task failure. Do not copy `idle` as “completed” (`B/src/store.ts:35`). Bridge shutdown kills active work (`B/src/bridge.ts:626-654`), so persistence is not execution survival.

## 3. Transcript and result mapping

Headroom accepts `text{text}`, `tool{id,summary,input}`, `result{id,text,isError}` (`H/ClaudePlugin/headroom/types/index.d.ts:2`; `H/Sources/Headroom/Subagents/SubagentRunner.swift:267-335`). Every tool start also emits `step{text:summary}`. The UI appends items, keeps 300, renders Markdown text and six result lines, and derives its count from retained tool rows (`H/ClaudePlugin/headroom/hooks/register.tsx:169,379-400`).

| Codex item/event | Headroom mapping |
|---|---|
| agentMessage | Completed item → text; deltas → progress, without duplicate text rows |
| reasoning | `item/reasoning/summaryTextDelta` → progress; completed summary → text “Reasoning”; raw content optional |
| commandExecution | tool “Bash: command”, input command/cwd; completed result aggregatedOutput + exitCode/status |
| fileChange | One tool per patch item, summary changed paths, input changes/diffs; result apply status |
| mcpToolCall | tool “MCP server/tool”, arguments JSON; result text/structuredContent or error |
| webSearch | tool “WebSearch: query” or URL action; result available action/status, without inventing search results |
| plan; turn/plan/updated | Text “Plan” and step statuses; progress step on updates; no invented tool count |

Schemas: `P/item.rs:236-399`; plan notification `P/turn.rs:568`. Also normalize dynamic/collaboration tools when enabled. Deduplicate starts/completions by `(threadId,turnId,itemId)` and synthesize a tool start if only completion arrives. Keep full items in runner storage; apply existing 4,000/2,000-character display caps. The current append-only UI needs an upsert extension for live item updates; completed snapshots work immediately.

Final `result`: use final_answer-phase agent messages from the completed turn; fallback to its last agent message when phase is absent (`C/protocol/src/models.rs:938`). Failed/interrupted turns remain errors. Return the existing fields from `H/Sources/Headroom/Subagents/AgentRun.swift:320-338`; plugin foreground/background formatting already consumes them (`register.tsx:220-269`). Count each distinct executable tool item once, not deltas, reasoning or plan snapshots. Persist this count; fix the UI's 300-item count truncation and fallback that counts steps as tools. Report effective model from start/resume, updating on model/rerouted (`P/model.rs:188`). Derive run token usage from cumulative-total differences, not repeated snapshots or just `last`; cached/reasoning tokens are subsets (`P/thread.rs:1849-1923`).

For limits, read `account/rateLimits/read`, merge sparse `account/rateLimits/updated` by limit ID (`P/account.rs:596-620`). Inspect terminal `codexErrorInfo`: distinguish usageLimitExceeded, rateLimitExceeded, sessionBudgetExceeded, unauthorized and model rejection (`P/shared.rs:77`; `P/thread_data.rs:425`). Respect `error.willRetry` (`P/notification.rs:62`). A transient rate limit is not proof the account quota is exhausted; retain reset/quota scope. Do not restart side-effecting work on another account.

## 4. Permission translation

These are Headroom policies, not exact cross-provider equivalents (`P/shared.rs:176,239,305`):

| Claude mode | Codex recommendation |
|---|---|
| default | read-only + untrusted + user reviewer; deny unanswered requests |
| acceptEdits | workspace-write + on-request + user reviewer; deny escalations |
| plan | read-only + never; planning instructions and read-only MCP allowlist |
| auto | workspace-write + on-request + auto_review |
| bypassPermissions | danger-full-access + never, subject to managed requirements |

Workspace-write also permits sandboxed shell execution; acceptEdits parity requires additional tool/rule restrictions. Sandbox limits do not confine remote MCP mutations. Keep network access explicit. If auto_review is unsupported, fail configuration or use an explicitly documented stricter policy; never silently substitute bypass. Claude's current default→auto mapping (`H/Sources/Headroom/Subagents/AgentRun.swift:236`) does not establish permission equivalence.

Answer approval requests with typed decline/cancel responses (`P/item.rs:66,115`), cancel MCP elicitations, grant no requested permissions, and surface a blocked reason. Never leave unanswered RPCs hanging. Unanswerable agent questions should terminate as blocked, not fabricate user input.

## 5. MCP and instructions

Yes, **translate per thread**, without editing global Codex configuration. Read `~/.claude.json`; reuse Headroom's user/project merge and exclusion of headroom (`H/Sources/Headroom/Subagents/SubagentRunner.swift:101-108`); resolve project scope using original cwd before worktree creation. Send thread start/resume `config` overrides such as `"mcp_servers.docs.command":"..."` (`C/app-server/src/mcp_refresh.rs:194-205`). Translate stdio command/args/env/cwd; HTTP url and headers→http_headers (`C/config/src/mcp_types.rs:564`). Expand Claude variables deliberately. Legacy SSE, Claude-specific transports, OAuth sessions and approval lists are not automatically portable; report unsupported entries and retain per-run translated settings for resume. Store secrets privately, outside transcript logs.

Put resolved agent-role/system-prompt content in `developerInstructions`; retain Codex's base harness unless deliberately replacing it with `baseInstructions` (`P/thread.rs:100-106,410-414`). A Claude agent-type name alone imports nothing. AGENTS discovery works natively. CLAUDE.md is not loaded by default; fallback configuration selects only one instruction file per directory (`C/core/src/agents_md.rs:242-281`). For both, explicitly assemble applicable Claude guidance with provenance while leaving native AGENTS loading intact; keep repository guidance at user priority rather than promoting it to developer instructions; preserve the instruction snapshot for continuation. Claude imports/rules require explicit resolution.

## 6. Terminal, isolation and survival

Open in the saved worktree with the same executable/account CODEX_HOME:

```sh
cd '/saved/cwd' && CODEX_HOME='/saved/codex-home' codex resume THREAD_ID
```

Explicit UUID selects the thread (`C/cli/src/main.rs:350`). Reapply required MCP/config snapshots. Coordinate ownership and stop/unload the runner's thread before interactive continuation; this command resumes history, not the existing live stdio connection.

Headroom should create the Git worktree before `thread/start`, pass its cwd, persist ownership, and retain dirty worktrees. Use `git worktree add --detach PATH HEAD`; define how parent uncommitted changes enter the task. Worktrees isolate repository files, not MCP/external effects. App-server ThreadStartParams has no worktree switch. CLI has worktree support, but resume cannot create one (`C/cli/src/main.rs:2538-2577`).

Keep stdio open: disconnect shuts down single-client app-server (`C/app-server/src/lib.rs:1155,1313`). Existing SCM_RIGHTS transfer can hand an exclusive process to the runner (`H/Sources/Headroom/Subagents/WarmPool.swift:86-98,289-299`). Transfer only before protocol reads, or transfer initialized state, sequence and buffered bytes too. Prefer warming the independent runner plus app-server together; do not share its pipes between agents. Initialize early, create threads at dispatch; this warms process/protocol, not necessarily MCP/model context.

Headroom quitting can then leave the runner alive. Claude-session exit remains a separate limitation (`H/README.md:97`); durable workers, spooled events and reconnectable control sockets are required to survive it. Verify installed-CLI compatibility, auto-review availability, MCP auth and terminal ownership before claiming parity.

**Next action:** build one disposable lifecycle tracer covering stream→continue→interrupt→quit Headroom→resume in Terminal before implementing the picker.
