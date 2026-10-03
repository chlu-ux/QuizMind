import { reactive, ref } from 'vue'
import { HttpApi } from '@/data/api'
import { openDb } from '@/data/db'
import { Repo } from '@/data/repo'
import { ApiError } from '@/data/api'
import { summarize, SyncService } from '@/data/sync'
import { newUlid } from './ulid'

const DEVICE_KEY = 'quizmind.device'

function read(key: string): string {
  try {
    return localStorage.getItem(key) ?? ''
  } catch {
    return ''
  }
}
function write(key: string, value: string) {
  try {
    localStorage.setItem(key, value)
  } catch {
    /* private mode: keep going with in-memory state */
  }
}

let device = read(DEVICE_KEY)
if (!device) {
  device = newUlid()
  write(DEVICE_KEY, device)
}

export const settings = reactive({ deviceId: device })

/** Bumped after every write or sync so views know to reload what they show. */
export const dataVersion = ref(0)
export const bump = () => dataVersion.value++

export const syncStatus = reactive({
  running: false,
  message: '' as string,
  isError: false,
  lastSync: null as number | null,
})

let repoPromise: Promise<Repo> | null = null
export function getRepo(): Promise<Repo> {
  repoPromise ??= openDb().then((db) => new Repo(db, settings.deviceId))
  return repoPromise
}

const api = new HttpApi()

/** Runs a full sync. Failures land in syncStatus, never thrown, so the app keeps working offline. */
export async function runSync(): Promise<void> {
  if (syncStatus.running) return
  syncStatus.running = true
  syncStatus.message = ''
  try {
    const repo = await getRepo()
    const svc = new SyncService(repo.db, api, Date.now, settings.deviceId)
    const report = await svc.run()
    syncStatus.message = summarize(report)
    syncStatus.isError = false
    syncStatus.lastSync = await svc.lastSync()
    bump()
  } catch (e) {
    syncStatus.isError = true
    syncStatus.message = e instanceof ApiError ? e.message : `同步失败：${(e as Error).message}`
  } finally {
    syncStatus.running = false
  }
}

export async function loadLastSync() {
  const repo = await getRepo()
  syncStatus.lastSync = await new SyncService(repo.db, api).lastSync()
}

export async function testConnection(): Promise<number> {
  const banks = await api.banks()
  return banks.length
}

export function formatTime(t: number | null): string {
  if (!t) return '从未同步'
  const d = new Date(t)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getMonth() + 1}月${d.getDate()}日 ${p(d.getHours())}:${p(d.getMinutes())}`
}

// ---- toast ----
export const toast = reactive({ text: '', error: false, seq: 0 })
let toastTimer: ReturnType<typeof setTimeout> | undefined
export function showToast(text: string, error = false) {
  toast.text = text
  toast.error = error
  toast.seq++
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => (toast.text = ''), 2600)
}
