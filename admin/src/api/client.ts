import axios, { AxiosError } from 'axios'
import type {
  AIConfig, AIConfigUpdate, AINotePage, Bank, BulkResult, DocumentContent, DocumentDetail, DocumentRow, ImportResult, Job, LlmConfig, LlmLimits, LlmModel,
  LlmModelInput, LlmProvider, LlmProviderInput, LlmRole, MediaView, ModelTestResult, QuestionDetail, QuestionEdit, QuestionPage, Question, UsageCallPage, UsageRow,
} from './types'

const TOKEN_KEY = 'quizmind.token'

export function loadToken(): string {
  try {
    return localStorage.getItem(TOKEN_KEY) ?? ''
  } catch {
    return '' // storage can be blocked; the app still works for loopback servers
  }
}

export function saveToken(token: string) {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token)
    else localStorage.removeItem(TOKEN_KEY)
  } catch {
    /* ignore */
  }
}

let token = loadToken()
let onUnauthorized: () => void = () => {}

export function setToken(t: string) {
  token = t
  saveToken(t)
}
export function getToken() {
  return token
}
export function setUnauthorizedHandler(fn: () => void) {
  onUnauthorized = fn
}

const http = axios.create({ timeout: 30_000 })

http.interceptors.request.use((cfg) => {
  if (token) cfg.headers.set('Authorization', `Bearer ${token}`)
  return cfg
})

http.interceptors.response.use(
  (r) => r,
  (err: AxiosError) => {
    if (err.response?.status === 401) onUnauthorized()
    return Promise.reject(err)
  },
)

/** Human-readable message from a failed request. */
export function errorMessage(e: unknown): string {
  if (axios.isAxiosError(e)) {
    const data = e.response?.data as { error?: string } | undefined
    if (data?.error) return data.error
    if (e.code === 'ERR_NETWORK') return '无法连接到服务端'
    return e.message
  }
  return e instanceof Error ? e.message : String(e)
}

const get = <T>(url: string, params?: Record<string, unknown>) =>
  http.get<T>(url, { params }).then((r) => r.data)
const put = <T>(url: string, body?: unknown) => http.put<T>(url, body).then((r) => r.data)
const post = <T>(url: string, body?: unknown) => http.post<T>(url, body).then((r) => r.data)
const del = (url: string) => http.delete(url).then(() => undefined)

export const api = {
  /** Cheap authenticated call used to check whether the stored token works. */
  probe: () => get<Bank[]>('/admin/banks'),

  banks: () => get<Bank[]>('/admin/banks'),
  createBank: (title: string, description: string) => post<Bank>('/admin/banks', { title, description }),

  documents: () => get<DocumentRow[]>('/admin/documents'),
  document: (id: string) => get<DocumentDetail>(`/admin/documents/${id}`),
  documentContent: (id: string) => get<DocumentContent>(`/admin/documents/${id}/content`),
  retryDocument: (id: string) => post<{ requeued: number }>(`/admin/documents/${id}/retry`),
  upload: (bankId: string, file: File) => {
    const form = new FormData()
    form.append('bank_id', bankId)
    form.append('file', file)
    return http.post<ImportResult>('/admin/documents', form).then((r) => r.data)
  },

  /** Uploads a picture for use in a question; the same bytes always give the same id. */
  uploadMedia: (file: File | Blob) => {
    const form = new FormData()
    form.append('file', file)
    return http.post<MediaView>('/admin/media', form).then((r) => r.data)
  },

  jobs: (params: { status?: string; document_id?: string; limit?: number } = {}) =>
    get<Job[]>('/admin/jobs', params),
  retryJob: (id: string) => post<void>(`/admin/jobs/${id}/retry`),

  questions: (params: { status?: string; bank_id?: string; document_id?: string; flagged?: 1; source?: 'agent'; search?: string; limit?: number; offset?: number }) =>
    get<QuestionPage>('/admin/questions', params),
  question: (id: string) => get<QuestionDetail>(`/admin/questions/${id}`),
  editQuestion: (id: string, edit: QuestionEdit) =>
    http.patch<QuestionDetail>(`/admin/questions/${id}`, edit).then((r) => r.data),
  approve: (id: string) => post<Question>(`/admin/questions/${id}/approve`),
  reject: (id: string, note: string) => post<Question>(`/admin/questions/${id}/reject`, { note }),
  dismissFlags: (id: string) => post<Question>(`/admin/questions/${id}/dismiss-flags`),
  bulk: (action: 'approve' | 'reject', ids: string[], note = '') =>
    post<BulkResult>('/admin/questions/bulk', { action, ids, note }),

  usage: (days: number) => get<UsageRow[]>('/admin/usage', { days }),
  usageCalls: (params: { days: number; source?: string; role?: string; failed?: 1; limit?: number; offset?: number }) =>
    get<UsageCallPage>('/admin/usage/calls', params),

  aiConfig: () => get<AIConfig>('/admin/ai'),
  saveAIConfig: (c: AIConfigUpdate) => put<AIConfig>('/admin/ai', c),

  llm: () => get<LlmConfig>('/admin/llm'),
  createProvider: (p: LlmProviderInput) => post<LlmProvider>('/admin/llm/providers', p),
  updateProvider: (id: string, p: LlmProviderInput) => put<LlmProvider>(`/admin/llm/providers/${id}`, p),
  deleteProvider: (id: string) => del(`/admin/llm/providers/${id}`),
  createModel: (m: LlmModelInput) => post<LlmModel>('/admin/llm/models', m),
  updateModel: (id: string, m: LlmModelInput) => put<LlmModel>(`/admin/llm/models/${id}`, m),
  deleteModel: (id: string) => del(`/admin/llm/models/${id}`),
  testModel: (id: string) => post<ModelTestResult>(`/admin/llm/models/${id}/test`),
  saveRoles: (roles: Partial<Record<LlmRole, string>>) => put<LlmConfig>('/admin/llm/roles', roles),
  saveLimits: (l: LlmLimits) => put<LlmConfig>('/admin/llm/limits', l),

  aiNotes: (params: { bank_id?: string; search?: string; limit?: number; offset?: number }) =>
    get<AINotePage>('/admin/ai/notes', params),
}
