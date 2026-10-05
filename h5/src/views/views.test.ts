// @vitest-environment happy-dom
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import router from '@/router'
import { getRepo } from '@/core/app'
import { DEFAULT_GOALS, updateGoals } from '@/core/goals'
import { newUlid } from '@/core/ulid'
import type { ExamDraft, ExamRecord, LocalQuestion } from '@/data/types'
import { pendingExam } from '@/quiz/examLaunch'
import { pendingQuiz, startQuiz } from '@/quiz/launch'
import ExamReviewView from './ExamReviewView.vue'
import ExamSetupView from './ExamSetupView.vue'
import ExamView from './ExamView.vue'
import BankView from './BankView.vue'
import BanksView from './BanksView.vue'
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
