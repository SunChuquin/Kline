// fc/formCreate.ts：@form-create/vant 实例 + k-* / vant 组件注册。
// main.ts 通过 installFormCreate(app) 一次性接入；规则 JSON 的 type 引用组件名。
//
// vant 组件经 fc.component 注册进 form-create 实例（规则 JSON 动态渲染，
// unplugin-vue-components 只扫 SFC 模板扫不到它们，样式须手动引入）。
import formCreate from '@form-create/vant'
import type { App } from 'vue'
import {
  ActionSheet,
  Button,
  Cell,
  CellGroup,
  Col,
  Dialog,
  Field,
  Form as VanForm,
  Row,
  Switch,
} from 'vant'
import { kComponents } from './components'

export const fc = formCreate

/** 规则 JSON 中动态渲染的 vant 组件（按需追加） */
const vantComponents: Record<string, unknown> = {
  'van-action-sheet': ActionSheet,
  'van-dialog': Dialog,
  'van-cell': Cell,
  'van-cell-group': CellGroup,
  'van-field': Field,
  'van-switch': Switch,
  'van-button': Button,
  // form-create 表单包装布局（FormCreateMobile 内部使用）
  'van-row': Row,
  'van-col': Col,
  'van-form': VanForm,
}

/** vant 组件样式（动态渲染无 unplugin 注入，手动引入） */
const vantStyles: Record<string, () => void> = {
  'van-action-sheet': () => import('vant/es/action-sheet/style/index'),
  'van-dialog': () => import('vant/es/dialog/style/index'),
  'van-cell': () => import('vant/es/cell/style/index'),
  'van-cell-group': () => import('vant/es/cell-group/style/index'),
  'van-field': () => import('vant/es/field/style/index'),
  'van-switch': () => import('vant/es/switch/style/index'),
  'van-button': () => import('vant/es/button/style/index'),
  'van-row': () => import('vant/es/row/style/index'),
  'van-col': () => import('vant/es/col/style/index'),
  'van-form': () => import('vant/es/form/style/index'),
}

/** 弹层组件 v-model 字段是 show（非 modelValue） */
const vantModelFields: Record<string, string> = {
  'van-action-sheet': 'show',
  'van-dialog': 'show',
}

/** 注册 k-* / vant 组件并安装 form-create（Vue app 级，一次即可） */
export function installFormCreate(app: App): void {
  for (const [name, comp] of Object.entries(kComponents)) {
    fc.component(name, comp)
  }
  for (const [name, comp] of Object.entries(vantComponents)) {
    fc.component(name, comp)
    vantStyles[name]?.()
  }
  for (const [name, field] of Object.entries(vantModelFields)) {
    fc.setModelField(name, field)
  }
  app.use(fc)
}
