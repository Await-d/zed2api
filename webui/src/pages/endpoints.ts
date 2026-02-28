import { t } from '../i18n'

const ENDPOINTS = [
  { method: 'POST', path: '/v1/chat/completions', key: 'epChat' },
  { method: 'POST', path: '/v1/messages', key: 'epMessages' },
  { method: 'GET', path: '/v1/models', key: 'epModels' },
  { method: 'GET', path: '/zed/accounts', key: 'epAccounts' },
  { method: 'POST', path: '/zed/accounts/switch', key: 'epSwitch' },
  { method: 'GET', path: '/zed/usage', key: 'epUsage' },
  { method: 'POST', path: '/zed/login', key: 'epLogin' },
  { method: 'POST', path: '/api/event_logging/batch', key: 'epEventLog' },
] as const

export function renderEndpoints() {
  const page = document.getElementById('page-endpoints')!
  page.innerHTML = `
    <div class="page-header">
      <h2>${t('endpointsTitle')}</h2>
      <p>${t('endpointsDesc')}</p>
    </div>
    <div class="page-body">
      <div class="endpoint-list">
        ${ENDPOINTS.map(ep => `
          <div class="ep-row">
            <span class="ep-method ${ep.method.toLowerCase()}">${ep.method}</span>
            <span class="ep-path">${ep.path}</span>
            <span class="ep-desc">${t(ep.key)}</span>
          </div>
        `).join('')}
      </div>
    </div>
  `
}
