// fc/adapters/page-pickerEditor.ts：选股公式编辑器（page-pickerEditor）逻辑适配器。
// 编辑对象由原生 pickerEdit.snapshot 下发（id/name/pickBody）；公式文本为 Web 本地态；
// testPick 走 pickerEdit.testPick（异步，结果随 pickerEdit.changed(pickTest) 推送）；
// 保存走 pickerEdit.save（同步写库，成功由原生关页）。
import { klineBus } from '../../bridge/klineBus'
import type { BridgeEvent } from '../../types/protocol'
import type { PickerEditSnapshot } from '../../types/protocol'
import type { FcApi, FcPageAdapter, HostContext } from '../types'
import { patchRule } from '../rule-patch'

let snap: PickerEditSnapshot | null = null
let nameStr = ''
let pickBody = ''
let testMessage = ''
let testError = false
let selectReqSeq = 0
let insertReqSeq = 0
let ctxRef: HostContext | null = null

/** 名称与公式均非空才允许保存（对齐原生选股模式 canSave） */
function canSave(): boolean {
  if (!snap) return false
  return nameStr.trim().length > 0 && pickBody.trim().length > 0
}

/** 相对初始快照是否有未保存修改（对齐原生选股模式 hasChanges） */
function hasChanges(): boolean {
  const s = snap
  if (!s) return false
  if (s.id === '') {
    return nameStr.trim().length > 0 || pickBody.trim().length > 0
  }
  return nameStr !== s.name || pickBody !== s.pickBody
}

function syncTestMsg(api: FcApi): void {
  patchRule(api, 'testMsg', {
    props: { text: testMessage, danger: testError, plain: !testError },
    style: { display: testMessage ? '' : 'none' },
  })
}

function syncSave(api: FcApi): void {
  patchRule(api, 'navRow', { props: { rightDisabled: !canSave() } })
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  try {
    const d = ((await klineBus.request('pickerEdit', 'snapshot')) ?? {}) as Record<string, unknown>
    snap = {
      id: String(d.id ?? ''),
      name: String(d.name ?? ''),
      pickBody: String(d.pickBody ?? ''),
      hasData: d.hasData === true,
    }
    nameStr = snap.name
    pickBody = snap.pickBody
    testMessage = ''
    testError = false
    api.setValue({ name: nameStr, pickBody, confirmOpen: false })
    syncTestMsg(api)
    syncSave(api)
  } catch (e) {
    console.error('pickerEdit.snapshot 失败', e)
  }
}

function runTest(api: FcApi): void {
  testMessage = '计算中…'
  testError = false
  syncTestMsg(api)
  void klineBus.request('pickerEdit', 'testPick', { pickBody }).catch((e) => {
    testMessage = `✗ ${String(e instanceof Error ? e.message : e).slice(0, 60)}`
    testError = true
    syncTestMsg(api)
  })
}

async function save(api: FcApi): Promise<void> {
  if (!canSave()) return
  try {
    await klineBus.request('pickerEdit', 'save', {
      id: snap?.id ?? '',
      name: nameStr.trim(),
      pickBody,
    })
    // 成功后原生已关页（同步保存链路）；本地同步清理兜底
    ctxRef?.close()
  } catch (e) {
    testMessage = `✗ ${String(e instanceof Error ? e.message : e).slice(0, 60)}`
    testError = true
    syncTestMsg(api)
  }
}

function handleChanged(api: FcApi, payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'pickTest') {
    testMessage = String(payload?.['testMessage'] ?? '')
    testError = payload?.['testIsError'] === true
    syncTestMsg(api)
  } else if (reason === 'dataReady') {
    if (snap) snap.hasData = true
  }
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    onBack: (inj) => {
      if (hasChanges()) inj.api.setValue({ confirmOpen: true })
      else ctxRef?.close()
    },

    pickTool: (inj) => {
      const tool = String(inj.args[0] ?? '')
      const api = inj.api
      if (tool === 'selectAll') {
        selectReqSeq += 1
        patchRule(api, 'pickInput', { props: { selectReq: selectReqSeq } })
      } else if (tool === 'clearPick') {
        pickBody = ''
        api.setValue({ pickBody })
        testMessage = ''
        testError = false
        syncTestMsg(api)
        syncSave(api)
      } else if (tool === 'runTest') {
        runTest(api)
      }
    },

    insertSymbol: (inj) => {
      const text = String(inj.args[0] ?? '')
      if (!text) return
      insertReqSeq += 1
      patchRule(inj.api, 'pickInput', { props: { insertReq: { seq: insertReqSeq, text } } })
    },

    save: (inj) => {
      void save(inj.api)
    },
  },

  onChange: (field, value, api) => {
    if (field === 'name') {
      nameStr = String(value ?? '')
      syncSave(api)
      return
    }
    if (field === 'pickBody') {
      pickBody = String(value ?? '')
      syncSave(api)
    }
  },

  subscribe: (api, ctx) => {
    ctxRef = ctx
    // pickTest / dataReady 推送（陈旧 api 静默跳过）
    const handler = (ev: BridgeEvent): void => {
      try {
        handleChanged(api, ev.payload)
      } catch (e) {
        console.warn('[fc] pickerEditor changed 跳过（面板可能已关闭）', e)
      }
    }
    klineBus.on('pickerEdit.changed', handler)
    return () => {}
  },
}

export default adapter
