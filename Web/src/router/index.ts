import { createRouter, createWebHashHistory } from 'vue-router'
import ProfilePilotPage from '../pages/ProfilePilotPage.vue'
import FavoritesPage from '../pages/FavoritesPage.vue'
import MarketPage from '../pages/MarketPage.vue'
import HomePage from '../pages/HomePage.vue'
import TabStubPage from '../pages/TabStubPage.vue'

// Web SPA 路由（hash 模式：kline:// scheme 与 /web/ HTTP 双通道均兼容）
// Tab 页：P2-1 Favorites / P2-2 Market / P2-3 Home 已实装；simulation 占位（P2-4）
const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', redirect: '/favorites' },
    { path: '/profile', component: ProfilePilotPage },
    { path: '/favorites', component: FavoritesPage },
    { path: '/market', component: MarketPage },
    { path: '/home', component: HomePage },
    { path: '/simulation', component: TabStubPage, props: { path: '/simulation', batch: 'P2-4 Simulation' } },
  ],
})

export default router
