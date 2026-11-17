import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Kline 混合架构 Web 视图层（见 .trae/documents/Kline-混合架构改造方案.md §6）
// 红线：iPad mini 4 / iOS 15.8.8 → 构建目标必须锁 Safari 15，
// 禁用仅 Safari 16+ 的 CSS/JS 特性；不用 Element Plus，自绘轻量组件。
export default defineConfig({
  plugins: [vue()],
  // 相对路径：dist 由 WKURLSchemeHandler 经 kline://app/ 提供服务
  base: './',
  build: {
    target: 'safari15',
    outDir: 'dist',
    assetsDir: 'assets',
  },
  define: {
    // 构建时间戳注入：页面显示「Web 构建」，用于核对装机包里的 dist 版本
    __BUILD_TS__: JSON.stringify(new Date().toISOString()),
  },
})
