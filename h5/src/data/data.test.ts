import { beforeEach, describe, expect, it } from 'vitest'
import { newUlid } from '@/core/ulid'
import { ApiError } from './api'
import type { Db } from './db'
import { inWrongBook, isCorrect, readProgress } from './progress'
import { Repo } from './repo'
import { SyncService } from './sync'
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
      await repo.flagQuestion('q1')
      expect(await repo.bankQuestions('b1')).toHaveLength(0)
      await sync.run()
      expect(api.flagged).toEqual(['q1'])
      expect(await db.count('flags')).toBe(0)

      await repo.flagQuestion('gone')
      api.flagError = new ApiError('not found', 404)
      await sync.run()
      expect(await db.count('flags')).toBe(0)
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
})
