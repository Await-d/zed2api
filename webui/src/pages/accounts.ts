import { fetchAccounts, fetchUsage, fetchBilling, switchAccount, startLogin, fetchLoginStatus, type UsageInfo } from '../api'
import { icons } from '../icons'
import { getLocale, t } from '../i18n'
import { showToast } from '../toast'

function esc(s: string): string {
  const d = document.createElement('div')
  d.textContent = s
  return d.innerHTML
}

export function renderAccounts() {
  const page = document.getElementById('page-accounts')!
  page.innerHTML = `
    <div class="page-header">
      <h2>${t('accountsTitle')}</h2>
      <p>${t('accountsDesc')}</p>
    </div>
    <div class="page-body">
      <div class="account-list" id="account-list"></div>
      <button class="add-account-btn" id="add-account-btn">
        <span class="add-icon">${icons.plus}</span>
        <span>${t('addAccount')}</span>
        <span class="add-hint">${t('addAccountHint')}</span>
      </button>
      <div id="login-banner" class="login-banner" style="display:none"></div>
      <div class="usage-section" id="usage-section" style="display:none"></div>
    </div>
  `
  document.getElementById('add-account-btn')!.addEventListener('click', doLogin)
  loadAccounts()
}

async function loadAccounts() {
  const list = document.getElementById('account-list')!
  try {
    const data = await fetchAccounts()
    const accs = data.accounts || []
    document.getElementById('acc-count')!.textContent = String(accs.length)
    if (accs.length === 0) {
      list.innerHTML = `<div class="empty-state">
        <div class="empty-icon">${icons.users}</div>
        <div>${t('noAccounts')}</div>
      </div>`
      return
    }
    list.innerHTML = accs.map(acc => `
      <div class="account-card ${acc.current ? 'active' : ''}">
        <div class="account-avatar">${acc.name.charAt(0).toUpperCase()}</div>
        <div class="account-info">
          <div class="account-name">${esc(acc.name)}</div>
          <div class="account-meta">ID: ${esc(acc.user_id)}</div>
        </div>
        <div class="account-actions">
          ${acc.current
            ? `<span class="tag tag-active">${icons.check} ${t('current')}</span>`
            : `<button class="btn switch-btn" data-name="${esc(acc.name)}">${t('switch')}</button>`}
        </div>
      </div>
    `).join('')

    list.querySelectorAll<HTMLButtonElement>('.switch-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const name = btn.dataset.name!
        await switchAccount(name)
        showToast(t('switchedTo', { name }))
        loadAccounts()
      })
    })
    if (accs.some(a => a.current)) loadUsage()
  } catch (e) {
    list.innerHTML = `<div class="error-state">
      ${t('loadAccountsFailed', { error: e instanceof Error ? esc(e.message) : t('unknownError') })}
    </div>`
  }
}

async function loadUsage() {
  const section = document.getElementById('usage-section')!
  try {
    // Fetch JWT claims for plan info
    const usage: UsageInfo = await fetchUsage()
    // Also fetch /client/users/me for richer data
    const billing = await fetchBilling().catch(() => null) as Record<string, unknown> | null
    if (billing?.plan && typeof billing.plan === 'object') {
      const planObj = billing.plan as Record<string, unknown>
      const period = planObj.subscription_period as Record<string, string> | undefined
      if (period?.started_at && period?.ended_at) {
        usage.subscriptionPeriod = [period.started_at, period.ended_at]
      }
    }
    section.style.display = 'block'
    section.innerHTML = renderUsageCard(usage)
  } catch {
    section.style.display = 'none'
  }
}

function renderUsageCard(u: UsageInfo): string {
  const plan = u.plan || t('unknown')
  const limitCents = u.monthly_spending_limit_in_cents ?? 2000
  const limit = (limitCents / 100).toFixed(2)

  const period = u.subscriptionPeriod
  let periodHtml = ''
  if (period && period.length === 2) {
    const end = new Date(period[1])
    const days = Math.ceil((end.getTime() - Date.now()) / 86400000)
    const locale = getLocale() === 'zh' ? 'zh-CN' : 'en-US'
    periodHtml = `<div class="usage-stat">
      <div class="usage-stat-label">${t('expires')}</div>
      <div class="usage-stat-value">${end.toLocaleDateString(locale, { month: 'long', day: 'numeric', year: 'numeric' })} <small>${t('daysLeft', { days })}</small></div>
    </div>`
  }

  return `
    <div class="usage-card">
      <div class="usage-card-header">
        <span class="usage-card-icon">${icons.activity}</span>
        <h3>${t('usage')}</h3>
      </div>
      <div class="usage-stats">
        <div class="usage-stat">
          <div class="usage-stat-label">${t('plan')}</div>
          <div class="usage-stat-value plan-value">${esc(plan)}</div>
        </div>
        ${periodHtml}
        <div class="usage-stat">
          <div class="usage-stat-label">${t('spend')}</div>
          <div class="usage-stat-value">
            <a href="https://zed.dev/account/billing" target="_blank" class="spend-link" title="${t('viewOnZed')}">${t('viewOnZed')} ${icons.externalLink}</a>
            <small>${t('limit', { limit })}</small>
          </div>
        </div>
      </div>
    </div>
  `
}

async function doLogin() {
  const banner = document.getElementById('login-banner')!
  const btn = document.getElementById('add-account-btn') as HTMLButtonElement
  btn.disabled = true
  banner.style.display = 'block'
  banner.innerHTML = `<span class="spinner"></span> ${t('oauthPreparing')}`
  try {
    const currentPort = window.location.port ? Number(window.location.port) : undefined
    const publicPort = currentPort !== undefined && Number.isFinite(currentPort) && currentPort > 0
      ? Math.trunc(currentPort)
      : undefined
    const data = await startLogin(undefined, publicPort)
    if (data.error) {
      banner.innerHTML = `<span class="error-text">${icons.xCircle} ${esc(data.error)}</span>`
      btn.disabled = false
      return
    }
    const loginLink = data.login_url
      ? `<a href="${esc(data.login_url)}" target="_blank" rel="noopener noreferrer">${t('openLoginPage')}</a>`
      : ''
    let popupBlocked = false
    if (data.login_url) {
      const popup = window.open(data.login_url, '_blank', 'noopener,noreferrer')
      if (popup == null) {
        popupBlocked = true
      }
    }
    banner.innerHTML = `
      <span class="spinner"></span>
      ${t('oauthWaiting')}
      ${loginLink}
      ${popupBlocked ? `<span class="error-text">${icons.xCircle} ${t('oauthPopupBlocked')}</span>` : ''}
      <span class="login-hint">${t('oauthHint')}</span>
    `
    const poll = setInterval(async () => {
      try {
        const st = await fetchLoginStatus()
        if (st.status === 'success') {
          clearInterval(poll)
          banner.innerHTML = `${icons.check} <span>${t('loginSuccess')}</span>`
          btn.disabled = false
          showToast(t('accountAddedSuccess'))
          loadAccounts()
          setTimeout(() => { banner.style.display = 'none' }, 3000)
        } else if (st.status === 'failed') {
          clearInterval(poll)
          banner.innerHTML = `<span class="error-text">${icons.xCircle} ${t('loginFailedRetry')}</span>`
          btn.disabled = false
        }
      } catch { /* ignore */ }
    }, 1500)
  } catch (e) {
    banner.innerHTML = `<span class="error-text">${icons.xCircle} ${t('errorPrefix')}${e instanceof Error ? esc(e.message) : t('unknown')}</span>`
    btn.disabled = false
  }
}
