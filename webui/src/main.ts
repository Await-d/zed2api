import './style.css'
import { icons } from './icons'
import { renderAccounts } from './pages/accounts'
import { renderHealth } from './pages/health'
import { renderEndpoints } from './pages/endpoints'
import { renderIntegration } from './pages/integration'
import { getLocale, initLocale, t, toggleLocale } from './i18n'

const app = document.getElementById('app')!

function renderShell(activePage: string) {
  const locale = getLocale()
  app.innerHTML = `
<div class="app">
  <aside class="sidebar">
    <div class="sidebar-header">
      <h1><span class="logo-icon">${icons.zap}</span> zed2api</h1>
      <p>${t('appTagline')}</p>
    </div>
    <nav class="sidebar-nav">
      <div class="nav-group">
        <div class="nav-group-label">${t('navManage')}</div>
        <button class="nav-btn ${activePage === 'accounts' ? 'active' : ''}" data-page="accounts">
          <span class="icon">${icons.users}</span> ${t('navAccounts')}
          <span class="badge" id="acc-count">0</span>
        </button>
        <button class="nav-btn ${activePage === 'health' ? 'active' : ''}" data-page="health">
          <span class="icon">${icons.activity}</span> ${t('navHealth')}
        </button>
      </div>
      <div class="nav-group">
        <div class="nav-group-label">${t('navReference')}</div>
        <button class="nav-btn ${activePage === 'endpoints' ? 'active' : ''}" data-page="endpoints">
          <span class="icon">${icons.globe}</span> ${t('navEndpoints')}
        </button>
        <button class="nav-btn ${activePage === 'integration' ? 'active' : ''}" data-page="integration">
          <span class="icon">${icons.code}</span> ${t('navIntegration')}
        </button>
      </div>
    </nav>
    <div class="sidebar-footer" style="display:flex;align-items:center;justify-content:space-between;gap:8px">
      <span><span class="status-dot"></span> ${t('runningPort')} :${location.port || '8000'}</span>
      <button class="btn" id="lang-toggle" title="${locale === 'zh' ? t('switchToEnglish') : t('switchToChinese')}">${locale.toUpperCase()}</button>
    </div>
  </aside>
  <main class="main-content">
    <div class="page ${activePage === 'accounts' ? 'active' : ''}" id="page-accounts"></div>
    <div class="page ${activePage === 'health' ? 'active' : ''}" id="page-health"></div>
    <div class="page ${activePage === 'endpoints' ? 'active' : ''}" id="page-endpoints"></div>
    <div class="page ${activePage === 'integration' ? 'active' : ''}" id="page-integration"></div>
  </main>
</div>
<div class="toast" id="toast"></div>
`
}

function getActivePage(): string {
  return document.querySelector<HTMLButtonElement>('.nav-btn.active')?.dataset.page ?? 'accounts'
}

function bindNavigation() {
  document.querySelectorAll<HTMLButtonElement>('.nav-btn[data-page]').forEach(btn => {
    btn.addEventListener('click', () => {
      const pageId = btn.dataset.page ?? 'accounts'
      renderApp(pageId)
    })
  })

  document.getElementById('lang-toggle')?.addEventListener('click', () => {
    toggleLocale()
    renderApp(getActivePage())
  })
}

function renderApp(activePage = 'accounts') {
  renderShell(activePage)
  renderAccounts()
  renderHealth()
  renderEndpoints()
  renderIntegration()
  bindNavigation()
}

initLocale()
renderApp('accounts')
