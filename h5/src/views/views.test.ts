// @vitest-environment happy-dom
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import router from '@/router'
import { getRepo } from '@/core/app'
import { newUlid } from '@/core/ulid'
import type { ExamDraft, ExamRecord, LocalQuestion } from '@/data/types'
import { pendingExam } from '@/quiz/examLaunch'
import ExamReviewView from './ExamReviewView.vue'
import ExamSetupView from './ExamSetupView.vue'
import ExamView from './ExamView.vue'
import StatsView from './StatsView.vue'

let bankSeq = 0
let bank: string

const question = (id: string, o: Partial<LocalQuestion> = {}): LocalQuestion => ({
  id,
  bank_id: bank,
  type: 'single',
  stem: `题干 ${id}`,
  options: ['甲', '乙', '丙', '丁'],
  answer: [1],
  explanation: `解析 ${id}`,
  difficulty: 2,
  tags: ['锁'],
  source_quote: '',
  sync_seq: 1,
  hidden: false,
  ...o,
})

async function seed(n: number, tags: (i: number) => string[] = () => ['锁']) {
  const repo = await getRepo()
  await repo.db.put('banks', { id: bank, title: `题库${bankSeq}`, description: '', question_count: n })
  const qs: LocalQuestion[] = []
  for (let i = 1; i <= n; i++) {
    const q = question(`${bank}-q${i}`, { tags: tags(i) })
    await repo.db.put('questions', q)
    qs.push(q)
  }
  return { repo, qs }
}

const flush = async () => {
  await flushPromises()
  await new Promise((r) => setTimeout(r, 20))
  await flushPromises()
}

async function open(path: string, comp: object, props: Record<string, unknown> = {}): Promise<VueWrapper> {
  await router.push(path)
  await router.isReady()
  const w = mount(comp, { props, global: { plugins: [router] }, attachTo: document.body })
  await flush()
  return w
}

const button = (w: VueWrapper, text: string) => {
  const b = w.findAll('button').find((x) => x.text().includes(text))
  if (!b) throw new Error(`no button "${text}" in: ${w.text().slice(0, 200)}`)
  return b
}

beforeEach(async () => {
  bank = `bank${++bankSeq}`
  pendingExam.value = null
  const repo = await getRepo()
  await repo.db.clear('examDrafts') // the database is shared by the tests in this file
  vi.stubGlobal('confirm', () => true)
  // Leaving a page starts a background sync; there is no server here, so it just fails quietly.
  vi.stubGlobal('fetch', () => Promise.reject(new TypeError('offline')))
  window.scrollTo = () => {}
})

describe('ExamSetupView', () => {
  it('limits the paper to the chosen topic and starts the exam', async () => {
    await seed(6, (i) => (i <= 4 ? ['锁'] : ['范式']))
    const w = await open(`/bank/${bank}/exam`, ExamSetupView, { id: bank })

    expect(w.text()).toContain('出卷方式')
    expect(w.text()).toContain('查漏补缺')
    expect(w.text()).toContain('知识点')
    await button(w, '范式').trigger('click')
    await flush()
    expect(w.text()).toContain('共 2 题') // only the two 范式 questions are in the pool

    await button(w, '不限时').trigger('click')
    await button(w, '开始考试').trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe('/exam')
    const launch = pendingExam.value!
    expect(launch.questions.map((q) => q.id).sort()).toEqual([`${bank}-q5`, `${bank}-q6`])
    expect(launch.limitSec).toBeNull()
    w.unmount()
  })

  it('offers to continue an unfinished exam and lists past exams to review', async () => {
    const { repo, qs } = await seed(3)
    const draft: ExamDraft = {
      bank_id: bank, title: 't', ids: qs.map((q) => q.id), slots: [0, 1, 2], seed: 1, started_at: Date.now(),
      limit_sec: null, index: 1, answers: { [qs[0].id]: [1] }, spent: {}, marked: [], saved_at: Date.now(),
    }
    await repo.saveExamDraft(draft)
    const exam: ExamRecord = {
      id: newUlid(), bank_id: bank, title: 't', finished_at: Date.now(), total: 3, correct: 1, answered: 3, percent: 33,
      passed: false, limit_sec: null, used_ms: 61000, device_id: 'd', items: [],
    }
    await repo.db.put('exams', { ...exam, synced: 1 })

    const w = await open(`/bank/${bank}/exam`, ExamSetupView, { id: bank })
    expect(w.text()).toContain('有一场没做完的考试')
    expect(w.text()).toContain('已答 1 / 3 题')
    expect(w.text()).toContain('另开一场新考试')

    await button(w, '继续考试').trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe('/exam')
    expect(pendingExam.value?.draft?.index).toBe(1)
    w.unmount()

    const again = await open(`/bank/${bank}/exam`, ExamSetupView, { id: bank })
    await again.find('button.card.link').trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe(`/exam/review/${exam.id}`)
    again.unmount()
  })

  it('drops the unfinished exam when asked to', async () => {
    const { repo, qs } = await seed(2)
    await repo.saveExamDraft({
      bank_id: bank, title: 't', ids: qs.map((q) => q.id), slots: [0, 1], seed: 1, started_at: Date.now(), limit_sec: null,
      index: 0, answers: {}, spent: {}, marked: [], saved_at: Date.now(),
    })
    const w = await open(`/bank/${bank}/exam`, ExamSetupView, { id: bank })
    await button(w, '放弃').trigger('click')
    await flush()
    expect(w.text()).not.toContain('有一场没做完的考试')
    expect(await repo.examDraft(bank)).toBeUndefined()
    w.unmount()
  })
})

describe('ExamView', () => {
  it('answers, marks, hands in, shows the score and leaves a synced-later record', async () => {
    const { repo, qs } = await seed(3)
    pendingExam.value = { bankId: bank, title: '题库', questions: qs, limitSec: null }
    const w = await open('/exam', ExamView)

    expect(w.text()).toContain('模拟考试 · 1/3')
    expect(w.text()).not.toContain('⏱') // untimed
    await w.findAll('.option')[0].trigger('click') // whichever is shown first
    await button(w, '标记待检查').trigger('click')
    expect(w.text()).toContain('已标记待检查')
    await button(w, '下一题').trigger('click')
    expect(w.text()).toContain('模拟考试 · 2/3')

    await button(w, '答题卡').trigger('click')
    expect(w.text()).toContain('已答 1 / 3')
    expect(w.text()).toContain('待检查 1')
    expect(w.find('.sheet button.marked').exists()).toBe(true)
    expect(w.findAll('.sheet button')[0].attributes('aria-label')).toBe('第 1 题，待检查，已答')

    const asked: string[] = []
    vi.stubGlobal('confirm', (m: string) => (asked.push(m), true))
    await w.find('button.primary').trigger('click') // 交卷
    await flush()
    expect(asked[0]).toBe('还有 2 题没有作答，有 1 题标记了待检查，确定交卷吗？')
    expect(w.text()).toContain('考试结果')
    expect(w.find('.score').exists()).toBe(true)
    expect(w.text()).toContain('逐题解析')

    const [record] = await repo.exams(bank)
    expect(record.answered).toBe(1)
    expect(record.items).toHaveLength(3)
    expect(await repo.examDraft(bank)).toBeUndefined()
    w.unmount()
  })

  it('picks up a saved exam after a reload (no launch), on the same question', async () => {
    const { repo, qs } = await seed(3)
    await repo.saveExamDraft({
      bank_id: bank, title: '题库', ids: qs.map((q) => q.id), slots: [0, 1, 2], seed: 3, started_at: Date.now() - 30_000,
      limit_sec: 600, index: 2, answers: { [qs[0].id]: [1] }, spent: {}, marked: [qs[1].id], saved_at: Date.now(),
    })
    const w = await open('/exam', ExamView)
    expect(w.text()).toContain('模拟考试 · 3/3')
    expect(w.text()).toMatch(/⏱ 9:[2-3]\d/) // the clock kept running while away
    await button(w, '答题卡').trigger('click')
    expect(w.text()).toContain('已答 1 / 3')
    expect(w.text()).toContain('待检查 1')
    w.unmount()
  })

  it('an expired timed exam is handed in straight away', async () => {
    const { repo, qs } = await seed(2)
    await repo.saveExamDraft({
      bank_id: bank, title: '题库', ids: qs.map((q) => q.id), slots: [0, 1], seed: 3, started_at: Date.now() - 3_600_000,
      limit_sec: 120, index: 0, answers: { [qs[0].id]: [1] }, spent: {}, marked: [], saved_at: Date.now(),
    })
    const w = await open('/exam', ExamView)
    await flush()
    expect(w.text()).toContain('考试结果')
    expect((await repo.exams(bank))[0].answered).toBe(1)
    w.unmount()
  })

  it('goes home when there is nothing to show', async () => {
    const w = await open('/exam', ExamView)
    await flush()
    expect(router.currentRoute.value.path).toBe('/')
    w.unmount()
  })

  it('abandoning removes the saved exam and records nothing', async () => {
    const { repo, qs } = await seed(2)
    pendingExam.value = { bankId: bank, title: '题库', questions: qs, limitSec: null }
    const w = await open('/exam', ExamView)
    await w.findAll('.option')[0].trigger('click')
    await button(w, '答题卡').trigger('click')
    await button(w, '放弃本次考试').trigger('click')
    await flush()
    expect(await repo.examDraft(bank)).toBeUndefined()
    expect(await repo.exams(bank)).toEqual([])
    expect((await repo.db.getAll('attempts')).filter((a) => a.question_id.startsWith(bank))).toEqual([]) // the database is shared by the tests in this file
    w.unmount()
  })
})

describe('ExamReviewView', () => {
  it('shows the paper again, with withdrawn questions marked as such', async () => {
    const { repo, qs } = await seed(2)
    const rec: ExamRecord = {
      id: newUlid(), bank_id: bank, title: 't', finished_at: Date.now(), total: 3, correct: 1, answered: 2, percent: 33,
      passed: false, limit_sec: null, used_ms: 5000, device_id: 'd',
      items: [{ q: qs[0].id, s: [1], c: true }, { q: qs[1].id, s: [0], c: false }, { q: 'gone', s: [], c: false }],
    }
    await repo.db.put('exams', { ...rec, synced: 1 })
    const w = await open(`/exam/review/${rec.id}`, ExamReviewView, { id: rec.id })
    expect(w.text()).toContain('考试回顾')
    expect(w.text()).toContain('重做错题（1）') // the withdrawn one cannot be retried
    expect(w.text()).toContain('（这道题已下线）')
    expect(w.text()).toContain(`题干 ${qs[0].id}`)
    w.unmount()
  })

  it('says so for an exam this device does not have', async () => {
    const w = await open('/exam/review/nope', ExamReviewView, { id: 'nope' })
    expect(w.text()).toContain('没有找到这场考试')
    w.unmount()
  })

  it('an old record without detail shows the score only', async () => {
    const { repo } = await seed(1)
    const rec: ExamRecord = {
      id: newUlid(), bank_id: bank, title: 't', finished_at: 1, total: 10, correct: 6, answered: 10, percent: 60, passed: true,
      limit_sec: null, used_ms: 1000, device_id: '', items: [],
    }
    await repo.db.put('exams', { ...rec, synced: 0 })
    const w = await open(`/exam/review/${rec.id}`, ExamReviewView, { id: rec.id })
    expect(w.text()).toContain('只保留了成绩')
    expect(w.text()).not.toContain('逐题解析')
    w.unmount()
  })
})

describe('StatsView', () => {
  it('switches range and tag grouping, and charts exam scores', async () => {
    const { repo, qs } = await seed(3, (i) => (i === 1 ? ['UML'] : i === 2 ? ['UML 辨析'] : ['范式']))
    await repo.recordAnswer(qs[0], [1], 1000)
    await repo.recordAnswer(qs[1], [0], 1000)
    for (const [i, percent] of [[1, 40], [2, 70]] as const) {
      await repo.db.put('exams', {
        id: newUlid(1000 + i), bank_id: bank, title: 't', finished_at: 1000 + i, total: 10, correct: percent / 10, answered: 10,
        percent, passed: percent >= 60, limit_sec: null, used_ms: 1, device_id: 'd', items: [], synced: 1,
      })
    }
    const w = await open(`/bank/${bank}/stats`, StatsView, { id: bank })

    expect(w.text()).toContain('最近 7 天')
    expect(w.findAll('.days .day')).toHaveLength(7)
    await button(w, '30 天').trigger('click')
    expect(w.text()).toContain('最近 30 天')
    expect(w.findAll('.days .day')).toHaveLength(30)

    expect(w.text()).toContain('考试成绩')
    expect(w.findAll('.trend circle')).toHaveLength(2)
    expect(w.find('.trend polyline').exists()).toBe(true)

    expect(w.text()).toContain('共 1 个') // UML + UML 辨析 merged (范式 was never answered)
    await button(w, '细分').trigger('click')
    expect(w.text()).toContain('共 2 个')
    w.unmount()
  })
})
