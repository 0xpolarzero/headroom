# C — Z.ai and OpenRouter through Claude Code

Verified 2026-10-27. Research only; no repository edits, credential reads, key creation, or paid inference. Installed Claude Code: **2.1.310** (`claude --version`; `--help`). Repository paths below are relative to `/Users/polarzero/code/projects/headroom`.

## Verdict

**Reuse `SubagentRunner` and Claude Code’s transcript pipeline, but reject “full compatibility for free.”** Both expose Anthropic Messages endpoints. Local tools and transcript production remain Claude Code’s responsibility; successful tool selection, server tools, thinking, and resume compatibility require provider tests. Anthropic explicitly [does not support non-Claude models behind gateways](https://code.claude.com/docs/en/llm-gateway); OpenRouter [guarantees Claude Code compatibility only with Anthropic first-party](https://openrouter.ai/docs/guides/coding-agents/claude-code-integration). This saves a harness implementation, not inference charges or validation.

## Z.ai

[Official setup](https://docs.z.ai/devpack/tool/claude) specifies:

```text
ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic
ANTHROPIC_AUTH_TOKEN=<Coding Plan API key>
ANTHROPIC_API_KEY=
ANTHROPIC_MODEL=glm-5.3[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.3[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3[1m]
ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.3-flash[1m]
CLAUDE_CODE_SUBAGENT_MODEL=glm-5.3[1m]
CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
API_TIMEOUT_MS=3000000
```

The main/subagent pins and empty API-key variable are recommended explicit overrides. Auth token means the **API key**, sent as Bearer, not Headroom’s website JWT. Do not substitute `/api/paas/v4` or `/api/coding/paas/v4`, which use another protocol. Current plan models are `glm-5.3` and `glm-5.3-flash`; the [switching guide](https://docs.z.ai/devpack/latest-model) documents `[1m]`, upgrading Claude Code if suffixed IDs fail, and these effective effort levels:

| Requested effort | GLM level |
|---|---|
| minimal/light/low | low |
| medium/high | high |
| xhigh/max/ultra | max |

Claude Code sends `output_config.effort`; explicit effort overrides the thinking toggle. Default is max; disabling thinking becomes low. [Thinking remains mandatory](https://docs.z.ai/guides/capabilities/thinking-mode), with interleaved and preserved thinking. Expose low/high/max, not a fake “off.”

**Key type matters.** The [October 16 key-management change](https://docs.z.ai/devpack/notice/api-key-management.md) separates Standard, Personal Coding Plan, and Team keys. New Standard keys bill balance regardless of endpoint; existing Compatible keys retain endpoint/account-dependent billing. A discovered `ZAI_API_KEY` is not proof it consumes plan quota.

**Web-session bootstrap:** Headroom saves a quota-tested website Authorization value, not an inference key (`Providers/ZAIProvider.swift:81–97`, `Views/ZAISignInWindow.swift:43–76`). Its API-key resolver separately checks Keychain, `~/.config/zai/key.json`, then `ZAI_API_KEY`/`GLM_API_KEY` (`ZAIProvider.swift:100–119`).

The public console’s [key-management bundle](https://static.bigmodel.cn/z-ai-website/_next/static/chunks/23763226chqec.js) contains:

- GET/POST `/biz/v1/organization/{org}/projects/{project}/api_keys` for listing/creation; POST fields: `name`, `keyType`, `usageScene`.
- Personal Coding Plan uses `keyType=1`, `usageScene=1`; GET `/api_keys/copy/{keyId}` exists. Returned credentials combine `apiKey.secretKey`.

Its [HTTP client](https://static.bigmodel.cn/z-ai-website/_next/static/chunks/0u6lq2er1j7j0.js) prefixes `https://api.z.ai/api`, sends the website token as Bearer, and adds organization/project headers. **Inference:** session-based creation is technically plausible through these private APIs. Headroom’s stored token’s permissions, identity discovery, cookie/2FA requirements, and existing-secret recovery remain untested. UI text says keys appear fully only once, despite the copy route. Ship manual Coding Plan key capture first; do not treat JWT quota access as proven key-management authorization.

**Quota/errors:** Existing GET `https://api.z.ai/api/monitor/usage/quota/limit` supports Headroom’s session/API-key paths; it parses `CREDIT_LIMIT`/`TOKENS_LIMIT`, `percentage`, `nextResetTime`, and window units (`ZAIProvider.swift:7–67`). This is existing private integration, not a documented stable quota contract. [Official errors](https://docs.z.ai/api-reference/api-code) distinguish:

| Code, generally HTTP 429 | Meaning |
|---|---|
| 1308; 1310 | Window exhausted; reset appears in message |
| 1316–1321 | Five-hour/seven-day exhaustion plus extra-usage restrictions |
| 1302; 1305 | Request throttling; overload |
| 1309; 1314 | Personal/enterprise plan expired |
| 1311 | Model entitlement missing |
| 1113 | Balance/resource package issue; also wrong setup per FAQ |
| 1313; 1315 | Fair-use restriction; wrong key scenario |

Preserve business code/message; do not mark every 429 “quota full.” Auth failures are 401; unknown model is 400/1211. Claude Code’s stream may flatten provider errors, requiring captured failure fixtures.

**Compatibility:** GLM-5.3 is text-only; Flash is multimodal. Z.ai documents separate [search MCP](https://docs.z.ai/devpack/mcp/search-mcp-server) and [vision MCP](https://docs.z.ai/devpack/mcp/vision-mcp-server); endpoint compatibility does not establish native WebSearch parity. New Claude Code beta fields/tool search need testing. [Usage policy](https://docs.z.ai/devpack/usage-policy) permits concurrent subagents inside supported tools, with dynamic tier limits and subscriber-only access.

## OpenRouter

[Official Claude Code configuration](https://openrouter.ai/docs/guides/coding-agents/claude-code-integration): base `https://openrouter.ai/api`, `ANTHROPIC_AUTH_TOKEN=<regular inference key>`, explicitly empty `ANTHROPIC_API_KEY`. Claude appends `/v1/messages`; avoid a doubled `/v1`. Optional attribution headers go through `ANTHROPIC_CUSTOM_HEADERS`; no extra auth header is necessary. Pin main and all model roles to explicit OpenRouter IDs; gateway discovery is optional and curated.

**Non-Anthropic candidates, not validated winners:** the live [model catalog](https://openrouter.ai/api/v1/models) advertises tools plus reasoning for `z-ai/glm-5.3`, `moonshotai/kimi-k3`, `minimax/minimax-m3.1-flash`, and `deepseek/deepseek-v4.1-flash-1017`. `qwen/qwen3-coder-next` advertises tools without reasoning. No researched evidence proves these reliably complete Headroom workflows through Claude Code.

Picker: GET `/api/v1/models`; require `supported_parameters` containing `tools`, inspect `tool_choice`, modalities, context, pricing, and [reasoning metadata](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens): `supported_efforts`, `default_effort`, `mandatory`, `supports_max_tokens`. Capabilities are eligibility, not quality. Messages `output_config.effort` maps to `reasoning.effort`; enabled thinking budgets map to `reasoning.max_tokens`; adaptive enables reasoning. Explicit effort wins over adaptive; disabled thinking disables reasoning.

[Provider routing](https://openrouter.ai/docs/guides/routing/provider-selection) supports `order`, `only`, `allow_fallbacks`, `require_parameters`. Claude has no generic provider-object flag or routing-header substitute: use account routing or a [preset model ID](https://openrouter.ai/docs/guides/features/presets), `@preset/<slug>`, and test it. Require supported parameters; prefer Anthropic 1P for supported Claude use.

[Management keys](https://openrouter.ai/docs/guides/overview/auth/management-api-keys) cannot infer; they can POST `/api/v1/keys` to provision a limited regular key. Current Headroom conflates both and requests management-only `/credits` before regular-key `/key` fallback (`OpenRouterProvider.swift:19–29`): fix that upstream. Use regular-key `/key` usage/`limit_remaining`; management `/credits` supplies account balance.

[Exhaustion](https://openrouter.ai/docs/api_reference/errors-and-debugging): HTTP 402, Anthropic `billing_error`/canonical `payment_required`; budget limits can produce 403. In-flight budget 402 can include `Retry-After`; ordinary insufficient credit needs funding. Keep throttling 429 separate. Current runner misses 402 (`SubagentRunner.swift:290–312`).

## Isolation and reuse

Use absolute `CLAUDE_CONFIG_DIR` paths, expanding `~/.claude-accounts/zai` and `~/.claude-accounts/openrouter`, preferably credential-profile-specific. Own settings and sessions; no Anthropic login. Keep an owned `settings.json` with sanitized preferences and, if fresh headless startup requires onboarding state, initialize `.claude.json` inside that profile, never the main profile. **Do not reuse settings symlinks** from `ClaudeSignIn.swift:8–22`. Share selected skills/agents; merge permitted preferences and explicit MCP configuration. Resolve secrets per launch into env or a provider-specific `apiKeyHelper`, including Terminal resume (`AgentRun.swift:288–292` currently exports only config dir).

`SubagentRunner.environment:82–89` strips base URL but leaves inherited Anthropic credentials/model overrides. Scrub all provider credentials/routing/model/effort variables, then inject the selected profile. [Settings env can override shell env](https://code.claude.com/docs/en/env-vars); use session `--settings` overrides above project/user settings, respecting managed policy.

[Custom IDs](https://code.claude.com/docs/en/model-config) work with `--model`; `ANTHROPIC_CUSTOM_MODEL_OPTION` bypasses ID validation, but managed allowlists still apply. `ANTHROPIC_SMALL_FAST_MODEL` is deprecated; use Haiku mapping. Set real context limits.

`WarmPool.swift:19–28` ignores environment/model; `:70–75` sends `set_model`, and runner waits for success (`:244–262`). A live process cannot adopt another endpoint/key. Partition by provider, credential generation, config/settings, context and effort; initially include model too. Test custom-ID switching before relaxing. Preserve provider/model/profile in registry/resume; avoid cross-provider history switching.

## Future providers and next action

The same path is officially documented for [Moonshot/Kimi](https://platform.kimi.ai/docs/guide/claude-code-kimi) (`https://api.moonshot.ai/anthropic`), [DeepSeek](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/) (`https://api.deepseek.com/anthropic`), and [MiniMax](https://platform.minimax.io/docs/m-plan/claude-code) (`https://api.minimax.io/anthropic`), all using API keys as auth tokens.

**Next action:** build one isolated GLM tracer: Read/Bash/Edit, warm claim, continue, stop, transcript/Terminal resume, and exhausted-quota handling; require the same proof before enabling each OpenRouter model/provider pair.
