<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { dataVersion, getRepo, showToast } from '@/core/app'
import { formatDuration, percent, type BankReport, type Tally } from '@/data/stats'
import type { Bank } from '@/data/types'
import { PASS_PERCENT } from '@/quiz/exam'
import { startQuiz } from '@/quiz/launch'

const props = defineProps<{ id: string }>()
const router = useRouter()
const bank = ref<Bank | null>(null)
const report = ref<BankReport | null>(null)

async function load() {
  const repo = await getRepo()
  bank.value = (await repo.banks()).find((b) => b.id === props.id) ?? null
  report.value = await repo.bankReport(props.id)
}
onMounted(load)
watch([dataVersion, () => props.id], load)

const coverage = computed(() =>
  report.value && report.value.totalQuestions ? Math.round((report.value.answeredQuestions * 100) / report.value.totalQuestions) : 0,
)
const range = ref<7 | 30>(7)
const days = computed(() => (range.value === 7 ? report.value?.daily : report.value?.daily30) ?? [])
const maxDaily = computed(() => Math.max(1, ...days.value.map((d) => d.attempts)))
const rangeTotal = computed(() => days.value.reduce((n, d) => n + d.attempts, 0))
// Related tags are merged by default ("UML 辨析" into "UML"); the detailed view lists them as tagged.
const merged = ref(true)
const tags = computed(() => (merged.value ? report.value?.byTagMerged : report.value?.byTag)?.slice(0, 8) ?? [])
const tagCount = computed(() => (merged.value ? report.value?.byTagMerged : report.value?.byTag)?.length ?? 0)

// Exam scores as a line, oldest to newest, with the pass line dashed.
const W = 300
const H = 130
const trend = computed(() => {
  const pts = report.value?.examTrend ?? []
  const x = (i: number) => (pts.length === 1 ? W / 2 : 24 + (i * (W - 40)) / (pts.length - 1))
  const y = (p: number) => 10 + ((100 - p) * (H - 24)) / 100
  return pts.map((p, i) => ({ ...p, x: x(i), y: y(p.percent) }))
})
const trendLine = computed(() => trend.value.map((p) => `${p.x},${p.y}`).join(' '))
const passY = 10 + ((100 - PASS_PERCENT) * (H - 24)) / 100
const weakest = computed(() => report.value?.weakest.slice(0, 5) ?? [])

const pct = (t: Tally) => percent(t)
/** Colour of an accuracy: green when solid, amber when shaky, red when poor. */
function tone(p: number | null) {
  if (p === null) return ''
  return p >= 80 ? 'good' : p >= 60 ? 'mid' : 'bad'
}

function practiseWeak() {
  const qs = report.value?.weakest.slice(0, 20).map((w) => w.question) ?? []
  if (qs.length === 0) return showToast('还没有做错过的题')
  startQuiz('薄弱题', qs)
}
</script>

<template>
  <header class="topbar">
    <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
    <h1 class="clamp">{{ bank?.title ?? '题库' }} · 统计</h1>
  </header>
  <main class="page">
    <p v-if="!report" class="muted center">加载中…</p>
    <p v-else-if="!bank" class="muted center">题库不存在，可能已被删除</p>
    <div v-else-if="report.attempts === 0" class="empty">
      <div class="big">📊</div>
      <p>还没有答题记录，做几道题再来看统计</p>
      <button class="btn primary" @click="router.back()">去刷题</button>
    </div>
    <template v-else>
      <div class="stat-grid">
        <div class="card col stat">
          <span class="muted small">总正确率</span>
          <strong class="big-num" :class="tone(report.accuracy)">{{ report.accuracy }}%</strong>
          <span class="muted small">答对 {{ report.correct }} / {{ report.attempts }} 次</span>
        </div>
        <div class="card col stat">
          <span class="muted small">覆盖率</span>
          <strong class="big-num">{{ coverage }}%</strong>
          <span class="muted small">做过 {{ report.answeredQuestions }} / {{ report.totalQuestions }} 题</span>
        </div>
        <div class="card col stat">
          <span class="muted small">连续学习</span>
          <strong class="big-num">{{ report.streakDays }}<small> 天</small></strong>
          <span class="muted small">累计 {{ formatDuration(report.studyMs) }}</span>
        </div>
        <div class="card col stat">
          <span class="muted small">当前状态</span>
          <strong class="big-num">{{ report.latestCorrect }}<small> 题</small></strong>
          <span class="muted small">最近一次答对 · 错题本 {{ report.wrongBook }}</span>
        </div>
      </div>

      <section class="card col">
        <div class="row between">
          <h2>最近 {{ range }} 天</h2>
          <div class="seg-toggle" role="group" aria-label="时间范围">
            <button :class="{ on: range === 7 }" @click="range = 7">7 天</button>
            <button :class="{ on: range === 30 }" @click="range = 30">30 天</button>
          </div>
        </div>
        <span class="muted small">共 {{ rangeTotal }} 次作答</span>
        <div class="days" :class="{ dense: range === 30 }">
          <div v-for="(d, i) in days" :key="i" class="day">
            <span class="small muted">{{ range === 7 && d.attempts ? pct(d) + '%' : '' }}</span>
            <div class="col-bar">
              <div class="seg wrong" :style="{ height: ((d.attempts - d.correct) / maxDaily) * 100 + '%' }" />
              <div class="seg right" :style="{ height: (d.correct / maxDaily) * 100 + '%' }" />
            </div>
            <span class="small muted">{{ range === 7 || i % 5 === 4 ? d.label : '' }}</span>
          </div>
        </div>
        <div class="legend small muted"><i class="dot right" />答对 <i class="dot wrong" />答错</div>
      </section>

      <section class="card col">
        <h2>按题型 / 难度</h2>
        <div v-for="g in [...report.byType, ...report.byDifficulty]" :key="g.key + g.label" class="meter">
          <span class="name">{{ g.label }}</span>
          <div class="bar"><div class="fill" :class="tone(pct(g))" :style="{ width: pct(g) + '%' }" /></div>
          <span class="val" :class="tone(pct(g))">{{ pct(g) }}%</span>
          <span class="muted small n">{{ g.attempts }}次</span>
        </div>
      </section>

      <section v-if="report.examTrend.length" class="card col">
        <div class="row between">
          <h2>考试成绩</h2>
          <span class="muted small">最近 {{ report.examTrend.length }} 场 · 虚线是 {{ PASS_PERCENT }} 分及格线</span>
        </div>
        <svg class="trend" :viewBox="`0 0 ${W} ${H}`" role="img" :aria-label="`最近 ${report.examTrend.length} 场考试成绩`">
          <line class="grid" x1="24" :x2="W" y1="10" y2="10" />
          <line class="grid" x1="24" :x2="W" :y1="H - 14" :y2="H - 14" />
          <line class="pass" x1="24" :x2="W" :y1="passY" :y2="passY" />
          <text x="0" y="14">100</text>
          <text x="0" :y="passY + 4">{{ PASS_PERCENT }}</text>
          <text x="6" :y="H - 10">0</text>
          <polyline v-if="trend.length > 1" class="line" :points="trendLine" />
          <g v-for="p in trend" :key="p.finishedAt">
            <circle class="pt" :class="{ fail: !p.passed }" :cx="p.x" :cy="p.y" r="4" />
            <text :x="p.x" :y="p.y - 8" text-anchor="middle">{{ p.percent }}</text>
          </g>
        </svg>
      </section>

      <section v-if="tags.length" class="card col">
        <div class="row between">
          <h2>知识点（薄弱的在前）</h2>
          <div class="seg-toggle" role="group" aria-label="知识点归类">
            <button :class="{ on: merged }" @click="merged = true">归类</button>
            <button :class="{ on: !merged }" @click="merged = false">细分</button>
          </div>
        </div>
        <span class="muted small">共 {{ tagCount }} 个，显示前 {{ tags.length }} 个<template v-if="merged">；相近的标签已合并（如「UML 辨析」归入「UML」）</template></span>
        <div v-for="g in tags" :key="g.key" class="meter">
          <span class="name clamp">{{ g.label }}</span>
          <div class="bar"><div class="fill" :class="tone(pct(g))" :style="{ width: pct(g) + '%' }" /></div>
          <span class="val" :class="tone(pct(g))">{{ pct(g) }}%</span>
          <span class="muted small n">{{ g.attempts }}次</span>
        </div>
      </section>

      <section v-if="weakest.length" class="card col">
        <h2>最常做错的题</h2>
        <div v-for="w in weakest" :key="w.question.id" class="weak">
          <span class="grow clamp2">{{ w.question.stem }}</span>
          <span class="err small nowrap">错 {{ w.wrong }}/{{ w.attempts }}</span>
        </div>
        <button class="btn primary block" @click="practiseWeak">专攻薄弱题（最多 20 道）</button>
      </section>
    </template>
  </main>
</template>
