import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import Components from 'unplugin-vue-components/vite'
import { VantResolver } from '@vant/auto-import-resolver'

// Kline 混合架构 Web 视图层（见 .trae/documents/Kline-混合架构改造方案.md §6）
// 红线：iPad mini 4 / iOS 15.8.8 → 构建目标必须锁 Safari 15，
// 禁用仅 Safari 16+ 的 CSS/JS 特性。
// UI 组件：直接按需引入 Vant（browserslist 声明 iOS >= 10，官方兼容），
// 自绘 K 组件（KCard/KCell 等）与 Vant 共存，逐步替换。
export default defineConfig({
  plugins: [
    vue(),
    // Vant 组件模板内直接使用 <van-xxx>，模板/样式按需注入
    Components({ resolvers: [VantResolver()] }),
  ],
  // 相对路径：dist 由 WKURLSchemeHandler 经 kline://app/ 提供服务
  base: './',
  // PC 本地开发循环：dev server 把 /bridge 代理到 USB 隧道（127.0.0.1:5051），
  // 浏览器 localhost:5173 直接真数据真写回（隧道需常驻：python TrollRestore/web_debug_tunnel.py）
  server: {
    proxy: {
      '/bridge': 'http://127.0.0.1:5051',
    },
  },
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
