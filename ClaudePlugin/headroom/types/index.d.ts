/** A subagent Headroom runs on another Claude account. */
export type RemoteAgent = {
  id: string
  description: string
  account: string
  model: string
  status: 'running' | 'done' | 'failed'
  /** The steps it took, newest last ("Read: note.txt"). */
  steps: string[]
  startedAt: number
  endedAt?: number
  /** SendMessage text that arrived while it ran, sent once it finishes. */
  pending: string[]
}

declare module 'claude-code' {
  interface PluginState {
    headroom: { agents: RemoteAgent[]; paneShown: boolean }
  }
}
