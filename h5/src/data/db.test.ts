import { openDB } from 'idb'
import { describe, expect, it } from 'vitest'
import { openDb } from './db'

describe('database upgrade', () => {
  it('queues exams saved by version 3 for upload, without detail, and adds the draft store', async () => {
    const name = `upgrade-${Math.random()}`
    // What version 3 left behind: an exams store holding score-only records.
    const old = await openDB(name, 3, {
      upgrade(db) {
        db.createObjectStore('banks', { keyPath: 'id' })
        db.createObjectStore('questions', { keyPath: 'id' }).createIndex('bank', 'bank_id')
        const attempts = db.createObjectStore('attempts', { keyPath: 'id' })
        attempts.createIndex('synced', 'synced')
        attempts.createIndex('question', 'question_id')
        db.createObjectStore('states', { keyPath: 'question_id' }).createIndex('dirty', 'dirty')
        db.createObjectStore('flags', { keyPath: 'question_id' })
        db.createObjectStore('meta')
        db.createObjectStore('sessions', { keyPath: 'scope' }).createIndex('dirty', 'dirty')
        db.createObjectStore('exams', { keyPath: 'id' }).createIndex('bank', 'bank_id')
      },
    })
    for (const id of ['E1', 'E2']) {
      await old.put('exams', {
        id, bank_id: 'b1', title: '题库', finished_at: 100, total: 10, correct: 6, answered: 10, percent: 60,
        passed: true, limit_sec: null, used_ms: 1000,
      })
    }
    old.close()

    const db = await openDb(name)
    const rows = await db.getAll('exams')
    expect(rows.map((r) => [r.id, r.synced, r.items, r.device_id])).toEqual([
      ['E1', 0, [], ''],
      ['E2', 0, [], ''],
    ])
    expect(await db.getAllFromIndex('exams', 'synced', 0)).toHaveLength(2)
    expect(await db.getAllFromIndex('exams', 'bank', 'b1')).toHaveLength(2)
    await db.put('examDrafts', {
      bank_id: 'b1', title: 't', ids: ['q'], slots: [0], seed: 1, started_at: 1, limit_sec: null, index: 0,
      answers: {}, spent: {}, marked: [], saved_at: 1,
    })
    expect(await db.count('examDrafts')).toBe(1)
    db.close()
  })

  it('creates a fresh database at the latest version', async () => {
    const db = await openDb(`fresh-${Math.random()}`)
    expect([...db.objectStoreNames].sort()).toEqual(
      ['attempts', 'banks', 'examDrafts', 'exams', 'flags', 'lessonReads', 'lessons', 'meta', 'questions', 'sessions', 'states'],
    )
    db.close()
  })
})
