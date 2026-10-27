import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, TurnStepChunk, TurnStepInput, TurnStepResult, TurnUsage } from 'claude-code'

import type { RemoteAgent, TranscriptItem } from '../types'

// Claude Code owns each routed agent's task, transcript row, notifications and lifetime. Headroom
// answers its `turn.step` with the other account or provider's report, without a local model request.
// A separate `agent.spawn` hook calls the engine, so that hook's nesting never skips our step adapter.
// Forks, teammates, workflow agents, remote agents and calls inside subagents stay built-in on purpose.

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

type Line = { type: string; [key: string]: unknown }

/** An agent of Headroom's list, as `Headroom --agent-catalog` gives it. */
type Defined = { name: string; description: string; provider: string; summary: string; prompt: string }

/** Headroom's enabled agents as last read, by type (`headroom:codex-deep`), and the list's revision. */
let catalog = new Map<string, Defined>()
let revision: number | undefined
let nativeTasks: boolean | undefined

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
  const parsed = JSON.parse(text.trim() || '{}') as { revision?: number; agents?: Defined[]; nativeTasks?: boolean }
  nativeTasks = parsed.nativeTasks === true
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

type Request = Record<string, unknown>
type Route = { request: Request; description: string; toolUseId: string; ran: boolean; cursor: number; handback?: boolean; resumePrompt?: string; error?: string }
const claims = new Map<string, Request>()
const routes = new Map<string, Route>()
/** A native step can arrive before its spawn's reply has crossed the worker boundary. */
const spawning = new Set<Promise<void>>()

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
    const stream = $.process.spawn({ argv: [await runner($), '--agent-run'], input: JSON.stringify(request) })
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
                       toolUseId?: string): Promise<void> {
  const id = String(line.agentId)
  await update($, agents, list => {
    const known = list.find(a => a.id === id)
    if (known) return list.map(a => (a.id === id ? { ...a, status: 'running' as const, endedAt: undefined } : a))
    const agent: RemoteAgent = {
      id, description, account: String(line.account), model: String(line.model ?? ''),
      provider: line.provider === undefined ? undefined : String(line.provider),
      status: 'running', steps: [], items: [], startedAt: Date.now(), toolUseId,
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
  const stopped = line.stopped === true
  let agent: RemoteAgent | undefined
  await update($, agents, list =>
    list.map(a => {
      if (a.id !== id) return a
      agent = { ...a, status: stopped ? 'stopped' : failed ? 'failed' : 'done', endedAt: Date.now(),
                result: stopped ? 'Stopped' : String(line.text ?? ''),
                account: String(line.account ?? a.account), model: String(line.model ?? a.model) }
      return agent
    }),
  )
  await showStatus($)
  return agent
}

/** Admission happens before native spawn; it never starts a remote model or claims a warm process. */
async function admission($: EngineInterface, request: Request): Promise<'routed' | 'no_room'> {
  if (nativeTasks === undefined) await syncCatalog($)
  if (!nativeTasks) throw new Error('Update the Headroom app and plugin together: this app does not support native routed tasks.')
  const stream = $.process.spawn({ argv: [await runner($), '--agent-route'], input: JSON.stringify(request) })
  const run = new Run(stream[Symbol.asyncIterator]())
  try {
    const line = await run.next()
    if (line?.type === 'routed' || line?.type === 'no_room') return line.type
    throw new Error(String(line?.text ?? 'Headroom’s routing check ended without an answer.'))
  } finally {
    run.stop()
  }
}

async function stopRemote($: EngineInterface, id: string): Promise<void> {
  const result = await $.process.run([await runner($), '--agent-stop', id])
  if (result.exitCode !== 0) $.ui.log(`headroom: stop ${id}: ${result.stdout || result.stderr}`, { to: 'debug' })
}

/** New native inbox messages since the preceding remote run, without the engine's context reminders. */
async function inbox($: EngineInterface, id: string, route: Route): Promise<string> {
  const messages = await $.session.messages({ agentId: id, as: 'api' })
  if (!Array.isArray(messages)) throw new Error(messages.deny)
  // $.tool.list() lists the main loop's tools. The native request itself carries this instruction in auto mode.
  route.handback = messages.some(m => m.role === 'user' && m.content.some(b => b.type === 'text'
    && typeof b.text === 'string' && b.text.startsWith('<system-reminder>\nYour final report is delivered through SubagentHandback:')))
  if (messages.length < route.cursor) throw new Error('The native agent’s transcript was compacted before Headroom read its messages.')
  const text: string[] = []
  for (const message of messages.slice(route.cursor)) {
    if (message.role !== 'user') continue
    const blocks = message.content.filter(b => b.type === 'text' && typeof b.text === 'string').map(b => String(b.text))
    // A resumed turn can contain the coordinator's reminder and the same message as its own text block.
    const plain = blocks.filter(t => !t.startsWith('<system-reminder>') && !t.startsWith('The coordinator sent a message while you were working:\n'))
    for (const block of blocks) {
      const prefix = 'The coordinator sent a message while you were working:\n'
      const suffix = '\n\nAddress this before completing your current task.\n'
      if (!block.startsWith(prefix)) continue
      if (!block.endsWith(suffix)) throw new Error('Claude Code changed the native inbox message format.')
      const message = block.slice(prefix.length, -suffix.length)
      if (!plain.includes(message)) plain.push(message)
    }
    text.push(...plain)
    if (message.content.some(b => b.type !== 'text' && b.type !== 'tool_result')) {
      throw new Error('Headroom cannot forward a non-text message to the remote agent.')
    }
  }
  route.cursor = messages.length
  return text.join('\n\n')
}

/** Auto-mode native agents require handback; other modes deliver plain text at end_turn. */
function* respond(e: TurnStepInput, text: string, usage: TurnUsage | null, handback: boolean): Generator<TurnStepChunk, TurnStepResult> {
  if (handback && e.index === 0) {
    yield { kind: 'tool', index: 0, id: `headroom_${e.turnId}_${e.index}`, name: 'SubagentHandback' }
    yield { kind: 'input', index: 0, json: JSON.stringify({ message: text }) }
    yield { kind: 'stop', stopReason: 'tool_use', usage }
    return { turnId: e.turnId, index: e.index, answer: '',
             toolUses: [{ name: 'SubagentHandback', input: { message: text } }], stopReason: 'tool_use', usage }
  }
  yield { kind: 'text', index: 0, text }
  yield { kind: 'stop', stopReason: 'end_turn', usage }
  return { turnId: e.turnId, index: e.index, answer: text, toolUses: [], stopReason: 'end_turn', usage }
}

function usageOf(line: Line, model: string): TurnUsage {
  const cached = Number(line.cacheReadInputTokens ?? 0)
  const created = Number(line.cacheCreationInputTokens ?? 0)
  return { model: String(line.model ?? model), input_tokens: Math.max(0, Number(line.inputTokens ?? 0) - cached - created),
           output_tokens: Number(line.outputTokens ?? 0), cache_read_input_tokens: cached, cache_creation_input_tokens: created }
}

/** One remote run per native turn; the engine schedules new turns for messages queued while it worked. */
async function remoteTurn($: EngineInterface, e: TurnStepInput, route: Route, signal: AbortSignal): Promise<Line> {
  const id = e.agentId!
  if (route.error) throw new Error(route.error)
  if (e.index !== 0) throw new Error('Claude Code requested another model step after Headroom’s handback.')
  const previous = route.cursor
  const message = await inbox($, id, route)
  const nextPrompt = route.resumePrompt || message
  route.resumePrompt = undefined
  const prompt = route.ran ? nextPrompt : [String(route.request.prompt), previous > 0 ? nextPrompt : ''].filter(Boolean).join('\n\n')
  if (route.ran && !prompt) throw new Error('The native agent resumed without a new text message.')
  await $.store.set(`native-agent:${id}`, route)
  let run: Run | undefined
  const stop = () => {
    void stopRemote($, id).catch(error => $.ui.log(`headroom: stop ${id} failed: ${String(error)}`, { to: 'debug' }))
  }
  signal.addEventListener('abort', stop, { once: true })
  try {
    if (signal.aborted) throw new Error('Stopped by Claude Code.')
    const request = { ...route.request, prompt, id, resume: route.ran ? id : undefined }
    const begun = await start($, request)
    if ('noRoom' in begun) throw new Error('No other account has room after the native agent started. Headroom did not run it on the session’s account.')
    if ('error' in begun) throw new Error(begun.error)
    run = begun.run
    if (String(begun.line.agentId) !== id) throw new Error('Headroom’s runner did not keep the native agent id. Update the Headroom app and plugin together.')
    await started($, begun.line, route.description, route.ran, route.toolUseId)
    route.ran = true
    route.request.prompt = ''
    await $.store.set(`native-agent:${id}`, route)
    let result: Line | undefined
    for (let line = await run.next(); line; line = await run.next()) {
      await record($, id, line)
      if (line.type === 'result' || line.type === 'error') { result = line; break }
    }
    run.stop()
    run = undefined
    if (!result) throw new Error('Headroom’s runner ended without the agent’s report.')
    if (result.isError === true || result.type === 'error') throw new Error(String(result.text ?? 'The remote agent failed.'))
    await inbox($, id, route)
    await $.store.set(`native-agent:${id}`, route)
    return result
  } finally {
    signal.removeEventListener('abort', stop)
    run?.stop()
    if (signal.aborted) {
      await record($, id, { type: 'result', stopped: true, text: 'Stopped', isError: true })
    }
  }
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
    if (e.subagent_type === 'fork') return next(e)
    const owned = owns(e.subagent_type)
    if (owned) {
      if (!catalog.has(e.subagent_type)) await syncCatalog($)
      if (!catalog.has(e.subagent_type)) return { deny: `No agent ${e.subagent_type} is enabled in Headroom (Settings → Agents). Use another agent type.` }
      if (e.agentId !== undefined || e.isolation === 'remote' || e.name !== undefined) {
        return { deny: `Headroom's agents (${e.subagent_type}) run only from the main session, unnamed, without remote isolation.` }
      }
    }
    if (e.agentId !== undefined || e.isolation === 'remote' || e.name !== undefined) return next(e)
    const unknown = Object.keys(e).filter(key => !AGENT_KEYS.has(key))
    if (unknown.length > 0 || !ISOLATIONS.has(e.isolation)) {
      const what = unknown.length > 0 ? `field${unknown.length === 1 ? '' : 's'} ${unknown.map(k => `\`${k}\``).join(', ')}`
        : `isolation \`${String(e.isolation)}\``
      return { deny: `Headroom doesn't handle the Agent tool's ${what} yet, so it can't run this agent. Tell the user: Headroom's plugin needs updating for it.` }
    }
    const request: Request = {
      prompt: e.prompt, description: e.description, subagentType: e.subagent_type, model: e.model,
      effort: e.effort, isolation: e.isolation, cwd: await $.session.cwd(), permissionMode,
      parentModel: await $.session.model(), agent: owned ? e.subagent_type : undefined,
    }
    if (await admission($, request) === 'no_room') {
      return owned ? { deny: `Headroom found nowhere to run ${String(e.subagent_type)}.` } : next(e)
    }
    claims.set(e.tool_use_id, request)
    try {
      // Only the remote worker needs a worktree; the native task's shell executes no workspace tools.
      const shell = e.isolation === 'worktree' ? { ...e, isolation: undefined } : e
      const answer = await next(shell)
      const missing = `Agent type '${e.subagent_type}' not found. Available agents:`
      if (owned && answer.isError === true && answer.text?.startsWith(missing)) {
        // The turn's catalog snapshot can predate registration. The native shell still runs the owned provider.
        return await next({ ...shell, subagent_type: 'general-purpose' })
      }
      return answer
    } finally {
      claims.delete(e.tool_use_id)
    }
  }).catch(($, e, next) => ({ deny: `Headroom failed: ${next.error.message ?? next.error.kind}` }))

  on('agent.spawn', async ($, e, next) => {
    const special = e.fork || e.isTeammate || e.workflow || e.parentAgentId !== undefined
    if (!e.resume && owns(e.subagentType) && (special || !claims.has(e.tool_use_id))) {
      return { deny: `Headroom's agents (${e.subagentType}) run only from the main session's Agent tool.` }
    }
    if (special && !e.resume) return next(e)
    if (e.resume) {
      const id = e.resume.agentId
      const route = routes.get(id) ?? await $.store.get(`native-agent:${id}`) as Route | undefined
      if (route) {
        // Queued resumes can reach step 0 before their coordinator message appears in session.messages.
        route.resumePrompt = e.prompt
        if (e.permissionMode) route.request.permissionMode = e.permissionMode
        routes.set(id, route)
        await $.store.set(`native-agent:${id}`, route)
      } else if (owns(e.subagentType)) {
        return { deny: `Headroom has no saved route for native agent ${id}.` }
      }
      return next(e)
    }
    const claim = claims.get(e.tool_use_id)
    if (!claim) return next(e)
    const request: Request = {
      ...claim, subagentType: claim.agent ?? e.subagentType, model: e.model ?? claim.model,
      cwd: e.cwd ?? claim.cwd, permissionMode: e.permissionMode ?? claim.permissionMode,
      parentModel: e.parentModel, background: e.background,
    }
    let ready = () => {}
    const pending = new Promise<void>(resolve => { ready = resolve })
    spawning.add(pending)
    try {
      const result = await next(e)
      if (result.deny !== undefined || !result.agentId) return result
      const route: Route = { request, description: e.description, toolUseId: e.tool_use_id, ran: false, cursor: 0,
                             handback: e.permissionMode === 'auto' }
      routes.set(result.agentId, route)
      try { await $.store.set(`native-agent:${result.agentId}`, route) }
      catch (error) { route.error = `Headroom could not save the native agent’s route: ${String(error)}` }
      return result
    } finally {
      ready()
      spawning.delete(pending)
    }
  }).catch(($, e, next) => ({ deny: `Headroom failed: ${next.error.message ?? next.error.kind}` }))

  // Separate registration: a spawn nested in agent.spawn/tool.call still reaches this hook.
  on('turn.step', async function* ($, e, next) {
    if (!e.agentId) return yield* next(e)
    if (spawning.size > 0) await Promise.all([...spawning])
    const route = routes.get(e.agentId) ?? await $.store.get(`native-agent:${e.agentId}`) as Route | undefined
    if (!route) return yield* next(e)
    routes.set(e.agentId, route)
    let result: Line
    try {
      result = await remoteTurn($, e, route, next.signal)
    } catch (error) {
      if (next.signal.aborted) return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: null, usage: null }
      result = { type: 'result', isError: true, text: `Headroom agent failed: ${String(error)}` }
      await record($, e.agentId, result)
      $.ui.log(String(result.text), { to: 'debug' })
    }
    const text = String(result.text ?? '')
    const usage = usageOf(result, e.model)
    return yield* respond(e, text, usage, route.handback === true)
  }).catch(async function* ($, e, next) {
    // A routing adapter must never fail open to a model request on the session's account.
    const text = `Headroom agent failed: ${next.error.message ?? next.error.kind}`
    return yield* respond(e, text, null, e.agentId !== undefined && routes.get(e.agentId)?.handback === true)
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
