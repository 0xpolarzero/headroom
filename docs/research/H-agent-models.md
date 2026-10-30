# H: extra models through the Agent tool — byte checks and live results

Claude Code 2.1.311, 2026-10-30. Design: [docs/agents.md](../agents.md). Real lastdrop plugin and build, no bypass flags. Sample sizes are small; none of this is a general claim.

## Request capture

Request capture (2026-10-30, Claude Code 2.1.311, local mock API): tools and system were unchanged by the Save Claude usage switch, and each request's cached prefix stayed byte-identical in the next through on, off and text edits. The instruction stayed in the request after switching off and left only with compaction.

## Byte checks (local mock API, no real model)

| # | Check | Result |
| --- | --- | --- |
| 1 | `tools` and `system` with and without the plugin | Byte-identical; only session metadata differs. |
| 2 | What else differs | Only text appended to the `agent_listing_delta` attachment (`messages[1]`, block 0): the two-line header and one `- name: description (provider · model · effort)` line per model. |
| 3 | Three requests in one session | `tools`/`system` equal; each request's messages are a strict extension of the previous one; the listing is identical in all three (cache marks stay put). |
| 4 | List changed after the first prompt | The listing is unchanged. A note appears only in the new turn's block, once; later requests repeat it as history, not again as a new note. |
| 5 | `--resume` after a list change | The stored listing text is byte-identical to the original session's (old list). The new list arrives as a note in the new turn. |
| 6 | `/compact` after a change | The listing is the current list; no "changed" note. |
| 7 | Empty catalog | The whole body equals the no-plugin body except metadata. |
| 8 | Wire scan | None of 33 request bodies contains "lastdrop". |
| 9 | Unknown model, or `statusline-setup` + an added model | Denied before schema validation with the available names, or "runs only as general-purpose, Explore or Plan". No agent started. Without the plugin the same call is an enum `InputValidationError`. |
| 10 | Precomputed compaction | Not observable (server-gated). A manual `/compact` fires `session.compact` and a fresh `compact_boundary` row through `session.append`; from the binary, installing a precomputed result builds a fresh boundary with no `session.compact`. The plugin resets on the boundary row for that reason. |

## Live results (real providers)

- The Sonnet main session listed the added models as accepted by the Agent tool's `model` parameter and said the schema enum still shows four values.
- Sonnet, n=10 per prompt: reviews ended on `sol` 2/10, opinions on `argon` 7/10, searches on an added model 0/10 (Explore with Claude models every time). Opus, n=2 per prompt: used `sol` and `argon` through `model` 2/2 each, without errors.
- Sonnet first tried the model name as `subagent_type` in 19 of 20 review and opinion runs ("Agent type not found"), then often recovered with `model`, sometimes falling back to Claude.
- Added models ran on their own provider each time: the report header names the model that ran; no final message named a different one. Native runs get no header.
- Read-only role (Explore + `sol`) asked to edit: no file changed. Worktree (`sol`): the edit landed in the worktree, main checkout untouched. `SendMessage` continued the same agent id and session. `TaskStop` stopped a running agent. `effort: "low"` reached Codex.
- After a list change in a two-turn session, the next request read about 40k tokens from cache and created 351–363 new ones, against 81–98 with no plugin: the prefix was kept and only the note was new. The new model was used in 4 of 5 runs.
- Native `opus` and `fable` calls were left to Claude Code (no header, subagent transcript on the model asked for).

The results above used the earlier "these agents the user added" wording. After changing it to "these models the user added" and accepting `subagent_type: "<added>"`:

| Main model, n per prompt | Review | Opinion | Search | First-try `model` |
| --- | --- | --- | --- | --- |
| Sonnet, 10 | `sol` 10/10 | `argon` 10/10 | Added 0/10 | 20/20 |
| Opus, 5 | `sol` 5/5 | `argon` 5/5 | Added 0/5 | 10/10 |

Every routed report had a body and a `Ran on` header. The Sonnet batch ran on the build before the last fixes, and the Opus batch and the flows on the final build.

Flows on the final build, Sonnet main session: Plan + `argon` returned a plan; Explore + `argon` stayed read-only but gave a weak report, having no shell; worktree + `sol` landed in `.claude/worktrees/agent-<id>` on `worktree-agent-<id>`, and an unchanged one was removed; `SendMessage`, `TaskStop`, `subagent_type: "sol"`, and the `sol` + `opus` and unknown-model denials behaved as designed. After a list change, the first request read 40.0k–40.3k tokens from cache and created 346–353 new ones, against 83 with no plugin, and all 3 runs used the newly listed model. Not exercised: `gemini`, `flash`, `terra-cu`, and the desktop app.

## Found and handled

- An account lacking a model while another has it was not exercised live (the other account was at its limit); it is covered offline with a stand-in `claude`.
- `argon` (Antigravity) runs that used a shell command returned an empty report: `agy` denies the command headless, ends its turn as a success with no response, and lastdrop now continues the conversation once and reports the denial. 6 of 6 runs with a tempting prompt then returned a report (3 in plan mode, 3 in default mode).
- In auto mode, reports from routed agents can carry Claude Code's notice that its safety classifier was unavailable. Likely cause, not confirmed: the handoff classifier can't review a synthetic transcript. lastdrop leaves this as it is rather than bypass a safety check.
