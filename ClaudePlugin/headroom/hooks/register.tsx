import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { RemoteAgent, TranscriptItem } from '../types'

// Headroom runs a subagent on another of your Claude accounts when one has room, and answers the
// built-in Agent tool with it exactly as a built-in agent answers. The engine checks the call and decides
// whether the agent runs in the foreground or the background, then raises `agent.spawn`, where Headroom
// takes the agent over. In the foreground the call waits for the report (ctrl+b sends it to the
// background); in the background it answers "launched" at once and the report comes as a notification.
// SendMessage continues it, TaskStop stops it, ListAgents lists it.
//
// Headroom's own agents (Settings → Agents) are agent types beside the built-in ones, `headroom:<name>`, each
// on a provider and model of its own (Codex, Z.ai, OpenRouter, Antigravity, your Claude accounts). A call to
// one always runs there: never as a built-in agent, and what keeps it from running is the call's error.
//
// Built-in on purpose, untouched: forks (they need this session's context and its cache), teammates and
// named agents, workflow agents, remote ones, agents started inside a subagent, and any call when no account
// has room. Anything else Headroom can't handle as expected (a field it doesn't know, a runner that fails,
// Claude Code not starting as it should) is the call's error, so it gets fixed rather than hidden.

/**
 * The Agent tool's arguments as of Claude Code 2.1.310, and the keys `tool.call` adds beside them.
 * `run_in_background` is left out of some sessions' schema; the engine still reads it, and `agent.spawn`'s
 * `background` carries what it decided.
 */
const AGENT_KEYS = new Set([
  'description', 'prompt', 'subagent_type', 'model', 'effort', 'name', 'team_name', 'mode', 'isolation', 'run_in_background',
  'tool', 'tool_use_id', 'consent', 'agentId', 'requestMeta',
])
const ISOLATIONS = new Set([undefined, 'worktree', 'remote'])

const PANE = 'headroom-agents'
const agents = atom({ plugin: 'headroom', key: 'agents' } as const, [] as RemoteAgent[])
const paneShown = atom({ plugin: 'headroom', key: 'paneShown' } as const, false)
/** Agents whose transcript is unfolded, in their row and in the pane. */
const open = atom({ plugin: 'headroom', key: 'open' } as const, [] as string[])

/** The session's permission mode, as the last classic hook event reported it. */
let permissionMode: string | undefined
/** A headless host can close its input at any time; it cannot wait for our background reports. */
let interactive = false

type Line = { type: string; [key: string]: unknown }

/** An agent of Headroom's list, as `Headroom --agent-catalog` gives it. */
type Defined = { name: string; description: string; provider: string; summary: string; prompt: string }

/** Headroom's enabled agents as last read, by type (`headroom:codex-deep`), and the list's revision. */
let catalog = new Map<string, Defined>()
let revision: number | undefined

const TYPE_PREFIX = 'headroom:'

function owns(type: unknown): type is string {
  return typeof type === 'string' && type.startsWith(TYPE_PREFIX)
}

/** Its line in Claude's list of agent types: what it is for, and where it runs. */
function listing(agent: Defined): string {
  return `${agent.description.trim()} (Runs on ${agent.summary}, with Headroom.)`
}

/**
 * Reads Headroom's list and registers its enabled agents as agent types, from the next turn on. A type that
 * left the list stays registered (a session can't drop one), so `agent.offer` hides it and a call is an error.
 */
async function syncCatalog($: EngineInterface): Promise<void> {
  let text = ''
  for await (const chunk of $.process.spawn({ argv: [await runner($), '--agent-catalog'] })) {
    if (chunk.stream === 'stdout') text += chunk.text
  }
  const parsed = JSON.parse(text.trim() || '{}') as { revision?: number; agents?: Defined[] }
  if (parsed.revision !== undefined && parsed.revision === revision) return
  const next = new Map((parsed.agents ?? []).map(agent => [`${TYPE_PREFIX}${agent.name}`, agent] as const))
  for (const [type, agent] of next) {
    const before = catalog.get(type)
    if (before && listing(before) === listing(agent) && before.prompt === agent.prompt) continue
    await $.agent.register({ name: agent.name, description: listing(agent), prompt: agent.prompt })
  }
  catalog = next
  revision = parsed.revision
  $.ui.invalidate('tool.describe')
}

/** Who ran it, as its notification and answers say it: "the Pro account", or a provider ("Codex"). */
function place(agent: { account: string; provider?: string }): string {
  return agent.provider && agent.provider !== 'claude' ? agent.account : `the ${agent.account} account`
}

/**
 * An Agent call Headroom may answer, by its tool_use_id: what its `tool.call` hook asks for, and once the
 * engine's `agent.spawn` for it found an account with room, the run there.
 */
type Claim = { request: Record<string, unknown>; started?: { run: Run; line: Line; background: boolean } }
const claims = new Map<string, Claim>()

/** Sends a foreground agent to the background (its row's button, ctrl+b), by agent id. */
const toBackground = new Map<string, () => void>()

/** Headroom's own binary: beside this plugin inside Headroom.app, else the usual install. */
async function runner($: EngineInterface): Promise<string> {
  const bundled = `${$.plugin.root}/../../../MacOS/Headroom`
  return (await $.fs.exists(bundled)) ? bundled : '/Applications/Headroom.app/Contents/MacOS/Headroom'
}

type Chunk = { stream: string; text: string }

/** A `Headroom --agent-run` process, read as JSON lines. Ending its stream ends the process. */
class Run {
  private buffer = ''
  constructor(private readonly stream: AsyncIterator<Chunk, unknown>) {}

  /** Its next line, or null once it ended. */
  async next(): Promise<Line | null> {
    for (;;) {
      const newline = this.buffer.indexOf('\n')
      if (newline >= 0) {
        const text = this.buffer.slice(0, newline)
        this.buffer = this.buffer.slice(newline + 1)
        try {
          return JSON.parse(text) as Line
        } catch {
          continue
        }
      }
      const chunk = await this.stream.next()
      if (chunk.done) return null
      if (chunk.value.stream === 'stdout') this.buffer += chunk.value.text
    }
  }

  stop(): void {
    void this.stream.return?.()
  }
}

type Begun = { run: Run; line: Line } | { noRoom: true } | { error: string }

/**
 * Starts `Headroom --agent-run` and reads it until the agent started: the run and its `started` line,
 * `noRoom` when no account has room, else the error that kept it from starting.
 */
async function start($: EngineInterface, request: Record<string, unknown>): Promise<Begun> {
  try {
    const stream = $.process.spawn({ argv: [await runner($), '--agent-run'], input: JSON.stringify({ ...request, interactive }) })
    const run = new Run(stream[Symbol.asyncIterator]())
    for (let line = await run.next(); line; line = await run.next()) {
      if (line.type === 'no_room') return { noRoom: true }
      if (line.type === 'started') return { run, line }
      if (line.type === 'error' || line.type === 'result') return { error: String(line.text ?? 'Headroom could not start the agent.') }
    }
    return { error: 'Headroom’s runner ended before the agent started.' }
  } catch (error) {
    return { error: `Headroom’s runner failed: ${String(error)}` }
  }
}

/** Stopped by TaskStop: their runs end without a report, which isn't a failure. */
const stopping = new Set<string>()

/**
 * Reads a background agent's run to its end; `first` is a line already asked for. A run that ends with
 * no result still reports, as a failure: a notification never comes otherwise.
 */
async function follow($: EngineInterface, run: Run, id: string, first?: Promise<Line | null>): Promise<void> {
  let failure = 'Headroom’s runner ended without the agent’s report.'
  try {
    for (let line = await (first ?? run.next()); line; line = await run.next()) {
      const agent = await record($, id, line)
      if (agent) {
        if (line.stopped !== true) await deliver($, agent, line)
        await afterResult($, agent)
        return
      }
    }
  } catch (error) {
    failure = `Headroom’s runner failed: ${String(error)}`
  }
  const end = { type: 'result', text: failure, isError: true, stopped: stopping.has(id) }
  try {
    const agent = await record($, id, end)
    if (agent && !end.stopped) await deliver($, agent, end)
  } catch (error) {
    $.ui.log(`headroom: agent ${id} ended unreported: ${failure} (${String(error)})`, { to: 'debug' })
  }
}

/**
 * A prompt was sent, so an Agent call may follow: Headroom starts Claude Code on the account it would
 * pick, so the agent finds it ready instead of waiting for it to start. Nothing happens when one is ready.
 */
async function warmUp($: EngineInterface): Promise<void> {
  const request = { prompt: '', cwd: await $.session.cwd(), permissionMode, parentModel: await $.session.model() }
  for await (const _ of $.process.spawn({ argv: [await runner($), '--agent-warm'], input: JSON.stringify(request) })) {
    // Nothing to read; it ends once the app has the request.
  }
}

async function started($: EngineInterface, line: Line, description: string, resumed: boolean,
                       foreground = false, toolUseId?: string): Promise<void> {
  const id = String(line.agentId)
  await update($, agents, list => {
    const known = list.find(a => a.id === id)
    if (known) return list.map(a => (a.id === id ? { ...a, status: 'running' as const, endedAt: undefined } : a))
    const agent: RemoteAgent = {
      id, description, account: String(line.account), model: String(line.model ?? ''),
      provider: line.provider === undefined ? undefined : String(line.provider),
      status: 'running', steps: [], items: [], startedAt: Date.now(), pending: [], foreground, toolUseId,
    }
    return [...list, agent].slice(-50)
  })
  if (!resumed && !(await read($, paneShown))) {
    await update($, paneShown, () => true)
    void $.ui.open({ id: PANE, title: 'Agents on other accounts' })
  }
  await showStatus($)
}

/** Records a line of an agent's run; for its result, returns the agent as it ended. */
async function record($: EngineInterface, id: string, line: Line): Promise<RemoteAgent | undefined> {
  if (line.type === 'step' || line.type === 'moved') {
    const text = line.type === 'moved' ? `Moved off ${line.account}: ${line.reason}` : String(line.text)
    await update($, agents, list => list.map(a => (a.id === id ? { ...a, steps: [...a.steps, text].slice(-40) } : a)))
    $.ui.invalidate('ui.render')
    return
  }
  if (line.type === 'item') {
    const { type: _, ...item } = line
    await update($, agents, list =>
      list.map(a => (a.id === id ? { ...a, items: [...a.items, item as unknown as TranscriptItem].slice(-300) } : a)))
    return
  }
  if (line.type !== 'result') return
  const failed = line.isError === true
  const stopped = line.stopped === true || stopping.has(id)
  stopping.delete(id)
  let agent: RemoteAgent | undefined
  await update($, agents, list =>
    list.map(a => {
      if (a.id !== id) return a
      agent = { ...a, status: stopped ? 'stopped' : failed ? 'failed' : 'done', endedAt: Date.now(),
                result: stopped ? 'Stopped' : String(line.text ?? ''),
                account: String(line.account ?? a.account), model: String(line.model ?? a.model), foreground: false }
      return agent
    }),
  )
  await showStatus($)
  return agent
}

/** Messages sent while it ran: continue it with them now, as a built-in agent reads its inbox. */
async function afterResult($: EngineInterface, agent: RemoteAgent): Promise<void> {
  const pending = (await read($, agents)).find(a => a.id === agent.id)?.pending ?? []
  const queued = agentPending.get(agent.id) ?? []
  agentPending.delete(agent.id)
  await update($, agents, list => list.map(a => (a.id === agent.id ? { ...a, pending: [] } : a)))
  const messages = [...pending, ...queued]
  if (messages.length === 0) return
  const sent = await continueAgent($, agent, messages.join('\n\n'))
  if ('error' in sent) {
    await $.prompt.submit({ text: `Headroom could not give agent ${agent.id} the messages sent while it ran: ${sent.error}` })
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/** SendMessage text held for an agent that is still running. */
const agentPending = new Map<string, string[]>()

/** The report, as a background agent's completion notification reads. */
async function deliver($: EngineInterface, agent: RemoteAgent, line: Line): Promise<void> {
  const failed = line.isError === true
  const seconds = Math.round(Number(line.durationMs ?? 0) / 1000)
  const text = [
    '<task-notification>',
    `<task-id>${agent.id}</task-id>`,
    `<status>${failed ? 'failed' : 'completed'}</status>`,
    `<summary>Agent "${agent.description}" ${failed ? 'failed' : 'finished'} (ran on ${place(agent)} with Headroom)</summary>`,
    `<result>${String(line.text ?? '')}</result>`,
    `<usage>tool uses: ${line.toolUses ?? 0}, duration: ${seconds}s, model: ${agent.model}</usage>`,
    '</task-notification>',
    `Continue this agent with SendMessage to "${agent.id}".`,
  ].join('\n')
  await $.prompt.submit({ text })
}

/** What the Agent call answers for an agent left running: a built-in background agent's "launched". */
function launched(e: { description: string; prompt: string }, line: Line) {
  return {
    result: {
      status: 'async_launched' as const,
      isAsync: true as const,
      agentId: String(line.agentId),
      description: e.description,
      prompt: e.prompt,
      outputFile: String(line.outputFile),
      resolvedModel: String(line.model ?? '') || undefined,
    },
  }
}

/** What the Agent call answers for a finished foreground agent: a built-in one's report, or its error. */
function completed(prompt: string, agent: RemoteAgent, line: Line) {
  if (line.isError === true) return { deny: String(line.text ?? 'The subagent failed.') }
  const input = Number(line.inputTokens ?? 0)
  const output = Number(line.outputTokens ?? 0)
  return {
    result: {
      status: 'completed' as const,
      agentId: agent.id,
      content: [{ type: 'text' as const, text: String(line.text ?? '') }],
      prompt,
      resolvedModel: agent.model || undefined,
      totalToolUseCount: Number(line.toolUses ?? 0),
      totalDurationMs: Number(line.durationMs ?? 0),
      totalTokens: input + output,
      usage: {
        input_tokens: input, output_tokens: output, cache_creation_input_tokens: null, cache_read_input_tokens: null,
        server_tool_use: null, service_tier: null, cache_creation: null,
      },
    },
  }
}

/**
 * A foreground agent: the Agent call waits for its report, as for a built-in one. Sent to the background
 * it answers "launched" and the report comes as a notification; interrupted, the run is stopped.
 */
async function foreground($: EngineInterface, e: { description: string; prompt: string }, signal: AbortSignal,
                          run: Run, line: Line) {
  const id = String(line.agentId)
  const backgrounded = new Promise<'background'>(resolve => toBackground.set(id, () => resolve('background')))
  const aborted = new Promise<'abort'>(resolve =>
    signal.aborted ? resolve('abort') : signal.addEventListener('abort', () => resolve('abort'), { once: true }))
  try {
    for (;;) {
      const next = run.next()
      const got = await Promise.race([next, backgrounded, aborted])
      if (got === 'background') {
        await update($, agents, list => list.map(a => (a.id === id ? { ...a, foreground: false } : a)))
        void follow($, run, id, next)
        return launched(e, line)
      }
      if (got === 'abort') {
        run.stop()
        await update($, agents, list => list.map(a =>
          a.id === id ? { ...a, status: 'failed' as const, endedAt: Date.now(), result: 'Interrupted', foreground: false } : a))
        await showStatus($)
        return { deny: 'Interrupted by the user.' }
      }
      if (!got) {
        const end = { type: 'result', text: 'The subagent stopped without an answer.', isError: true }
        const agent = await record($, id, end)
        return agent ? completed(e.prompt, agent, end) : { deny: String(end.text) }
      }
      const agent = await record($, id, got)
      if (agent) {
        void afterResult($, agent)
        return completed(e.prompt, agent, got)
      }
    }
  } finally {
    toBackground.delete(id)
  }
}

/** Continues an agent with a message on its account: its `started` line, or why it couldn't. */
async function continueAgent($: EngineInterface, agent: RemoteAgent, message: string): Promise<Line | { error: string }> {
  const begun = await start($, { prompt: message, resume: agent.id, cwd: await $.session.cwd(), permissionMode, background: true })
  if ('noRoom' in begun) return { error: 'Headroom found no account for it.' }
  // A follow-up's `started` names where it runs; an agent from an earlier session is known by it.
  if ('error' in begun) return begun
  await started($, begun.line, agent.description, true)
  void follow($, begun.run, String(begun.line.agentId))
  return begun.line
}

/** What the self-test found broken on this Claude Code version, shown until a run passes. */
let broken: string | undefined

/**
 * Checks, once per Claude Code version, that subagents on other accounts still work (`Headroom
 * --agent-selftest`); what broke stays in the status line and the debug log.
 */
async function selfTest($: EngineInterface): Promise<void> {
  let line: Line | undefined
  for await (const chunk of $.process.spawn({ argv: [await runner($), '--agent-selftest'] })) {
    if (chunk.stream === 'stdout' && chunk.text.trim()) line = JSON.parse(chunk.text.trim().split('\n')[0] ?? '{}') as Line
  }
  if (line?.type === 'failed') {
    broken = `Headroom: subagents on other accounts are broken on Claude Code ${String(line.version)} (${String(line.step)}: ${String(line.text)})`
    $.ui.log(broken, { to: 'debug' })
    $.ui.toast(broken, { timeoutMs: 15_000 })
  } else if (line?.type === 'ok') {
    broken = undefined
  }
  await showStatus($)
}

async function showStatus($: EngineInterface): Promise<void> {
  const running = (await read($, agents)).filter(a => a.status === 'running')
  const where = [...new Set(running.map(a => a.account))].join(', ')
  const text = [running.length > 0 ? `${running.length} agent${running.length === 1 ? '' : 's'} on ${where}` : undefined, broken]
    .filter(Boolean).join(' · ')
  $.ui.status(text || undefined)
}

function elapsed(agent: RemoteAgent, now: number): string {
  const s = Math.round(((agent.endedAt ?? now) - agent.startedAt) / 1000)
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`
}

function plural(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? '' : 's'}`
}

/** Terminal on the agent's own Claude Code session, on its account. */
async function openInTerminal($: EngineInterface, id: string): Promise<void> {
  for await (const _ of $.process.spawn({ argv: [await runner($), '--agent-open', id] })) {
    // Nothing to read.
  }
}

/**
 * An agent as its row reads, like a built-in agent's: what it is and where it runs, its latest steps, and
 * on demand its whole transcript (what it said, each tool call and result, its answer).
 */
function agentBlock($: EngineInterface, e: Parameters<EngineInterface['ui']['resolve']>[0], agent: RemoteAgent,
                    unfolded: boolean): JSX.Element {
  const { Box, Text, Button, Markdown } = $.ui.resolve(e)
  const tools = agent.items.filter(i => i.kind === 'tool').length || agent.steps.length
  const state = { running: 'Running', done: 'Done', failed: 'Failed', stopped: 'Stopped' }[agent.status]
  const toggle = () => update($, open, list => (list.includes(agent.id) ? list.filter(i => i !== agent.id) : [...list, agent.id]))
  return (
    <Box flexDirection="column">
      <Text>
        <Text bold>{{ running: '● ', done: '✓ ', failed: '✗ ', stopped: '■ ' }[agent.status]}Agent · {agent.description}</Text>
        <Text dimColor>  on {agent.account || 'another account'}{agent.model ? ` · ${agent.model}` : ''}</Text>
      </Text>
      <Text dimColor>  {state} {elapsed(agent, Date.now())} · {plural(tools, 'tool use')}</Text>
      {!unfolded && (agent.status === 'running' ? agent.steps.slice(-3) : agent.steps.slice(-1)).map(step => (
        <Text dimColor>  ⎿ {step}</Text>
      ))}
      {unfolded && (
        <Box flexDirection="column" marginLeft={2} marginTop={1}>
          {agent.items.length === 0 && <Text dimColor>Nothing yet.</Text>}
          {agent.items.map(item =>
            item.kind === 'text' ? <Markdown text={item.text} />
            : item.kind === 'tool' ? <Text>→ {item.summary}</Text>
            : <Text dimColor={!item.isError} color={item.isError ? 'red' : undefined}>
                {'  ⎿ '}{item.text.split('\n').slice(0, 6).join('\n    ')}{item.text.split('\n').length > 6 ? '\n    …' : ''}
              </Text>,
          )}
        </Box>
      )}
      <Box flexDirection="row" gap={1} marginTop={unfolded ? 1 : 0}>
        {agent.foreground && agent.status === 'running' && (
          <Button key={`background-${agent.id}`} action="task:background" dimColor onPress={() => toBackground.get(agent.id)?.()}>
            Run in background (ctrl+b)
          </Button>
        )}
        <Button key={`transcript-${agent.id}`} dimColor onPress={toggle}>{unfolded ? 'Hide transcript' : 'Show transcript'}</Button>
        <Button key={`terminal-${agent.id}`} dimColor onPress={() => openInTerminal($, agent.id)}>Open in Terminal</Button>
      </Box>
    </Box>
  )
}

export const register: Register = on => {
  // The mode built-in subagents inherit; the classic hook events carry it.
  on('classic.UserPromptSubmit', async ($, e, next) => {
    if (e.permission_mode) permissionMode = e.permission_mode
    void warmUp($).catch(error => $.ui.log(`headroom: warm-up failed: ${String(error)}`, { to: 'debug' }))
    // Edits to Headroom's list apply from this turn's next model call on.
    await syncCatalog($).catch(error => $.ui.log(`headroom: reading Headroom's agents failed: ${String(error)}`, { to: 'debug' }))
    return next(e)
  }).catch(($, e, next) => next(e))

  // A type that left Headroom's list stays registered: it is no longer offered.
  on('agent.offer', ($, e, next) => (owns(e.agent) && !catalog.has(e.agent) ? { isOffered: false } : next(e)))

  // Claude snapshots agent types before prompt hooks: new types and edited descriptions go here too.
  on('tool.describe', { tool: 'Agent' }, async ($, e, next) => {
    const answer = await next(e)
    if (catalog.size === 0) return answer
    const lines = [...catalog].map(([type, agent]) => `- ${type}: ${listing(agent)}`)
    return { ...answer, description: [answer.description, '', "Headroom's agent types as they read now (this replaces their earlier lines):", ...lines].join('\n') }
  })
  on('classic.PostToolUse', ($, e, next) => {
    if (e.permission_mode) permissionMode = e.permission_mode
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.start', async ($, e, next) => {
    interactive = e.isInteractive
    await $.command.register({ name: 'agents-elsewhere', description: 'Show the subagents Headroom runs on your other accounts and providers' })
    await syncCatalog($).catch(error => $.ui.log(`headroom: reading Headroom's agents failed: ${String(error)}`, { to: 'debug' }))
    void selfTest($).catch(error => {
      broken = `Headroom: its self-test could not run (${String(error)})`
      $.ui.log(broken, { to: 'debug' })
      $.ui.toast(broken, { timeoutMs: 15_000 })
    })
    return next(e)
  })

  on('command.run', { command: 'agents-elsewhere' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Agents on other accounts' })
    return { text: 'Opened the pane of agents running on your other accounts.' }
  })

  on('tool.call', { tool: 'Agent' }, async ($, e, next) => {
    const owned = owns(e.subagent_type)
    if (owned) {
      if (!catalog.has(e.subagent_type)) await syncCatalog($)
      if (!catalog.has(e.subagent_type)) return { deny: `No agent ${e.subagent_type} is enabled in Headroom (Settings → Agents). Use another agent type.` }
      const unsupported = e.agentId !== undefined ? 'from inside a subagent' : e.name !== undefined ? 'as a named teammate'
        : e.isolation === 'remote' ? 'remotely' : undefined
      if (unsupported) return { deny: `Headroom's agents (${e.subagent_type}) can't run ${unsupported}. Call it from the main session, unnamed, without remote isolation.` }
    }
    // Kept built-in on purpose: agents started by subagents, remote agents and named agents (teammates).
    else if (e.agentId !== undefined || e.isolation === 'remote' || e.name !== undefined) return next(e)
    const unknown = Object.keys(e).filter(key => !AGENT_KEYS.has(key))
    if (unknown.length > 0 || !ISOLATIONS.has(e.isolation)) {
      const what = unknown.length > 0 ? `field${unknown.length === 1 ? '' : 's'} ${unknown.map(k => `\`${k}\``).join(', ')}`
        : `isolation \`${String(e.isolation)}\``
      return { deny: `Headroom doesn't handle the Agent tool's ${what} yet, so it can't run this agent. Tell the user: Headroom's plugin needs updating for it.` }
    }
    const request = {
      prompt: e.prompt, description: e.description, subagentType: e.subagent_type, model: e.model,
      effort: e.effort, isolation: e.isolation, cwd: await $.session.cwd(), permissionMode,
      parentModel: await $.session.model(), agent: owned ? e.subagent_type : undefined,
    }
    // The engine checks the call (permissions, other hooks) and raises `agent.spawn`, where an account
    // with room takes the agent; otherwise the built-in agent runs and this is its answer.
    const claim: Claim = { request }
    claims.set(e.tool_use_id, claim)
    let answer: Awaited<ReturnType<typeof next>>
    try {
      const missing = `Agent type '${e.subagent_type}' not found. Available agents:`
      answer = await next(e)
      // Core checked permissions, but its turn-local agent list predates UserPromptSubmit. Only that
      // exact rejection is recoverable: the catalog and runner still enforce ownership and enablement.
      if (owned && !claim.started && answer.isError === true && answer.text?.startsWith(missing)) {
        const background = (e as typeof e & { run_in_background?: boolean }).run_in_background === true
        const begun = await start($, { ...request, background })
        if ('noRoom' in begun) return { deny: `Headroom found nowhere to run ${e.subagent_type}.` }
        if ('error' in begun) return { deny: `Headroom couldn't run this agent (${e.subagent_type}): ${begun.error}` }
        await started($, begun.line, e.description, false, !background, e.tool_use_id)
        claim.started = { ...begun, background }
      }
    } finally {
      claims.delete(e.tool_use_id)
    }
    if (!claim.started) return answer
    const { run, line, background } = claim.started
    if (background) {
      void follow($, run, String(line.agentId))
      return launched(e, line)
    }
    return foreground($, e, next.signal, run, line)
  }).catch(($, e, next) => (next.called ? next(e) : { deny: `Headroom failed: ${next.error.message ?? next.error.kind}` }))

  on('agent.spawn', async ($, e, next) => {
    const claim = claims.get(e.tool_use_id)
    const owned = claim?.request.agent !== undefined || owns(e.subagentType)
    const type = String(claim?.request.agent ?? e.subagentType)
    const special = e.resume || e.fork || e.isTeammate || e.workflow || e.parentAgentId !== undefined
    if (owned && (!claim || special)) {
      return { deny: `Headroom's agents (${type}) run only from the main session's Agent tool, not as a fork, teammate, workflow agent or resume.` }
    }
    // Kept built-in on purpose: a fork runs on this session's context and cache, a teammate and a workflow
    // agent belong to this session, a resume continues a built-in agent.
    if (!claim || special) return next(e)
    const request = {
      ...claim.request, subagentType: e.subagentType, model: e.model ?? claim.request.model,
      cwd: e.cwd ?? claim.request.cwd, permissionMode: e.permissionMode ?? claim.request.permissionMode,
      parentModel: e.parentModel,
      background: e.background,
    }
    const begun = await start($, request)
    if ('noRoom' in begun) return owned ? { deny: `Headroom found nowhere to run ${type}.` } : next(e)
    if ('error' in begun) return { deny: `Headroom couldn't run this agent${owned ? ` (${type})` : ' on another account'}: ${begun.error}` }
    await started($, begun.line, e.description, false, !e.background, e.tool_use_id)
    claim.started = { ...begun, background: e.background }
    return { deny: 'Headroom runs this agent.' }
  }).catch(($, e, next) => (next.called ? next(e) : { deny: `Headroom failed: ${next.error.message ?? next.error.kind}` }))

  on('tool.call', { tool: 'SendMessage' }, async ($, e, next) => {
    const to = String(e.to)
    const agent = (await read($, agents)).find(a => a.id === to)
    // Headroom's agents have UUIDs; one from an earlier session is still known to Headroom.
    if (!agent && !UUID.test(to)) return next(e)
    if (!interactive) return { deny: 'Headroom cannot deliver SendMessage replies in a non-interactive session: Claude Code does not wait for its background work. Start a foreground Agent call instead, or use an interactive Claude Code session.' }
    if (agent?.status === 'running') {
      agentPending.set(to, [...(agentPending.get(to) ?? []), e.message])
      return { result: { success: true, message: `Queued for agent ${to}: it reads it when it finishes its current work.` } }
    }
    const known: RemoteAgent = agent ?? {
      id: to, description: e.summary ?? 'agent', account: '', model: '', status: 'done', steps: [], items: [], startedAt: Date.now(), pending: [],
    }
    const line = await continueAgent($, known, e.message)
    if ('error' in line) return { deny: `Headroom could not continue agent ${to}: ${line.error}` }
    return {
      result: {
        success: true,
        message: `Message sent to agent ${to} on ${place({ account: String(line.account), provider: line.provider as string | undefined })}. Its reply arrives as a notification when it finishes.`,
      },
    }
  }).catch(($, e, next) => (next.called ? next(e) : { deny: `Headroom failed: ${next.error.message ?? next.error.kind}` }))

  on('tool.call', { tool: 'TaskStop' }, async ($, e, next) => {
    const id = String(e.task_id ?? e.shell_id ?? '')
    const agent = (await read($, agents)).find(a => a.id === id)
    if (!agent) return next(e)
    if (agent.status !== 'running') return { deny: `Agent ${id} isn't running (it is ${agent.status}).` }
    stopping.add(id)
    let answer = null as Line | null
    for await (const chunk of $.process.spawn({ argv: [await runner($), '--agent-stop', id] })) {
      if (chunk.stream === 'stdout') answer = JSON.parse(chunk.text.trim().split('\n')[0] || '{}') as Line
    }
    if (answer?.type !== 'stopped') {
      stopping.delete(id)
      return { deny: `Headroom could not stop agent ${id}: ${String(answer?.text ?? 'its runner gave no answer')}` }
    }
    return {
      result: {
        message: `Stopped agent ${id} (${agent.description}) on ${place(agent)}.`,
        task_id: id, task_type: 'local_agent', command: agent.description,
      },
    }
  }).catch(($, e, next) => (next.called ? next(e) : { deny: `Headroom failed: ${next.error.message ?? next.error.kind}` }))

  // The session's agents as ListAgents lists them, Headroom's beside the built-in ones.
  on('tool.call', { tool: 'ListAgents' }, async ($, e, next) => {
    const answer = await next(e)
    const mine = (await read($, agents)).filter(a => a.status === 'running' || Date.now() - (a.endedAt ?? 0) < 3_600_000)
    if (answer.deny !== undefined || mine.length === 0) return answer
    const result = answer.result as { listing: string; sections?: { kind: string; total: number; rows: object[] }[]; notes?: object[] }
    const rows = mine.map(a => ({ id: a.id, name: a.description, type: 'headroom', status: a.status }))
    const listing = [
      result.listing.trimEnd(),
      '',
      `Agents Headroom runs on your other accounts and providers (SendMessage or TaskStop them by id):`,
      ...mine.map(a => `- ${a.id} · ${a.description} · ${a.status} · on ${a.account}${a.model ? ` · ${a.model}` : ''}`),
    ].join('\n')
    return { ...answer, result: { ...result, listing, sections: [...(result.sections ?? []), { kind: 'headroom', total: rows.length, rows }] } }
  })

  // The Agent call's row in the transcript: the remote agent, drawn like a built-in one.
  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    if (e.props.tool !== 'Agent') return next(e)
    const agent = (await read($, agents)).find(a => a.toolUseId === e.requestId)
    if (!agent) return next(e)
    const unfolded = (await read($, open)).includes(agent.id) || e.props.isExpanded === true
    return agentBlock($, e, agent, unfolded)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const list = (await read($, agents)).slice().reverse()
    const unfolded = await read($, open)
    return (
      <Box flexDirection="column">
        {list.length === 0 && <Text dimColor>No agents on other accounts yet in this session.</Text>}
        {list.map(agent => (
          <Box flexDirection="column" marginBottom={1}>
            {agentBlock($, e, agent, unfolded.includes(agent.id))}
          </Box>
        ))}
      </Box>
    )
  })
}
