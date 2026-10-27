import { expect, test } from 'claude-code/testing'

// Each test stands in for the engine beneath the plugin and for Headroom's runner: `process.spawn`
// answers with the JSON lines `Headroom --agent-run` writes.

const AGENT_ID = '122651c3-88a7-4bf2-b4b0-2c3b5ade7404'

function lines(...objects: object[]): string {
  return objects.map(o => JSON.stringify(o)).join('\n') + '\n'
}

type Stubs = { requests: string[]; argvs: string[][]; submitted: string[]; reachedEngine: string[] }

function engine(on: Parameters<Parameters<typeof test>[1]>[1], runnerOutput: string): Stubs {
  const stubs: Stubs = { requests: [], argvs: [], submitted: [], reachedEngine: [] }
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
    stubs.argvs.push(e.argv)
    stubs.requests.push(e.input ?? '')
    if (runnerOutput) yield { stream: 'stdout', text: runnerOutput }
    return { value: { code: 0, signal: null } }
  })
  on('tool.call', (_, e) => {
    stubs.reachedEngine.push(e.tool)
    return { result: { status: 'completed', agentId: 'built-in', content: [{ type: 'text', text: 'built-in ran' }] } }
  })
  return stubs
}

async function eventually(check: () => boolean): Promise<void> {
  for (let i = 0; i < 100 && !check(); i++) await new Promise(resolve => setTimeout(resolve, 10))
}

test('an Agent call runs on another account and reports like a background agent', async ($, on) => {
  const stubs = engine(on, lines(
    { type: 'started', agentId: AGENT_ID, account: 'Pro', model: 'claude-fable-5-1', outputFile: '/tmp/a.log' },
    { type: 'step', text: 'Read: note.txt' },
    { type: 'result', text: 'olleh', isError: false, account: 'Pro', model: 'claude-sonnet-5-5', toolUses: 1, durationMs: 11000 },
  ))

  const answer = await $.tool.call({ tool: 'Agent', description: 'reverse the note', prompt: 'Read note.txt' })

  expect(stubs.reachedEngine).toEqual([])
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

test('with no account free, the built-in subagent runs', async ($, on) => {
  const stubs = engine(on, lines({ type: 'no_room' }))

  const answer = await $.tool.call({ tool: 'Agent', description: 'x', prompt: 'y' })

  expect(stubs.reachedEngine).toEqual(['Agent'])
  expect((answer.result as { agentId: string }).agentId).toBe('built-in')
})

test('a sent prompt has Headroom get a process ready', async ($, on) => {
  const stubs = engine(on, '')
  on('classic.UserPromptSubmit', () => ({}))

  await $.classic.UserPromptSubmit({ prompt: 'hi', permission_mode: 'acceptEdits' } as never)
  await eventually(() => stubs.argvs.length > 0)

  expect(stubs.argvs[0]?.[1]).toBe('--agent-warm')
  const request = JSON.parse(stubs.requests[0] ?? '{}')
  expect(request.permissionMode).toBe('acceptEdits')
  expect(request.cwd).toBe('/work')
})

test("SendMessage to a built-in agent isn't Headroom's", async ($, on) => {
  const stubs = engine(on, lines({ type: 'no_room' }))

  await $.tool.call({ tool: 'SendMessage', to: 'aeb08a749aaadf89c', message: 'hi' })

  expect(stubs.reachedEngine).toEqual(['SendMessage'])
  expect(stubs.requests).toEqual([])
})

test('the pane shows a running agent and its steps', async ($, on) => {
  engine(on, lines(
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
  engine(on, lines(
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

