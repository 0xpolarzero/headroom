/** One entry of a remote agent's transcript: what it said, a tool call, a tool's result. */
export type TranscriptItem =
  | { kind: 'text'; text: string }
  | { kind: 'tool'; id: string; summary: string; input: string }
  | { kind: 'result'; id: string; text: string; isError: boolean }

/** A subagent Headroom runs on another Claude account. */
export type RemoteAgent = {
  id: string
  description: string
  account: string
  model: string
  status: 'running' | 'done' | 'failed'
  /** The steps it took, newest last ("Read: note.txt"). */
  steps: string[]
  /** Its transcript so far, newest last, long texts cut. */
  items: TranscriptItem[]
  /** Its final answer, once it finished. */
  result?: string
  /** The Agent call it answered: its row in the session's transcript. */
  toolUseId?: string
  startedAt: number
  endedAt?: number
  /** SendMessage text that arrived while it ran, sent once it finishes. */
  pending: string[]
  /** Its Agent call is waiting for its report, as for a built-in foreground agent. */
  foreground?: boolean
}

declare module 'claude-code' {
  interface PluginState {
    headroom: { agents: RemoteAgent[]; paneShown: boolean; open: string[] }
  }
}
