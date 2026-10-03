import { ApiError, type QuizApi } from './api'
import type { Db } from './db'
import type { AttemptDto, LocalQuestion, SessionData, SessionDto, StateDto } from './types'

export interface SyncReport {
  questionsUpdated: number
  questionsRemoved: number
  attemptsUploaded: number
  statesUploaded: number
  statesPulled: number
  /** Saved quizzes taken from another device. */
  sessionsPulled: number
}

export function summarize(r: SyncReport): string {
  const parts = [
    r.questionsUpdated > 0 && `新增/更新 ${r.questionsUpdated} 题`,
    r.questionsRemoved > 0 && `下线 ${r.questionsRemoved} 题`,
    r.attemptsUploaded > 0 && `上传 ${r.attemptsUploaded} 条作答`,
    r.sessionsPulled > 0 && `同步了 ${r.sessionsPulled} 个题库的刷题进度`,
  ].filter(Boolean)
  return parts.length ? parts.join('，') : '已是最新'
}

const QUESTION_CURSOR = 'question_seq'
const STATE_CURSOR = 'state_seq'
const SESSION_CURSOR = 'session_seq'
const LAST_SYNC = 'last_sync_at'
const BATCH = 500
const SESSION_BATCH = 50 // the server's per-request limit

/**
 * Uploads the outbox, then pulls server changes. Uploading first means a device
 * never loses local progress to a stale pull.
 */
export class SyncService {
  constructor(
    private readonly db: Db,
    private readonly api: QuizApi,
    private readonly now: () => number = Date.now,
    private readonly deviceId = '',
  ) {}

  async lastSync(): Promise<number | null> {
    return (await this.db.get('meta', LAST_SYNC)) ?? null
  }

  async run(): Promise<SyncReport> {
    const attemptsUploaded = await this.pushAttempts()
    await this.pushFlags()
    const statesUploaded = await this.pushStates()
    await this.pushSessions()
    const banks = await this.api.banks()
    const [questionsUpdated, questionsRemoved] = await this.pullQuestions()
    const statesPulled = await this.pullStates()
    // After the states: a restored quiz shows its answers from the local state rows.
    const sessionsPulled = await this.pullSessions()

    const tx = this.db.transaction(['banks', 'meta'], 'readwrite')
    await tx.objectStore('banks').clear()
    for (const b of banks) await tx.objectStore('banks').put(b)
    await tx.objectStore('meta').put(this.now(), LAST_SYNC)
    await tx.done
    return { questionsUpdated, questionsRemoved, attemptsUploaded, statesUploaded, statesPulled, sessionsPulled }
  }

  private async pushAttempts(): Promise<number> {
    let total = 0
    for (;;) {
      const rows = (await this.db.getAllFromIndex('attempts', 'synced', 0)).sort(
        (a, b) => a.answered_at - b.answered_at,
      )
      const batch = rows.slice(0, BATCH)
      if (batch.length === 0) return total
      const dtos: AttemptDto[] = batch.map(({ synced: _s, ...dto }) => dto)
      await this.api.uploadAttempts(dtos)
      const tx = this.db.transaction('attempts', 'readwrite')
      for (const r of batch) await tx.store.put({ ...r, synced: 1 })
      await tx.done
      total += batch.length
    }
  }

  private async pushFlags() {
    for (const f of await this.db.getAll('flags')) {
      try {
        await this.api.flagQuestion(f.question_id)
      } catch (e) {
        // A question the server no longer knows cannot be flagged; drop the report.
        if (!(e instanceof ApiError) || e.status !== 404) throw e
      }
      await this.db.delete('flags', f.question_id)
    }
  }

  private async pushStates(): Promise<number> {
    let total = 0
    for (;;) {
      const batch = (await this.db.getAllFromIndex('states', 'dirty', 1)).slice(0, BATCH)
      if (batch.length === 0) return total
      const dtos: StateDto[] = batch.map(({ dirty: _d, ...dto }) => dto)
      await this.api.uploadStates(dtos)
      // Clear the flag only if the row was not edited while the upload was in flight.
      const tx = this.db.transaction('states', 'readwrite')
      for (const r of batch) {
        const cur = await tx.store.get(r.question_id)
        if (cur && cur.updated_at === r.updated_at) await tx.store.put({ ...cur, dirty: 0 })
      }
      await tx.done
      total += batch.length
    }
  }

  /**
   * A server without the sessions endpoint answers 404. Progress sync is a
   * convenience, so that must not fail the rest of the sync.
   */
  private static unsupported(e: unknown): boolean {
    return e instanceof ApiError && e.status === 404
  }

  private async pushSessions() {
    try {
      for (;;) {
        const batch = (await this.db.getAllFromIndex('sessions', 'dirty', 1)).slice(0, SESSION_BATCH)
        if (batch.length === 0) return
        const dtos: SessionDto[] = batch.map((r) => ({
          scope: r.scope,
          data: r.data,
          updated_at: r.updated_at,
          device_id: this.deviceId,
        }))
        await this.api.uploadSessions(dtos)
        // Clear the flag only if the quiz did not change while the upload was in flight.
        const tx = this.db.transaction('sessions', 'readwrite')
        for (const r of batch) {
          const cur = await tx.store.get(r.scope)
          if (cur && cur.updated_at === r.updated_at) await tx.store.put({ ...cur, dirty: 0 })
        }
        await tx.done
      }
    } catch (e) {
      if (!SyncService.unsupported(e)) throw e
    }
  }

  /** Last-writer-wins on updated_at, so a newer local quiz survives the pull. Returns how many were taken. */
  private async pullSessions(): Promise<number> {
    let pulled = 0
    let cursor = (await this.db.get('meta', SESSION_CURSOR)) ?? 0
    try {
      for (;;) {
        const page = await this.api.syncSessions(cursor, SESSION_BATCH)
        const tx = this.db.transaction(['sessions', 'meta'], 'readwrite')
        for (const s of page.items) {
          const local = await tx.objectStore('sessions').get(s.scope)
          if (local && local.updated_at >= s.updated_at) continue
          if (s.data !== null && !isSessionData(s.data)) continue // a document this version cannot read
          await tx.objectStore('sessions').put({ scope: s.scope, data: s.data, updated_at: s.updated_at, dirty: 0 })
          pulled++
        }
        await tx.objectStore('meta').put(page.next_seq, SESSION_CURSOR)
        await tx.done
        cursor = page.next_seq
        if (!page.has_more) return pulled
      }
    } catch (e) {
      if (!SyncService.unsupported(e)) throw e
      return pulled
    }
  }

  /** Returns [updated, removed]. */
  private async pullQuestions(): Promise<[number, number]> {
    let updated = 0
    let removed = 0
    let cursor = (await this.db.get('meta', QUESTION_CURSOR)) ?? 0
    for (;;) {
      const page = await this.api.syncQuestions(cursor, BATCH)
      const tx = this.db.transaction(['questions', 'meta'], 'readwrite')
      for (const q of page.items) {
        const row: LocalQuestion = { ...q, hidden: false }
        await tx.objectStore('questions').put(row)
      }
      for (const id of page.deleted) {
        const q = await tx.objectStore('questions').get(id)
        if (q) await tx.objectStore('questions').put({ ...q, hidden: true })
      }
      await tx.objectStore('meta').put(page.next_seq, QUESTION_CURSOR)
      await tx.done
      updated += page.items.length
      removed += page.deleted.length
      cursor = page.next_seq
      if (!page.has_more) return [updated, removed]
    }
  }

  /** Last-writer-wins on updated_at, so a newer local edit survives the pull. */
  private async pullStates(): Promise<number> {
    let pulled = 0
    let cursor = (await this.db.get('meta', STATE_CURSOR)) ?? 0
    for (;;) {
      const page = await this.api.syncStates(cursor, BATCH)
      const tx = this.db.transaction(['states', 'meta'], 'readwrite')
      for (const s of page.items) {
        const local = await tx.objectStore('states').get(s.question_id)
        if (local && local.updated_at >= s.updated_at) continue
        await tx.objectStore('states').put({
          question_id: s.question_id,
          fsrs: s.fsrs ?? null,
          due_at: s.due_at ?? null,
          favorite: s.favorite,
          wrong_count: s.wrong_count,
          updated_at: s.updated_at,
          dirty: 0,
        })
        pulled++
      }
      await tx.objectStore('meta').put(page.next_seq, STATE_CURSOR)
      await tx.done
      cursor = page.next_seq
      if (!page.has_more) return pulled
    }
  }
}

function isSessionData(d: unknown): d is SessionData {
  if (typeof d !== 'object' || d === null) return false
  const x = d as Record<string, unknown>
  return (
    typeof x.title === 'string' &&
    Array.isArray(x.ids) &&
    x.ids.length > 0 &&
    x.ids.every((i) => typeof i === 'string') &&
    typeof x.seed === 'number' &&
    typeof x.index === 'number' &&
    typeof x.answers === 'object' &&
    x.answers !== null
  )
}
