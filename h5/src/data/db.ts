import { openDB, type DBSchema, type IDBPDatabase } from 'idb'
import type { Bank, ExamRecord, LocalAttempt, LocalQuestion, LocalSession, LocalState } from './types'

interface Schema extends DBSchema {
  banks: { key: string; value: Bank }
  questions: { key: string; value: LocalQuestion; indexes: { bank: string } }
  attempts: { key: string; value: LocalAttempt; indexes: { synced: number; question: string } }
  states: { key: string; value: LocalState; indexes: { dirty: number } }
  flags: { key: string; value: { question_id: string; created_at: number } }
  sessions: { key: string; value: LocalSession; indexes: { dirty: number } }
  exams: { key: string; value: ExamRecord; indexes: { bank: string } }
  meta: { key: string; value: number }
}

export type Db = IDBPDatabase<Schema>

export function openDb(name = 'quizmind'): Promise<Db> {
  return openDB<Schema>(name, 3, {
    upgrade(db, oldVersion) {
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
        // Mock exam results (this device only).
        db.createObjectStore('exams', { keyPath: 'id' }).createIndex('bank', 'bank_id')
      }
    },
  })
}
