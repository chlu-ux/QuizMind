import { ApiError, type QuizApi } from './api'
import type { Db } from './db'
import type { AttemptDto, ExamRecord, LocalQuestion, SessionData, SessionDto, StateDto } from './types'

export interface SyncReport {
  questionsUpdated: number
  questionsRemoved: number
  attemptsUploaded: number
  statesUploaded: number
  statesPulled: number
  /** Answers other devices gave (they count towards statistics here). */
  attemptsPulled: number
  examsUploaded: number
  examsPulled: number
  /** Saved quizzes taken from another device. */
  sessionsPulled: number
  /** Sections of the study text downloaded; 0 when the library had not changed. */
  lessonsPulled: number
}

export function summarize(r: SyncReport): string {
  const parts = [
    r.questionsUpdated > 0 && `新增/更新 ${r.questionsUpdated} 题`,
    r.questionsRemoved > 0 && `下线 ${r.questionsRemoved} 题`,
    r.attemptsUploaded > 0 && `上传 ${r.attemptsUploaded} 条作答`,
    r.attemptsPulled > 0 && `同步了其他设备的 ${r.attemptsPulled} 条作答`,
    r.examsPulled > 0 && `同步了 ${r.examsPulled} 场考试`,
    r.sessionsPulled > 0 && `同步了 ${r.sessionsPulled} 个题库的刷题进度`,
    r.lessonsPulled > 0 && `更新了讲义（${r.lessonsPulled} 节）`,
  ].filter(Boolean)
  return parts.length ? parts.join('，') : '已是最新'
}

const QUESTION_CURSOR = 'question_seq'
const STATE_CURSOR = 'state_seq'
const SESSION_CURSOR = 'session_seq'
const ATTEMPT_CURSOR = 'attempt_seq'
const EXAM_CURSOR = 'exam_seq'
const LESSONS_VERSION = 'lessons_version'
const LAST_SYNC = 'last_sync_at'
const BATCH = 500
const SESSION_BATCH = 50 // the server's per-request limit
const EXAM_BATCH = 10 // ditto

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
    const examsUploaded = await this.pushExams()
    const banks = await this.api.banks()
    const [questionsUpdated, questionsRemoved] = await this.pullQuestions()
    const statesPulled = await this.pullStates()
    // After the states: a restored quiz shows its answers from the local state rows.
    const sessionsPulled = await this.pullSessions()
    const attemptsPulled = await this.pullAttempts()
    const examsPulled = await this.pullExams()
    const lessonsPulled = await this.pullLessons()

    const tx = this.db.transaction(['banks', 'meta'], 'readwrite')
    await tx.objectStore('banks').clear()
    for (const b of banks) await tx.objectStore('banks').put(b)
    await tx.objectStore('meta').put(this.now(), LAST_SYNC)
    await tx.done
    return {
      questionsUpdated,
      questionsRemoved,
      attemptsUploaded,
      statesUploaded,
      statesPulled,
      attemptsPulled,
      examsUploaded,
      examsPulled,
      sessionsPulled,
      lessonsPulled,
    }
  }

  private async pushAttempts(): Promise<number> {
    let total = 0
    // An attempt that gains reading time mid-upload stays queued; it goes out with the next sync, not in a loop here.
    const sent = new Set<string>()
    for (;;) {
      const rows = (await this.db.getAllFromIndex('attempts', 'synced', 0))
        .filter((a) => !sent.has(a.id))
        .sort((a, b) => a.answered_at - b.answered_at)
      const batch = rows.slice(0, BATCH)
      if (batch.length === 0) return total
      const dtos: AttemptDto[] = batch.map(({ synced: _s, ...dto }) => dto)
      await this.api.uploadAttempts(dtos)
      for (const r of batch) sent.add(r.id)
      // Leave the row queued if reading time was added while the upload was in flight.
      const tx = this.db.transaction('attempts', 'readwrite')
      for (const r of batch) {
        const cur = await tx.store.get(r.id)
        if (cur && (cur.review_ms ?? 0) === (r.review_ms ?? 0)) await tx.store.put({ ...cur, synced: 1 })
      }
      await tx.done
      total += batch.length
    }
  }

  private async pushFlags() {
    for (const f of await this.db.getAll('flags')) {
      try {
        await this.api.flagQuestion(f.question_id, f.reason)
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

  private async pushExams(): Promise<number> {
    let total = 0
    try {
      for (;;) {
        const batch = (await this.db.getAllFromIndex('exams', 'synced', 0)).sort((a, b) => a.finished_at - b.finished_at).slice(0, EXAM_BATCH)
        if (batch.length === 0) return total
        const dtos: ExamRecord[] = batch.map(({ synced: _s, ...dto }) => ({ ...dto, device_id: dto.device_id || this.deviceId }))
        await this.api.uploadExams(dtos)
        const tx = this.db.transaction('exams', 'readwrite')
        for (const r of batch) await tx.store.put({ ...r, synced: 1 })
        await tx.done
        total += batch.length
      }
    } catch (e) {
      if (!SyncService.unsupported(e)) throw e
      return total
    }
  }

  /**
   * Answers of every device, so statistics cover everything. Attempts are an append-only log:
   * only unknown ids are added. The one thing a known attempt can still gain is review time.
   */
  private async pullAttempts(): Promise<number> {
    let pulled = 0
    let cursor = (await this.db.get('meta', ATTEMPT_CURSOR)) ?? 0
    try {
      for (;;) {
        const page = await this.api.syncAttempts(cursor, BATCH)
        const tx = this.db.transaction(['attempts', 'meta'], 'readwrite')
        for (const a of page.items) {
          const have = await tx.objectStore('attempts').get(a.id)
          if (have) {
            if ((a.review_ms ?? 0) > (have.review_ms ?? 0)) await tx.objectStore('attempts').put({ ...have, review_ms: a.review_ms })
            continue
          }
          await tx.objectStore('attempts').put({ ...a, synced: 1 })
          pulled++
        }
        await tx.objectStore('meta').put(page.next_seq, ATTEMPT_CURSOR)
        await tx.done
        cursor = page.next_seq
        if (!page.has_more) return pulled
      }
    } catch (e) {
      if (!SyncService.unsupported(e)) throw e
      return pulled
    }
  }

  /** Exams are immutable, so a known id is skipped. */
  private async pullExams(): Promise<number> {
    let pulled = 0
    let cursor = (await this.db.get('meta', EXAM_CURSOR)) ?? 0
    try {
      for (;;) {
        const page = await this.api.syncExams(cursor, EXAM_BATCH)
        const tx = this.db.transaction(['exams', 'meta'], 'readwrite')
        for (const e of page.items) {
          if (await tx.objectStore('exams').get(e.id)) continue
          await tx.objectStore('exams').put({ ...e, synced: 1 })
          pulled++
        }
        await tx.objectStore('meta').put(page.next_seq, EXAM_CURSOR)
        await tx.done
        cursor = page.next_seq
        if (!page.has_more) return pulled
      }
    } catch (e) {
      if (!SyncService.unsupported(e)) throw e
      return pulled
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

  /**
   * The study text is small and rarely changes, so it is fetched whole whenever the server's version
   * differs from ours, and replaces what we had. Returns how many sections came down.
   */
  private async pullLessons(): Promise<number> {
    try {
      const have = (await this.db.get('meta', LESSONS_VERSION)) ?? 0
      const page = await this.api.lessons(have)
      if (page.unchanged) return 0
      const tx = this.db.transaction(['lessons', 'meta'], 'readwrite')
      await tx.objectStore('lessons').clear()
      for (const l of page.items) await tx.objectStore('lessons').put(l)
      await tx.objectStore('meta').put(page.version, LESSONS_VERSION)
      await tx.done
      return page.items.length
    } catch (e) {
      // A server from before lessons: there is simply nothing to read.
      if (!SyncService.unsupported(e)) throw e
      return 0
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
