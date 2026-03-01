export type Locale = 'zh' | 'en'

const LOCALE_KEY = 'zed2api.locale'

const translations = {
  zh: {
    appTagline: 'Zed LLM API 代理',
    navManage: '管理',
    navAccounts: '账号',
    navHealth: '健康检查',
    navReference: '参考',
    navEndpoints: '接口',
    navIntegration: '集成',
    runningPort: '运行端口',
    switchToEnglish: '切换到英文',
    switchToChinese: '切换到中文',

    accountsTitle: '账号',
    accountsDesc: '管理你的 Zed 账号与凭据。',
    addAccount: '通过 GitHub OAuth 添加账号',
    addAccountHint: '将在隐私/无痕窗口中打开',
    noAccounts: '暂无已配置账号。',
    current: '当前',
    switch: '切换',
    switchedTo: '已切换到 {name}',
    loadAccountsFailed: '加载账号失败：{error}',
    unknownError: '未知错误',
    unknown: '未知',
    expires: '到期时间',
    daysLeft: '（剩余 {days} 天）',
    usage: '用量',
    plan: '套餐',
    spend: '消费',
    viewOnZed: '在 zed.dev 查看',
    limit: '额度 ${limit}',
    oauthPreparing: '正在生成密钥并启动 OAuth...',
    oauthWaiting: '等待 GitHub 登录回调...',
    oauthHint: '请在弹出的浏览器窗口完成登录，当前页面会自动更新。',
    openLoginPage: '打开登录页面',
    oauthPopupBlocked: '浏览器拦截了弹窗，请点击链接继续登录。',
    loginSuccess: '登录成功',
    accountAddedSuccess: '账号添加成功',
    loginFailedRetry: '登录失败，请重试。',
    errorPrefix: '错误：',

    // account management
    deleteSelected: '删除选中',
    selectAll: '全选',
    deselectAll: '取消全选',
    deleteConfirm: '确认删除以下 {count} 个账号？',
    deleted: '已删除 {count} 个账号',
    rename: '重命名',
    renameTitle: '重命名账号',
    renameLabel: '新名称',
    renameConfirm: '确认',
    renameCancel: '取消',
    renameDone: '已重命名为 {name}',
    renameError: '重命名失败：{error}',
    deleteError: '删除失败：{error}',
    copyUserId: '复制 User ID',
    copied: '已复制',
    managing: '管理模式',
    doneManaging: '完成',

    healthTitle: '健康检查',
    healthDesc: '验证所有服务是否正常运行。',
    rerun: '重新检测',
    checking: '检测中...',
    runningChecks: '正在执行检测...',
    checksPassed: '{passed}/{total} 项通过',
    allOperational: '所有服务正常',
    lastChecked: '最近检测：{time}',
    genericError: '错误',
    unreachable: '不可达',
    apiServer: 'API 服务',
    apiServerDesc: '本地代理可正常响应',
    modelsAvailable: '可用模型 {count} 个',
    accountsCheck: '账号配置',
    accountsCheckDesc: '至少已配置一个账号',
    noAccountsConfigured: '未配置账号',
    accountsActive: '{count} 个账号，当前：{name}',
    tokenRefresh: '令牌刷新',
    tokenRefreshDesc: '可从 Zed 获取 JWT',
    checkCredentials: '请检查账号凭据',
    planValue: '套餐：{plan}',
    openaiEndpoint: 'OpenAI 接口',
    openaiEndpointDesc: '/v1/chat/completions 可访问',
    anthropicEndpoint: 'Anthropic 接口',
    anthropicEndpointDesc: '/v1/messages 可访问',

    endpointsTitle: 'API 接口',
    endpointsDesc: '当前代理服务可用路由。',
    epChat: 'OpenAI 兼容聊天补全接口',
    epMessages: 'Anthropic 原生消息接口',
    epModels: '获取可用模型列表',
    epAccounts: '获取已配置账号列表',
    epSwitch: '切换当前活跃账号',
    epUsage: '获取当前账号用量与套餐信息',
    epLogin: '启动 GitHub OAuth 登录流程',
    epEventLog: 'Claude Code 事件日志接口（占位）',

    integrationTitle: '集成接入',
    integrationDesc: '将你的工具接入 zed2api。',
    addToClaudeConfig: '添加到 ~/.claude.json：',
    copy: '复制',
    openaiUsage: '作为 OpenAI 兼容端点使用：',
    anthropicUsage: '作为 Anthropic 兼容端点使用：',
  },
  en: {
    appTagline: 'Zed LLM API Proxy',
    navManage: 'Manage',
    navAccounts: 'Accounts',
    navHealth: 'Health',
    navReference: 'Reference',
    navEndpoints: 'Endpoints',
    navIntegration: 'Integration',
    runningPort: 'Running on',
    switchToEnglish: 'Switch to English',
    switchToChinese: '切换到中文',

    accountsTitle: 'Accounts',
    accountsDesc: 'Manage your Zed accounts and credentials.',
    addAccount: 'Add account via GitHub OAuth',
    addAccountHint: 'Opens in private/incognito window',
    noAccounts: 'No accounts configured yet.',
    current: 'Active',
    switch: 'Switch',
    switchedTo: 'Switched to {name}',
    loadAccountsFailed: 'Failed to load accounts: {error}',
    unknownError: 'unknown error',
    unknown: 'Unknown',
    expires: 'Expires',
    daysLeft: '({days}d left)',
    usage: 'Usage',
    plan: 'Plan',
    spend: 'Token Spend',
    viewOnZed: 'View on zed.dev',
    limit: 'limit ${limit}',
    oauthPreparing: 'Generating keypair and starting OAuth...',
    oauthWaiting: 'Waiting for GitHub login callback...',
    oauthHint: 'Complete the login in the opened browser window. This page updates automatically.',
    openLoginPage: 'Open login page',
    oauthPopupBlocked: 'Popup was blocked. Click the link to continue login.',
    loginSuccess: 'Login successful',
accountAddedSuccess: 'Account added successfully',
loginFailedRetry: 'Login failed. Try again.',
    errorPrefix: 'Error: ',

    // account management
    deleteSelected: 'Delete selected',
    selectAll: 'Select all',
    deselectAll: 'Deselect all',
    deleteConfirm: 'Delete {count} account(s)?',
    deleted: 'Deleted {count} account(s)',
    rename: 'Rename',
    renameTitle: 'Rename account',
    renameLabel: 'New name',
    renameConfirm: 'Confirm',
    renameCancel: 'Cancel',
    renameDone: 'Renamed to {name}',
    renameError: 'Rename failed: {error}',
    deleteError: 'Delete failed: {error}',
    copyUserId: 'Copy User ID',
    copied: 'Copied!',
    managing: 'Manage',
    doneManaging: 'Done',

    healthTitle: 'Health Check',
    healthDesc: 'Verify all services are operational.',
    rerun: 'Re-run',
    checking: 'Checking...',
    runningChecks: 'Running checks...',
    checksPassed: '{passed}/{total} checks passed',
    allOperational: 'All systems operational',
    lastChecked: 'Last checked: {time}',
    genericError: 'error',
    unreachable: 'unreachable',
    apiServer: 'API Server',
    apiServerDesc: 'Local proxy is responding',
    modelsAvailable: '{count} models available',
    accountsCheck: 'Accounts',
    accountsCheckDesc: 'At least one account configured',
    noAccountsConfigured: 'No accounts configured',
    accountsActive: '{count} account(s), active: {name}',
    tokenRefresh: 'Token Refresh',
    tokenRefreshDesc: 'Can obtain a JWT from Zed',
    checkCredentials: 'check account credentials',
    planValue: 'Plan: {plan}',
    openaiEndpoint: 'OpenAI Endpoint',
    openaiEndpointDesc: '/v1/chat/completions is reachable',
    anthropicEndpoint: 'Anthropic Endpoint',
    anthropicEndpointDesc: '/v1/messages is reachable',

    endpointsTitle: 'API Endpoints',
    endpointsDesc: 'Available routes on this proxy server.',
    epChat: 'OpenAI-compatible chat completions',
    epMessages: 'Anthropic native messages API',
    epModels: 'List available models',
    epAccounts: 'List configured accounts',
    epSwitch: 'Switch active account',
    epUsage: 'Current account usage and plan info',
    epLogin: 'Start GitHub OAuth login flow',
    epEventLog: 'Claude Code event logging (stub)',

    integrationTitle: 'Integration',
    integrationDesc: 'Connect your tools to zed2api.',
    addToClaudeConfig: 'Add to ~/.claude.json:',
    copy: 'Copy',
    openaiUsage: 'Use as an OpenAI-compatible endpoint:',
    anthropicUsage: 'Use as an Anthropic-compatible endpoint:',
  },
} as const

type Dict = typeof translations.zh
type Key = keyof Dict

let currentLocale: Locale = 'zh'

export function initLocale() {
  const saved = localStorage.getItem(LOCALE_KEY)
  if (saved === 'zh' || saved === 'en') {
    currentLocale = saved
  }
}

export function getLocale(): Locale {
  return currentLocale
}

export function setLocale(locale: Locale) {
  currentLocale = locale
  localStorage.setItem(LOCALE_KEY, locale)
}

export function toggleLocale(): Locale {
  const next: Locale = currentLocale === 'zh' ? 'en' : 'zh'
  setLocale(next)
  return next
}

export function t(key: Key, vars?: Record<string, string | number>): string {
  const template = String(translations[currentLocale][key])
  if (!vars) return template
  return Object.entries(vars).reduce<string>((acc, [name, value]) => {
    return acc.replaceAll(`{${name}}`, String(value))
  }, template)
}
