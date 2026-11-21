// k-* 自定义组件 lib 构建配置：输出 ESM + CSS 到 form-create/lib/，
// 供本地设计器 playground（vue-cli）导入注册，保证编辑所见即运行所得。
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'path'

export default defineConfig({
  plugins: [vue()],
  build: {
    lib: {
      entry: resolve(__dirname, 'src/fc/components/index.ts'),
      formats: ['es'],
      fileName: () => 'k-components.es.js',
    },
    cssCodeSplit: false,
    outDir: 'form-create/lib',
    emptyOutDir: true,
    rollupOptions: {
      external: ['vue'],
      output: { globals: { vue: 'Vue' } },
    },
  },
})
