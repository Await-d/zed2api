import { fetchAccounts, switchAccount, startLogin, fetchLoginStatus, deleteAccounts, renameAccount, syncBilling, type Account } from '../api'
import { icons } from '../icons'
import { getLocale, t } from '../i18n'
import { showToast } from '../toast'

function esc(s: string): string {
  const d = document.createElement('div')
  d.textContent = s
  return d.innerHTML
}

function formatPlanName(plan: string): string {
  return plan.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())
}

function renderPlanRow(acc: Account, expiresAt?: string): string {
  if (!acc.plan) return ''
  const planBadge = `<span class="plan-badge">${esc(formatPlanName(acc.plan))}</span>`
  let expiryHtml = ''
  if (acc.current && expiresAt) {
    const end = new Date(expiresAt)
    const days = Math.ceil((end.getTime() - Date.now()) / 86400000)
    const locale = getLocale() === 'zh' ? 'zh-CN' : 'en-US'
    const dateStr = end.toLocaleDateString(locale, { month: 'long', day: 'numeric', year: 'numeric' })
    expiryHtml = `<span class="account-expires">${t('expires')}: ${dateStr} <span class="days-left">${t('daysLeft', { days })}</span></span>`
  }
  return `<div class="account-plan">${planBadge}${expiryHtml}</div>`
}

// Track selected account names
let selected: Set<string> = new Set()
let managingMode = false

export function renderAccounts() {
  selected = new Set()
  managingMode = false
  const page = document.getElementById('page-accounts')!
  page.innerHTML = `
    <div class="page-header">
      <h2>${t('accountsTitle')}</h2>
      <p>${t('accountsDesc')}</p>
    </div>
    <div class="page-body">
      <div id="account-toolbar" class="account-toolbar" style="display:none"></div>
      <div class="account-list" id="account-list"></div>
      <button class="add-account-btn" id="add-account-btn">
        <span class="add-icon">${icons.plus}</span>
        <span>${t('addAccount')}</span>
        <span class="add-hint">${t('addAccountHint')}</span>
      </button>
      <div id="login-banner" class="login-banner" style="display:none"></div>
    </div>
  `
  document.getElementById('add-account-btn')!.addEventListener('click', doLogin)
  loadAccounts()
}

function renderToolbar(total: number) {
  const toolbar = document.getElementById('account-toolbar')!
  if (!managingMode) {
    toolbar.style.display = 'none'
    return
  }
  toolbar.style.display = 'flex'
  const allSelected = selected.size === total && total > 0
  toolbar.innerHTML = `
    <button class="btn btn-sm" id="tb-toggle-all">
      ${allSelected ? t('deselectAll') : t('selectAll')}
    </button>
    <span class="toolbar-count">${selected.size > 0 ? `${selected.size} / ${total}` : ''}</span>
    <button class="btn btn-sm btn-danger" id="tb-delete" ${selected.size === 0 ? 'disabled' : ''}>
      ${icons.trash} ${t('deleteSelected')}
    </button>
    <button class="btn btn-sm btn-secondary" id="tb-done">
      ${t('doneManaging')}
    </button>
  `

  document.getElementById('tb-toggle-all')!.addEventListener('click', () => {
    if (allSelected) {
      selected.clear()
    } else {
      const list = document.querySelectorAll<HTMLInputElement>('.acc-checkbox')
      list.forEach(cb => selected.add(cb.dataset.name!))
    }
    loadAccounts()
  })

  document.getElementById('tb-delete')!.addEventListener('click', async () => {
    if (selected.size === 0) return
    const msg = t('deleteConfirm', { count: selected.size })
    if (!window.confirm(msg)) return
    const names = Array.from(selected)
    try {
      const res = await deleteAccounts(names)
      selected.clear()
      showToast(t('deleted', { count: res.removed }))
      loadAccounts()
    } catch (e) {
      showToast(t('deleteError', { error: e instanceof Error ? e.message : String(e) }))
    }
  })

  document.getElementById('tb-done')!.addEventListener('click', () => {
    managingMode = false
    selected.clear()
    loadAccounts()
  })
}

async function loadAccounts() {
  const list = document.getElementById('account-list')!
  try {
    const data = await fetchAccounts()
    const accs = data.accounts || []
    const badge = document.getElementById('acc-count')
    if (badge) badge.textContent = String(accs.length)


    const currentAcc = (data.accounts || []).find((a: Account) => a.current)

    // Show/hide manage button next to "Add account"
    let manageBtn = document.getElementById('manage-accounts-btn')
    if (accs.length > 0) {
      if (!manageBtn) {
        const addBtn = document.getElementById('add-account-btn')!
        manageBtn = document.createElement('button')
        manageBtn.id = 'manage-accounts-btn'
        manageBtn.className = 'btn btn-sm btn-outline manage-btn'
        addBtn.insertAdjacentElement('afterend', manageBtn)
      }
      manageBtn.textContent = managingMode ? t('doneManaging') : t('managing')
      manageBtn.onclick = () => {
        managingMode = !managingMode
        if (!managingMode) selected.clear()
        loadAccounts()
      }
    } else {
      manageBtn?.remove()
    }

    renderToolbar(accs.length)

    if (accs.length === 0) {
      list.innerHTML = `<div class="empty-state">
        <div class="empty-icon">${icons.users}</div>
        <div>${t('noAccounts')}</div>
      </div>`
      return
    }

    list.innerHTML = accs.map(acc => {
      const isSelected = selected.has(acc.name)
      const planRow = renderPlanRow(acc, acc.expires_at)
      return `
      <div class="account-card ${acc.current ? 'active' : ''} ${isSelected ? 'card-selected' : ''}">
        ${managingMode ? `<label class="acc-checkbox-wrap">
          <input type="checkbox" class="acc-checkbox" data-name="${esc(acc.name)}" ${isSelected ? 'checked' : ''}>
        </label>` : ''}
        <div class="account-avatar">${acc.name.charAt(0).toUpperCase()}</div>
        <div class="account-info">
          <div class="account-name">${esc(acc.name)}</div>
          <div class="account-meta">ID: ${esc(acc.user_id)}</div>
          ${planRow}
        </div>
        <div class="account-actions">
          ${acc.current
            ? `<span class="tag tag-active">${icons.check} ${t('current')}</span>`
            : `<button class="btn switch-btn" data-name="${esc(acc.name)}">${t('switch')}</button>`}
          ${managingMode ? '' : `
            <div class="acc-menu-wrap">
              <button class="btn btn-icon acc-menu-btn" data-name="${esc(acc.name)}" title="More">&#8943;</button>
              <div class="acc-dropdown" id="menu-${esc(acc.name)}" style="display:none">
                <button class="dropdown-item rename-btn" data-name="${esc(acc.name)}">${icons.edit ?? '✎'} ${t('rename')}</button>
                <button class="dropdown-item copy-uid-btn" data-uid="${esc(acc.user_id)}">${t('copyUserId')}</button>
                <button class="dropdown-item delete-one-btn danger-item" data-name="${esc(acc.name)}">${icons.trash ?? '🗑'} ${t('deleteSelected')}</button>
              </div>
            </div>
          `}
        </div>
      </div>
    `}).join('')

    // Checkbox listeners
    list.querySelectorAll<HTMLInputElement>('.acc-checkbox').forEach(cb => {
      cb.addEventListener('change', () => {
        const name = cb.dataset.name!
        if (cb.checked) selected.add(name)
        else selected.delete(name)
        renderToolbar(accs.length)
        // Update card highlight
        const card = cb.closest('.account-card')
        if (card) card.classList.toggle('card-selected', cb.checked)
      })
    })

    // Switch listeners
    list.querySelectorAll<HTMLButtonElement>('.switch-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const name = btn.dataset.name!
        await switchAccount(name)
        showToast(t('switchedTo', { name }))
        loadAccounts()
      })
    })

    // Dropdown toggle
    list.querySelectorAll<HTMLButtonElement>('.acc-menu-btn').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation()
        const name = btn.dataset.name!
        const dropdown = document.getElementById(`menu-${name}`)
        if (!dropdown) return
        // Close all others
        document.querySelectorAll<HTMLElement>('.acc-dropdown').forEach(d => {
          if (d !== dropdown) d.style.display = 'none'
        })
        dropdown.style.display = dropdown.style.display === 'none' ? 'block' : 'none'
      })
    })

    // Close dropdowns on outside click
    document.addEventListener('click', () => {
      document.querySelectorAll<HTMLElement>('.acc-dropdown').forEach(d => {
        d.style.display = 'none'
      })
    }, { once: true })

    // Rename listeners
    list.querySelectorAll<HTMLButtonElement>('.rename-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const oldName = btn.dataset.name!
        showRenameModal(oldName)
      })
    })

    // Copy UID
    list.querySelectorAll<HTMLButtonElement>('.copy-uid-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const uid = btn.dataset.uid!
        await navigator.clipboard.writeText(uid).catch(() => {})
        showToast(t('copied'))
      })
    })

    // Delete single
    list.querySelectorAll<HTMLButtonElement>('.delete-one-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const name = btn.dataset.name!
        if (!window.confirm(t('deleteConfirm', { count: 1 }))) return
        try {
          const res = await deleteAccounts([name])
          selected.delete(name)
          showToast(t('deleted', { count: res.removed }))
          loadAccounts()
        } catch (e) {
          showToast(t('deleteError', { error: e instanceof Error ? e.message : String(e) }))
        }
      })
    })


    // Background sync: trigger whenever plan or expires_at is missing for current account.
    // This covers fresh start (no JWT cached yet) and post-save states alike.
    if (currentAcc && (!currentAcc.plan || !currentAcc.expires_at)) {
      syncBilling(currentAcc.name).then(() => loadAccounts()).catch(() => {})
    }
  } catch (e) {
    list.innerHTML = `<div class="error-state">
      ${t('loadAccountsFailed', { error: e instanceof Error ? esc(e.message) : t('unknownError') })}
    </div>`
  }
}

function showRenameModal(oldName: string) {
  // Remove any existing modal
  document.getElementById('rename-modal')?.remove()

  const modal = document.createElement('div')
  modal.id = 'rename-modal'
  modal.className = 'modal-overlay'
  modal.innerHTML = `
    <div class="modal-box">
      <h3>${t('renameTitle')}</h3>
      <p class="modal-subtitle">${esc(oldName)}</p>
      <label class="modal-label">${t('renameLabel')}</label>
      <input id="rename-input" class="modal-input" type="text" value="${esc(oldName)}" />
      <div class="modal-actions">
        <button class="btn" id="rename-cancel-btn">${t('renameCancel')}</button>
        <button class="btn btn-primary" id="rename-confirm-btn">${t('renameConfirm')}</button>
      </div>
    </div>
  `
  document.body.appendChild(modal)

  const input = document.getElementById('rename-input') as HTMLInputElement
  input.focus()
  input.select()

  document.getElementById('rename-cancel-btn')!.addEventListener('click', () => modal.remove())

  document.getElementById('rename-confirm-btn')!.addEventListener('click', async () => {
    const newName = input.value.trim()
    if (!newName || newName === oldName) { modal.remove(); return }
    try {
      await renameAccount(oldName, newName)
      modal.remove()
      showToast(t('renameDone', { name: newName }))
      loadAccounts()
    } catch (e) {
      showToast(t('renameError', { error: e instanceof Error ? e.message : String(e) }))
    }
  })

  // Enter key to confirm
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') document.getElementById('rename-confirm-btn')!.click()
    if (e.key === 'Escape') modal.remove()
  })

  // Click outside to close
  modal.addEventListener('click', (e) => {
    if (e.target === modal) modal.remove()
  })
}

async function doLogin() {
  const banner = document.getElementById('login-banner')!
  const btn = document.getElementById('add-account-btn') as HTMLButtonElement
  btn.disabled = true
  banner.style.display = 'block'
  banner.innerHTML = `<span class="spinner"></span> ${t('oauthPreparing')}`
  try {
    const currentPort = window.location.port ? Number(window.location.port) : undefined
    const currentHost = window.location.hostname
    const publicPort = currentPort !== undefined && Number.isFinite(currentPort) && currentPort > 0
      ? Math.trunc(currentPort)
      : undefined
    const data = await startLogin(undefined, publicPort, currentHost)
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
