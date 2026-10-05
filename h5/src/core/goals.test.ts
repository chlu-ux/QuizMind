// @vitest-environment happy-dom
import { beforeEach, describe, expect, it } from 'vitest'
import { DEFAULT_GOALS, goals, goalStatus, reminderDue, remainingText, sanitizeGoals, updateGoals, type Goals } from './goals'

const min = (n: number) => n * 60000
const at = (h: number, m: number) => new Date(2026, 9, 5, h, m)
const g = (o: Partial<Goals> = {}): Goals => ({ ...DEFAULT_GOALS, ...o })

describe('goalStatus', () => {
  it('has no goal when both are off, and is never "achieved" then', () => {
    const s = goalStatus(g(), { questions: 50, ms: min(90) })
    expect(s).toMatchObject({ hasGoal: false, achieved: false, questionsLeft: 0, minutesLeft: 0 })
  })

  it('judges only the questions goal when only that is on', () => {
    const goal = g({ questions: 20 })
    expect(goalStatus(goal, { questions: 12, ms: min(500) })).toMatchObject({ questionsLeft: 8, minutesLeft: 0, achieved: false })
    expect(goalStatus(goal, { questions: 20, ms: 0 }).achieved).toBe(true)
    expect(goalStatus(goal, { questions: 35, ms: 0 }).questionsLeft).toBe(0)
  })

  it('judges only the minutes goal when only that is on, on whole minutes', () => {
    const goal = g({ minutes: 30 })
    expect(goalStatus(goal, { questions: 999, ms: min(29) + 59_999 })).toMatchObject({ minutesDone: 29, minutesLeft: 1, achieved: false })
    expect(goalStatus(goal, { questions: 0, ms: min(30) }).achieved).toBe(true)
  })

  it('needs both when both are on', () => {
    const goal = g({ questions: 10, minutes: 15 })
    expect(goalStatus(goal, { questions: 10, ms: min(10) })).toMatchObject({ achieved: false, questionsLeft: 0, minutesLeft: 5 })
    expect(goalStatus(goal, { questions: 4, ms: min(20) })).toMatchObject({ achieved: false, questionsLeft: 6, minutesLeft: 0 })
    expect(goalStatus(goal, { questions: 10, ms: min(15) }).achieved).toBe(true)
  })
})

describe('reminderDue', () => {
  const goal = g({ questions: 10, remind: true, remindAt: '20:00' })
  const open = goalStatus(goal, { questions: 3, ms: 0 })

  it('fires from the set time on, not before', () => {
    expect(reminderDue(goal, open, at(19, 59))).toBe(false)
    expect(reminderDue(goal, open, at(20, 0))).toBe(true)
    expect(reminderDue(goal, open, at(23, 59))).toBe(true)
  })

  it('starts over after midnight', () => {
    expect(reminderDue(goal, open, at(0, 5))).toBe(false)
  })

  it('stays quiet when reminders are off, no goal is set, or the goal is met', () => {
    expect(reminderDue({ ...goal, remind: false }, open, at(21, 0))).toBe(false)
    expect(reminderDue(g({ remind: true }), goalStatus(g(), { questions: 0, ms: 0 }), at(21, 0))).toBe(false)
    expect(reminderDue(goal, goalStatus(goal, { questions: 10, ms: 0 }), at(21, 0))).toBe(false)
  })

  it('treats a broken time as no reminder', () => {
    expect(reminderDue({ ...goal, remindAt: 'xx' }, open, at(21, 0))).toBe(false)
  })
})

describe('remainingText', () => {
  it('names what is left, only for the goals still open', () => {
    expect(remainingText(goalStatus(g({ questions: 10, minutes: 15 }), { questions: 5, ms: min(3) }))).toBe('还差 5 题、12 分钟')
    expect(remainingText(goalStatus(g({ questions: 10, minutes: 15 }), { questions: 10, ms: min(3) }))).toBe('还差 12 分钟')
    expect(remainingText(goalStatus(g({ questions: 10 }), { questions: 10, ms: 0 }))).toBe('')
  })
})

describe('sanitizeGoals', () => {
  it('keeps valid values and repairs the rest field by field', () => {
    expect(sanitizeGoals({ questions: 20, minutes: 30, remind: true, remindAt: '07:30' })).toEqual({ questions: 20, minutes: 30, remind: true, remindAt: '07:30' })
    expect(sanitizeGoals({ questions: 0, minutes: -5, remind: 'yes', remindAt: '25:00' })).toEqual(DEFAULT_GOALS)
    expect(sanitizeGoals({ questions: 12.9, minutes: 100000 })).toMatchObject({ questions: 12, minutes: 600 })
    expect(sanitizeGoals(null)).toEqual(DEFAULT_GOALS)
    expect(sanitizeGoals('junk')).toEqual(DEFAULT_GOALS)
  })
})

describe('updateGoals', () => {
  beforeEach(() => {
    localStorage.clear()
    updateGoals(DEFAULT_GOALS)
  })

  it('applies a change, validates it and saves it on this device', () => {
    updateGoals({ questions: 30 })
    updateGoals({ minutes: 45, remind: true, remindAt: '21:15' })
    expect({ ...goals }).toEqual({ questions: 30, minutes: 45, remind: true, remindAt: '21:15' })
    expect(JSON.parse(localStorage.getItem('quizmind.goals')!)).toEqual({ ...goals })
    updateGoals({ questions: null, remindAt: 'bad' })
    expect(goals.questions).toBeNull()
    expect(goals.remindAt).toBe('20:00')
  })
})
