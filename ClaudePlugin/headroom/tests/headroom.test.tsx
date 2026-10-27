import { expect, test } from 'claude-code/testing'

// Each test stands in for the engine beneath the plugin and for Headroom's runner: `process.spawn`
// answers with the JSON lines `Headroom --agent-run` writes.

const AGENT_ID = '122651c3-88a7-4bf2-b4b0-2c3b5ade7404'

function lines(...objects: object[]): string {
  return objects.map(o => JSON.stringify(o)).join('\n') + '\n'
}

type Stubs = {
  requests: string[]; argvs: string[][]; submitted: string[]; reachedEngine: string[]; spawned: string[]; statuses: (string | undefined)[]
}

/**
 * `background` is what the engine decides for the agent (its definition, settings), as `agent.spawn`
 * carries it, and `fork` whether the call forks this session. `gate`, when given, holds the runner's
 * output after its first line until it resolves. `outputs` answers other Headroom commands, by flag.
 * `missingType` reproduces core dispatch's stale listing; `refusal` stands in for a permission denial.
 */
type Options = { background?: boolean; fork?: boolean; gate?: Promise<void>; outputs?: Record<string, string>; missingType?: string; refusal?: string }

type Body = Parameters<typeof test>[1] extends infer B ? (B extends (...args: infer A) => unknown ? A : never) : never

function engine([$test, on]: Body, runnerOutput: string, options: Options = {}): Stubs {
  const stubs: Stubs = { requests: [], argvs: [], submitted: [], reachedEngine: [], spawned: [], statuses: [] }
  on('fs.exists', () => ({ value: true }))
  on('session.cwd', () => ({ value: '/work' }))
  on('session.model', () => ({ value: 'claude-fable-5-1' }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.status', (_, e) => {
    stubs.statuses.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.invalidate', () => ({ value: undefined }))
  on('prompt.submit', (_, e) => {
    stubs.submitted.push(e.text)
    return { text: e.text }
  })
  on('process.spawn', async function* (_, e) {
    stubs.argvs.push([...e.argv])
    stubs.requests.push(e.input ?? '')
    const other = options.outputs?.[e.argv[1] ?? '']
    if (other !== undefined || e.argv[1] !== '--agent-run') {
      if (other) yield { stream: 'stdout', text: other }
    } else if (runnerOutput && options.gate) {
      const newline = runnerOutput.indexOf('\n') + 1
      yield { stream: 'stdout', text: runnerOutput.slice(0, newline) }
      await options.gate
      yield { stream: 'stdout', text: runnerOutput.slice(newline) }
    } else if (runnerOutput) yield { stream: 'stdout', text: runnerOutput }
    return { value: { code: 0, signal: null } }
  })
  // The Agent tool as the engine runs it: it raises `agent.spawn`, whose deny is its error.
  on('tool.call', async (_, e) => {
    stubs.reachedEngine.push(e.tool)
    if (e.tool === 'Agent') {
      if (options.refusal) return { deny: options.refusal }
      if (options.missingType && e.subagent_type === options.missingType) {
        return { result: undefined, text: `Agent type '${e.subagent_type}' not found. Available agents: general-purpose`, isError: true }
      }
      const spawn = await $test.agent.spawn({
        tool_use_id: e.tool_use_id, prompt: e.prompt, description: e.description, subagentType: e.subagent_type ?? 'general-purpose',
        parentModel: 'claude-fable-5-1', background: options.background ?? true, fork: options.fork ?? false,
      } as never)
      if ('deny' in spawn && spawn.deny) return { deny: `Subagent spawn denied by a plugin: ${spawn.deny}` }
    }
    if (e.tool === 'ListAgents') return { result: { listing: 'Background agents:\n- a1 · built-in task', sections: [] } }
    return { result: { status: 'completed', agentId: 'built-in', content: [{ type: 'text', text: 'built-in ran' }] } }
  })
  on('agent.spawn', (_, e) => {
    stubs.spawned.push(e.description)
    return { model: 'claude-fable-5-1', agentId: 'built-in' }
  })
  return stubs
}

async function eventually(check: () => boolean): Promise<void> {
  for (let i = 0; i < 100 && !check(); i++) await new Promise(resolve => setTimeout(resolve, 10))
}

const STARTED = { type: 'started', agentId: AGENT_ID, account: 'Pro', model: 'claude-fable-5-1', outputFile: '/tmp/a.log' }
const RESULT = {
  type: 'result', text: 'olleh', isError: false, account: 'Pro', model: 'claude-sonnet-5-5', toolUses: 1, durationMs: 11000,
  inputTokens: 1200, outputTokens: 300,
}

test('a background agent runs on another account and reports like a built-in background agent', async ($, on) => {
  const stubs = engine([$, on], lines(STARTED, { type: 'step', text: 'Read: note.txt' }, RESULT), { background: true })

  const answer = await $.tool.call({ tool: 'Agent', description: 'reverse the note', prompt: 'Read note.txt' })

  // The engine checked the call and decided; no built-in agent started.
  expect(stubs.reachedEngine).toEqual(['Agent'])
  expect(stubs.spawned).toEqual([])
  expect((answer.result as { status: string }).status).toBe('async_launched')
  expect((answer.result as { agentId: string }).agentId).toBe(AGENT_ID)
  const request = JSON.parse(stubs.requests[0] ?? '{}')
  expect(request.prompt).toBe('Read note.txt')
  expect(request.parentModel).toBe('claude-fable-5-1')
  expect(request.cwd).toBe('/work')

  await eventually(() => stubs.submitted.length > 0)
  expect(stubs.submitted[0]).toContain(`<task-id>${AGENT_ID}</task-id>`)
  expect(stubs.submitted[0]).toContain('<result>olleh</result>')
  expect(stubs.submitted[0]).toContain('ran on the Pro account')
})

test('a foreground agent runs on another account and answers like a built-in foreground agent', async ($, on) => {
  const stubs = engine([$, on], lines(STARTED, { type: 'step', text: 'Read: note.txt' }, RESULT), { background: false })

  const answer = await $.tool.call({ tool: 'Agent', description: 'reverse the note', prompt: 'Read note.txt' })

  expect(stubs.spawned).toEqual([])
  const result = answer.result as {
    status: string; agentId: string; content: { type: string; text: string }[]; prompt: string
    totalToolUseCount: number; totalDurationMs: number; totalTokens: number; usage: { input_tokens: number; output_tokens: number }
  }
  expect(result.status).toBe('completed')
  expect(result.agentId).toBe(AGENT_ID)
  expect(result.content).toEqual([{ type: 'text', text: 'olleh' }])
  expect(result.prompt).toBe('Read note.txt')
  expect(result.totalToolUseCount).toBe(1)
  expect(result.totalDurationMs).toBe(11000)
  expect(result.totalTokens).toBe(1500)
  expect(result.usage.input_tokens).toBe(1200)
  // The report was the call's answer: no notification follows.
  await new Promise(resolve => setTimeout(resolve, 50))
  expect(stubs.submitted).toEqual([])
})

test("a foreground agent's failure is the Agent call's error", async ($, on) => {
  engine([$, on], lines(STARTED, { type: 'result', text: 'Pro is at its usage limit', isError: true, account: 'Pro' }), { background: false })

  const answer = await $.tool.call({ tool: 'Agent', description: 'x', prompt: 'y' })

  expect((answer as { deny?: string }).deny).toContain('Pro is at its usage limit')
})

test('a foreground agent sent to the background answers "launched", then reports as a notification', async ($, on) => {
  let release = () => {}
  const gate = new Promise<void>(resolve => (release = resolve))
  const stubs = engine([$, on], lines(STARTED, RESULT), { background: false, gate })

  const call = $.tool.call({ tool: 'Agent', description: 'reverse the note', prompt: 'Read note.txt', tool_use_id: 'toolu_fg' } as never)
  await new Promise(resolve => setTimeout(resolve, 50))
  const ui = await $.ui.mount({
    plugin: 'headroom', component: 'ToolUse', requestId: 'toolu_fg', surface: 'terminal',
    props: { tool_use_id: 'toolu_fg', tool: 'Agent', input: {}, isRunning: true, isErrored: false, isInterrupted: false },
  })
  await ui.press({ key: `background-${AGENT_ID}` })
  const answer = await call
  await ui.unmount()

  expect((answer.result as { status: string }).status).toBe('async_launched')
  expect(stubs.submitted).toEqual([])
  release()
  await eventually(() => stubs.submitted.length > 0)
  expect(stubs.submitted[0]).toContain('<result>olleh</result>')
})

test('with no account free, the built-in subagent runs', async ($, on) => {
  const stubs = engine([$, on], lines({ type: 'no_room' }), { background: false })

  const answer = await $.tool.call({ tool: 'Agent', description: 'x', prompt: 'y' })

  expect(stubs.spawned).toEqual(['x'])
  expect((answer.result as { agentId: string }).agentId).toBe('built-in')
})

test('a sent prompt has Headroom get a process ready', async ($, on) => {
  const stubs = engine([$, on], '')
  on('classic.UserPromptSubmit', () => ({}))

  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'acceptEdits' } as never)
  await eventually(() => stubs.argvs.some(argv => argv[1] === '--agent-warm'))

  const request = JSON.parse(stubs.requests[stubs.argvs.findIndex(argv => argv[1] === '--agent-warm')] ?? '{}')
  expect(request.permissionMode).toBe('acceptEdits')
  expect(request.cwd).toBe('/work')
})

test("SendMessage to a built-in agent isn't Headroom's", async ($, on) => {
  const stubs = engine([$, on], lines({ type: 'no_room' }))

  await $.tool.call({ tool: 'SendMessage', to: 'aeb08a749aaadf89c', message: 'hi' })

  expect(stubs.reachedEngine).toEqual(['SendMessage'])
  expect(stubs.requests).toEqual([])
})

test('the pane shows a running agent and its steps', async ($, on) => {
  engine([$, on], lines(
    { type: 'started', agentId: AGENT_ID, account: 'Pro', model: 'claude-sonnet-5-5', outputFile: '/tmp/a.log' },
    { type: 'step', text: 'Read: note.txt' },
  ))
  await $.tool.call({ tool: 'Agent', description: 'reverse the note', prompt: 'Read note.txt' })
  await new Promise(resolve => setTimeout(resolve, 50))

  const ui = await $.ui.mount({
    plugin: 'headroom', component: 'Pane', requestId: 'headroom-agents', surface: 'desktop',
    props: { title: 'Agents on other accounts', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} },
  })
  expect((await ui.find({ type: 'Text', text: /reverse the note/ }))?.text).toContain('reverse the note')
  expect((await ui.find({ type: 'Text', text: /Read: note.txt/ }))?.text).toContain('Read: note.txt')
  await ui.unmount()
})

test("the Agent call's row shows the remote agent and unfolds its transcript", async ($, on) => {
  engine([$, on], lines(
    { type: 'started', agentId: AGENT_ID, account: 'Pro', model: 'claude-sonnet-5-5', outputFile: '/tmp/a.log' },
    { type: 'step', text: 'Read: note.txt' },
    { type: 'item', kind: 'tool', id: 't1', summary: 'Read: note.txt', input: '{}' },
    { type: 'item', kind: 'result', id: 't1', text: 'hello', isError: false },
    { type: 'item', kind: 'text', text: 'The note says hello.' },
  ))
  await $.tool.call({ tool: 'Agent', description: 'read the note', prompt: 'Read note.txt', tool_use_id: 'toolu_1' } as never)
  await new Promise(resolve => setTimeout(resolve, 50))

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({
      plugin: 'headroom', component: 'ToolUse', requestId: 'toolu_1', surface,
      props: { tool_use_id: 'toolu_1', tool: 'Agent', input: {}, isRunning: false, isErrored: false, isInterrupted: false },
    })
    expect((await ui.find({ type: 'Text', text: /read the note/ }))?.text).toContain('Agent')
    expect((await ui.find({ type: 'Text', text: /on Pro/ }))?.text).toContain('on Pro')
    expect(await ui.find({ type: 'Markdown' })).toBeUndefined()
    await ui.press({ key: `transcript-${AGENT_ID}` })
    expect((await ui.find({ type: 'Markdown' }) as { text?: string } | undefined)?.text).toContain('The note says hello.')
    expect((await ui.find({ type: 'Text', text: /hello$/ }))?.text).toContain('hello')
    await ui.press({ key: `transcript-${AGENT_ID}` })
    await ui.unmount()
  }
})

test('a fork runs built-in, on this session’s own context', async ($, on) => {
  const stubs = engine([$, on], lines(STARTED, RESULT), { fork: true })

  const answer = await $.tool.call({ tool: 'Agent', description: 'fork it', prompt: 'carry on', subagent_type: 'fork' })

  expect(stubs.spawned).toEqual(['fork it'])
  expect(stubs.argvs.filter(a => a[1] === '--agent-run')).toEqual([])
  expect((answer.result as { agentId: string }).agentId).toBe('built-in')
})

test("an Agent field Headroom doesn't know is the call's error, not a silent built-in run", async ($, on) => {
  const stubs = engine([$, on], lines(STARTED, RESULT))

  const answer = await $.tool.call({ tool: 'Agent', description: 'x', prompt: 'y', run_after: 'lunch' } as never)

  expect((answer as { deny?: string }).deny).toContain('`run_after`')
  expect(stubs.reachedEngine).toEqual([])
  expect(stubs.spawned).toEqual([])
})

test('run_in_background is a field Headroom knows: the engine decides and agent.spawn says', async ($, on) => {
  const stubs = engine([$, on], lines(STARTED, RESULT), { background: true })

  const answer = await $.tool.call({ tool: 'Agent', description: 'x', prompt: 'y', run_in_background: true } as never)

  expect((answer.result as { status: string }).status).toBe('async_launched')
  await eventually(() => stubs.submitted.length > 0)
})

test("a runner that can't start the agent is the call's error", async ($, on) => {
  const stubs = engine([$, on], lines({ type: 'error', text: 'the Reviewer agent type isn’t available on the Pro account' }))

  const answer = await $.tool.call({ tool: 'Agent', description: 'x', prompt: 'y' })

  expect((answer as { deny?: string }).deny).toContain('Reviewer agent type')
  expect(stubs.spawned).toEqual([])
})

test("a runner that ends before the agent started is the call's error", async ($, on) => {
  const stubs = engine([$, on], '')

  const answer = await $.tool.call({ tool: 'Agent', description: 'x', prompt: 'y' })

  expect((answer as { deny?: string }).deny).toContain('ended before the agent started')
  expect(stubs.spawned).toEqual([])
})

test('a background agent whose runner dies still reports, as a failure', async ($, on) => {
  const stubs = engine([$, on], lines(STARTED, { type: 'step', text: 'Read: note.txt' }), { background: true })

  await $.tool.call({ tool: 'Agent', description: 'x', prompt: 'y' })

  await eventually(() => stubs.submitted.length > 0)
  expect(stubs.submitted[0]).toContain('<status>failed</status>')
  expect(stubs.submitted[0]).toContain('without the agent’s report')
})

test('TaskStop stops a Headroom agent on its account', async ($, on) => {
  let release = () => {}
  const gate = new Promise<void>(resolve => (release = resolve))
  const stubs = engine([$, on], lines(STARTED, { type: 'result', text: 'Stopped.', isError: true, stopped: true }),
                       { background: true, gate, outputs: { '--agent-stop': lines({ type: 'stopped' }) } })
  await $.tool.call({ tool: 'Agent', description: 'long task', prompt: 'y' })

  const answer = await $.tool.call({ tool: 'TaskStop', task_id: AGENT_ID })
  release()

  expect(stubs.argvs.find(a => a[1] === '--agent-stop')?.[2]).toBe(AGENT_ID)
  expect((answer.result as { task_id: string }).task_id).toBe(AGENT_ID)
  expect(stubs.reachedEngine).toEqual(['Agent'])
  await new Promise(resolve => setTimeout(resolve, 50))
  // Stopped is TaskStop's own answer: no failure notification follows.
  expect(stubs.submitted).toEqual([])
  const listed = await $.tool.call({ tool: 'ListAgents' })
  expect((listed.result as { listing: string }).listing).toContain(`${AGENT_ID} · long task · stopped · on Pro`)
})

test('TaskStop for a built-in task goes to the engine', async ($, on) => {
  const stubs = engine([$, on], '')

  await $.tool.call({ tool: 'TaskStop', task_id: 'b2sp5yayl' })

  expect(stubs.reachedEngine).toEqual(['TaskStop'])
})

test('ListAgents lists Headroom agents beside the built-in ones', async ($, on) => {
  let release = () => {}
  const gate = new Promise<void>(resolve => (release = resolve))
  const stubs = engine([$, on], lines(STARTED, RESULT), { background: true, gate })
  await $.tool.call({ tool: 'Agent', description: 'reverse the note', prompt: 'y' })

  const answer = await $.tool.call({ tool: 'ListAgents' })
  release()
  await eventually(() => stubs.submitted.length > 0)

  const result = answer.result as { listing: string; sections: { kind: string; rows: { id: string }[] }[] }
  expect(result.listing).toContain('built-in task')
  expect(result.listing).toContain(`${AGENT_ID} · reverse the note · running · on Pro`)
  expect(result.sections.find(s => s.kind === 'headroom')?.rows[0]?.id).toBe(AGENT_ID)
})

test('a failed self-test stays in the status line', async ($, on) => {
  const stubs = engine([$, on], '', { outputs: {
    '--agent-selftest': lines({ type: 'failed', version: '2.2.0 (Claude Code)', step: 'continue', text: 'No conversation found' }),
  } })
  on('command.register', () => ({ value: undefined }))
  on('session.start', (_, e) => e)

  await $.session.start({ cwd: '/work' } as never)

  await eventually(() => stubs.statuses.some(t => t?.includes('broken')))
  expect(stubs.statuses.at(-1)).toContain('broken on Claude Code 2.2.0 (Claude Code) (continue: No conversation found)')
})

// Headroom's own agents: `--agent-catalog` lists them, the plugin registers them as agent types.

const CATALOG = lines({ revision: 3, agents: [
  { name: 'codex-deep', description: 'Second opinion on hard bugs.', provider: 'codex', summary: 'Codex · gpt-6.1-sol · high', prompt: 'You are codex-deep.' },
] })
const CODEX_STARTED = { ...STARTED, account: 'Codex', model: 'gpt-6.1-sol', provider: 'codex' }

/** Stands in for registering agent types; `catalog` is what `--agent-catalog` answers, read on each call. */
function withCatalog(registered: { name: string; description: string }[], catalog = () => CATALOG) {
  return (on: Body[1]): Record<string, string> => {
    on('agent.register', (_, e) => {
      registered.push({ name: e.name, description: e.description })
      return { value: { agent: `headroom:${e.name}` } }
    })
    on('agent.offer', () => ({ isOffered: true }))
    on('classic.UserPromptSubmit', () => ({}))
    return { get '--agent-catalog'() { return catalog() } }
  }
}

test("a prompt registers Headroom's enabled agents as agent types, saying where each runs", async ($, on) => {
  const registered: { name: string; description: string }[] = []
  const outputs = withCatalog(registered)(on)
  engine([$, on], '', { outputs })

  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  await $.classic.UserPromptSubmit({ prompt: 'again' } as never)

  // The same revision twice registers once.
  expect(registered).toEqual([{ name: 'codex-deep', description: 'Second opinion on hard bugs. (Runs on Codex · gpt-6.1-sol · high, with Headroom.)' }])
  expect((await $.agent.offer({ agent: 'headroom:codex-deep', description: '', source: 'plugin', provider: {} } as never)).isOffered).not.toBe(false)
  expect((await $.agent.offer({ agent: 'headroom:gone', description: '', source: 'plugin', provider: {} } as never)).isOffered).toBe(false)
})

test("a Headroom agent runs on its provider, and the runner is told which agent it is", async ($, on) => {
  const registered: { name: string; description: string }[] = []
  const outputs = withCatalog(registered)(on)
  const stubs = engine([$, on], lines(CODEX_STARTED, { ...RESULT, account: 'Codex', model: 'gpt-6.1-sol' }), { background: true, outputs })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)

  const answer = await $.tool.call({ tool: 'Agent', description: 'hunt the bug', prompt: 'Why does it crash?', subagent_type: 'headroom:codex-deep' })

  expect(stubs.spawned).toEqual([])
  expect((answer.result as { status: string }).status).toBe('async_launched')
  const run = stubs.argvs.findIndex(argv => argv[1] === '--agent-run')
  expect(JSON.parse(stubs.requests[run] ?? '{}').agent).toBe('headroom:codex-deep')
  await eventually(() => stubs.submitted.length > 0)
  expect(stubs.submitted[0]).toContain('ran on Codex with Headroom')
})

test("a Headroom agent its provider can't take is the call's error, never a built-in agent", async ($, on) => {
  const registered: { name: string; description: string }[] = []
  const outputs = withCatalog(registered)(on)
  const stubs = engine([$, on], lines({ type: 'no_room' }), { outputs })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)

  const answer = await $.tool.call({ tool: 'Agent', description: 'hunt', prompt: 'x', subagent_type: 'headroom:codex-deep' })

  expect(stubs.spawned).toEqual([])
  expect(answer.deny).toContain('headroom:codex-deep')
})

test("a Headroom agent that isn't enabled is the call's error", async ($, on) => {
  const registered: { name: string; description: string }[] = []
  const outputs = withCatalog(registered)(on)
  const stubs = engine([$, on], '', { outputs })

  const answer = await $.tool.call({ tool: 'Agent', description: 'hunt', prompt: 'x', subagent_type: 'headroom:gone' })

  expect(stubs.reachedEngine).toEqual([])
  expect(answer.deny).toContain('No agent headroom:gone is enabled in Headroom')
})

test("a Headroom agent's edited description reaches Claude beside the Agent tool's", async ($, on) => {
  const registered: { name: string; description: string }[] = []
  let catalog = CATALOG
  const outputs = withCatalog(registered, () => catalog)(on)
  engine([$, on], '', { outputs })
  on('tool.describe', (_, e) => ({ description: e.description }))
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)
  catalog = lines({ revision: 4, agents: [
    { name: 'codex-deep', description: 'Reviews migrations.', provider: 'codex', summary: 'Codex · gpt-6.1-sol', prompt: 'You are codex-deep.' },
  ] })
  await $.classic.UserPromptSubmit({ prompt: 'again' } as never)

  const described = await $.tool.describe({ tool: 'Agent', description: 'Launch a new agent.', provider: {} } as never)
  expect(described.description).toContain('Launch a new agent.')
  expect(described.description).toContain('- headroom:codex-deep: Reviews migrations. (Runs on Codex · gpt-6.1-sol, with Headroom.)')
})

test('a newly registered type runs when the current turn still has the earlier agent snapshot', async ($, on) => {
  const registered: { name: string; description: string }[] = []
  const outputs = withCatalog(registered)(on)
  const stubs = engine([$, on], lines(CODEX_STARTED, { ...RESULT, account: 'Codex' }), {
    background: false, outputs, missingType: 'headroom:codex-deep',
  })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)

  const answer = await $.tool.call({ tool: 'Agent', description: 'new agent', prompt: 'x', subagent_type: 'headroom:codex-deep' })

  expect(stubs.spawned).toEqual([])
  expect((answer.result as { content: { text: string }[] } | undefined)?.content).toEqual([{ type: 'text', text: 'olleh' }])
})


test('a permission refusal is never recovered as a stale agent listing', async ($, on) => {
  const registered: { name: string; description: string }[] = []
  const outputs = withCatalog(registered)(on)
  const stubs = engine([$, on], lines(CODEX_STARTED, RESULT), { outputs, refusal: 'Agent denied by a permission rule.' })
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)

  const answer = await $.tool.call({ tool: 'Agent', description: 'denied agent', prompt: 'x', subagent_type: 'headroom:codex-deep' })

  expect(answer.deny).toBe('Agent denied by a permission rule.')
  expect(stubs.argvs.some(argv => argv[1] === '--agent-run')).toBe(false)
})

test('the Agent tool describes newly added types before the engine announces them', async ($, on) => {
  const registered: { name: string; description: string }[] = []
  const outputs = withCatalog(registered)(on)
  engine([$, on], '', { outputs })
  on('tool.describe', (_, e) => ({ description: e.description }))
  await $.classic.UserPromptSubmit({ prompt: 'hi' } as never)

  const described = await $.tool.describe({ tool: 'Agent', description: 'Launch a new agent.', provider: {} } as never)

  expect(described.description).toContain('- headroom:codex-deep: Second opinion on hard bugs. (Runs on Codex · gpt-6.1-sol · high, with Headroom.)')
})
