import { createRouter, createWebHashHistory } from 'vue-router'

// Hash routing: the Go server only has to serve /m/ and never needs to know the app's routes.
const router = createRouter({
  history: createWebHashHistory('/m/'),
  routes: [
    { path: '/', component: () => import('./views/BanksView.vue'), meta: { tabs: true } },
    { path: '/bank/:id', component: () => import('./views/BankView.vue'), props: true },
    { path: '/bank/:id/learn', component: () => import('./views/LearnView.vue'), props: true },
    { path: '/bank/:id/learn/:lessonId', component: () => import('./views/LessonView.vue'), props: true },
    { path: '/bank/:id/topics', component: () => import('./views/TopicsView.vue'), props: true },
    { path: '/bank/:id/search', component: () => import('./views/SearchView.vue'), props: true },
    { path: '/bank/:id/stats', component: () => import('./views/StatsView.vue'), props: true },
    { path: '/bank/:id/exam', component: () => import('./views/ExamSetupView.vue'), props: true },
    { path: '/exam', component: () => import('./views/ExamView.vue') },
    { path: '/exam/review/:id', component: () => import('./views/ExamReviewView.vue'), props: true },
    { path: '/wrong', component: () => import('./views/ListView.vue'), props: { kind: 'wrong' }, meta: { tabs: true } },
    { path: '/fav', component: () => import('./views/ListView.vue'), props: { kind: 'fav' }, meta: { tabs: true } },
    { path: '/settings', component: () => import('./views/SettingsView.vue'), meta: { tabs: true } },
    { path: '/agent/history', component: () => import('./views/AgentHistoryView.vue') },
    { path: '/agent', component: () => import('./views/AgentView.vue') },
    { path: '/quiz', component: () => import('./views/QuizView.vue') },
    { path: '/:rest(.*)*', redirect: '/' },
  ],
})

export default router
