import { icons } from '../icons'
import { getLocale, t } from '../i18n'

interface CheckResult {
  name: string
  desc: string
  status: 'ok' | 'fail' | 'pending'
  detail: string
  latency?: number
}

type CheckDef = { name: string; desc: string; run: () => Promise<Omit<CheckResult, 'name' | 'desc'>> }

function getChecks(): CheckDef[] {
  return [
  {
    name: t('apiServer'),
    desc: t('apiServerDesc'),
    run: async () => {
      const t0 = performance.now()
      const r = await fetch('/v1/models')
      const latency = Math.round(performance.now() - t0)
      if (!r.ok) return { status: 'fail', detail: `HTTP ${r.status}`, latency }
      const d = await r.json()
      const count = d.data?.length ?? 0
      return { status: 'ok', detail: t('modelsAvailable', { count }), latency }
    },
  },
  {
    name: t('accountsCheck'),
    desc: t('accountsCheckDesc'),
    run: async () => {
      const t0 = performance.now()
      const r = await fetch('/zed/accounts')
      const latency = Math.round(performance.now() - t0)
      if (!r.ok) return { status: 'fail', detail: `HTTP ${r.status}`, latency }
      const d = await r.json()
      const count = d.accounts?.length ?? 0
      if (count === 0) return { status: 'fail', detail: t('noAccountsConfigured'), latency }
      const current = d.accounts.find((a: { current: boolean }) => a.current)
      return { status: 'ok', detail: t('accountsActive', { count, name: current?.name ?? t('unknown') }), latency }
    },
  },
  {
    name: t('tokenRefresh'),
    desc: t('tokenRefreshDesc'),
    run: async () => {
      const t0 = performance.now()
      const r = await fetch('/zed/usage')
      const latency = Math.round(performance.now() - t0)
      if (!r.ok) return { status: 'fail', detail: `HTTP ${r.status} — ${t('checkCredentials')}`, latency }
      const d = await r.json()
      const plan = d.plan ?? t('unknown')
      return { status: 'ok', detail: t('planValue', { plan }), latency }
    },
  },
  {
    name: t('openaiEndpoint'),
    desc: t('openaiEndpointDesc'),
    run: async () => {
      const t0 = performance.now()
      try {
        // Send OPTIONS to check endpoint exists without triggering a real proxy call
        const r = await fetch('/v1/chat/completions', { method: 'OPTIONS' })
        const latency = Math.round(performance.now() - t0)
        return { status: r.ok ? 'ok' : 'fail', detail: `HTTP ${r.status}`, latency }
      } catch (e) {
        return { status: 'fail', detail: e instanceof Error ? e.message : t('unreachable') }
      }
    },
  },
  {
    name: t('anthropicEndpoint'),
    desc: t('anthropicEndpointDesc'),
    run: async () => {
      const t0 = performance.now()
      try {
        const r = await fetch('/v1/messages', { method: 'OPTIONS' })
        const latency = Math.round(performance.now() - t0)
        return { status: r.ok ? 'ok' : 'fail', detail: `HTTP ${r.status}`, latency }
      } catch (e) {
        return { status: 'fail', detail: e instanceof Error ? e.message : t('unreachable') }
      }
    },
  },
  ]
}

export function renderHealth() {
  const page = document.getElementById('page-health')!
  page.innerHTML = `
    <div class="page-header" style="display:flex;align-items:flex-end;justify-content:space-between">
      <div>
        <h2>${t('healthTitle')}</h2>
        <p>${t('healthDesc')}</p>
      </div>
      <button class="btn" id="rerun-btn">
        ${icons.refresh} ${t('rerun')}
      </button>
    </div>
    <div class="page-body">
      <div class="health-summary" id="health-summary"></div>
      <div class="health-list" id="health-list"></div>
    </div>
  `

  document.getElementById('rerun-btn')!.addEventListener('click', runChecks)
  runChecks()
}

async function runChecks() {
  const list = document.getElementById('health-list')!
  const summary = document.getElementById('health-summary')!
  const checks = getChecks()

  // Show pending state
  list.innerHTML = checks.map(c => `
    <div class="health-row pending">
      <div class="health-status"><span class="spinner"></span></div>
      <div class="health-info">
        <div class="health-name">${c.name}</div>
        <div class="health-desc">${c.desc}</div>
      </div>
      <div class="health-detail">${t('checking')}</div>
    </div>
  `).join('')

  summary.innerHTML = `<div class="health-summary-text"><span class="spinner"></span> ${t('runningChecks')}</div>`

  const results: CheckResult[] = []

  for (let i = 0; i < checks.length; i++) {
    const c = checks[i]
    let result: CheckResult
    try {
      const r = await c.run()
      result = { name: c.name, desc: c.desc, ...r }
    } catch (e) {
      result = { name: c.name, desc: c.desc, status: 'fail', detail: e instanceof Error ? e.message : t('genericError') }
    }
    results.push(result)

    // Update this row
    const rows = list.querySelectorAll('.health-row')
    const row = rows[i]
    if (row) {
      row.className = `health-row ${result.status}`
      row.innerHTML = `
        <div class="health-status">
          ${result.status === 'ok' ? icons.checkCircle : icons.xCircle}
        </div>
        <div class="health-info">
          <div class="health-name">${result.name}</div>
          <div class="health-desc">${result.desc}</div>
        </div>
        <div class="health-right">
          <div class="health-detail">${esc(result.detail)}</div>
          ${result.latency != null ? `<div class="health-latency">${result.latency}ms</div>` : ''}
        </div>
      `
    }
  }

  // Summary
  const passed = results.filter(r => r.status === 'ok').length
  const total = checks.length
  const allOk = passed === total
  const locale = getLocale() === 'zh' ? 'zh-CN' : 'en-US'
  summary.innerHTML = `
    <div class="health-summary-icon ${allOk ? 'ok' : 'warn'}">
      ${allOk ? icons.checkCircle : icons.alertCircle}
    </div>
    <div>
      <div class="health-summary-title">${allOk ? t('allOperational') : t('checksPassed', { passed, total })}</div>
      <div class="health-summary-sub">${t('lastChecked', { time: new Date().toLocaleTimeString(locale) })}</div>
    </div>
  `
}

function esc(s: string): string {
  const d = document.createElement('div')
  d.textContent = s
  return d.innerHTML
}
