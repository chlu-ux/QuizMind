// @vitest-environment happy-dom
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import router from '@/router'
import { getRepo, toast } from '@/core/app'
import { setAgentApi, setAgentToken } from '@/core/agent'
import { AgentError } from '@/data/agentTypes'
import { adoptedDraft, draft, FakeAgentApi, storedMessage } from '@/test-support'
import { DEFAULT_GOALS, updateGoals } from '@/core/goals'
import { newUlid } from '@/core/ulid'
import type { ExamDraft, ExamRecord, Lesson, LocalQuestion } from '@/data/types'
import { pendingExam } from '@/quiz/examLaunch'
import { pendingQuiz, startQuiz } from '@/quiz/launch'
import ExamReviewView from './ExamReviewView.vue'
import ExamSetupView from './ExamSetupView.vue'
import ExamView from './ExamView.vue'
import AgentHistoryView from './AgentHistoryView.vue'
import AgentView from './AgentView.vue'
import BankView from './BankView.vue'
import BanksView from './BanksView.vue'
import LearnView from './LearnView.vue'
import LessonView from './LessonView.vue'
import ListView from './ListView.vue'
import QuizView from './QuizView.vue'
import SearchView from './SearchView.vue'
import SettingsView from './SettingsView.vue'
import StatsView from './StatsView.vue'
import TopicsView from './TopicsView.vue'

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

describe('StatsView topics', () => {
  it('a tag row starts practice on that knowledge point, following the merged / detailed switch', async () => {
    const { repo, qs } = await seed(4, (i) => (i === 1 ? ['UML'] : i === 2 ? ['UML 辨析'] : i === 3 ? ['UML'] : ['范式']))
    for (const q of qs) await repo.recordAnswer(q, [1], 1000)
    const w = await open(`/bank/${bank}/stats`, StatsView, { id: bank })

    await w.find('[aria-label="练习知识点 UML"]').trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe('/quiz')
    expect(pendingQuiz.value!.questions.map((q) => q.id).sort()).toEqual([qs[0].id, qs[1].id, qs[2].id].sort())
    expect(pendingQuiz.value!.title).toBe('知识点 · UML')
    expect(pendingQuiz.value!.scope).toBeUndefined() // a one-off drill must not replace the bank's saved round

    await router.push(`/bank/${bank}/stats`)
    await button(w, '细分').trigger('click')
    await w.find('[aria-label="练习知识点 UML"]').trigger('click')
    await flush()
    expect(pendingQuiz.value!.questions.map((q) => q.id).sort()).toEqual([qs[0].id, qs[2].id].sort()) // "UML 辨析" stays out
    w.unmount()
  })
})

describe('TopicsView', () => {
  it('lists knowledge points biggest first with counts and accuracy, and starts the topic at random', async () => {
    const { repo, qs } = await seed(6, (i) => (i <= 3 ? ['锁'] : i <= 5 ? ['范式'] : ['UML']))
    await repo.recordAnswer(qs[0], [1], 1) // right
    await repo.recordAnswer(qs[1], [0], 1) // wrong
    const w = await open(`/bank/${bank}/topics`, TopicsView, { id: bank })

    const rows = w.findAll('.topic').map((r) => r.text().replace(/\s+/g, ' '))
    expect(rows).toHaveLength(3)
    expect(rows[0]).toContain('锁')
    expect(rows[0]).toContain('3 题')
    expect(rows[0]).toContain('做过 2')
    expect(rows[0]).toContain('50%')
    expect(rows[1]).toContain('范式')
    expect(rows[1]).toContain('未做')

    await w.findAll('.topic')[0].trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe('/quiz')
    expect(pendingQuiz.value!.questions.map((q) => q.id).sort()).toEqual([qs[0].id, qs[1].id, qs[2].id].sort())
    expect(pendingQuiz.value!.title).toBe('知识点 · 锁')
    expect(pendingQuiz.value!.scope).toBeUndefined()
    w.unmount()
  })

  it('"only unanswered" and "only missed" narrow the draw, exclude each other and toggle off', async () => {
    const { repo, qs } = await seed(3, () => ['锁'])
    await repo.recordAnswer(qs[0], [1], 1) // right
    await repo.recordAnswer(qs[1], [0], 1) // wrong
    const w = await open(`/bank/${bank}/topics`, TopicsView, { id: bank })
    const draw = async () => {
      await w.findAll('.topic')[0].trigger('click')
      await flush()
      const ids = pendingQuiz.value!.questions.map((q) => q.id).sort()
      await router.push(`/bank/${bank}/topics`)
      return ids
    }

    await button(w, '只刷没做过的').trigger('click')
    expect(w.text()).toContain('可刷 1')
    expect(await draw()).toEqual([qs[2].id])

    await button(w, '只刷做错过的').trigger('click')
    expect(button(w, '只刷没做过的').attributes('aria-pressed')).toBe('false')
    expect(w.text()).toContain('可刷 1')
    expect(await draw()).toEqual([qs[1].id])

    await button(w, '只刷做错过的').trigger('click') // off again
    expect(w.text()).not.toContain('可刷')
    expect(await draw()).toHaveLength(3)
    w.unmount()
  })

  it('says so instead of starting an empty quiz', async () => {
    const { repo, qs } = await seed(2, () => ['锁'])
    for (const q of qs) await repo.recordAnswer(q, [1], 1) // everything answered, nothing wrong
    pendingQuiz.value = null
    const w = await open(`/bank/${bank}/topics`, TopicsView, { id: bank })
    await button(w, '只刷做错过的').trigger('click')
    expect(w.find('.topic').classes()).toContain('off')
    await w.find('.topic').trigger('click')
    await flush()
    expect(pendingQuiz.value).toBeNull()
    expect(router.currentRoute.value.path).toBe(`/bank/${bank}/topics`)
    w.unmount()
  })

  it('merges related tags by default and shows them apart in the detailed view', async () => {
    await seed(2, (i) => (i === 1 ? ['UML'] : ['UML 辨析']))
    const w = await open(`/bank/${bank}/topics`, TopicsView, { id: bank })
    expect(w.findAll('.topic')).toHaveLength(1)
    await button(w, '细分').trigger('click')
    expect(w.findAll('.topic')).toHaveLength(2)
    w.unmount()
  })

  it('is reachable from the bank page and tells when there are no tags', async () => {
    await seed(2, () => [])
    const page = await open(`/bank/${bank}`, BankView, { id: bank })
    await button(page, '按知识点刷题').trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe(`/bank/${bank}/topics`)
    page.unmount()
    const w = await open(`/bank/${bank}/topics`, TopicsView, { id: bank })
    expect(w.text()).toContain('还没有知识点标签')
    w.unmount()
  })
})

describe('QuizView', () => {
  it('asks why a question is reported and queues the report with that reason', async () => {
    const { repo, qs } = await seed(2)
    await startQuiz('练习', qs)
    const w = await open('/quiz', QuizView)

    await w.find('[aria-label="更多"]').trigger('click')
    await w.findAll('.menu div').find((d) => d.text().includes('反馈'))!.trigger('click')
    await flush()
    expect(w.text()).toContain('这道题哪里有问题')
    for (const label of ['答案不对', '题干有歧义', '选项或文字有误', '其他']) expect(w.text()).toContain(label)

    await button(w, '题干有歧义').trigger('click')
    await flush()
    const flags = await repo.db.getAll('flags')
    expect(flags.map((f) => [f.question_id, f.reason])).toEqual([[qs[0].id, 'ambiguous']])
    expect(w.text()).not.toContain('这道题哪里有问题')
    w.unmount()
  })
})

describe('wrong book by bank', () => {
  // Two banks with wrong answers in each; the first bank's title sorts first.
  async function seedWrong() {
    const a = await seed(3)
    const bankA = bank
    const titleA = `题库${bankSeq}`
    bank = `${bank}b`
    const b = await seed(2)
    const titleB = `${titleA}乙`
    await b.repo.db.put('banks', { id: bank, title: titleB, description: '', question_count: 2 })
    for (const q of [...a.qs.slice(0, 2), ...b.qs]) await a.repo.recordAnswer(q, [0], 1)
    return { repo: a.repo, bankA, bankB: bank, titleA, titleB, qa: a.qs, qb: b.qs }
  }
  const chip = (w: VueWrapper, text: string) => w.findAll('.bank-filter .pick').find((x) => x.text().includes(text))!

  beforeEach(async () => {
    sessionStorage.clear()
    pendingQuiz.value = null
    // The database is shared by the tests in this file: start each from an empty wrong book and favourites.
    const repo = await getRepo()
    await repo.db.clear('states')
  })

  it('shows every bank by default, with the bank of each question and a count per bank', async () => {
    const { titleA, titleB } = await seedWrong()
    const w = await open('/wrong', ListView, { kind: 'wrong' })
    expect(w.findAll('.bank-filter .pick').map((c) => c.text())).toEqual(['全部 4', `${titleA} 2`, `${titleB} 2`])
    expect(w.text()).toContain('共 4 题')
    expect(w.findAll('.card .small').every((r) => r.text().includes('题库'))).toBe(true) // each row names its bank
    w.unmount()
  })

  it('narrows the list and the random practice to the chosen bank, and remembers the choice for the session', async () => {
    const { qb, titleB } = await seedWrong()
    const w = await open('/wrong', ListView, { kind: 'wrong' })
    await chip(w, '乙').trigger('click')
    await flush()
    expect(w.text()).toContain('共 2 题')
    expect(w.findAll('.card')).toHaveLength(2)

    await button(w, '随机练习').trigger('click')
    await flush()
    expect(pendingQuiz.value!.title).toBe(`错题本 · ${titleB}`)
    expect(pendingQuiz.value!.questions.map((q) => q.id).sort()).toEqual(qb.map((q) => q.id).sort())
    w.unmount()

    // Back on the list in the same session it is still narrowed.
    const again = await open('/wrong', ListView, { kind: 'wrong' })
    expect(again.text()).toContain('共 2 题')
    again.unmount()
  })

  it('opens on the bank named in the address when coming from the bank page', async () => {
    const { bankA, qa } = await seedWrong()
    const w = await open(`/wrong?bank=${bankA}`, ListView, { kind: 'wrong' })
    expect(w.text()).toContain('共 2 题')
    expect(chip(w, '全部').classes()).not.toContain('on')
    expect(w.text()).toContain(qa[0].stem)
    w.unmount()
  })

  it('falls back to everything when the remembered bank has no wrong questions left', async () => {
    await seedWrong()
    sessionStorage.setItem('quizmind.listBank.wrong', 'gone')
    const w = await open('/wrong', ListView, { kind: 'wrong' })
    expect(w.text()).toContain('共 4 题')
    w.unmount()
  })

  it('the favourites list is split by bank the same way', async () => {
    const { repo, qa, qb } = await seedWrong()
    await repo.setFavorite(qa[0].id, true)
    await repo.setFavorite(qb[0].id, true)
    const w = await open('/fav', ListView, { kind: 'fav' })
    expect(w.findAll('.bank-filter .pick')).toHaveLength(3)
    await chip(w, '乙').trigger('click')
    await flush()
    expect(w.text()).toContain('共 1 题')
    w.unmount()
  })

  it('the bank page links to its own wrong book, greyed out when it has none', async () => {
    const { bankA, bankB } = await seedWrong()
    const w = await open(`/bank/${bankA}`, BankView, { id: bankA })
    const link = button(w, '本题库错题本')
    expect(link.text()).toContain('2 题')
    expect(link.attributes('disabled')).toBeUndefined()
    await link.trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe('/wrong')
    expect(router.currentRoute.value.query.bank).toBe(bankA)
    w.unmount()

    // A bank whose questions were never answered wrongly.
    bank = `${bankB}c`
    await seed(2)
    const empty = await open(`/bank/${bank}`, BankView, { id: bank })
    expect(button(empty, '本题库错题本').attributes('disabled')).toBeDefined()
    expect(empty.text()).toContain('没有错题')
    empty.unmount()
  })
})

describe('SearchView', () => {
  const type = async (w: VueWrapper, text: string) => {
    await w.find('input').setValue(text)
    await new Promise((r) => setTimeout(r, 260)) // the box is debounced by 200 ms
    await flush()
  }

  async function seedSearch() {
    const repo = await getRepo()
    await repo.db.put('banks', { id: bank, title: `题库${bankSeq}`, description: '', question_count: 4 })
    const qs = [
      question(`${bank}-1`, { stem: '读写锁允许多个读者同时持有锁' }),
      question(`${bank}-2`, { stem: '互斥锁只允许一个线程持有', explanation: '和读写锁相比，互斥锁更简单' }),
      question(`${bank}-3`, { stem: '哪个是缓存淘汰算法', tags: ['LRU'], options: ['先进先出', 'LRU', '随机', '轮转'] }),
      question(`${bank}-4`, { stem: '被服务器撤回的题 读写锁', hidden: true }),
    ]
    for (const q of qs) await repo.db.put('questions', q)
    return qs
  }

  it('finds questions as you type, highlights the words and says where a hidden match is', async () => {
    await seedSearch()
    const w = await open(`/bank/${bank}/search`, SearchView, { id: bank })
    expect(w.text()).toContain('输入关键词开始搜索')

    await type(w, '读写锁')
    expect(w.text()).toContain('找到 2 题')
    expect(w.findAll('.card')).toHaveLength(2) // the withdrawn question is not offered
    expect(w.findAll('mark').map((m) => m.text())).toContain('读写锁')
    expect(w.findAll('.snippet')).toHaveLength(1) // only the one that matched in the explanation
    expect(w.find('.snippet').text()).toContain('解析')

    await type(w, 'lru 缓存')
    expect(w.text()).toContain('找到 1 题')
    await type(w, 'ＬＲＵ')
    expect(w.text()).toContain('找到 1 题')
    expect(w.find('.snippet').text()).toContain('选项') // the option "LRU" comes before the tag
    w.unmount()
  })

  it('says so when nothing matches, and shows nothing for a blank box', async () => {
    await seedSearch()
    const w = await open(`/bank/${bank}/search`, SearchView, { id: bank })
    await type(w, '不存在的词')
    expect(w.text()).toContain('没有找到')
    expect(w.findAll('.card')).toHaveLength(0)
    await type(w, '   ')
    expect(w.text()).not.toContain('没有找到')
    expect(w.text()).toContain('输入关键词开始搜索')
    w.unmount()
  })

  it('starts the quiz from the tapped result over the whole result list, or practises all of it', async () => {
    const qs = await seedSearch()
    const w = await open(`/bank/${bank}/search`, SearchView, { id: bank })
    await type(w, '锁')
    await w.findAll('.card button')[1].trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe('/quiz')
    expect(pendingQuiz.value!.questions.map((q) => q.id)).toEqual([qs[0].id, qs[1].id])
    expect(pendingQuiz.value!.startAt).toBe(1)
    expect(pendingQuiz.value!.scope).toBeUndefined() // a one-off search does not replace the bank's saved round
    expect(pendingQuiz.value!.title).toBe('搜索：锁')

    await router.push(`/bank/${bank}/search`)
    await type(w, '锁')
    await button(w, '练习这 2 道').trigger('click')
    await flush()
    expect(pendingQuiz.value!.questions.map((q) => q.id).sort()).toEqual([qs[0].id, qs[1].id].sort())
    w.unmount()
  })

  it('draws at most 100 rows and tells how many more there are', async () => {
    const repo = await getRepo()
    await repo.db.put('banks', { id: bank, title: 'big', description: '', question_count: 130 })
    for (let i = 0; i < 130; i++) await repo.db.put('questions', question(`${bank}-${i}`, { stem: `共同的词 ${i}` }))
    const w = await open(`/bank/${bank}/search`, SearchView, { id: bank })
    await type(w, '共同的词')
    expect(w.text()).toContain('找到 130 题')
    expect(w.findAll('.card')).toHaveLength(100)
    expect(w.text()).toContain('还有 30 条，请缩小范围')
    w.unmount()
  })

  it('is reachable from the bank page', async () => {
    await seedSearch()
    const w = await open(`/bank/${bank}`, BankView, { id: bank })
    await button(w, '搜索题目').trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe(`/bank/${bank}/search`)
    w.unmount()
  })
})

describe('daily goal', () => {
  beforeEach(async () => {
    localStorage.clear()
    updateGoals(DEFAULT_GOALS)
    await (await getRepo()).db.clear('attempts')
  })

  /** Answers [n] questions of a fresh bank now. */
  async function answer(n: number) {
    const { repo, qs } = await seed(Math.max(n, 1))
    for (const q of qs.slice(0, n)) await repo.recordAnswer(q, [1], 1000)
  }

  it('shows no progress card without a goal', async () => {
    await answer(3)
    const w = await open('/', BanksView)
    expect(w.find('[aria-label="今日进度"]').exists()).toBe(false)
    w.unmount()
  })

  it('shows how far today is toward each goal, and celebrates when both are met', async () => {
    await answer(3)
    updateGoals({ questions: 5, minutes: 30 })
    const w = await open('/', BanksView)
    const card = w.find('[aria-label="今日进度"]')
    expect(card.text()).toContain('3 / 5 题')
    expect(card.text()).toContain('0 / 30 分钟')
    expect(card.text()).toContain('还差 2 题、30 分钟')
    expect(card.text()).not.toContain('目标完成')
    w.unmount()

    updateGoals({ questions: 3, minutes: null })
    const done = await open('/', BanksView)
    expect(done.find('[aria-label="今日进度"]').text()).toContain('今天的目标完成了')
    expect(done.find('[aria-label="今日进度"]').text()).not.toContain('分钟') // the minutes goal is off
    done.unmount()
  })

  it('turns into a reminder once the set time has passed and the goal is still open', async () => {
    await answer(1)
    updateGoals({ questions: 5, remind: true, remindAt: '00:00' }) // already past
    const due = await open('/', BanksView)
    expect(due.find('[aria-label="今日进度"]').classes()).toContain('due')
    expect(due.find('.goal-nudge').text()).toContain('还差 4 题')
    due.unmount()

    updateGoals({ remindAt: '23:59' })
    const early = new Date()
    if (early.getHours() === 23 && early.getMinutes() === 59) return // the one minute this cannot tell
    const w = await open('/', BanksView)
    expect(w.find('[aria-label="今日进度"]').classes()).not.toContain('due')
    w.unmount()

    updateGoals({ remindAt: '00:00', remind: false })
    const off = await open('/', BanksView)
    expect(off.find('[aria-label="今日进度"]').classes()).not.toContain('due')
    off.unmount()
  })

  it('the settings page sets and clears goals, with presets or a custom number, and the reminder time', async () => {
    const w = await open('/settings', SettingsView)
    const group = (label: string) => w.find(`[aria-label="${label}"][role="group"]`)

    await group('每天做题').findAll('button').find((b) => b.text() === '20')!.trigger('click')
    await group('每天学习').findAll('button').find((b) => b.text() === '自定义')!.trigger('click')
    await flush()
    const input = w.find('input[aria-label="每天学习（自定义）"]')
    await input.setValue('45')
    expect(JSON.parse(localStorage.getItem('quizmind.goals')!)).toMatchObject({ questions: 20, minutes: 45 })

    expect(w.find('input[aria-label="提醒时间"]').exists()).toBe(false)
    await w.find('input[aria-label="每日提醒"]').setValue(true)
    await w.find('input[aria-label="提醒时间"]').setValue('21:30')
    expect(JSON.parse(localStorage.getItem('quizmind.goals')!)).toMatchObject({ remind: true, remindAt: '21:30' })
    expect(w.text()).toContain('不会在后台弹通知')

    await group('每天做题').findAll('button').find((b) => b.text() === '关闭')!.trigger('click')
    expect(JSON.parse(localStorage.getItem('quizmind.goals')!).questions).toBeNull()
    w.unmount()
  })
})

describe('study text', () => {
  const lesson = (id: string, o: Partial<Lesson> = {}): Lesson => ({
    id: `${bank}-${id}`, bank_id: bank, document_id: `${bank}-d1`, document_title: '讲义（操作系统）', document_created_at: 1, seq: 0,
    heading_path: `讲义 > ${id} 标题`, text: `${id} 第一句。${id} 第二句。`, ...o,
  })

  /** Two chapters of two sections; questions q1,q2 belong to L1 and q3 to L3. */
  async function seedLessons() {
    const { repo, qs } = await seed(3)
    for (const [i, q] of qs.entries()) await repo.db.put('questions', { ...q, chunk_id: `${bank}-${i < 2 ? 'L1' : 'L3'}` })
    const ls = [
      lesson('L1'),
      lesson('L2', { seq: 1 }),
      lesson('L3', { document_id: `${bank}-d2`, document_title: '讲义（数据库）', document_created_at: 2 }),
      lesson('L4', { document_id: `${bank}-d2`, document_title: '讲义（数据库）', document_created_at: 2, seq: 1 }),
    ]
    for (const l of ls) await repo.db.put('lessons', l)
    return { repo, qs, ls }
  }

  it('the bank page offers the study text only when the bank has some, with how much was read', async () => {
    await seed(1)
    const plain = await open(`/bank/${bank}`, BankView, { id: bank })
    expect(plain.text()).not.toContain('先学后练')
    plain.unmount()

    const { repo, ls } = await seedLessons()
    await repo.markLessonRead(ls[0])
    const w = await open(`/bank/${bank}`, BankView, { id: bank })
    expect(button(w, '先学后练').text()).toContain('1 / 4')
    await button(w, '先学后练').trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe(`/bank/${bank}/learn`)
    w.unmount()
  })

  it('the contents page groups sections by chapter, opens the one to study next and goes on from there', async () => {
    const { repo, ls } = await seedLessons()
    await repo.markLessonRead(ls[0])
    await repo.markLessonRead(ls[1])
    const w = await open(`/bank/${bank}/learn`, LearnView, { id: bank })

    expect(w.text()).toContain('已读 2 / 4 节')
    expect(w.text()).toContain('操作系统')
    expect(w.text()).toContain('数据库')
    // L3 is the first never opened: its chapter is open, the finished one is not.
    expect(w.text()).toContain('L3 标题')
    expect(w.text()).not.toContain('L1 标题')
    expect(button(w, '继续学习').text()).toContain('L3 标题')

    await button(w, '操作系统').trigger('click')
    await flush()
    expect(w.text()).toContain('L1 标题')
    expect(w.text()).toContain('2 题')
    expect(w.text()).toContain('已读')

    await button(w, 'L2 标题').trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe(`/bank/${bank}/learn/${bank}-L2`)
    w.unmount()
  })

  it('says so when the bank has no study text', async () => {
    await seed(1)
    const w = await open(`/bank/${bank}/learn`, LearnView, { id: bank })
    expect(w.text()).toContain('还没有讲义')
    w.unmount()
  })

  it('a section is read one sentence per line and can be covered for recall', async () => {
    const { ls } = await seedLessons()
    const w = await open(`/bank/${bank}/learn/${ls[0].id}`, LessonView, { id: bank, lessonId: ls[0].id })
    expect(w.findAll('.sentence').map((s) => s.text())).toEqual(['L1 第一句。', 'L1 第二句。'])
    expect(w.findAll('.sentence.covered')).toHaveLength(0)

    await button(w, '背诵遮盖').trigger('click')
    expect(w.findAll('.sentence.covered')).toHaveLength(2)
    await w.findAll('.sentence')[0].trigger('click')
    expect(w.findAll('.sentence.covered')).toHaveLength(1)
    await w.findAll('.sentence')[0].trigger('click')
    expect(w.findAll('.sentence.covered')).toHaveLength(2)
    await button(w, '显示全部').trigger('click')
    expect(w.findAll('.sentence.covered')).toHaveLength(0)
    w.unmount()
  })

  it('covering also hides list items and every table cell but the first of a row, one tap at a time', async () => {
    const { ls } = await seedLessons()
    const text = '**要点**\n\n- 甲项\n- 乙项\n  - 乙一\n\n| 名称 | 含义 |\n|---|---|\n| 阿 | 解释阿 |\n| 波 | 解释波 |'
    const repo = await getRepo()
    await repo.db.put('lessons', { ...ls[0], text })
    const w = await open(`/bank/${bank}/learn/${ls[0].id}`, LessonView, { id: bank, lessonId: ls[0].id })
    const body = w.find('.lesson-body')
    expect(body.classes()).not.toContain('covering')

    await button(w, '背诵遮盖').trigger('click')
    expect(body.classes()).toContain('covering')
    const cells = w.findAll('td')
    await cells[1].trigger('click') // 解释阿
    expect(cells[1].classes()).toContain('shown')
    expect(cells[3].classes()).not.toContain('shown')
    await cells[0].trigger('click') // the cue column is never covered, so a tap does nothing
    expect(cells[0].classes()).not.toContain('shown')

    const items = w.findAll('li')
    await items[2].trigger('click') // 乙一, inside the still-covered 乙项: uncovers the outer item first
    expect(items[1].classes()).toContain('shown')
    expect(items[2].classes()).not.toContain('shown')
    await items[2].trigger('click')
    expect(items[2].classes()).toContain('shown')

    await button(w, '显示全部').trigger('click')
    await flush()
    expect(w.findAll('.shown')).toHaveLength(0)
    w.unmount()
  })

  it('"学完了" marks the section read and starts a quiz on exactly its questions', async () => {
    const { repo, qs, ls } = await seedLessons()
    const w = await open(`/bank/${bank}/learn/${ls[0].id}`, LessonView, { id: bank, lessonId: ls[0].id })
    expect(w.text()).toContain('本节 2 题')

    await button(w, '做这一节的 2 道题').trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe('/quiz')
    expect(pendingQuiz.value?.questions.map((q) => q.id).sort()).toEqual([qs[0].id, qs[1].id])
    expect(pendingQuiz.value?.title).toContain('L1 标题')
    expect((await repo.lessonReadIds(bank)).has(ls[0].id)).toBe(true)
    w.unmount()
  })

  it('a section without questions goes straight on to the next, and neighbours cross chapters', async () => {
    const { repo, ls } = await seedLessons()
    const w = await open(`/bank/${bank}/learn/${ls[1].id}`, LessonView, { id: bank, lessonId: ls[1].id })
    expect(w.text()).not.toContain('道题')
    expect(button(w, '上一节').attributes('disabled')).toBeUndefined()

    await button(w, '学完了，下一节').trigger('click')
    await flush()
    expect(router.currentRoute.value.path).toBe(`/bank/${bank}/learn/${ls[2].id}`) // first section of the next chapter
    expect((await repo.lessonReadIds(bank)).has(ls[1].id)).toBe(true)
    w.unmount()

    const first = await open(`/bank/${bank}/learn/${ls[0].id}`, LessonView, { id: bank, lessonId: ls[0].id })
    expect(button(first, '上一节').attributes('disabled')).toBeDefined()
    await button(first, '标记为已读').trigger('click')
    await flush()
    expect(first.text()).toContain('已读（点此取消）')
    await button(first, '已读（点此取消）').trigger('click')
    await flush()
    expect((await repo.lessonReadIds(bank)).has(ls[0].id)).toBe(false)
    first.unmount()
  })

  it('says so for a section that is not there', async () => {
    await seedLessons()
    const w = await open(`/bank/${bank}/learn/nope`, LessonView, { id: bank, lessonId: 'nope' })
    expect(w.text()).toContain('这一节不存在')
    w.unmount()
  })

  it('a question offers its section while practising, in a sheet over the quiz', async () => {
    const { repo, ls } = await seedLessons()
    await startQuiz('练习', [(await repo.bankQuestions(bank))[0]]) // the copy that knows its section
    const w = await open('/quiz', QuizView)
    expect(w.text()).not.toContain('看这一节讲义') // only once the question is answered

    await w.findAll('.option')[1].trigger('click')
    await button(w, '提交').trigger('click')
    await flush()
    await button(w, '看这一节讲义').trigger('click')
    await flush()
    expect(w.find('[aria-label="讲义"]').text()).toContain('L1 第一句。')
    expect(w.find('[aria-label="讲义"]').text()).toContain('L1 标题')
    await button(w, '关闭').trigger('click')
    expect(w.find('[aria-label="讲义"]').exists()).toBe(false)
    expect(await repo.lesson(ls[0].id)).toBeTruthy()
    w.unmount()
  })
})

describe('study assistant', () => {
  let api: FakeAgentApi
  const input = (w: VueWrapper) => w.find('[data-testid="agent-input"]')
  const type = async (w: VueWrapper, text: string) => {
    await input(w).setValue(text)
  }
  const sendBtn = (w: VueWrapper) => w.find('[data-testid="agent-send"]')
  const done = { kind: 'done', stop: 'end_turn', inputTokens: 1, outputTokens: 1 } as const

  beforeEach(() => {
    localStorage.clear()
    setAgentToken('tok')
    api = new FakeAgentApi()
    setAgentApi(api)
  })

  describe('AgentView', () => {
    describe('files', () => {
      const attach = async (w: VueWrapper, ...files: File[]) => {
        const el = w.find('[data-testid="agent-file-input"]').element as HTMLInputElement
        Object.defineProperty(el, 'files', { value: files, configurable: true })
        await w.find('[data-testid="agent-file-input"]').trigger('change')
        await flush()
      }
      const md = (name: string) => new File(['# 笔记'], name, { type: 'text/markdown' })

      it('a chosen file shows above the box, goes with the question, and shows as a tag on it', async () => {
        api.events = [{ kind: 'delta', text: '好' }, done]
        const w = await open('/agent?bank=b1', AgentView)
        expect(w.find('[data-testid="agent-files"]').exists()).toBe(false)
        expect(w.find('[data-testid="agent-file-input"]').attributes('accept')).toContain('.md')

        await attach(w, md('笔记.md'))
        expect(w.find('[data-testid="agent-file"]').text()).toContain('笔记.md')
        // A file alone is enough to send.
        expect(sendBtn(w).attributes('disabled')).toBeUndefined()
        await type(w, '总结一下')
        await sendBtn(w).trigger('click')
        await flush()
        expect(api.requests[0].message).toEqual({ text: '总结一下', attachmentIds: ['F1'] })
        expect(w.find('[data-testid="agent-files"]').exists()).toBe(false)
        expect(w.find('.bubble.user [data-testid="agent-file-tag"]').text()).toContain('笔记.md')
        w.unmount()
      })

      it('shows why a file was turned away, lets it be taken off, and does not send it', async () => {
        const w = await open('/agent', AgentView)
        await attach(w, new File(['x'], 'a.pdf'))
        expect(w.find('[data-testid="agent-file"]').text()).toContain('不支持这种文件')
        await type(w, '你好')
        await w.find('[data-testid="agent-file-remove"]').trigger('click')
        await flush()
        expect(w.find('[data-testid="agent-files"]').exists()).toBe(false)
        expect(api.uploads).toEqual([])
        w.unmount()
      })

      it('removing an uploaded file removes it on the server', async () => {
        const w = await open('/agent', AgentView)
        await attach(w, md('a.md'))
        await w.find('[data-testid="agent-file-remove"]').trigger('click')
        await flush()
        expect(api.removed).toEqual(['F1'])
        w.unmount()
      })

      it('the plus button is off without a connection, and when the files are at their limit', async () => {
        setAgentToken('')
        let w = await open('/agent', AgentView)
        expect(w.find('[data-testid="agent-attach"]').attributes('disabled')).toBeDefined()
        w.unmount()

        setAgentToken('tok')
        w = await open('/agent', AgentView)
        expect(w.find('[data-testid="agent-attach"]').attributes('disabled')).toBeUndefined()
        await attach(w, md('1.md'), md('2.md'), md('3.md'), md('4.md'))
        expect(w.find('[data-testid="agent-attach"]').attributes('disabled')).toBeDefined()
        w.unmount()
      })

      describe('pictures', () => {
        const attachImage = async (w: VueWrapper, ...files: File[]) => {
          const el = w.find('[data-testid="agent-image-input"]').element as HTMLInputElement
          Object.defineProperty(el, 'files', { value: files, configurable: true })
          await w.find('[data-testid="agent-image-input"]').trigger('change')
          await flush()
        }
        const pic = (name: string) => new File(['png'], name, { type: 'image/png' })
        beforeEach(() => {
          URL.createObjectURL = vi.fn(() => 'blob:pic')
          URL.revokeObjectURL = vi.fn()
        })

        it('the plus button opens a choice only when the model can see; otherwise it picks a file at once', async () => {
          let w = await open('/agent', AgentView)
          const fileClick = vi.spyOn(w.find('[data-testid="agent-file-input"]').element as HTMLInputElement, 'click')
          await w.find('[data-testid="agent-attach"]').trigger('click')
          expect(fileClick).toHaveBeenCalled()
          expect(w.find('[data-testid="agent-attach-menu"]').exists()).toBe(false)
          w.unmount()

          api.statusValue = { ...api.statusValue, vision: true }
          w = await open('/agent', AgentView)
          const imageClick = vi.spyOn(w.find('[data-testid="agent-image-input"]').element as HTMLInputElement, 'click')
          await w.find('[data-testid="agent-attach"]').trigger('click')
          expect(w.find('[data-testid="agent-attach-menu"]').exists()).toBe(true)
          await w.find('[data-testid="agent-attach-image"]').trigger('click')
          expect(imageClick).toHaveBeenCalled()
          expect(w.find('[data-testid="agent-attach-menu"]').exists()).toBe(false)
          expect(w.find('[data-testid="agent-image-input"]').attributes('accept')).toContain('image/png')
          w.unmount()
        })

        it('a chosen picture shows as a thumbnail, goes with the question, and can be opened large', async () => {
          api.statusValue = { ...api.statusValue, vision: true }
          api.events = [{ kind: 'delta', text: '好' }, done]
          const w = await open('/agent', AgentView)
          await attachImage(w, pic('图.png'))
          expect(w.find('[data-testid="agent-file-preview"]').attributes('src')).toBe('blob:pic')
          await type(w, '这是什么')
          await sendBtn(w).trigger('click')
          await flush()
          expect(api.requests[0].message).toEqual({ text: '这是什么', attachmentIds: ['F1'] })
          expect(w.find('.bubble.user [data-testid="agent-file-tag"]').exists()).toBe(false)
          const thumb = w.find('.bubble.user [data-testid="agent-image"]')
          expect(thumb.find('img').attributes('src')).toBe('blob:pic')
          expect(api.fetched).toEqual([])

          expect(w.find('[data-testid="agent-image-big"]').exists()).toBe(false)
          await thumb.trigger('click')
          expect(w.find('[data-testid="agent-image-big"] img').attributes('src')).toBe('blob:pic')
          await w.find('[data-testid="agent-image-big"]').trigger('click')
          expect(w.find('[data-testid="agent-image-big"]').exists()).toBe(false)
          w.unmount()
        })

        it('a stored conversation fetches its pictures with the token to show them', async () => {
          api.keep('c1', {
            messages: [
              storedMessage({
                id: 1, role: 'user', text: '看',
                attachments: [{ id: 'A1', kind: 'image', name: 'p.png', mime: 'image/png', size: 3, chars: 0, width: 3, height: 2 }],
              }),
              storedMessage({ id: 2, role: 'assistant', text: '好' }),
            ],
          })
          const w = await open('/agent?conversation=c1', AgentView)
          await flush()
          expect(api.fetched).toEqual(['A1'])
          expect(w.find('[data-testid="agent-image"] img').attributes('src')).toBe('blob:pic')
          expect(w.find('[data-testid="agent-file-tag"]').exists()).toBe(false)
          w.unmount()
        })

        it('a picture is turned away with the reason while the model cannot see', async () => {
          const w = await open('/agent', AgentView)
          await attachImage(w, pic('图.png'))
          expect(w.find('[data-testid="agent-file"]').text()).toContain('不支持识别图片')
          expect(api.uploads).toEqual([])
          w.unmount()
        })
      })

      it('a stored conversation shows its files as tags', async () => {
        api.keep('c1', {
          messages: [
            storedMessage({ id: 1, role: 'user', text: '看', attachments: [{ id: 'A1', kind: 'text', name: 'n.md', mime: 'text/markdown', size: 3, chars: 3, width: 0, height: 0 }] }),
            storedMessage({ id: 2, role: 'assistant', text: '好' }),
          ],
        })
        const w = await open('/agent?conversation=c1', AgentView)
        expect(w.find('[data-testid="agent-file-tag"]').text()).toContain('n.md')
        w.unmount()
      })
    })

    it('asks for a token when there is none, and cannot send', async () => {
      setAgentToken('')
      const w = await open('/agent?bank=b1', AgentView)
      expect(w.find('[data-testid="agent-banner"]').text()).toContain('还没有填访问令牌')
      await type(w, '你好')
      expect(sendBtn(w).attributes('disabled')).toBeDefined()
      await w.find('[data-testid="agent-banner"] button').trigger('click')
      await flush()
      expect(router.currentRoute.value.path).toBe('/settings')
      w.unmount()
    })

    it('says so when the token is wrong, or the server has no assistant', async () => {
      api.statusError = new AgentError('访问令牌不对或还没设置', 401)
      let w = await open('/agent', AgentView)
      expect(w.find('[data-testid="agent-banner"]').text()).toContain('访问令牌不对或还没设置')
      expect(w.find('[data-testid="agent-banner"] button').text()).toBe('去设置')
      w.unmount()

      api.statusError = new AgentError('AI 助手还没有启用', 404)
      w = await open('/agent', AgentView)
      expect(w.find('[data-testid="agent-banner"]').text()).toContain('AI 助手还没有启用')
      expect(w.find('[data-testid="agent-banner"] button').exists()).toBe(false)
      w.unmount()
    })

    it('offline: explains and offers a retry, which brings it back', async () => {
      api.statusError = new AgentError('连不上服务器，请确认地址正确并已联网')
      const w = await open('/agent', AgentView)
      expect(w.find('[data-testid="agent-banner"]').text()).toContain('连不上服务器')
      api.statusError = null
      await w.find('[data-testid="agent-banner"] button').trigger('click')
      await flush()
      expect(w.find('[data-testid="agent-banner"]').exists()).toBe(false)
      await type(w, '你好')
      expect(sendBtn(w).attributes('disabled')).toBeUndefined()
      w.unmount()
    })

    it('a quick prompt asks right away; the answer and its lookups show', async () => {
      api.events = [
        { kind: 'tool', id: 't1', name: 'search_lessons', label: '在讲义里查找…', status: 'done' },
        { kind: 'delta', text: '读写锁**允许**多个读者。' },
        done,
      ]
      const w = await open('/agent?bank=b1', AgentView)
      expect(w.text()).toContain('可以问我讲义里的内容')
      await w.findAll('.chip.pick')[0].trigger('click')
      await flush()
      expect(api.requests[0].message.text).toBe('我哪里比较薄弱？')
      expect(w.text()).toContain('在讲义里查找…')
      expect(w.find('.bubble.bot strong').text()).toBe('允许')
      expect(w.find('.bubble.user').text()).toBe('我哪里比较薄弱？')
      w.unmount()
    })

    it('typing and sending clears the box; stop appears while the answer is written and keeps what came', async () => {
      api.events = [{ kind: 'delta', text: '写到一半' }]
      api.holdOpen = true
      const w = await open('/agent', AgentView)
      await type(w, '讲讲锁')
      await sendBtn(w).trigger('click')
      await flush()
      expect((input(w).element as HTMLTextAreaElement).value).toBe('')
      expect(w.find('[data-testid="agent-stop"]').exists()).toBe(true)
      expect(sendBtn(w).exists()).toBe(false)
      await w.find('[data-testid="agent-stop"]').trigger('click')
      await flush()
      expect(w.text()).toContain('写到一半')
      expect(w.text()).toContain('已停止')
      expect(w.find('[data-testid="agent-stop"]').exists()).toBe(false)
      w.unmount()
    })

    it('leaving the page stops the answer on the server', async () => {
      api.holdOpen = true
      const w = await open('/agent', AgentView)
      await type(w, '讲讲锁')
      await sendBtn(w).trigger('click')
      await flush()
      w.unmount()
      await flush()
      expect(api.requests).toHaveLength(1) // and the held stream was released, or the test would hang
    })

    it('the text from the address is put in the box, not sent', async () => {
      const w = await open('/agent?question=q1&selected=2&text=' + encodeURIComponent('我还是没懂，'), AgentView)
      expect((input(w).element as HTMLTextAreaElement).value).toBe('我还是没懂，')
      expect(api.requests).toHaveLength(0)
      await sendBtn(w).trigger('click')
      await flush()
      expect(api.requests[0].context).toMatchObject({ questionId: 'q1', selected: [2] })
      w.unmount()
    })

    it('a diagram in the answer shows as a picture, and an unsafe one as code', async () => {
      const ns = 'xmlns="http://www.w3.org/2000/svg"'
      api.events = [
        { kind: 'delta', text: `流程：\n\n\`\`\`svg\n<svg ${ns} viewBox="0 0 9 9"><rect width="4" height="4"/></svg>\n\`\`\`\n\n再看：<svg ${ns}><script>alert(1)</script></svg>` },
        done,
      ]
      const w = await open('/agent', AgentView)
      await w.findAll('.chip.pick')[0].trigger('click')
      await flush()
      const imgs = w.findAll('.bubble.bot img')
      expect(imgs).toHaveLength(1)
      expect(imgs[0].attributes('src')).toMatch(/^data:image\/svg\+xml/)
      expect(w.find('.bubble.bot pre').text()).toContain('<script>')
      expect(w.find('.bubble.bot script').exists()).toBe(false)
      w.unmount()
    })

    it('a lesson or question link opens what it points at in a sheet; one this device lacks says so', async () => {
      const { repo, qs } = await seed(1)
      await repo.db.put('lessons', {
        id: `${bank}-L1`, bank_id: bank, document_id: `${bank}-d1`, document_title: '讲义', document_created_at: 1, seq: 0,
        heading_path: '讲义 > 锁', text: '锁第一句。',
      })
      api.events = [
        { kind: 'delta', text: `见[这一节](lesson:${bank}-L1)和[这道题](question:${qs[0].id})，还有[缺的](lesson:nope)、[外链](https://example.com)。` },
        done,
      ]
      const w = await open('/agent', AgentView)
      await w.findAll('.chip.pick')[0].trigger('click')
      await flush()
      const links = w.findAll('.bubble.bot a')
      expect(links[3].attributes('target')).toBe('_blank') // an ordinary link is left to the browser

      await links[0].trigger('click')
      await flush()
      expect(w.find('[aria-label="讲义"]').text()).toContain('锁第一句。')
      await button(w, '关闭').trigger('click')

      await links[1].trigger('click')
      await flush()
      const sheet = w.find('[aria-label="题目"]')
      expect(sheet.text()).toContain(`题干 ${qs[0].id}`)
      expect(sheet.findAll('.draft-opt.right')).toHaveLength(1)
      expect(sheet.text()).toContain(`解析 ${qs[0].id}`)
      await button(w, '关闭').trigger('click')

      await links[2].trigger('click')
      await flush()
      expect(toast.text).toContain('找不到')
      expect(router.currentRoute.value.path).toBe('/agent')
      w.unmount()
    })

    describe('question-writing', () => {
      const writing = async (drafts = [adoptedDraft('D1')]) => {
        api.events = [{ kind: 'delta', text: '出好了：' }, { kind: 'drafts', drafts }, done]
        const w = await open('/agent?bank=b1', AgentView)
        await w.findAll('.chip.pick').find((c) => c.text() === '帮我出 5 道单选题')!.trigger('click')
        await flush()
        return w
      }
      const sw = (w: VueWrapper, id: string) => w.find(`[data-testid="draft-switch-${id}"]`)
      const adopted = (w: VueWrapper, id: string) => (sw(w, id).element as HTMLInputElement).checked

      it('a new question is adopted already; the switch takes it back and adopts it again', async () => {
        const w = await writing()
        const card = w.find('[data-testid="draft-group"]')
        expect(card.text()).toContain('出了 1 道题')
        expect(card.find('[data-testid="drafts-summary"]').text()).toContain('已采纳 1 道')
        expect(adopted(w, 'D1')).toBe(true)
        expect(api.accepted).toEqual([])
        // One question is shown open: the stem, the options with the answer marked.
        expect(card.text()).toContain('读写锁的特点是什么？')
        expect(card.text()).toContain('未经独立复核')
        expect(card.findAll('.draft-opt.right')).toHaveLength(1)
        expect(card.find('.draft-opt.right').text()).toContain('多个读者同时持有')
        expect(api.requests[0].mode).toBeUndefined()

        await sw(w, 'D1').setValue(false)
        await flush()
        expect(api.discarded).toEqual(['D1'])
        expect(adopted(w, 'D1')).toBe(false)
        expect(card.find('[data-testid="drafts-summary"]').text()).toContain('已采纳 0 道')

        await sw(w, 'D1').setValue(true)
        await flush()
        expect(api.accepted).toEqual(['D1'])
        expect(adopted(w, 'D1')).toBe(true)
        w.unmount()
      })

      it('an older server leaves the question to the learner: the switch starts off', async () => {
        const w = await writing([draft('D1')])
        expect(adopted(w, 'D1')).toBe(false)
        await sw(w, 'D1').setValue(true)
        await flush()
        expect(api.accepted).toEqual(['D1'])
        expect(adopted(w, 'D1')).toBe(true)
        w.unmount()
      })

      it('a long run of questions is one card: a line each, opened one at a time, all at once on request', async () => {
        const w = await writing([1, 2, 3, 4, 5, 6].map((n) => adoptedDraft(`D${n}`)))
        const card = w.find('[data-testid="draft-group"]')
        expect(card.text()).toContain('出了 6 道题')
        expect(w.findAll('input.switch')).toHaveLength(6)
        expect(card.findAll('.draft-opt')).toHaveLength(0) // folded: only the stems show

        await w.find('[data-testid="draft-row-D3"]').trigger('click')
        expect(card.findAll('.draft-opt').length).toBeGreaterThan(0)
        await w.find('[data-testid="draft-row-D3"]').trigger('click')
        expect(card.findAll('.draft-opt')).toHaveLength(0)

        await w.find('[data-testid="drafts-all"]').trigger('click')
        await flush()
        expect(api.discarded).toEqual(['D1', 'D2', 'D3', 'D4', 'D5', 'D6'])
        expect(w.find('[data-testid="drafts-all"]').text()).toBe('全部采纳')
        await w.find('[data-testid="drafts-all"]').trigger('click')
        await flush()
        expect(api.accepted).toEqual(['D1', 'D2', 'D3', 'D4', 'D5', 'D6'])

        await w.find('[data-testid="drafts-header"]').trigger('click')
        expect(w.findAll('input.switch')).toHaveLength(0) // folded up to the header
        w.unmount()
      })

      it('a refused change shows the reason and the switch goes back', async () => {
        const w = await writing()
        api.decideError = new AgentError('网络不通', 500)
        await sw(w, 'D1').setValue(false)
        await flush()
        expect(w.find('[data-testid="draft-group"]').text()).toContain('网络不通')
        expect(adopted(w, 'D1')).toBe(true) // still adopted: the server did not take it back
        w.unmount()
      })

      it('asking for a rewrite fills the box with the question id', async () => {
        const w = await writing()
        await w.find('[data-testid="draft-revise-D1"]').trigger('click')
        await flush()
        const box = (input(w).element as HTMLTextAreaElement).value
        expect(box).toContain('draft_id：D1')
        expect(box).toContain('读写锁的特点是什么？')
        w.unmount()
      })
    })
  })

  describe('history', () => {
    const old = async () => {
      await seed(1)
      api.keep('c-old', { title: '死锁的四个条件', bankId: bank, at: 1, messages: [storedMessage({ role: 'user', text: '死锁？' })] })
      api.keep('c-make', {
        mode: 'create', title: '用这一节出 3 道单选题', bankId: bank, lessonId: 'L1', at: 2,
        messages: [
          storedMessage({ id: 1, role: 'user', text: '出 3 道题' }),
          storedMessage({
            id: 2, role: 'assistant', text: '出好了：', tools: [{ id: 't', label: '读取讲义「锁」', status: 'done' }],
            drafts: [
              { draft: draft('D1'), phase: 'pending' },
              { draft: draft('D2'), phase: 'accepted' },
              { draft: draft('D3'), phase: 'discarded' },
            ],
          }),
        ],
      })
    }

    it('lists the conversations newest first, with their bank, time and waiting drafts', async () => {
      await old()
      const w = await open('/agent/history', AgentHistoryView)
      const rows = w.findAll('[data-testid="history-row"]')
      expect(rows).toHaveLength(2)
      expect(rows[0].text()).toContain('用这一节出 3 道单选题')
      expect(rows[0].text()).toContain(`题库${bankSeq}`)
      expect(rows[0].text()).toContain('1 道草稿待处理')
      expect(rows[1].text()).toContain('死锁的四个条件')
      expect(rows[1].text()).toContain(`题库${bankSeq}`)
      expect(rows[1].text()).not.toContain('草稿待处理')
      w.unmount()
    })

    it('says so when there is nothing, no token, or the server cannot be reached (and tries again)', async () => {
      let w = await open('/agent/history', AgentHistoryView)
      expect(w.find('[data-testid="history-empty"]').exists()).toBe(true)
      w.unmount()

      setAgentToken('')
      w = await open('/agent/history', AgentHistoryView)
      expect(w.find('[data-testid="history-no-token"]').exists()).toBe(true)
      w.unmount()

      setAgentToken('tok')
      api.keep('c-1', { title: '一场对话' })
      api.listError = new AgentError('连不上服务器，请确认地址正确并已联网')
      w = await open('/agent/history', AgentHistoryView)
      expect(w.find('[data-testid="history-error"]').text()).toContain('连不上服务器')
      api.listError = null
      await button(w, '重试').trigger('click')
      await flush()
      expect(w.findAll('[data-testid="history-row"]')).toHaveLength(1)
      w.unmount()
    })

    it('loads more when there are more than a page', async () => {
      for (let i = 1; i <= 35; i++) api.keep(`c-${i}`, { title: `第 ${i} 场`, at: i })
      const w = await open('/agent/history', AgentHistoryView)
      expect(w.findAll('[data-testid="history-row"]')).toHaveLength(30)
      await w.find('[data-testid="history-more"]').trigger('click')
      await flush()
      expect(w.findAll('[data-testid="history-row"]')).toHaveLength(35)
      expect(w.find('[data-testid="history-more"]').exists()).toBe(false)
      expect(w.findAll('[data-testid="history-row"]')[34].text()).toContain('第 1 场')
      w.unmount()
    })

    it('deletes a conversation after asking, and keeps it when the learner says no', async () => {
      await old()
      const w = await open('/agent/history', AgentHistoryView)
      const ask = vi.fn(() => false)
      vi.stubGlobal('confirm', ask)
      await w.findAll('[aria-label="删除对话"]')[0].trigger('click')
      await flush()
      expect(ask).toHaveBeenCalledWith(expect.stringContaining('1 道没处理的草稿也会被丢弃'))
      expect(api.deleted).toEqual([])
      expect(w.findAll('[data-testid="history-row"]')).toHaveLength(2)

      vi.stubGlobal('confirm', () => true)
      await w.findAll('[aria-label="删除对话"]')[0].trigger('click')
      await flush()
      expect(api.deleted).toEqual(['c-make'])
      expect(w.findAll('[data-testid="history-row"]')).toHaveLength(1)
      w.unmount()
    })

    it('opens a conversation in the chat page: its messages, lookups and cards as they stood, and carries on', async () => {
      await old()
      const h = await open('/agent/history', AgentHistoryView)
      await h.findAll('[data-testid="history-row"] button.plain')[0].trigger('click')
      await flush()
      expect(router.currentRoute.value.path).toBe('/agent')
      expect(router.currentRoute.value.query).toEqual({ conversation: 'c-make' })
      h.unmount()

      const w = await open('/agent?conversation=c-make', AgentView)
      expect(w.find('h1').text()).toBe('AI 助手')
      expect(w.find('.bubble.user').text()).toBe('出 3 道题')
      expect(w.text()).toContain('读取讲义「锁」')
      // The three questions are one card; each switch shows where its question stands.
      expect(w.findAll('[data-testid="draft-group"]')).toHaveLength(1)
      expect(w.find('[data-testid="drafts-summary"]').text()).toContain('已采纳 1 道')
      const on = (id: string) => (w.find(`[data-testid="draft-switch-${id}"]`).element as HTMLInputElement).checked
      expect([on('D1'), on('D2'), on('D3')]).toEqual([false, true, false])

      // The one that still waits can be decided, and the next question goes into the same conversation.
      await w.find('[data-testid="draft-switch-D1"]').setValue(true)
      await flush()
      expect(api.accepted).toEqual(['D1'])
      api.events = [{ kind: 'delta', text: '好' }, done]
      await type(w, '再出一道')
      await sendBtn(w).trigger('click')
      await flush()
      expect(api.requests[0]).toMatchObject({ conversationId: 'c-make', message: { text: '再出一道' }, context: { bankId: bank, lessonId: 'L1' } })
      w.unmount()
    })

    it('says so when the conversation is gone', async () => {
      const w = await open('/agent?conversation=nope', AgentView)
      expect(w.find('[data-testid="agent-open-error"]').text()).toContain('已经不存在')
      w.unmount()
    })

    it('the page links to the history, and "new conversation" starts over from the same place', async () => {
      const w = await open('/agent?bank=b1&lesson=L1', AgentView)
      expect(w.find('[data-testid="agent-new"]').exists()).toBe(false) // nothing to leave yet
      api.events = [{ kind: 'delta', text: '好' }, done]
      await w.findAll('.chip.pick')[0].trigger('click')
      await flush()
      expect(w.findAll('.bubble')).toHaveLength(2)

      await w.find('[data-testid="agent-new"]').trigger('click')
      await flush()
      expect(router.currentRoute.value.query).toEqual({ bank: 'b1', lesson: 'L1' })
      expect(w.findAll('.bubble')).toHaveLength(0)
      expect(w.text()).toContain('可以问我讲义里的内容')
      await w.findAll('.chip.pick')[0].trigger('click')
      await flush()
      expect(api.requests).toHaveLength(2)
      expect(api.requests[1].conversationId).not.toBe(api.requests[0].conversationId)

      await w.find('[data-testid="agent-history"]').trigger('click')
      await flush()
      expect(router.currentRoute.value.path).toBe('/agent/history')
      w.unmount()
    })
  })

  describe('entry points', () => {
    it('the bank page opens the assistant', async () => {
      await seed(1)
      const w = await open(`/bank/${bank}`, BankView, { id: bank })
      expect(w.find('[data-testid="bank-ai-questions"]').exists()).toBe(false) // one entry now
      await w.find('[data-testid="bank-ask-ai"]').trigger('click')
      await flush()
      expect(router.currentRoute.value.path).toBe('/agent')
      expect(router.currentRoute.value.query).toEqual({ bank })
      w.unmount()
    })

    it('a section opens it on that section, with the question-writing request ready in the box', async () => {
      const { repo } = await seed(1)
      await repo.db.put('lessons', {
        id: `${bank}-L1`, bank_id: bank, document_id: `${bank}-d1`, document_title: '讲义', document_created_at: 1, seq: 0,
        heading_path: '讲义 > 锁', text: '锁第一句。',
      })
      const w = await open(`/bank/${bank}/learn/${bank}-L1`, LessonView, { id: bank, lessonId: `${bank}-L1` })
      await w.find('[data-testid="lesson-ask-ai"]').trigger('click')
      await flush()
      expect(router.currentRoute.value.query).toEqual({ bank, lesson: `${bank}-L1` })
      await router.push(`/bank/${bank}/learn/${bank}-L1`)
      await w.find('[data-testid="lesson-ai-questions"]').trigger('click')
      await flush()
      expect(router.currentRoute.value.query).toMatchObject({ lesson: `${bank}-L1`, text: '用这一节出 3 道单选题' })
      w.unmount()
    })

    it('"追问 AI" under the explanation opens the assistant on that question, only with a token', async () => {
      const { repo } = await seed(1)
      await startQuiz('练习', await repo.bankQuestions(bank))
      setAgentToken('')
      let w = await open('/quiz', QuizView)
      await w.findAll('.option')[0].trigger('click')
      await button(w, '提交').trigger('click')
      await flush()
      expect(w.find('[data-testid="ask-ai-more"]').exists()).toBe(false)
      w.unmount()

      setAgentToken('tok')
      await startQuiz('练习', await repo.bankQuestions(bank))
      w = await open('/quiz', QuizView)
      // Options are shuffled on screen; the assistant is told the index in the question itself.
      const picked = w.findAll('.option')[0]
      const original = ['甲', '乙', '丙', '丁'].findIndex((t) => picked.text().includes(t))
      await picked.trigger('click')
      await button(w, '提交').trigger('click')
      await flush()
      await w.find('[data-testid="ask-ai-more"]').trigger('click')
      await flush()
      expect(router.currentRoute.value.path).toBe('/agent')
      expect(router.currentRoute.value.query).toEqual({
        bank, question: `${bank}-q1`, selected: String(original), text: '我还是没懂，',
      })
      w.unmount()
    })

    it('the settings page keeps the access token on this device', async () => {
      setAgentToken('')
      const w = await open('/settings', SettingsView)
      await w.find('[data-testid="ai-token"]').setValue('  abc123 ')
      await w.find('[data-testid="ai-token"]').trigger('change')
      expect(localStorage.getItem('quizmind.ai.token')).toBe('abc123')
      await w.find('[data-testid="ai-token"]').setValue('')
      await w.find('[data-testid="ai-token"]').trigger('change')
      expect(localStorage.getItem('quizmind.ai.token')).toBeNull()
      w.unmount()
    })
  })
})
