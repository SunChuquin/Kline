import { createRouter, createWebHashHistory } from 'vue-router'
import ProfilePilotPage from '../pages/ProfilePilotPage.vue'
import FavoritesPage from '../pages/FavoritesPage.vue'
import MarketPage from '../pages/MarketPage.vue'
import HomePage from '../pages/HomePage.vue'
import SimulationPage from '../pages/SimulationPage.vue'
import SheetPage from '../pages/SheetPage.vue'

// Web SPA 路由（hash 模式：kline:// scheme 与 /web/ HTTP 双通道均兼容）
// Tab 页：P2-1~P2-4 已全部实装；/sheet = 图表弹层浮层 WebView（P2-5，独立全屏浮层实例）
const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', redirect: '/favorites' },
    { path: '/profile', component: ProfilePilotPage },
    { path: '/favorites', component: FavoritesPage },
    { path: '/market', component: MarketPage },
    { path: '/home', component: HomePage },
    { path: '/simulation', component: SimulationPage },
    { path: '/sheet', component: SheetPage },
  ],
})

export default router
