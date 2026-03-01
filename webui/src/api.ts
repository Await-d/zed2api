export interface Account {
  name: string
  user_id: string
  current: boolean
  plan?: string
  expires_at?: string
}

export interface AccountsResponse {
  accounts: Account[]
  current: string
}

export async function fetchAccounts(): Promise<AccountsResponse> {
  const r = await fetch('/zed/accounts')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function switchAccount(name: string): Promise<void> {
  await fetch('/zed/accounts/switch', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: name }),
  })
}

export async function deleteAccounts(names: string[]): Promise<{ removed: number }> {
  const r = await fetch('/zed/accounts/delete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ names }),
  })
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function renameAccount(oldName: string, newName: string): Promise<void> {
  const r = await fetch('/zed/accounts/rename', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ old_name: oldName, new_name: newName }),
  })
  if (!r.ok) {
    const body = await r.json().catch(() => ({}))
    throw new Error((body as Record<string, string>).error ?? `${r.status}`)
  }
}

export async function syncBilling(name: string): Promise<void> {
  const r = await fetch('/zed/accounts/sync-billing', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name }),
  })
  if (!r.ok) throw new Error(`${r.status}`)
}

export async function fetchBilling(): Promise<Record<string, unknown>> {
  const r = await fetch('/zed/billing')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function startLogin(name?: string, publicPort?: number, publicHost?: string): Promise<{ login_url?: string; error?: string }> {
  const payload: { name?: string; public_port?: number; public_host?: string } = {}
  if (name) payload.name = name
  if (publicPort !== undefined && Number.isFinite(publicPort) && publicPort > 0) {
    payload.public_port = Math.trunc(publicPort)
  }
  if (publicHost && publicHost.length > 0) {
    payload.public_host = publicHost
  }
  const r = await fetch('/zed/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
  return r.json()
}

export async function fetchLoginStatus(): Promise<{ status: string }> {
  const r = await fetch('/zed/login/status')
  return r.json()
}

export interface ChatMessage {
  role: 'user' | 'assistant' | 'system'
  content: string
}

export async function sendOpenAI(
  model: string,
  messages: ChatMessage[],
  maxTokens = 4096,
): Promise<string> {
  const r = await fetch('/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens }),
  })
  const d = await r.json()
  return d.choices?.[0]?.message?.content ?? JSON.stringify(d, null, 2)
}

export async function sendAnthropic(
  model: string,
  messages: ChatMessage[],
  maxTokens = 4096,
): Promise<string> {
  const r = await fetch('/v1/messages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens }),
  })
  const d = await r.json()
  return d.content?.[0]?.text ?? JSON.stringify(d, null, 2)
}
