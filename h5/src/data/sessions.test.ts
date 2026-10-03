import { beforeEach, describe, expect, it } from 'vitest'
import { ApiError } from './api'
import { Repo } from './repo'
import { SyncService } from './sync'
import type { SessionData } from './types'
import { FakeApi, freshDb } from '@/test-support'

const doc = (over: Partial<SessionData> = {}): SessionData => ({
  title: '软件设计师',
  ids: ['q1', 'q2', 'q3'],
  seed: 11,
  index: 0,
  answers: {},
  ...over,
})

describe('saved quizzes', () => {
  let api: FakeApi
  let tick: number
  const clock = () => (tick += 10)

  /** One device: its own database, like a separate phone or browser. */
  async function device(id: string) {
    const db = await freshDb()
    return { repo: new Repo(db, id, clock), sync: new SyncService(db, api, clock, id), db }
  }

  beforeEach(() => {
    api = new FakeApi()
    tick = 1000
  })

  describe('repo', () => {
    it('saves, reads back and finishes a quiz, stamping each change', async () => {
      const { repo, db } = await device('d1')
      expect(await repo.savedSession('b1')).toBeNull()

      await repo.saveSession('b1', doc({ index: 1 }))
      expect((await repo.savedSession('b1'))?.index).toBe(1)
      const first = (await db.get('sessions', 'b1'))!
      expect(first.dirty).toBe(1)

      await repo.saveSession('b1', doc({ index: 2 }))
      expect((await db.get('sessions', 'b1'))!.updated_at).toBeGreaterThan(first.updated_at)

      await repo.clearSession('b1')
      expect(await repo.savedSession('b1')).toBeNull()
      expect((await db.get('sessions', 'b1'))).toMatchObject({ data: null, dirty: 1 })
    })

    it('stores plain copies of reactive-looking input', async () => {
      const { repo } = await device('d1')
      const proxied = new Proxy(doc(), {}) // structuredClone would throw on a Vue proxy; JSON copy must not
      await repo.saveSession('b1', proxied)
      expect((await repo.savedSession('b1'))?.title).toBe('软件设计师')
    })
  })

  describe('sync', () => {
    it('a quiz left on one device can be continued on another', async () => {
      const phone = await device('phone')
      await phone.repo.saveSession('b1', doc({ index: 2, answers: { q1: { s: [1], c: true } } }))
      await phone.sync.run()
      expect(api.sessions.get('b1')!.dto.device_id).toBe('phone')
      expect(await phone.db.countFromIndex('sessions', 'dirty', 1)).toBe(0)

      const tablet = await device('tablet')
      expect(await tablet.repo.savedSession('b1')).toBeNull()
      const report = await tablet.sync.run()
      expect(report.sessionsPulled).toBe(1)
      const got = (await tablet.repo.savedSession('b1'))!
      expect([got.title, got.index, got.seed, got.ids.length]).toEqual(['软件设计师', 2, 11, 3])
      expect(got.answers.q1).toEqual({ s: [1], c: true })
      expect(await tablet.db.countFromIndex('sessions', 'dirty', 1)).toBe(0)

      expect((await tablet.sync.run()).sessionsPulled).toBe(0)
    })

    it('finishing on one device clears the others', async () => {
      const phone = await device('phone')
      await phone.repo.saveSession('b1', doc())
      await phone.sync.run()
      const tablet = await device('tablet')
      await tablet.sync.run()
      expect(await tablet.repo.savedSession('b1')).not.toBeNull()

      await tablet.repo.clearSession('b1')
      await tablet.sync.run()
      await phone.sync.run()
      expect(await phone.repo.savedSession('b1')).toBeNull()
      expect(api.sessions.get('b1')!.dto.data).toBeNull()
    })

    it('the more recent change wins when both devices moved on', async () => {
      const phone = await device('phone')
      await phone.repo.saveSession('b1', doc())
      await phone.sync.run()
      const tablet = await device('tablet')
      await tablet.sync.run()

      await phone.repo.saveSession('b1', doc({ index: 1 }))
      await tablet.repo.saveSession('b1', doc({ index: 2 })) // later
      await phone.sync.run()
      await tablet.sync.run()
      await phone.sync.run()
      expect((await phone.repo.savedSession('b1'))?.index).toBe(2)
      expect((await tablet.repo.savedSession('b1'))?.index).toBe(2)
    })

    it('a quiz changed here after the server copy survives a stale pull', async () => {
      const phone = await device('phone')
      await phone.repo.saveSession('b1', doc({ title: 'mine' }))
      api.sessions.set('b1', {
        dto: { scope: 'b1', data: doc({ title: 'old' }), updated_at: 1, device_id: 'x' },
        seq: 1,
      })
      await phone.sync.run()
      expect((await phone.repo.savedSession('b1'))?.title).toBe('mine')
    })

    it('ignores a document it cannot read', async () => {
      api.sessions.set('b1', {
        dto: { scope: 'b1', data: { title: 5 } as unknown as SessionData, updated_at: 9_999_999, device_id: 'x' },
        seq: 1,
      })
      const phone = await device('phone')
      const report = await phone.sync.run()
      expect(report.sessionsPulled).toBe(0)
      expect(await phone.repo.savedSession('b1')).toBeNull()
    })

    it('a server that does not know sessions yet does not break syncing', async () => {
      api.sessionsUnsupported = true
      const phone = await device('phone')
      await phone.repo.saveSession('b1', doc())
      const report = await phone.sync.run()
      expect(report.sessionsPulled).toBe(0)
      expect(await phone.db.countFromIndex('sessions', 'dirty', 1)).toBe(1) // kept for after the upgrade
      expect(await phone.repo.savedSession('b1')).not.toBeNull()

      api.sessionsUnsupported = false
      await phone.sync.run()
      expect(await phone.db.countFromIndex('sessions', 'dirty', 1)).toBe(0)
      expect(api.sessions.has('b1')).toBe(true)
    })

    it('other server errors still fail the sync', async () => {
      const phone = await device('phone')
      api.failWith = new ApiError('boom', 500)
      await expect(phone.sync.run()).rejects.toThrow('boom')
    })
  })
})
