import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { RemoteAgent } from '../types'

// Headroom runs a subagent on another of your Claude accounts when one has room, and answers the
// built-in Agent tool with it exactly as a background built-in agent answers: "launched" at once, the
// report delivered when it finishes, SendMessage continuing it. With no account free, the call goes
// through untouched and a built-in subagent runs.

const PANE = 'headroom-agents'
const agents = atom({ plugin: 'headroom', key: 'agents' } as const, [] as RemoteAgent[])
const paneShown = atom({ plugin: 'headroom', key: 'paneShown' } as const, false)

/** The session's permission mode, as the last classic hook event reported it. */
let permissionMode: string | undefined

type Line = { type: string; [key: string]: unknown }

/** Headroom's own binary: beside this plugin inside Headroom.app, else the usual install. */
async function runner($: EngineInterface): Promise<string> {
  const bundled = `${$.plugin.root}/../../../MacOS/Headroom`
  return (await $.fs.exists(bundled)) ? bundled : '/Applications/Headroom.app/Contents/MacOS/Headroom'
}

/**
 * Starts `Headroom --agent-run` and reads its JSON lines for the rest of the run. Resolves with the
 * `started` line, or null when no account has room (or the runner couldn't start).
 */
async function launch($: EngineInterface, request: Record<string, unknown>, description: string): Promise<Line | null> {
  const argv = [await runner($), '--agent-run']
  let settle: (line: Line | null) => void = () => {}
  const first = new Promise<Line | null>(resolve => (settle = resolve))
  void (async () => {
    let agentId: string | undefined
    let buffer = ''
    try {
      for await (const chunk of $.process.spawn({ argv, input: JSON.stringify(request) })) {
        if (chunk.stream !== 'stdout') continue
        buffer += chunk.text
        let newline: number
        while ((newline = buffer.indexOf('\n')) >= 0) {
          const text = buffer.slice(0, newline)
          buffer = buffer.slice(newline + 1)
          let line: Line
          try {
            line = JSON.parse(text) as Line
          } catch {
            continue
          }
          if (line.type === 'no_room') settle(null)
          else if (line.type === 'started') {
            agentId = String(line.agentId)
            await started($, line, description, request.resume !== undefined)
            settle(line)
          } else if (agentId) await progress($, agentId, line)
        }
      }
    } catch (error) {
      $.ui.log(`headroom: subagent runner failed: ${String(error)}`, { to: 'debug' })
    }
    settle(null)
  })()
  return first
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

async function started($: EngineInterface, line: Line, description: string, resumed: boolean): Promise<void> {
  const id = String(line.agentId)
  await update($, agents, list => {
    const known = list.find(a => a.id === id)
    if (known) return list.map(a => (a.id === id ? { ...a, status: 'running' as const, endedAt: undefined } : a))
    const agent: RemoteAgent = {
      id, description, account: String(line.account), model: String(line.model ?? ''),
      status: 'running', steps: [], startedAt: Date.now(), pending: [],
    }
    return [...list, agent].slice(-50)
  })
  if (!resumed && !(await read($, paneShown))) {
    await update($, paneShown, () => true)
    void $.ui.open({ id: PANE, title: 'Agents on other accounts' })
  }
  await showStatus($)
}

async function progress($: EngineInterface, id: string, line: Line): Promise<void> {
  if (line.type === 'step' || line.type === 'moved') {
    const text = line.type === 'moved' ? `Moved off ${line.account}: ${line.reason}` : String(line.text)
    await update($, agents, list => list.map(a => (a.id === id ? { ...a, steps: [...a.steps, text].slice(-40) } : a)))
    $.ui.invalidate('ui.render')
    return
  }
  if (line.type !== 'result') return
  const failed = line.isError === true
  let agent: RemoteAgent | undefined
  await update($, agents, list =>
    list.map(a => {
      if (a.id !== id) return a
      agent = { ...a, status: failed ? 'failed' : 'done', endedAt: Date.now(),
                account: String(line.account ?? a.account), model: String(line.model ?? a.model), pending: [] }
      return agent
    }),
  )
  await showStatus($)
  if (!agent) return
  await deliver($, agent, line, failed)
  // Messages sent while it ran: continue it with them now, as a built-in agent reads its inbox.
  const pending = (await read($, agents)).find(a => a.id === id)?.pending ?? []
  const queued = agentPending.get(id) ?? []
  agentPending.delete(id)
  const messages = [...pending, ...queued]
  if (messages.length > 0) void continueAgent($, agent, messages.join('\n\n'))
}

/** SendMessage text held for an agent that is still running. */
const agentPending = new Map<string, string[]>()

/** The report, as a background agent's completion notification reads. */
async function deliver($: EngineInterface, agent: RemoteAgent, line: Line, failed: boolean): Promise<void> {
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

async function continueAgent($: EngineInterface, agent: RemoteAgent, message: string): Promise<Line | null> {
  return launch($, { prompt: message, resume: agent.id, cwd: await $.session.cwd() }, agent.description)
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
    const line = await launch($, request, e.description)
    if (!line) return next(e)
    return {
      result: {
        status: 'async_launched' as const,
        isAsync: true as const,
        agentId: String(line.agentId),
        description: e.description,
        prompt: e.prompt,
        outputFile: String(line.outputFile),
        resolvedModel: String(line.model) || undefined,
      },
    }
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
      id: to, description: e.summary ?? 'agent', account: '', model: '', status: 'done', steps: [], startedAt: Date.now(), pending: [],
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

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const list = (await read($, agents)).slice().reverse()
    const now = Date.now()
    return (
      <Box flexDirection="column">
        {list.length === 0 && <Text dimColor>No agents on other accounts yet in this session.</Text>}
        {list.map(agent => (
          <Box flexDirection="column" marginBottom={1}>
            <Text bold>
              {agent.status === 'running' ? '● ' : agent.status === 'done' ? '✓ ' : '✗ '}
              {agent.description}
            </Text>
            <Text dimColor>
              {agent.account} · {agent.model || 'default model'} · {agent.status === 'running' ? 'running' : agent.status} {elapsed(agent, now)}
            </Text>
            {(agent.status === 'running' ? agent.steps.slice(-4) : agent.steps.slice(-1)).map(step => (
              <Text dimColor>  {step}</Text>
            ))}
          </Box>
        ))}
      </Box>
    )
  })
}
