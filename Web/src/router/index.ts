import { createRouter, createWebHashHistory } from 'vue-router'
import ProfilePilotPage from '../pages/ProfilePilotPage.vue'
import TabStubPage from '../pages/TabStubPage.vue'

// Web SPA 路由（hash 模式：kline:// scheme 与 /web/ HTTP 双通道均兼容）
// Tab 页骨架：P2-1 起逐页实装（当前为占位页）
const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', redirect: '/profile' },
    { path: '/profile', component: ProfilePilotPage },
    { path: '/favorites', component: () => import('../pages/FavoritesStubPage.vue') },
    { path: '/market', component: TabStubPage, props: { path: '/market', batch: 'P2-2 Market' } },
    { path: '/home', component: TabStubPage, props: { path: '/home', batch: 'P2-3 Home' } },
    { path: '/simulation', component: TabStubPage, props: { path: '/simulation', batch: 'P2-4 Simulation' } },
  ],
})

export default router
