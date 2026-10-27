import { expect, test } from 'claude-code/testing'

// Each test stands in for the engine beneath the plugin and for Headroom's runner: `process.spawn`
// answers with the JSON lines `Headroom --agent-run` writes.

const AGENT_ID = '122651c3-88a7-4bf2-b4b0-2c3b5ade7404'

function lines(...objects: object[]): string {
  return objects.map(o => JSON.stringify(o)).join('\n') + '\n'
}

type Stubs = { requests: string[]; argvs: string[][]; submitted: string[]; reachedEngine: string[]; spawned: string[] }

/**
 * `background` is what the engine decides for the agent (its definition, settings), as `agent.spawn`
 * carries it. `gate`, when given, holds the runner's output after its first line until it resolves.
 */
type Options = { background?: boolean; gate?: Promise<void> }

type Body = Parameters<typeof test>[1] extends infer B ? (B extends (...args: infer A) => unknown ? A : never) : never

function engine([$test, on]: Body, runnerOutput: string, options: Options = {}): Stubs {
  const stubs: Stubs = { requests: [], argvs: [], submitted: [], reachedEngine: [], spawned: [] }
  on('fs.exists', () => ({ value: true }))
  on('session.cwd', () => ({ value: '/work' }))
  on('session.model', () => ({ value: 'claude-fable-5-1' }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.status', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.invalidate', () => ({ value: undefined }))
  on('prompt.submit', (_, e) => {
    stubs.submitted.push(e.text)
    return { text: e.text }
  })
  on('process.spawn', async function* (_, e) {
    stubs.argvs.push([...e.argv])
    stubs.requests.push(e.input ?? '')
    if (runnerOutput && options.gate) {
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
      const spawn = await $test.agent.spawn({
        tool_use_id: e.tool_use_id, prompt: e.prompt, description: e.description, subagentType: 'general-purpose',
        parentModel: 'claude-fable-5-1', background: options.background ?? true, fork: false,
      } as never)
      if ('deny' in spawn && spawn.deny) return { deny: `Subagent spawn denied by a plugin: ${spawn.deny}` }
    }
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
  await eventually(() => stubs.argvs.length > 0)

  expect(stubs.argvs[0]?.[1]).toBe('--agent-warm')
  const request = JSON.parse(stubs.requests[0] ?? '{}')
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

