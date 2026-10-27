import { expect, test } from 'claude-code/testing'

// The seam under test is a native spawn followed by its model step. Core tool results stay opaque;
// the runner supplies JSON lines, and a model request beneath turn.step is counted as a routing failure.
const ID = 'a1111111111111111'
const NATIVE = { status: 'async_launched', agentId: ID, marker: 'core owns this answer' }
const RESULT = { type: 'result', text: 'exact remote report\n', inputTokens: 100, outputTokens: 10,
                 cacheReadInputTokens: 50, cacheCreationInputTokens: 20, model: 'claude-haiku-5-5' }
const CATALOG = { revision: 3, agents: [
  { name: 'codex-deep', description: 'Review hard bugs.', provider: 'codex', summary: 'Codex · gpt-6.1-sol', prompt: 'You are codex-deep.' },
] }
const HANDBACK = '<system-reminder>\nYour final report is delivered through SubagentHandback: when your work is complete, call SubagentHandback({message: <your full report>}). The call ends your run, so make it your last step. Only a SubagentHandback call reaches your caller as your result; plain text you write at the end is not delivered. Do not also send the report with SendMessage: your caller would get it twice.\n</system-reminder>'
type Body = Parameters<typeof test>[1] extends infer B ? (B extends (...args: infer A) => unknown ? A : never) : never
const lines = (...objects: object[]) => objects.map(o => JSON.stringify(o)).join('\n') + '\n'
type Message = { role: 'user' | 'assistant'; content: { type: string; text?: string }[] }
type Options = {
  route?: object; background?: boolean; fork?: boolean; workflow?: boolean; refusal?: string; missingType?: boolean
  outputs?: object[]; gate?: Promise<void>; wrongID?: boolean; noStart?: boolean; catalog?: typeof CATALOG; handback?: boolean
  storeFailure?: boolean; selfTest?: object; nativeTasks?: boolean
}

function engine([$test, on]: Body, options: Options = {}) {
  const calls: { flag: string; request: Record<string, unknown> }[] = []
  const spawned: object[] = []
  const nativeCalls: string[] = []
  const nativeInputs: Record<string, unknown>[] = []
  const statuses: (string | undefined)[] = []
  const registered: object[] = []
  const store = new Map<string, unknown>()
  const context = (value: Message[]) => options.handback === false ? value : value.map((m, i) =>
    i === 0 ? { ...m, content: [...m.content, { type: 'text', text: HANDBACK }] } : m)
  let messages: Message[] = context([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] }])
  let modelSteps = 0
  let runCount = 0
  on('fs.exists', () => ({ value: true }))
  on('session.cwd', () => ({ value: '/work' }))
  on('session.model', () => ({ value: 'claude-haiku-5-5' }))
  on('session.messages', () => ({ value: messages }))
  on('store.get', (_, e) => ({ value: store.get(e.key) }))
  on('store.set', (_, e) => {
    if (options.storeFailure) return { deny: 'disk full' }
    store.set(e.key, JSON.parse(JSON.stringify(e.value)))
    return { value: undefined }
  })
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.status', (_, e) => { statuses.push(e.text); return { value: undefined } })
  on('ui.log', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('ui.invalidate', () => ({ value: undefined }))
  on('agent.register', (_, e) => { registered.push(e); return { value: { agent: `headroom:${e.name}` } } })
  on('agent.offer', () => ({ isOffered: true }))
  on('command.register', (_, e) => ({ value: { command: `headroom:${e.name}` } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('classic.UserPromptSubmit', () => ({}))
  on('prompt.submit', () => { throw new Error('Headroom must leave notifications to the engine') })
  on('process.spawn', async function* (_, e) {
    const flag = e.argv[1] ?? ''
    const request = JSON.parse(e.input || '{}') as Record<string, unknown>
    calls.push({ flag, request })
    if (flag === '--agent-route') yield { stream: 'stdout', text: lines(options.route ?? { type: 'routed' }) }
    else if (flag === '--agent-catalog') yield { stream: 'stdout', text: lines({ ...(options.catalog ?? { revision: 1, agents: [] }), nativeTasks: options.nativeTasks ?? true }) }
    else if (flag === '--agent-selftest') yield { stream: 'stdout', text: lines(options.selfTest ?? { type: 'ok' }) }
    else if (flag === '--agent-run') {
      runCount++
      if (!options.noStart) yield { stream: 'stdout', text: lines({ type: 'started', agentId: options.wrongID ? 'old-runner-id' : request.id, account: 'Pro', model: 'haiku' }) }
      if (options.gate) await options.gate
      yield { stream: 'stdout', text: lines(...(options.outputs ?? [RESULT])) }
    }
    return { value: { code: 0, signal: null } }
  })
  on('tool.call', async (_, e) => {
    nativeCalls.push(e.tool)
    nativeInputs.push(e)
    if (e.tool !== 'Agent') return { result: { marker: `native ${e.tool}` } }
    if (options.refusal) return { deny: options.refusal }
    if (options.missingType && e.subagent_type === 'headroom:codex-deep') {
      return { result: undefined, text: "Agent type 'headroom:codex-deep' not found. Available agents: general-purpose", isError: true }
    }
    const spawn = await $test.agent.spawn({ tool_use_id: e.tool_use_id, prompt: e.prompt, description: e.description,
      subagentType: e.subagent_type ?? 'general-purpose', model: e.model, cwd: '/native', permissionMode: options.handback === false ? 'acceptEdits' : 'auto',
      parentModel: 'claude-haiku-5-5', background: options.background ?? true, fork: options.fork ?? false,
      workflow: options.workflow ? { runId: 'wf_x', agentIndex: 1 } : undefined } as never)
    if (spawn.deny !== undefined) return { deny: spawn.deny }
    return { result: NATIVE }
  })
  on('agent.spawn', (_, e) => { spawned.push(e); return { model: 'claude-haiku-5-5', agentId: ID } })
  on('turn.step', async function* (_, e) {
    modelSteps++
    yield { kind: 'text', index: 0, text: 'built-in response' }
    yield { kind: 'stop', stopReason: 'end_turn', usage: null }
    return { turnId: e.turnId, index: e.index, answer: 'built-in response', toolUses: [], stopReason: 'end_turn', usage: null }
  })
  return { calls, spawned, nativeCalls, nativeInputs, statuses, registered, store,
    get modelSteps() { return modelSteps }, get runCount() { return runCount },
    messages(value: Message[]) { messages = context(value) },
    async launch(fields: object = {}) {
      return $test.tool.call({ tool: 'Agent', tool_use_id: 'toolu_x', description: 'read a note', prompt: 'initial task', ...fields } as never)
    },
  }
}

async function step($: Body[0], turnId = 'turn-1', index = 0, agentId: string | undefined = ID) {
  const stream = $.turn.step({ turnId, index, agentId, model: 'claude-haiku-5-5', messageCount: 1 })
  const chunks = []
  for await (const chunk of stream) chunks.push(chunk)
  return chunks
}
async function resume($: Body[0], prompt: string) {
  await $.agent.spawn({ tool_use_id: '', prompt, description: 'read a note', subagentType: 'general-purpose',
    parentModel: 'haiku', permissionMode: 'auto', background: true, fork: false, resume: { agentId: ID } } as never)
}
function report(chunks: Awaited<ReturnType<typeof step>>): string {
  return chunks.filter(c => c.kind === 'input' || c.kind === 'text').map(c => c.kind === 'input' ? JSON.parse(c.json).message : c.text).join('')
}

test('routing creates a real native task before running the remote agent, and preserves the native answer', async ($, on) => {
  const e = engine([$, on])
  const answer = await e.launch()
  expect(answer.result).toEqual(NATIVE)
  expect(e.spawned.length).toBe(1)
  expect(e.runCount).toBe(0)
  expect(e.calls.some(c => c.flag === '--agent-route')).toBe(true)
  const chunks = await step($)
  expect(report(chunks)).toBe(RESULT.text)
  expect(chunks.find(c => c.kind === 'tool')?.name).toBe('SubagentHandback')
  expect(e.modelSteps).toBe(0)
  const request = e.calls.find(c => c.flag === '--agent-run')!.request
  expect(request.id).toBe(ID)
  expect(request.cwd).toBe('/native')
  expect(request.permissionMode).toBe('auto')
  expect(request.background).toBe(true)
})

test('foreground routing uses the same native task and report adapter', async ($, on) => {
  const e = engine([$, on], { background: false })
  expect((await e.launch()).result).toEqual(NATIVE)
  expect(report(await step($))).toBe(RESULT.text)
  expect(e.calls.find(c => c.flag === '--agent-run')?.request.background).toBe(false)
  expect(e.modelSteps).toBe(0)
})

test('native agents without the handback instruction return plain text and end_turn', async ($, on) => {
  const e = engine([$, on], { handback: false })
  await e.launch()
  const chunks = await step($)
  expect(report(chunks)).toBe(RESULT.text)
  expect(chunks.some(c => c.kind === 'tool')).toBe(false)
  expect(chunks.find(c => c.kind === 'stop')?.stopReason).toBe('end_turn')
  expect(e.modelSteps).toBe(0)
})

test('no room leaves the native agent and its model calls untouched', async ($, on) => {
  const e = engine([$, on], { route: { type: 'no_room' } })
  expect((await e.launch()).result).toEqual(NATIVE)
  expect((await step($))[0]).toEqual({ kind: 'text', index: 0, text: 'built-in response' })
  expect(e.runCount).toBe(0)
  expect(e.modelSteps).toBe(1)
})

test('SDK hosts retain background routing', async ($, on) => {
  const e = engine([$, on])
  await $.session.start({ cwd: '/work', surface: null, isInteractive: false })
  await e.launch()
  expect(report(await step($))).toBe(RESULT.text)
  expect(e.modelSteps).toBe(0)
})

test('native SendMessage follow-ups resume the remote id and only forward the new message', async ($, on) => {
  const e = engine([$, on])
  await e.launch()
  await step($)
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] },
    { role: 'assistant', content: [] },
    { role: 'user', content: [
      { type: 'text', text: 'The coordinator sent a message while you were working:\nnext task\n\nAddress this before completing your current task.\n' },
      { type: 'text', text: 'next task' },
    ] }])
  expect(report(await step($, 'turn-2'))).toBe(RESULT.text)
  const run = e.calls.filter(c => c.flag === '--agent-run').at(-1)!.request
  expect(run.resume).toBe(ID)
  expect(run.prompt).toBe('next task')
  expect(e.modelSteps).toBe(0)
})

test('a native agent restored from persistent routing state still resumes remotely', async ($, on) => {
  const e = engine([$, on])
  e.store.set(`native-agent:${ID}`, { request: { prompt: '', cwd: '/original', subagentType: 'Explore', effort: 'high' },
    description: 'restored agent', toolUseId: 'toolu_old', ran: true, cursor: 1 })
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'old task' }] },
    { role: 'user', content: [{ type: 'text', text: 'follow-up after resume' }] }])
  expect(report(await step($))).toBe(RESULT.text)
  const request = e.calls.find(c => c.flag === '--agent-run')!.request
  expect(request.resume).toBe(ID)
  expect(request.prompt).toBe('follow-up after resume')
  expect(request.cwd).toBe('/original')
  expect(request.subagentType).toBe('Explore')
  expect(e.modelSteps).toBe(0)
})

test('a coordinator-only inbox wrapper forwards its message instead of losing it', async ($, on) => {
  const e = engine([$, on])
  await e.launch()
  await step($)
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] },
    { role: 'user', content: [{ type: 'text', text: 'The coordinator sent a message while you were working:\nwrapped task\n\nAddress this before completing your current task.\n' }] }])
  expect(report(await step($, 'turn-2'))).toBe(RESULT.text)
  expect(e.calls.filter(c => c.flag === '--agent-run').at(-1)?.request.prompt).toBe('wrapped task')
})

test('a queued native resume forwards its pinned prompt before it appears in session.messages', async ($, on) => {
  let release = () => {}
  const gate = new Promise<void>(resolve => { release = resolve })
  const e = engine([$, on], { gate })
  await e.launch()
  const working = step($)
  for (let i = 0; i < 30 && e.runCount === 0; i++) await new Promise(resolve => setTimeout(resolve, 10))
  release()
  expect(report(await working)).toBe(RESULT.text)
  expect(e.runCount).toBe(1)
  e.messages([{ role: 'user', content: [{ type: 'text', text: 'initial task' }] },
    { role: 'assistant', content: [{ type: 'text', text: RESULT.text }] }])
  await resume($, 'message while working')
  expect(report(await step($, 'turn-2'))).toBe(RESULT.text)
  expect(e.runCount).toBe(2)
  expect(e.calls.filter(c => c.flag === '--agent-run')[1]?.request.prompt).toBe('message while working')
})

test('TaskStop, ListAgents and SendMessage remain native calls with native results', async ($, on) => {
  const e = engine([$, on])
  await e.launch()
  for (const name of ['TaskStop', 'ListAgents', 'SendMessage']) {
    const answer = await $.tool.call({ tool: name, task_id: ID, to: ID, message: 'hi' } as never)
    expect(answer.result).toEqual({ marker: `native ${name}` })
  }
  expect(e.calls.some(c => c.flag === '--agent-stop')).toBe(false)
  expect(e.runCount).toBe(0)
})

test('remote token usage reaches the native stop chunk without counting cached tokens twice', async ($, on) => {
  const e = engine([$, on])
  await e.launch()
  const stop = (await step($)).find(c => c.kind === 'stop')
  expect(stop?.usage).toEqual({ model: 'claude-haiku-5-5', input_tokens: 30, output_tokens: 10,
                              cache_read_input_tokens: 50, cache_creation_input_tokens: 20 })
})

test('an admission failure refuses the native spawn instead of falling back', async ($, on) => {
  const e = engine([$, on], { route: { type: 'error', text: 'routing is broken' } })
  expect((await e.launch()).deny).toContain('routing is broken')
  expect(e.spawned).toEqual([])
  expect(e.runCount).toBe(0)
})

test('an older app is rejected before calling a CLI mode it does not recognize', async ($, on) => {
  const e = engine([$, on], { nativeTasks: false })
  expect((await e.launch()).deny).toContain('Update the Headroom app and plugin together')
  expect(e.calls.some(c => c.flag === '--agent-route')).toBe(false)
  expect(e.spawned).toEqual([])
})

test('a runner error is an explicit native report and never a local model request', async ($, on) => {
  const e = engine([$, on], { noStart: true, outputs: [{ type: 'error', text: 'missing agent type on Pro' }] })
  await e.launch()
  expect(report(await step($))).toContain('Headroom agent failed: Error: missing agent type on Pro')
  expect(e.modelSteps).toBe(0)
})

test('a runner that ends without a report produces an explicit native failure report', async ($, on) => {
  const e = engine([$, on], { outputs: [{ type: 'step', text: 'Read: note.txt' }] })
  await e.launch()
  expect(report(await step($))).toContain('without the agent’s report')
  expect(e.modelSteps).toBe(0)
})

test('loss of room after native spawn is an error, not execution on the session account', async ($, on) => {
  const e = engine([$, on], { noStart: true, outputs: [{ type: 'no_room' }] })
  await e.launch()
  expect(report(await step($))).toContain('No other account has room after the native agent started')
  expect(e.modelSteps).toBe(0)
})

test('an older runner that changes ids fails visibly', async ($, on) => {
  const e = engine([$, on], { wrongID: true })
  await e.launch()
  expect(report(await step($))).toContain('did not keep the native agent id')
  expect(e.modelSteps).toBe(0)
})

test('a second model step after handback never falls back to the session account', async ($, on) => {
  const e = engine([$, on])
  await e.launch()
  await step($)
  const chunks = await step($, 'turn-1', 1)
  expect(report(chunks)).toContain('another model step')
  expect(chunks.some(c => c.kind === 'tool')).toBe(false)
  expect(e.modelSteps).toBe(0)
})

test('failure to persist a route produces an error report, never a local request', async ($, on) => {
  const e = engine([$, on], { storeFailure: true })
  await e.launch()
  expect(report(await step($))).toContain('could not save the native agent’s route')
  expect(e.runCount).toBe(0)
  expect(e.modelSteps).toBe(0)
})

test('only the remote worker creates a routed worktree', async ($, on) => {
  const e = engine([$, on])
  await e.launch({ isolation: 'worktree' })
  expect(e.nativeInputs[0]?.isolation).toBeUndefined()
  await step($)
  expect(e.calls.find(c => c.flag === '--agent-run')?.request.isolation).toBe('worktree')
})

test('a built-in worktree call retains its isolation when no other account has room', async ($, on) => {
  const e = engine([$, on], { route: { type: 'no_room' } })
  await e.launch({ isolation: 'worktree' })
  expect(e.nativeInputs[0]?.isolation).toBe('worktree')
  expect(e.runCount).toBe(0)
})

test('prompt hooks still warm a process with the session folder and model', async ($, on) => {
  const e = engine([$, on])
  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'plan' } as never)
  for (let i = 0; i < 30 && !e.calls.some(c => c.flag === '--agent-warm'); i++) await new Promise(resolve => setTimeout(resolve, 10))
  const request = e.calls.find(c => c.flag === '--agent-warm')?.request
  expect(request?.cwd).toBe('/work')
  expect(request?.parentModel).toBe('claude-haiku-5-5')
  expect(request?.permissionMode).toBe('plan')
})

test('a failed version self-test remains visible in the status line', async ($, on) => {
  const e = engine([$, on], { selfTest: { type: 'failed', version: '2.2.0', step: 'resume', text: 'missing session' } })
  await $.session.start({ cwd: '/work', surface: null, isInteractive: false })
  for (let i = 0; i < 30 && !e.statuses.some(t => t?.includes('broken')); i++) await new Promise(resolve => setTimeout(resolve, 10))
  expect(e.statuses.at(-1)).toContain('broken on Claude Code 2.2.0 (resume: missing session)')
})

test('unrelated native subagents and the main loop retain their model steps', async ($, on) => {
  const e = engine([$, on])
  await step($, 'native', 0, 'a-unrouted')
  await step($, 'main', 0, undefined)
  expect(e.modelSteps).toBe(2)
  expect(e.runCount).toBe(0)
})

for (const options of [{ fork: true }, { workflow: true }]) {
  test(`special native spawn ${JSON.stringify(options)} stays built-in`, async ($, on) => {
    const e = engine([$, on], options)
    await e.launch()
    await step($)
    expect(e.runCount).toBe(0)
    expect(e.modelSteps).toBe(1)
  })
}

for (const fields of [{ agentId: 'parent-agent' }, { name: 'teammate' }, { isolation: 'remote' }]) {
  test(`special Agent call ${JSON.stringify(fields)} stays built-in`, async ($, on) => {
    const e = engine([$, on])
    await e.launch(fields)
    await step($)
    expect(e.calls.some(c => c.flag === '--agent-route')).toBe(false)
    expect(e.modelSteps).toBe(1)
  })
}

test('unknown Agent fields still fail explicitly', async ($, on) => {
  const e = engine([$, on])
  expect((await e.launch({ run_after: 'lunch' })).deny).toContain('`run_after`')
  expect(e.nativeCalls).toEqual([])
})

test('permission refusal does not start a remote run', async ($, on) => {
  const e = engine([$, on], { refusal: 'Permission denied' })
  expect((await e.launch()).deny).toBe('Permission denied')
  expect(e.runCount).toBe(0)
})

test('Headroom-owned provider agents use the same native adapter', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await e.launch({ subagent_type: 'headroom:codex-deep' })
  expect(e.spawned.length).toBe(1)
  expect(report(await step($))).toBe(RESULT.text)
  expect(e.calls.find(c => c.flag === '--agent-run')?.request.agent).toBe('headroom:codex-deep')
  expect(e.modelSteps).toBe(0)
})

test('a stale owned-type listing recovers with a native shell and the same owned provider', async ($, on) => {
  const e = engine([$, on], { catalog: CATALOG, missingType: true })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  expect((await e.launch({ subagent_type: 'headroom:codex-deep' })).result).toEqual(NATIVE)
  expect(report(await step($))).toBe(RESULT.text)
  expect(e.calls.find(c => c.flag === '--agent-run')?.request.agent).toBe('headroom:codex-deep')
})

test('disabled owned agents are errors and are not offered', async ($, on) => {
  const e = engine([$, on])
  expect((await e.launch({ subagent_type: 'headroom:gone' })).deny).toContain('No agent headroom:gone')
  expect((await $.agent.offer({ agent: 'headroom:gone' } as never)).isOffered).toBe(false)
  expect(e.spawned).toEqual([])
})

test('the pane keeps remote progress and its expandable transcript beside the native task', async ($, on) => {
  const e = engine([$, on], { outputs: [
    { type: 'step', text: 'Read: note.txt' }, { type: 'item', kind: 'text', text: 'The note says hello.' }, RESULT,
  ] })
  await e.launch()
  await step($)
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'headroom', component: 'Pane', requestId: 'headroom-agents', props: {}, surface })
    expect((await ui.find({ type: 'Text', text: /on Pro/ }))?.text).toContain('on Pro')
    await ui.press({ key: `transcript-${ID}` })
    expect((await ui.find({ type: 'Markdown' }) as { text?: string })?.text).toContain('The note says hello.')
    await ui.press({ key: `transcript-${ID}` })
    await ui.unmount()
  }
})
