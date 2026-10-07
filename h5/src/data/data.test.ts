import { beforeEach, describe, expect, it } from 'vitest'
import { newUlid } from '@/core/ulid'
import { ApiError } from './api'
import type { Db } from './db'
import { inWrongBook, isCorrect, readProgress } from './progress'
import { Repo } from './repo'
import { SyncService } from './sync'
import type { Lesson } from './types'
import { FakeApi, freshDb, question } from '@/test-support'

describe('pure helpers', () => {
  it('ulid is 26 chars, unique and time ordered', () => {
    const a = newUlid(1000)
    const b = newUlid(2000)
    expect(a).toHaveLength(26)
    expect(a < b).toBe(true)
    expect(new Set(Array.from({ length: 200 }, () => newUlid())).size).toBe(200)
  })

  it('isCorrect compares answer sets exactly', () => {
    expect(isCorrect([1], [1])).toBe(true)
    expect(isCorrect([0], [1])).toBe(false)
    expect(isCorrect([], [1])).toBe(false)
    expect(isCorrect([0, 1], [1])).toBe(false)
  })

  it('progress record survives garbage', () => {
    expect(readProgress(null).streak).toBe(0)
    expect(readProgress({ streak: 'x' }).streak).toBe(0)
    expect(readProgress({ streak: 3 }).streak).toBe(3)
  })
})

describe('repo + sync', () => {
  let db: Db
  let api: FakeApi
  let repo: Repo
  let sync: SyncService
  let tick: number
  const clock = () => (tick += 10)

  beforeEach(async () => {
    db = await freshDb()
    api = new FakeApi()
    tick = 1000
    repo = new Repo(db, 'dev1', clock)
    sync = new SyncService(db, api, clock)
  })

  describe('pull', () => {
    it('downloads questions in pages and keeps the cursor', async () => {
      api.pageSize = 2
      api.published = [question('q1', { sync_seq: 1 }), question('q2', { sync_seq: 2 }), question('q3', { sync_seq: 3 })]
      const r = await sync.run()
      expect(r.questionsUpdated).toBe(3)
      expect((await repo.bankQuestions('b1')).map((q) => q.id)).toEqual(['q1', 'q2', 'q3'])
      const again = await sync.run()
      expect(again.questionsUpdated).toBe(0)
    })

    it('updates a changed question and hides withdrawn ones, keeping the row', async () => {
      api.published = [question('q1', { sync_seq: 1 }), question('q2', { sync_seq: 2 })]
      await sync.run()
      api.published = [question('q1', { sync_seq: 3, answer: [2] })]
      api.withdrawn = ['q2']
      const r = await sync.run()
      expect(r.questionsRemoved).toBe(1)
      const qs = await repo.bankQuestions('b1')
      expect(qs.map((q) => q.id)).toEqual(['q1'])
      expect(qs[0].answer).toEqual([2])
      expect(await db.count('questions')).toBe(2)
    })

    it('replaces the bank list and records the sync time', async () => {
      api.bankList = [{ id: 'b1', title: 'Go', description: 'd', question_count: 5 }]
      await sync.run()
      expect((await repo.banks())[0].title).toBe('Go')
      expect(await sync.lastSync()).not.toBeNull()
    })

    it('a failed call leaves local data and the outbox intact', async () => {
      api.published = [question('q1')]
      await sync.run()
      const [q] = await repo.bankQuestions('b1')
      await repo.recordAnswer(q, [0], 10)
      api.failWith = new ApiError('boom')
      await expect(sync.run()).rejects.toThrow('boom')
      expect(await repo.pendingUploads()).toBe(1)
    })
  })

  describe('answering', () => {
    beforeEach(async () => {
      api.published = [question('q1', { answer: [1] })]
      await sync.run()
    })

    it('a wrong answer enters the wrong book; two right ones in a row clear it', async () => {
      const [q] = await repo.bankQuestions('b1')
      let o = await repo.recordAnswer(q, [0], 500)
      expect(o.correct).toBe(false)
      expect(o.enteredWrongBook).toBe(true)
      expect(await repo.wrongBook()).toHaveLength(1)

      o = await repo.recordAnswer(q, [1], 500)
      expect(o.correct).toBe(true)
      expect(inWrongBook(o.state)).toBe(true)

      o = await repo.recordAnswer(q, [1], 500)
      expect(inWrongBook(o.state)).toBe(false)
      expect(await repo.wrongBook()).toHaveLength(0)
      expect(o.state.wrong_count).toBe(1)
    })

    it('a miss after progress puts it back', async () => {
      const [q] = await repo.bankQuestions('b1')
      await repo.recordAnswer(q, [0], 1)
      await repo.recordAnswer(q, [1], 1)
      await repo.recordAnswer(q, [1], 1)
      const o = await repo.recordAnswer(q, [0], 1)
      expect(o.enteredWrongBook).toBe(true)
      expect(o.state.wrong_count).toBe(2)
    })

    it('favorites and clearing the wrong book mark the state dirty', async () => {
      const [q] = await repo.bankQuestions('b1')
      await repo.setFavorite(q.id, true)
      expect(await repo.favorites()).toHaveLength(1)
      await repo.recordAnswer(q, [0], 1)
      await repo.clearFromWrongBook(q.id)
      expect(await repo.wrongBook()).toHaveLength(0)
      const s = (await repo.getState(q.id))!
      expect(s.favorite).toBe(true)
      expect(s.dirty).toBe(1)
    })

    it('wrong book and favourites can be narrowed to one bank', async () => {
      api.published = [
        question('q1', { answer: [1], sync_seq: 1 }),
        question('q2', { bank_id: 'b2', answer: [1], sync_seq: 2 }),
        question('q3', { bank_id: 'b2', answer: [1], sync_seq: 3 }),
      ]
      await sync.run()
      const q = async (id: string) => (await db.get('questions', id))!
      for (const id of ['q1', 'q2', 'q3']) await repo.recordAnswer(await q(id), [0], 1)
      await repo.setFavorite('q2', true)

      expect((await repo.wrongBook()).map((x) => x.id).sort()).toEqual(['q1', 'q2', 'q3'])
      expect((await repo.wrongBook('b2')).map((x) => x.id).sort()).toEqual(['q2', 'q3'])
      expect((await repo.wrongBook('nope'))).toEqual([])
      expect((await repo.favorites('b2')).map((x) => x.id)).toEqual(['q2'])
      expect(await repo.favorites('b1')).toEqual([])

      // Taken out of the wrong book, or withdrawn by the server: gone from the bank's list.
      await repo.clearFromWrongBook('q2')
      expect((await repo.wrongBook('b2')).map((x) => x.id)).toEqual(['q3'])
      await db.put('questions', { ...(await q('q3')), hidden: true })
      expect(await repo.wrongBook('b2')).toEqual([])
    })

    it('today\'s progress counts this local day over all banks, with the stats caps, minus withdrawn questions', async () => {
      api.published = [question('q1', { sync_seq: 1 }), question('q2', { bank_id: 'b2', sync_seq: 2 }), question('q3', { sync_seq: 3 })]
      await sync.run()
      const noon = new Date(2026, 9, 5, 12, 0).getTime()
      const put = (id: string, question_id: string, answered_at: number, o: Record<string, unknown> = {}) =>
        db.put('attempts', { id, question_id, device_id: 'other', answer: [0], is_correct: true, duration_ms: 30_000, answered_at, synced: 1, ...o } as never)
      await put('a1', 'q1', noon - 3600_000, { duration_ms: 30_000, review_ms: 20_000 })
      await put('a2', 'q2', noon, { duration_ms: 10 * 60_000, review_ms: 60 * 60_000 }) // another bank, another device; capped to 2 + 3 min
      await put('a3', 'q1', new Date(2026, 9, 5, 0, 0, 0).getTime()) // midnight today counts
      await put('a4', 'q1', new Date(2026, 9, 4, 23, 59, 59).getTime()) // yesterday does not
      await put('a5', 'q1', new Date(2026, 9, 6, 0, 0, 0).getTime()) // tomorrow does not
      await put('a6', 'q3', noon)
      await db.put('questions', { ...(await db.get('questions', 'q3'))!, hidden: true })
      await put('a7', 'gone', noon) // a question this device never had

      const p = await repo.todayProgress(noon)
      expect(p.questions).toBe(3)
      expect(p.ms).toBe(50_000 + (2 + 3) * 60_000 + 30_000)
      expect(await repo.todayProgress(new Date(2026, 9, 4, 12, 0).getTime())).toMatchObject({ questions: 1 })
      expect(await repo.todayProgress(new Date(2026, 9, 10, 12, 0).getTime())).toEqual({ questions: 0, ms: 0 })
    })

    it('bank stats use the latest attempt per question', async () => {
      const [q] = await repo.bankQuestions('b1')
      await repo.recordAnswer(q, [0], 1)
      expect(await repo.bankStats('b1')).toEqual({ total: 1, answered: 1, correct: 0 })
      await repo.recordAnswer(q, [1], 1)
      expect(await repo.bankStats('b1')).toEqual({ total: 1, answered: 1, correct: 1 })
      expect([...(await repo.answeredIds(['q1', 'zzz']))]).toEqual(['q1'])
    })
  })

  describe('push', () => {
    beforeEach(async () => {
      api.published = [question('q1', { answer: [1] })]
      await sync.run()
    })

    it('uploads attempts and states once, then the outbox is empty', async () => {
      const [q] = await repo.bankQuestions('b1')
      await repo.recordAnswer(q, [0], 800)
      const r = await sync.run()
      expect(r.attemptsUploaded).toBe(1)
      expect(r.statesUploaded).toBe(1)

      const a = api.uploadedAttempts[0]
      expect(a.device_id).toBe('dev1')
      expect(a.answer).toEqual([0])
      expect(a.is_correct).toBe(false)
      expect(a.id).toHaveLength(26)
      expect('synced' in a).toBe(false)
      const s = api.uploadedStates[0]
      expect(s.wrong_count).toBe(1)
      expect(s.fsrs?.streak).toBe(0)
      expect('dirty' in s).toBe(false)

      await sync.run()
      expect(api.uploadedAttempts).toHaveLength(1)
      expect(api.uploadedStates).toHaveLength(1)
    })

    it('a pending flag is uploaded then dropped; a 404 is tolerated', async () => {
      await repo.flagQuestion('q1', 'wrong_answer')
      expect(await repo.bankQuestions('b1')).toHaveLength(0)
      await sync.run()
      expect(api.flagged).toEqual(['q1'])
      expect(api.flagReasons).toEqual(['wrong_answer'])
      expect(await db.count('flags')).toBe(0)

      await repo.flagQuestion('gone')
      api.flagError = new ApiError('not found', 404)
      await sync.run()
      expect(await db.count('flags')).toBe(0)
    })

    it('a report queued before reasons existed is uploaded without one', async () => {
      await db.put('flags', { question_id: 'q1', created_at: 1 })
      await sync.run()
      expect(api.flagged).toEqual(['q1'])
      expect(api.flagReasons).toEqual([undefined])
    })
  })

  describe('state pull (last writer wins)', () => {
    beforeEach(async () => {
      api.published = [question('q1')]
      await sync.run()
    })

    it('takes a newer remote state and keeps a newer local one', async () => {
      api.remoteStates = [{ question_id: 'q1', fsrs: { streak: 0 }, due_at: null, favorite: true, wrong_count: 3, updated_at: 5e12 }]
      await sync.run()
      let s = (await repo.getState('q1'))!
      expect(s.favorite).toBe(true)
      expect(s.wrong_count).toBe(3)
      expect(s.dirty).toBe(0)
      expect(inWrongBook(s)).toBe(true)

      api.remoteStates = [{ question_id: 'q1', fsrs: null, due_at: null, favorite: false, wrong_count: 0, updated_at: 1 }]
      await sync.run()
      s = (await repo.getState('q1'))!
      expect(s.favorite).toBe(true)
    })

    it('stores a state for a question we do not have', async () => {
      api.remoteStates = [{ question_id: 'other', fsrs: null, due_at: null, favorite: true, wrong_count: 0, updated_at: 42 }]
      await sync.run()
      expect(await repo.getState('other')).toBeDefined()
    })
  })

  describe('answer history and exams from other devices', () => {
    const remote = (id: string, correct: boolean, at: number) => ({
      id, question_id: 'q1', device_id: 'phone', answer: [correct ? 1 : 0], is_correct: correct, duration_ms: 900, answered_at: at,
    })
    const exam = (id: string, finished: number) => ({
      id, bank_id: 'b1', title: '题库', finished_at: finished, total: 2, correct: 1, answered: 2, percent: 50, passed: false,
      limit_sec: null, used_ms: 5000, device_id: 'phone', items: [{ q: 'q1', s: [1], c: true }, { q: 'q2', s: [0], c: false }],
    })

    beforeEach(async () => {
      api.published = [question('q1', { answer: [1] })]
      await sync.run()
    })

    it('downloads other devices\' answers once, as already uploaded, so statistics cover both', async () => {
      const [q] = await repo.bankQuestions('b1')
      await repo.recordAnswer(q, [1], 500) // this device
      api.remoteAttempts = [remote('R1', false, 1000), remote('R2', true, 2000)]
      const r = await sync.run()
      expect(r.attemptsPulled).toBe(2)
      expect((await db.get('attempts', 'R1'))!.synced).toBe(1)
      expect(await db.count('attempts')).toBe(3)
      expect((await repo.bankReport('b1')).attempts).toBe(3)
      expect(await repo.pendingUploads()).toBe(0)

      expect((await sync.run()).attemptsPulled).toBe(0) // cursor moved on
      expect(api.uploadedAttempts.map((a) => a.id)).not.toContain('R1') // never echoed back
    })

    it('an attempt this device uploaded and then receives back is not duplicated', async () => {
      const [q] = await repo.bankQuestions('b1')
      await repo.recordAnswer(q, [0], 500)
      await sync.run()
      api.remoteAttempts = api.uploadedAttempts.map((a) => ({ ...a })) // the server echoes it
      const r = await sync.run()
      expect(r.attemptsPulled).toBe(0)
      expect(await db.count('attempts')).toBe(1)
    })

    it('uploads an attempt again when reading time was added after it was synced, and keeps it queued if added mid-upload', async () => {
      const [q] = await repo.bankQuestions('b1')
      const { attemptId } = await repo.recordAnswer(q, [1], 500)
      await sync.run()
      expect(api.uploadedAttempts).toHaveLength(1)
      expect(api.uploadedAttempts[0].review_ms ?? null).toBeNull()

      await repo.addReviewTime(attemptId!, 7000)
      await repo.addReviewTime(attemptId!, 3000)
      expect(await repo.pendingUploads()).toBe(1)
      await sync.run()
      expect(api.uploadedAttempts).toHaveLength(2)
      expect(api.uploadedAttempts[1]).toMatchObject({ id: attemptId, duration_ms: 500, review_ms: 10_000 })
      expect(await repo.pendingUploads()).toBe(0)

      // Reading time that arrives while the upload is in flight must not be marked as sent.
      const upload = api.uploadAttempts.bind(api)
      api.uploadAttempts = async (a) => {
        await repo.addReviewTime(attemptId!, 1000)
        await upload(a)
      }
      await repo.addReviewTime(attemptId!, 500)
      await sync.run()
      expect(await repo.pendingUploads()).toBe(1)
      expect((await db.get('attempts', attemptId!))!.review_ms).toBe(11_500)
    })

    it('takes a larger review time from the server for an attempt it already has, without counting it as new', async () => {
      const [q] = await repo.bankQuestions('b1')
      const { attemptId } = await repo.recordAnswer(q, [1], 500)
      await repo.addReviewTime(attemptId!, 2000)
      await sync.run()
      api.remoteAttempts = [{ ...api.uploadedAttempts[0], review_ms: 9000 }]
      const r = await sync.run()
      expect(r.attemptsPulled).toBe(0)
      expect((await db.get('attempts', attemptId!))!.review_ms).toBe(9000)
      api.remoteAttempts = [{ ...api.uploadedAttempts[0], review_ms: 1000 }, { ...api.uploadedAttempts[0], review_ms: 1000 }]
      await sync.run()
      expect((await db.get('attempts', attemptId!))!.review_ms).toBe(9000) // never shrinks
    })

    it('pages through a long history', async () => {
      api.remoteAttempts = Array.from({ length: 1200 }, (_, i) => remote(`R${i}`, true, i + 1))
      const r = await sync.run()
      expect(r.attemptsPulled).toBe(1200)
    })

    it('uploads finished exams once and downloads the other devices\'', async () => {
      const [q] = await repo.bankQuestions('b1')
      await repo.submitExam({ ...exam('MINE', 3000), device_id: '' }, [{ question: q, selected: [1], durationMs: 10 }])
      expect((await db.get('exams', 'MINE'))!.synced).toBe(0)
      api.remoteExams = [exam('THEIRS', 4000)]
      sync = new SyncService(db, api, clock, 'dev1')
      const r = await sync.run()
      expect([r.examsUploaded, r.examsPulled]).toEqual([1, 1])
      expect(api.uploadedExams.map((e) => e.id)).toEqual(['MINE'])
      expect(api.uploadedExams[0].device_id).toBe('dev1') // filled in for exams saved before it was recorded
      expect('synced' in api.uploadedExams[0]).toBe(false)
      expect((await db.get('exams', 'MINE'))!.synced).toBe(1)
      expect((await repo.exams('b1')).map((e) => e.id)).toEqual(['THEIRS', 'MINE'])
      expect((await repo.exam('THEIRS'))!.items).toHaveLength(2)

      const again = await sync.run()
      expect([again.examsUploaded, again.examsPulled]).toEqual([0, 0])
    })

    it('a server without these endpoints (404) does not fail the sync', async () => {
      api.historyUnsupported = true
      const [q] = await repo.bankQuestions('b1')
      await repo.submitExam(exam('E', 1000), [{ question: q, selected: [1], durationMs: 1 }])
      const r = await sync.run()
      expect([r.attemptsPulled, r.examsPulled, r.examsUploaded]).toEqual([0, 0, 0])
      expect((await db.get('exams', 'E'))!.synced).toBe(0) // still queued for when the server can take it
    })
  })
})

describe('lessons', () => {
  let db: Db
  let api: FakeApi
  let repo: Repo
  let sync: SyncService

  const lesson = (id: string, o: Partial<Lesson> = {}): Lesson => ({
    id, bank_id: 'b1', document_id: 'd1', document_title: '讲义', document_created_at: 1, seq: 0,
    heading_path: `讲义 > ${id}`, text: `正文 ${id}`, ...o,
  })

  beforeEach(async () => {
    db = await freshDb()
    api = new FakeApi()
    repo = new Repo(db, 'dev1', () => 1000)
    sync = new SyncService(db, api)
  })

  it('downloads the study text, then skips the download while the version holds', async () => {
    api.lessonList = [lesson('L1'), lesson('L2', { seq: 1 }), lesson('X', { bank_id: 'b2' })]
    const first = await sync.run()
    expect(first.lessonsPulled).toBe(3)
    expect((await repo.lessons('b1')).map((l) => l.id)).toEqual(['L1', 'L2'])
    expect((await repo.lessons('b2')).map((l) => l.id)).toEqual(['X'])
    expect((await repo.lesson('L1'))?.text).toBe('正文 L1')

    const again = await sync.run()
    expect(again.lessonsPulled).toBe(0)
    expect(api.lessonFetches).toBe(2)
    expect((await repo.lessons('b1')).map((l) => l.id)).toEqual(['L1', 'L2'])
  })

  it('replaces the text when the server version moves, and drops sections that are gone', async () => {
    api.lessonList = [lesson('L1'), lesson('L2', { seq: 1 })]
    await sync.run()
    api.lessonList = [lesson('L1', { text: '改过了' })]
    api.lessonsVersion = 2
    expect((await sync.run()).lessonsPulled).toBe(1)
    expect((await repo.lessons('b1')).map((l) => [l.id, l.text])).toEqual([['L1', '改过了']])
  })

  it('an older server without lessons does not fail the sync', async () => {
    api.lessonsUnsupported = true
    await expect(sync.run()).resolves.toMatchObject({ lessonsPulled: 0 })
    expect(await repo.lessons('b1')).toEqual([])
  })

  it('orders sections by chapter then position, and keeps read marks per bank', async () => {
    api.lessonList = [
      lesson('B2', { document_id: 'd2', document_created_at: 20, seq: 0 }),
      lesson('A2', { seq: 1 }),
      lesson('A1', { seq: 0 }),
    ]
    await sync.run()
    expect((await repo.lessons('b1')).map((l) => l.id)).toEqual(['A1', 'A2', 'B2'])

    expect(await repo.lessonSummary('b1')).toEqual({ total: 3, read: 0 })
    await repo.markLessonRead((await repo.lesson('A1'))!)
    await repo.markLessonRead((await repo.lesson('A1'))!)
    await repo.markLessonRead((await repo.lesson('B2'))!)
    expect(await repo.lessonSummary('b1')).toEqual({ total: 3, read: 2 })
    expect([...(await repo.lessonReadIds('b1'))].sort()).toEqual(['A1', 'B2'])
    await repo.unmarkLessonRead('A1')
    expect(await repo.lessonSummary('b1')).toEqual({ total: 3, read: 1 })
    expect(await repo.lessonSummary('nope')).toEqual({ total: 0, read: 0 })

    // a section the server dropped no longer counts as read
    api.lessonList = [lesson('A1', { seq: 0 })]
    api.lessonsVersion = 2
    await sync.run()
    expect(await repo.lessonSummary('b1')).toEqual({ total: 1, read: 0 })
  })

  it('keeps the section a question came from', async () => {
    api.published = [question('q1', { chunk_id: 'L1', sync_seq: 1 })]
    await sync.run()
    expect((await repo.bankQuestions('b1'))[0].chunk_id).toBe('L1')
  })
})
