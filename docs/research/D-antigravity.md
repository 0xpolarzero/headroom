# D — Antigravity backend

**2026-10-27. Recommendation: defer Headroom’s consumer-subscription backend; skip OAuth-token reuse.** Antigravity’s official runtime meets most technical requirements, but current Google policy explicitly excludes wrapping it inside third-party coding agents. Gemini CLI no longer provides the consumer-subscription alternative. API-funded execution is a separate, documented option.

**1. Installed runtimes and usable quota**

Read-only local checks: `command -v`, `--version`, `--help`, application Info.plist, and `agy models`. No model inference, credential extraction, installation, or repository edits.

| Runtime | Local evidence | Subscription position today |
| --- | --- | --- |
| Gemini CLI | `/Users/polarzero/.nvm/versions/node/v24.11.1/bin/gemini`, **0.26.0** | Consumer Google One/free access ended June 18, 2026. |
| Antigravity CLI | `/Users/polarzero/.local/bin/agy`, **1.4.7** | Official consumer runtime; direct scripts/CI supported, Headroom wrapping excluded by current FAQ. |
| Antigravity app | `/Applications/Antigravity.app`, **2.0.6** | Installed; `antigravity` is absent from PATH. Use `agy` for headless work. |

Google’s [May 19 transition announcement](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/) supersedes Gemini CLI’s older Pro/Ultra quota page. Signing Gemini CLI into the same Google account was sanctioned, but **does not restore consumer access today**. Code Assist Standard/Enterprise and paid API access remain supported.

Installed Gemini CLI supports `-p`, `--output-format stream-json`, `--model`, approval modes `default|auto_edit|yolo|plan`, `--resume`, `--list-sessions`, MCP management and server allowlisting. It remains technically viable for enterprise/API users. [Headless reference](https://geminicli.com/docs/cli/headless/), [session management](https://geminicli.com/docs/cli/tutorials/session-management/).

The shared backend is not a public subscription inference API: Google’s [Gemini CLI source](https://github.com/google-gemini/gemini-cli/blob/v0.26.0/packages/core/src/code_assist/server.ts#L62) uses `cloudcode-pa.googleapis.com/v1internal`, including `streamGenerateContent`, `loadCodeAssist`, and `retrieveUserQuota`. Headroom calls production/daily quota endpoints in [AntigravityProvider.swift:7](/Users/polarzero/code/projects/headroom/Sources/Headroom/Providers/AntigravityProvider.swift:7). A common host proves neither interchangeable credentials nor identical quota pools.

Additional official runtimes: [Antigravity SDK](https://www.antigravity.google/docs/sdk/overview/) documents Gemini API keys and enterprise ADC, not consumer subscription credentials. Google publishes an [ACP server](https://github.com/agentclientprotocol/registry/blob/main/antigravity-acp/agent.json); [Google’s Zed instructions](https://www.antigravity.google/docs/ide/extensions/zed/) explicitly support personal-account OAuth. That editor integration does not establish permission for Claude-driven orchestration. An [open first-hand report](https://github.com/google-antigravity/antigravity-cli/issues/1168) also shows ACP rejecting Claude/GPT models available through `agy`; do not promise pool parity.

**2. Terms and demonstrated enforcement**

[Antigravity Additional Terms §6](https://www.antigravity.google/terms) prohibit third-party access, explicitly including Antigravity OAuth reuse, and permit suspension/termination of Antigravity and/or Gemini CLI accounts. The [current FAQ](https://www.antigravity.google/docs/faq) separately addresses `agy -p`: direct scripts/CI are intended uses; wrapping `agy` inside third-party coding agents/applications and automated account rotation are unsupported on consumer plans. An unmodified binary is therefore insufficient evidence of permission.

There is contradictory evidence: a [September 30 moderator reply](https://discuss.ai.google.dev/t/is-invoking-the-official-agy-cli-from-a-local-ai-coding-assistant-allowed-on-an-individual-google-ai-account/185992) permits single-user local `agy` child processes without token access and says quota is shared. Forum JSON marks the author `staff:true, moderator:true`. The questioner then asks for reconciliation with the FAQ; no answer appears. Treat this as unresolved policy conflict, not clearance.

Enforcement is real: Google’s [February 27 announcement](https://github.com/google-gemini/gemini-cli/discussions/20632) confirms third-party/proxy quota-access bans, collateral Gemini CLI/Code Assist blocking, and a reset/unban process. This establishes service-account risk, not evidence of Gmail or whole-Google-account deletion. [Gemini CLI’s own terms notice](https://geminicli.com/docs/resources/tos-privacy/) likewise prohibits direct third-party access using its OAuth.

**Existing exposure:** [GoogleOAuth.swift:6](/Users/polarzero/code/projects/headroom/Sources/Headroom/Support/GoogleOAuth.swift:6) uses Antigravity’s OAuth client; [AntigravityProvider.swift:10](/Users/polarzero/code/projects/headroom/Sources/Headroom/Providers/AntigravityProvider.swift:10) impersonates its User-Agent for private quota calls. Read-only quota monitoring has no exemption in the sources reviewed. Audit this existing integration separately; its success does not authorize inference.

**3. Models and picker**

`agy models` returned these exact slug families locally:

| Model | Available suffix/effort |
| --- | --- |
| `gemini-4-argon-{low,medium,high}` | Low, Medium, High |
| `gemini-3.8-flash-{low,medium,high}` | Low, Medium, High |
| `claude-opus-5-5-{low,medium,high}` | Low, Medium, High |
| `claude-sonnet-5-5-{low,medium,high}` | Low, Medium, High |
| `gpt-oss-120b-medium` | Medium only |

The [current catalog](https://www.antigravity.google/docs/models) lists Gemini 3.1 Pro and 3.6/3.7 Flash for enterprise, while consumer models have moved beyond the older Gemini 3 Pro/Flash previews. Claude 4.6 variants and GPT-OSS are scheduled for removal **November 2, 2026**. Availability is plan-dependent; a quota bucket is not an entitlement list.

Keep Gemini, Argon, and third-party availability separate. Headroom’s [bucket labels:90](/Users/polarzero/code/projects/headroom/Sources/Headroom/Providers/AntigravityProvider.swift:90) call `3p-*` “Claude”; Google’s catalog labels that pool “Claude and GPT models.”

Design: refresh through `agy models`, preserve exact slugs, and expose only returned variants. [Effort documentation](https://www.antigravity.google/docs/cli/commands/effort/) supports `low|medium|high|xhigh|max` only when offered by that model; `agy -p /effort --output-format json` inspects capabilities. No local `xhigh/max` appeared. Gemini CLI has no installed `--effort` flag; its [model configuration](https://geminicli.com/docs/cli/generation-settings/) uses model-specific thinking settings. Do not copy Antigravity slugs/effort into Gemini CLI.

**4. Concrete adapter design, conditional on permission**

Best technical consumer runtime: `agy`. Start with `agy -p "$prompt" --output-format stream-json --model "$slug" --print-timeout 10m`. Local help and the [CLI reference](https://www.antigravity.google/docs/cli/reference/) support these flags, `--conversation`, MCP, and execution modes. Headless permissions require pregranted rules; soft denials can occur without process failure. Never equate `--mode auto` with Claude permissions or automatically add `--dangerously-skip-permissions`.

The [headless protocol](https://www.antigravity.google/docs/cli/headless/) uses NDJSON with **`event`**, not Gemini/Claude’s `type`:

| Event/payload | Proposed Headroom mapping |
| --- | --- |
| `init`, `conversation_id`, `init.cwd` | Validate configuration, persist runtime session, emit `started`. |
| `step_update`, `step_type:agent_response`, `text_delta` | Coalesce deltas by `step_index`; emit `kind:text`. |
| Tool step, `tool_name`, `tool_info.parameters` | Emit `kind:tool`; synthesize ID from conversation/step. |
| `tool_info.output/error` | Emit matched `kind:result`, setting `isError`. Deduplicate ACTIVE/DONE updates. |
| `result.result` | Final `response`, `status`, `error`, duration, turns, usage; no duplicate answer item. |

`SUCCESS` alone means success; handle `ERROR`, `CANCELED`, `INTERRUPTED`, and incomplete states explicitly. Persistent stdin mode accepts `{"event":"user","message":{"content":"..."}}`, one turn/result at a time. It rejects Claude control messages. Therefore do not reuse Claude WarmPool switching. Start cold initially.

Convert `duration_seconds` to milliseconds. Persistent-session usage/turn counters are cumulative; compute per-turn deltas.

Keep Headroom’s transport/rendering: [transcriptItem:267](/Users/polarzero/code/projects/headroom/Sources/Headroom/Subagents/SubagentRunner.swift:267), [AgentRun result:331](/Users/polarzero/code/projects/headroom/Sources/Headroom/Subagents/AgentRun.swift:331), and [register.tsx:395](/Users/polarzero/code/projects/headroom/ClaudePlugin/headroom/hooks/register.tsx:395) already represent text/tool/result items. Add provider/runtime/session identity to [AgentRegistry.Entry:372](/Users/polarzero/code/projects/headroom/Sources/Headroom/Subagents/AgentRun.swift:372); replace Claude-specific launch checks and account resolution. Native `subagent_type` roles need explicit runtime instructions, not a forwarded Claude flag.

SendMessage: resume the stored ID with `agy -p "$message" --conversation "$id"`; never `--continue` under concurrency. Terminal: shell-quote arguments and run `cd "$cwd" && exec agy --conversation "$id"`. Interrupt: SIGINT first, then timed TERM/KILL escalation; verify remote cancellation and child cleanup before promising TaskStop parity. Existing [termination:231](/Users/polarzero/code/projects/headroom/Sources/Headroom/Subagents/SubagentRunner.swift:231) starts with SIGTERM.

Gemini’s alternative stream uses `init.session_id`, assistant `message.content`, `tool_use(tool_id,tool_name,parameters)`, `tool_result(tool_id,status,output)`, and final `result.stats`; mapping is straightforward, but its stream schema differs. [Official protocol types](https://github.com/google-gemini/gemini-cli/blob/v0.26.0/packages/core/src/output/types.ts).

**5. Quota detection and release gate**

No stable typed quota-error contract was found for `agy`; inspect terminal error plus stderr. Proposed classification recognizes `RESOURCE_EXHAUSTED`, HTTP 429, and explicit exhausted-quota/reset messages, separating quota exhaustion from transient throttling, model entitlement, authentication, and cancellation. A [first-hand 429 report with moderator response](https://discuss.ai.google.dev/t/persistent-http-429-resource-exhausted-on-a-basic-prompt-despite-100-remaining-quota/190482) shows 429 despite full quota. Do not mark every pool full or replay after side effects. [AI-credit fallback](https://www.antigravity.google/docs/cli/credits/) is independently configurable and can spend credits.

Missing evidence: written authorization for Headroom/Claude orchestration, exact terminal quota-error fixtures, interrupted-session durability, and verified cancellation/resume behavior. **Next action: obtain Google’s written reconciliation of the FAQ with the moderator’s permission before implementing consumer-quota execution.**
