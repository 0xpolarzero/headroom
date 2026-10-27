import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { RemoteAgent, TranscriptItem } from '../types'

// Headroom runs a subagent on another of your Claude accounts when one has room, and answers the
// built-in Agent tool with it exactly as a built-in agent answers. The engine checks the call and decides
// whether the agent runs in the foreground or the background, then raises `agent.spawn`, where Headroom
// takes the agent over. In the foreground the call waits for the report (ctrl+b sends it to the
// background); in the background it answers "launched" at once and the report comes as a notification.
// SendMessage continues it. With no account free, the spawn goes through untouched and a built-in
// subagent runs.

const PANE = 'headroom-agents'
const agents = atom({ plugin: 'headroom', key: 'agents' } as const, [] as RemoteAgent[])
const paneShown = atom({ plugin: 'headroom', key: 'paneShown' } as const, false)
/** Agents whose transcript is unfolded, in their row and in the pane. */
const open = atom({ plugin: 'headroom', key: 'open' } as const, [] as string[])

/** The session's permission mode, as the last classic hook event reported it. */
let permissionMode: string | undefined

type Line = { type: string; [key: string]: unknown }

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

/**
 * Starts `Headroom --agent-run` and reads it until the agent started. Resolves with the run and its
 * `started` line, or null when no account has room (or the runner couldn't start).
 */
async function start($: EngineInterface, request: Record<string, unknown>): Promise<{ run: Run; line: Line } | null> {
  try {
    const stream = $.process.spawn({ argv: [await runner($), '--agent-run'], input: JSON.stringify(request) })
    const run = new Run(stream[Symbol.asyncIterator]())
    for (let line = await run.next(); line; line = await run.next()) {
      if (line.type === 'no_room') break
      if (line.type === 'started') return { run, line }
    }
  } catch (error) {
    $.ui.log(`headroom: subagent runner failed: ${String(error)}`, { to: 'debug' })
  }
  return null
}

/** Reads a background agent's run to its end; `first` is a line already asked for. */
async function follow($: EngineInterface, run: Run, id: string, first?: Promise<Line | null>): Promise<void> {
  try {
    for (let line = await (first ?? run.next()); line; line = await run.next()) {
      const agent = await record($, id, line)
      if (agent) {
        await deliver($, agent, line)
        await afterResult($, agent)
      }
    }
  } catch (error) {
    $.ui.log(`headroom: subagent runner failed: ${String(error)}`, { to: 'debug' })
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
  let agent: RemoteAgent | undefined
  await update($, agents, list =>
    list.map(a => {
      if (a.id !== id) return a
      agent = { ...a, status: failed ? 'failed' : 'done', endedAt: Date.now(), result: String(line.text ?? ''),
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
  if (messages.length > 0) void continueAgent($, agent, messages.join('\n\n'))
}

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
    `<summary>Agent "${agent.description}" ${failed ? 'failed' : 'finished'} (ran on the ${agent.account} account with Headroom)</summary>`,
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

async function continueAgent($: EngineInterface, agent: RemoteAgent, message: string): Promise<Line | null> {
  const begun = await start($, { prompt: message, resume: agent.id, cwd: await $.session.cwd() })
  if (!begun) return null
  await started($, begun.line, agent.description, true)
  void follow($, begun.run, String(begun.line.agentId))
  return begun.line
}

async function showStatus($: EngineInterface): Promise<void> {
  const running = (await read($, agents)).filter(a => a.status === 'running')
  if (running.length === 0) return $.ui.status(undefined)
  const where = [...new Set(running.map(a => a.account))].join(', ')
  $.ui.status(`${running.length} agent${running.length === 1 ? '' : 's'} on ${where}`)
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
  const state = agent.status === 'running' ? 'Running' : agent.status === 'done' ? 'Done' : 'Failed'
  const toggle = () => update($, open, list => (list.includes(agent.id) ? list.filter(i => i !== agent.id) : [...list, agent.id]))
  return (
    <Box flexDirection="column">
      <Text>
        <Text bold>{agent.status === 'running' ? '● ' : agent.status === 'done' ? '✓ ' : '✗ '}Agent · {agent.description}</Text>
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
  on('classic.UserPromptSubmit', ($, e, next) => {
    if (e.permission_mode) permissionMode = e.permission_mode
    void warmUp($).catch(error => $.ui.log(`headroom: warm-up failed: ${String(error)}`, { to: 'debug' }))
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.PostToolUse', ($, e, next) => {
    if (e.permission_mode) permissionMode = e.permission_mode
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'agents-elsewhere', description: 'Show the subagents running on your other Claude accounts' })
    return next(e)
  })

  on('command.run', { command: 'agents-elsewhere' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Agents on other accounts' })
    return { text: 'Opened the pane of agents running on your other accounts.' }
  })

  on('tool.call', { tool: 'Agent' }, async ($, e, next) => {
    // Kept built-in: agents started by subagents, remote agents and named teammates.
    if (e.agentId !== undefined || e.isolation === 'remote' || e.name !== undefined) return next(e)
    const request = {
      prompt: e.prompt, description: e.description, subagentType: e.subagent_type, model: e.model,
      effort: e.effort, isolation: e.isolation, cwd: await $.session.cwd(), permissionMode,
      parentModel: await $.session.model(),
    }
    // The engine checks the call (permissions, other hooks) and raises `agent.spawn`, where an account
    // with room takes the agent; otherwise the built-in agent runs and this is its answer.
    const claim: Claim = { request }
    claims.set(e.tool_use_id, claim)
    let answer: Awaited<ReturnType<typeof next>>
    try {
      answer = await next(e)
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
  }).catch(($, e, next) => next(e))

  on('agent.spawn', async ($, e, next) => {
    const claim = claims.get(e.tool_use_id)
    if (!claim || e.resume || e.fork || e.isTeammate || e.workflow || e.parentAgentId !== undefined) return next(e)
    const request = {
      ...claim.request, subagentType: e.subagentType, model: e.model ?? claim.request.model,
      cwd: e.cwd ?? claim.request.cwd, permissionMode: e.permissionMode ?? claim.request.permissionMode,
      parentModel: e.parentModel,
    }
    const begun = await start($, request)
    if (!begun) return next(e)
    await started($, begun.line, e.description, false, !e.background, e.tool_use_id)
    claim.started = { ...begun, background: e.background }
    return { deny: 'Headroom runs this agent on another Claude account.' }
  }).catch(($, e, next) => next(e))

  on('tool.call', { tool: 'SendMessage' }, async ($, e, next) => {
    const to = String(e.to)
    const agent = (await read($, agents)).find(a => a.id === to)
    // Headroom's agents have UUIDs; one from an earlier session is still known to Headroom.
    if (!agent && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(to)) return next(e)
    if (agent?.status === 'running') {
      agentPending.set(to, [...(agentPending.get(to) ?? []), e.message])
      return { result: { success: true, message: `Queued for agent ${to}: it reads it when it finishes its current work.` } }
    }
    const known: RemoteAgent = agent ?? {
      id: to, description: e.summary ?? 'agent', account: '', model: '', status: 'done', steps: [], items: [], startedAt: Date.now(), pending: [],
    }
    const line = await continueAgent($, known, e.message)
    if (!line) return { result: { success: false, message: `Headroom could not continue agent ${to}.` } }
    return {
      result: {
        success: true,
        message: `Message sent to agent ${to} on the ${String(line.account)} account. Its reply arrives as a notification when it finishes.`,
      },
    }
  }).catch(($, e, next) => next(e))

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
