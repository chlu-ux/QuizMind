import { createRouter, createWebHistory } from 'vue-router'
import { useAuth } from '@/stores/auth'

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue'), meta: { public: true } },
    { path: '/', redirect: '/documents' },
    { path: '/documents', name: 'documents', component: () => import('@/views/DocumentsView.vue'), meta: { title: '文档' } },
    { path: '/review', name: 'review', component: () => import('@/views/ReviewView.vue'), meta: { title: '审核' } },
    { path: '/banks', name: 'banks', component: () => import('@/views/BanksView.vue'), meta: { title: '题库' } },
    { path: '/jobs', name: 'jobs', component: () => import('@/views/JobsView.vue'), meta: { title: '任务' } },
    { path: '/usage', name: 'usage', component: () => import('@/views/UsageView.vue'), meta: { title: '用量' } },
    { path: '/:pathMatch(.*)*', redirect: '/documents' },
  ],
})

router.beforeEach(async (to) => {
  if (to.meta.public) return true
  const auth = useAuth()
  if (!auth.checked) await auth.check()
  if (!auth.authed) return { name: 'login', query: { redirect: to.fullPath } }
  return true
})
