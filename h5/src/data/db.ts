import { openDB, type DBSchema, type IDBPDatabase } from 'idb'
import type { Bank, ExamDraft, LocalAttempt, LocalExam, LocalQuestion, LocalSession, LocalState } from './types'

interface Schema extends DBSchema {
  banks: { key: string; value: Bank }
  questions: { key: string; value: LocalQuestion; indexes: { bank: string } }
  attempts: { key: string; value: LocalAttempt; indexes: { synced: number; question: string } }
  states: { key: string; value: LocalState; indexes: { dirty: number } }
  flags: { key: string; value: { question_id: string; created_at: number } }
  sessions: { key: string; value: LocalSession; indexes: { dirty: number } }
  exams: { key: string; value: LocalExam; indexes: { bank: string; synced: number } }
  examDrafts: { key: string; value: ExamDraft }
  meta: { key: string; value: number }
}

export type Db = IDBPDatabase<Schema>

export function openDb(name = 'quizmind'): Promise<Db> {
  return openDB<Schema>(name, 4, {
    upgrade(db, oldVersion, _newVersion, tx) {
      if (oldVersion < 1) {
        db.createObjectStore('banks', { keyPath: 'id' })
        db.createObjectStore('questions', { keyPath: 'id' }).createIndex('bank', 'bank_id')
        const attempts = db.createObjectStore('attempts', { keyPath: 'id' })
        attempts.createIndex('synced', 'synced')
        attempts.createIndex('question', 'question_id')
        db.createObjectStore('states', { keyPath: 'question_id' }).createIndex('dirty', 'dirty')
        db.createObjectStore('flags', { keyPath: 'question_id' })
        db.createObjectStore('meta')
      }
      if (oldVersion < 2) {
        // Saved quizzes ("continue where you left off"), synced between devices.
        db.createObjectStore('sessions', { keyPath: 'scope' }).createIndex('dirty', 'dirty')
      }
      if (oldVersion < 3) {
        db.createObjectStore('exams', { keyPath: 'id' }).createIndex('bank', 'bank_id')
      }
      if (oldVersion < 4) {
        // Exams now sync (per-question detail + an outbox flag), and a half-done exam can be resumed.
        const exams = tx.objectStore('exams')
        exams.createIndex('synced', 'synced')
        db.createObjectStore('examDrafts', { keyPath: 'bank_id' })
        // Version-3 results only knew their score: queue them for upload without detail.
        void (async () => {
          for (let c = await exams.openCursor(); c; c = await c.continue()) {
            await c.update({ ...c.value, items: [], device_id: '', synced: 0 })
          }
        })()
      }
    },
  })
}
