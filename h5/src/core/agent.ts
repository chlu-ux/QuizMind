import { reactive } from 'vue'
import { HttpAgentApi, type AgentApi } from '@/data/agentApi'

const TOKEN_KEY = 'quizmind.ai.token'

function read(key: string): string {
  try {
    return localStorage.getItem(key) ?? ''
  } catch {
    return ''
  }
}
function write(key: string, value: string) {
  try {
    if (value) localStorage.setItem(key, value)
    else localStorage.removeItem(key)
  } catch {
    /* private mode: keep going with in-memory state */
  }
}

/**
 * The assistant needs the access token that the admin page "AI 解读" shows (the H5 pages themselves
 * are same-origin and need none). It is kept on this device only.
 */
export const agentSettings = reactive({ token: read(TOKEN_KEY) })

export function setAgentToken(token: string) {
  agentSettings.token = token.trim()
  write(TOKEN_KEY, agentSettings.token)
}

let api: AgentApi = new HttpAgentApi(() => agentSettings.token)
export const agentApi = (): AgentApi => api
/** For tests: the assistant without a network. */
export function setAgentApi(next: AgentApi) {
  api = next
}
