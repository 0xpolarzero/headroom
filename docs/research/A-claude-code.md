# A — Exposing Headroom agents to Claude Code

**Recommendation: use `$.agent.register` and `agent.offer`, then enforce provider ownership in both interception stages.** The installed engine supports runtime registration; generated Markdown is a compatibility fallback.

Research date: 2026-10-27. No repository files changed or model requests made. Installed executable: `/Users/polarzero/.local/bin/claude` → `~/.local/share/claude/versions/2.1.310`, a native ARM64 binary containing readable bundled JavaScript. [Extracted evidence](A-claude-code-evidence.txt) records its hash, symbols and byte offsets. `E1`–`E19` below refer to that file. Runtime behavior was traced statically, not exercised in a conversation.

## 1. Discovery and presentation

Precedence, highest first: managed agents, `--agents` JSON, project `.claude/agents/`, user `$CLAUDE_CONFIG_DIR/agents/` (normally `~/.claude/agents/`), plugin agents, built-ins. The installed `e3` merge confirms this order (E1). Project scopes walk toward the repository root; additional directories also contribute agents. File agents identify themselves through frontmatter `name`; plugin identifiers derive from plugin/file paths, including nested folders. Plugin manifests can specify custom agent paths (E4). [Official scope reference](https://code.claude.com/docs/en/sub-agents#choose-the-subagent-scope).

`--agents` supplies session definitions keyed by name, with `prompt` replacing the Markdown body. SDK `query({options:{agents}})` supplies the same concept programmatically; it does not mutate an unrelated interactive session. Settings `agent` and CLI `--agent` select the main session persona; settings are not another arbitrary agent-definition registry. [SDK reference](https://code.claude.com/docs/en/agent-sdk/subagents#programmatic-definition-recommended).

Documented frontmatter:

| Fields | Meaning |
|---|---|
| `name`, `description` | Required identity and delegation criteria |
| `model`, `effort` | Model selection and reasoning level |
| `tools`, `disallowedTools`, `permissionMode` | Tool and permission controls |
| `maxTurns`, `autoCompactWindow` | Execution/context limits |
| `skills`, `mcpServers`, `hooks`, `memory` | Context and integrations |
| `background`, `isolation`, `omitClaudeMd` | Execution behavior |
| `color`, `initialPrompt`, `experimental.cacheTtl` | Presentation, main-session initialization, cache policy |

The installed parser accepts model strings, named effort levels or integers, and additional internal observer fields (E2–E3). Unknown keys do not become Headroom metadata. Plugin-file loading ignores `hooks`, `mcpServers`, `permissionMode`, and `initialPrompt`; names follow plugin paths. [Field reference](https://code.claude.com/docs/en/sub-agents#supported-frontmatter-fields).

**The current listing is not embedded wholesale in the Agent description.** `NMr` formats each entry as type, delegation description and tools; the description points to conversation reminders (E8). `CEe` emits `agent_listing_delta`; its renderer produces initial/new/removed agent-type reminders (E9–E10). Agent bodies stay out of the parent's listing.

## 2. Reload behavior

| Source | Installed behavior |
|---|---|
| Existing user/project agents directories | Polling watcher handles Markdown add/change/unlink, invalidates agent caches and refreshes session state |
| Newly created directory | Not initially watched; restart required |
| Additional-directory agents | Loaded, but not included in agent watcher roots |
| Plugin files | Cached; use `/reload-plugins` or restart |
| CLI/SDK definitions | Launch/query configuration, not a live global feed |
| `$.agent.register` | Adds/replaces scoped definition and awaits session refresh; available from next turn |

Evidence: watcher roots/stat checks and callbacks (E13–E15), session reread (E16), registration/refresh (E5–E7). Active polling interval is 2 seconds; idle polling becomes 30 seconds, with stabilization/debounce delays. ConfigChange hooks can block reload. The [official watcher notes](https://code.claude.com/docs/en/sub-agents#write-subagent-files) also exclude `--disable-slash-commands`; [plugin documentation](https://code.claude.com/docs/en/plugins/components) requires explicit reload after component changes. This is eventual availability, not immediate mutation of an executing model request.

## 3. The mod API already provides the needed seam

`ClaudePlugin/headroom/types/index.d.ts:30` only augments `PluginState`; it is **not** the engine's complete API contract. `register.tsx:1–2` imports that API from `claude-code`.

The installed `JVr` implementation validates a definition, registers/replaces `<plugin>:<name>`, clears cached definitions, and awaits `refreshAgents()` (E5–E7). Therefore:

```ts
await $.agent.register({
  name: 'reviewer', description: 'Review changes for correctness.',
  prompt: 'Review the supplied task.', model: 'inherit'
}) // { agent: 'headroom:reviewer' }
```

`agent.offer` hides a disabled type from listings and rejects model dispatch; it does not constrain another plugin's direct spawn. No public per-type unregister was found. Types disappear when the plugin unloads. [Official declarations](https://github.com/anthropics/claude-code/blob/main/mods/types/claude-code.d.ts) document these operations around lines 2697–2741; installed code independently confirms registration.

The API also exposes `tool.describe`, `prompt.compose`, `prompt.section`, `prompt.context`, and `prompt.attachment`, with cache invalidation through `$.ui.invalidate(...)`. Thus both tool-description and instruction injection exist. [Mods reference](https://code.claude.com/docs/en/plugins/mods/reference).

**Caveat:** E9 compares already-announced type names, not description hashes. Re-registering an existing name refreshes its definition but does not itself announce its changed description. Use a current catalog supplement through `tool.describe` and invalidate `tool.describe` on catalog revisions; prove same-name edits reach the next request before claiming seamless updates.

Fallback: atomically generate owned files under `~/.claude/agents/headroom/`, creating the root before sessions start. Plugin-dir files require plugin reload and packaged app contents are a poor mutable store. `ClaudeSignIn.swift:8–22` links `agents` only when its source already exists; the inspected Pro directory currently lacks that link. Reconcile missing account links without replacing user-owned paths.

## 4. Model and effort do not select a provider

The actual Agent schema restricts `model` to `sonnet`, `opus`, `haiku`, `fable` (E11), and sometimes omits it entirely (E12). Non-enum tool arguments fail schema validation. Full model strings accepted by definitions or internal spawn APIs do not expand this enum or install another backend.

Today Headroom copies invocation effort and model, receives spawn model separately, then runs Claude with `--agent`, `--model`, `--effort` (`register.tsx:453–485`; `SubagentRunner.swift:58–65`). `AgentRun.swift:145–168` inherits the parent model and can substitute Sonnet. **None of this translates non-Claude model or effort semantics.** Spawn occurs before native model/effort resolution; definition effort is not carried in its event (E19). Resolve presets from Headroom itself, rather than expecting the event to supply them.

For mapped types, resolve the provider model exclusively from Headroom's definition. Reject conflicting invocation model overrides clearly. Preset effort wins; dynamic effort uses an explicit adapter mapping of invocation effort, otherwise a provider default. Reject unsupported levels rather than silently clamping. Account for conditional omission and relative `lower`/`higher` effort in this version (E12).

## 5. Required interception changes

Current `tool.call` excludes nested, remote and named calls, validates keys, records a claim, then invokes core. `agent.spawn` excludes resumes/forks/teammates/workflows/nested calls, starts Headroom, and passes through on `no_room` (`register.tsx:444–493`). Custom types are already eligible; Swift currently runs them on another Claude account.

For mapped types:

1. Resolve exact owned type **before exclusions**. Reject unknown types in the reserved `headroom:` namespace. Retain retired aliases so stale calls receive a specific disabled/deleted error.
2. Snapshot agent ID/revision/provider/model/effort in the claim. Unsupported named/nested/remote/workflow combinations must fail explicitly, never call core.
3. Keep core permission checks; intercept at spawn. Use spawn's effective prompt, description, directory and background decision. Recheck ownership there, including direct spawns without claims.
4. Replace mapped `no_room → next(e)` with structured provider-unavailable/auth/limit errors, including reset/retry information when known. Remove mapped Sonnet/account substitution. Only unrelated types retain opportunistic Claude-account fallback.
5. Make catches for owned calls return errors without delegation. Persist provider session ID and effective configuration for continue/stop/transcript/terminal operations. Resume must not re-resolve to a different provider after a catalog edit.

## 6. Global model and delivery

Store definitions separately from existing runtime `AgentRegistry` records:

```ts
type AgentDefinition = {
  id: string; name: string; description: string; enabled: boolean;
  provider: 'claude' | 'codex' | 'antigravity' | 'zai' | 'openrouter';
  model: string;
  effort: { mode: 'preset'; value: string } | { mode: 'dynamic' };
  revision: number;
}
```

Use stable unique slugs and optional provider-profile selection. Headroom atomically publishes a revisioned catalog in Application Support. Generate the registered role prompt from the description and pass the same role instructions to the provider adapter alongside the task prompt. On `session.start`, synchronize definitions; on prompt submission, await synchronization; optionally poll while idle. Register enabled entries, retain dispatch tombstones, and gate offers against current state. Availability belongs to runtime eligibility, separate from the user's enabled switch. No credentials enter definitions or Claude's catalog. `$.agent.list()` lists runs, not catalog definitions.

Remaining evidence gaps: minimum supported registration version; same-name description refresh under prompt caching; symlink watcher behavior; adapter-specific effort support. Capability-check the API and test these cases. Generated file stubs can execute natively if the mod is absent, so they cannot alone guarantee provider ownership; runtime registrations disappear with their plugin.

**Next action:** run one disposable session proving add, same-name description edit, disable, exhausted provider, and unsupported named call, with an instrumented assertion that no mapped request reaches native Claude execution.
