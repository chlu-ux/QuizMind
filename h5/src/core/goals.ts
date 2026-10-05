import { reactive } from 'vue'
import type { DayProgress } from '@/data/repo'

/**
 * Daily study goals. They live on this device only (they are not synced), so a phone and a
 * laptop can aim at different numbers. A goal of null is off; with both on, both must be met.
 */
export interface Goals {
  /** Questions to answer per day. */
  questions: number | null
  /** Minutes to study per day. */
  minutes: number | null
  /** Remind, when the app is open after [remindAt] and the goal is not met yet. */
  remind: boolean
  /** Local time of day as "HH:MM". */
  remindAt: string
}

export const DEFAULT_GOALS: Goals = { questions: null, minutes: null, remind: false, remindAt: '20:00' }

export const MAX_QUESTIONS = 999
export const MAX_MINUTES = 600

const KEY = 'quizmind.goals'

const whole = (v: unknown, max: number): number | null =>
  typeof v === 'number' && Number.isFinite(v) && v >= 1 ? Math.min(Math.floor(v), max) : null

const isTime = (v: unknown): v is string => typeof v === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(v)

/** Turns whatever was stored (or typed) into valid goals, falling back to the defaults field by field. */
export function sanitizeGoals(raw: unknown): Goals {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>
  return {
    questions: whole(r.questions, MAX_QUESTIONS),
    minutes: whole(r.minutes, MAX_MINUTES),
    remind: r.remind === true,
    remindAt: isTime(r.remindAt) ? r.remindAt : DEFAULT_GOALS.remindAt,
  }
}

function read(): Goals {
  try {
    return sanitizeGoals(JSON.parse(localStorage.getItem(KEY) ?? 'null'))
  } catch {
    return { ...DEFAULT_GOALS }
  }
}

/** The goals as the views see them; change them through [updateGoals] so they are saved. */
export const goals = reactive<Goals>(read())

export function updateGoals(patch: Partial<Goals>) {
  Object.assign(goals, sanitizeGoals({ ...goals, ...patch }))
  try {
    localStorage.setItem(KEY, JSON.stringify({ ...goals }))
  } catch {
    /* private mode: the goal lasts until the page is closed */
  }
}

export interface GoalStatus {
  /** At least one goal is on. */
  hasGoal: boolean
  questionsDone: number
  /** Whole minutes studied. */
  minutesDone: number
  /** Questions still to answer; 0 when that goal is off or met. */
  questionsLeft: number
  /** Minutes still to study; 0 when that goal is off or met. */
  minutesLeft: number
  /** Every goal that is on is met. False when none is on. */
  achieved: boolean
}

export function goalStatus(g: Pick<Goals, 'questions' | 'minutes'>, p: DayProgress): GoalStatus {
  const minutesDone = Math.floor(p.ms / 60000)
  const questionsLeft = g.questions === null ? 0 : Math.max(0, g.questions - p.questions)
  const minutesLeft = g.minutes === null ? 0 : Math.max(0, g.minutes - minutesDone)
  const hasGoal = g.questions !== null || g.minutes !== null
  return {
    hasGoal,
    questionsDone: p.questions,
    minutesDone,
    questionsLeft,
    minutesLeft,
    achieved: hasGoal && questionsLeft === 0 && minutesLeft === 0,
  }
}

const minuteOfDay = (d: Date) => d.getHours() * 60 + d.getMinutes()

/** Is it time to nudge: reminders on, a goal set and not yet met, and the reminder time has passed today. */
export function reminderDue(g: Goals, status: GoalStatus, now: Date): boolean {
  if (!g.remind || !status.hasGoal || status.achieved || !isTime(g.remindAt)) return false
  const [h, m] = g.remindAt.split(':').map(Number)
  return minuteOfDay(now) >= h * 60 + m
}

/** "还差 5 题、12 分钟" */
export function remainingText(s: GoalStatus): string {
  const parts: string[] = []
  if (s.questionsLeft > 0) parts.push(`${s.questionsLeft} 题`)
  if (s.minutesLeft > 0) parts.push(`${s.minutesLeft} 分钟`)
  return parts.length ? `还差 ${parts.join('、')}` : ''
}
