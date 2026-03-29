#!/usr/bin/env sh
set -eu

node <<'NODE'
const fs = require('fs')
const path = require('path')
const APP_DIR = process.env.APP_DIR || '/app'

function insertBefore(src, marker, insert, label) {
  if (src.includes(insert.trim())) return src
  if (!src.includes(marker)) throw new Error(`Failed to find marker for ${label}`)
  return src.replace(marker, insert + marker)
}

function insertBeforeAny(src, markers, insert, label) {
  if (src.includes(insert.trim())) return src
  for (const marker of markers) {
    if (src.includes(marker)) return src.replace(marker, insert + marker)
  }
  throw new Error(`Failed to find marker for ${label}`)
}

function replaceOnce(src, search, replace, label) {
  if (src.includes(replace)) return src
  if (!src.includes(search)) throw new Error(`Failed to find search for ${label}`)
  return src.replace(search, replace)
}

function replaceRegex(src, pattern, replace, label) {
  if (!pattern.test(src)) throw new Error(`Failed to find pattern for ${label}`)
  return src.replace(pattern, replace)
}

let devApi = fs.readFileSync(path.join(APP_DIR, 'scripts/dev-api.js'), 'utf8')

devApi = insertBefore(
  devApi,
  `const OPENCLAW_DIR = path.join(homedir(), '.openclaw')\n`,
  `const _uiEventClients = new Set()\nconst OPENCLAW_GATEWAY_HOST = process.env.OPENCLAW_GATEWAY_HOST || '127.0.0.1'\n\nfunction _stripAnsi(value) {\n  return String(value || '').replace(/\\x1B\\[[0-9;]*[A-Za-z]/g, '')\n}\n\nfunction _emitUiEvent(eventName, payload) {\n  const frame = \`event: \${eventName}\\ndata: \${JSON.stringify(payload)}\\n\\n\`\n  for (const client of [..._uiEventClients]) {\n    try {\n      client.res.write(frame)\n    } catch {\n      clearInterval(client.keepalive)\n      _uiEventClients.delete(client)\n    }\n  }\n}\n\nfunction _emitChannelActionLog(platform, action, message) {\n  _emitUiEvent('channel-action-log', { platform, action, message: _stripAnsi(message) })\n}\n\nfunction _emitChannelActionProgress(platform, action, progress, stage = '') {\n  _emitUiEvent('channel-action-progress', { platform, action, progress, stage })\n}\n\nfunction _subscribeUiEvents(req, res) {\n  res.statusCode = 200\n  res.setHeader('Content-Type', 'text/event-stream; charset=utf-8')\n  res.setHeader('Cache-Control', 'no-cache, no-transform')\n  res.setHeader('Connection', 'keep-alive')\n  res.setHeader('X-Accel-Buffering', 'no')\n  if (typeof res.flushHeaders === 'function') res.flushHeaders()\n  res.write('retry: 1000\\n\\n')\n  const client = {\n    res,\n    keepalive: setInterval(() => {\n      try { res.write(': ping\\n\\n') } catch {}\n    }, 15000),\n  }\n  _uiEventClients.add(client)\n  req.on('close', () => {\n    clearInterval(client.keepalive)\n    _uiEventClients.delete(client)\n  })\n}\n\n`,
  'dev-api event helpers',
)

devApi = replaceOnce(
  devApi,
  `      return { gatewayUrl: \`http://127.0.0.1:\${gw.port || 18789}\`, authToken: gw.auth?.token || '', version: null }\n`,
  `      return { gatewayUrl: \`http://\${OPENCLAW_GATEWAY_HOST}:\${gw.port || 18789}\`, authToken: gw.auth?.token || '', version: null }\n`,
  'dev-api deploy config gateway host',
)

devApi = replaceOnce(
  devApi,
  `      return { gatewayUrl: 'http://127.0.0.1:18789', authToken: '', version: null }\n`,
  `      return { gatewayUrl: \`http://\${OPENCLAW_GATEWAY_HOST}:18789\`, authToken: '', version: null }\n`,
  'dev-api deploy config fallback host',
)

devApi = replaceOnce(
  devApi,
  `        socket = await rawWsConnect('127.0.0.1', parseInt(gwPort), '/ws')\n`,
  `        socket = await rawWsConnect(OPENCLAW_GATEWAY_HOST, parseInt(gwPort), '/ws')\n`,
  'dev-api raw websocket gateway host',
)

devApi = replaceOnce(
  devApi,
  `    console.log(\`[gateway-chat] WebSocket 已连接 ws://127.0.0.1:\${gwPort}/ws\`)\n`,
  `    console.log(\`[gateway-chat] WebSocket 已连接 ws://\${OPENCLAW_GATEWAY_HOST}:\${gwPort}/ws\`)\n`,
  'dev-api raw websocket log host',
)

devApi = insertBeforeAny(
  devApi,
  [
    `  async check_weixin_plugin_status() {\n`,
    `  async pairing_list_channel({ channel }) {\n`,
  ],
  `  async run_channel_action({ platform, action, version } = {}) {\n    if (!platform || !String(platform).trim()) throw new Error('platform 不能为空')\n    if (!action || !String(action).trim()) throw new Error('action 不能为空')\n\n    const pid = String(platform).trim()\n    const act = String(action).trim()\n    const bin = findOpenclawBin() || 'openclaw'\n    const env = {\n      ...process.env,\n      HOME: homedir(),\n      NO_COLOR: '1',\n      FORCE_COLOR: '0',\n      BROWSER: process.env.BROWSER || 'echo',\n    }\n\n    let args = []\n    let timeoutMs = 10 * 60 * 1000\n\n    if (pid === 'weixin' && act === 'login') {\n      args = ['channels', 'login', '--channel', 'openclaw-weixin']\n      timeoutMs = 8 * 60 * 1000\n    } else if (pid === 'weixin' && act === 'install') {\n      args = ['plugins', 'install', version ? \`@tencent-weixin/openclaw-weixin@\${version}\` : '@tencent-weixin/openclaw-weixin@latest']\n    } else {\n      throw new Error(\`暂不支持的渠道动作: \${pid}/\${act}\`)\n    }\n\n    _emitChannelActionProgress(pid, act, 5, 'starting')\n    _emitChannelActionLog(pid, act, \`执行命令: \${bin} \${args.join(' ')}\`)\n\n    return await new Promise((resolve, reject) => {\n      const child = spawn(bin, args, {\n        cwd: homedir(),\n        env,\n        stdio: ['ignore', 'pipe', 'pipe'],\n      })\n\n      const lines = []\n      let stdoutBuf = ''\n      let stderrBuf = ''\n      let finished = false\n\n      const emitLine = (text) => {\n        const msg = _stripAnsi(text)\n        if (!msg.trim()) return\n        lines.push(msg)\n        _emitChannelActionLog(pid, act, msg)\n      }\n\n      const bindStream = (stream, isErr = false) => {\n        stream.on('data', (chunk) => {\n          const str = chunk.toString('utf8')\n          const next = (isErr ? stderrBuf : stdoutBuf) + str\n          const parts = next.split(/\\r?\\n/)\n          const rest = parts.pop() || ''\n          if (isErr) stderrBuf = rest\n          else stdoutBuf = rest\n          for (const part of parts) emitLine(part)\n        })\n      }\n\n      const timer = setTimeout(() => {\n        _emitChannelActionLog(pid, act, '命令执行超时，已终止。')\n        try { child.kill('SIGTERM') } catch {}\n      }, timeoutMs)\n\n      const finish = (err, result) => {\n        if (finished) return\n        finished = true\n        clearTimeout(timer)\n        if (stdoutBuf) emitLine(stdoutBuf)\n        if (stderrBuf) emitLine(stderrBuf)\n        if (err) return reject(err)\n        return resolve(result)\n      }\n\n      bindStream(child.stdout)\n      bindStream(child.stderr, true)\n\n      child.on('error', (err) => finish(new Error(\`执行失败: \${err.message || err}\`)))\n      child.on('close', (code, signal) => {\n        if (code === 0) {\n          _emitChannelActionProgress(pid, act, 100, 'done')\n          finish(null, lines.join('\\n').trim() || '执行完成')\n          return\n        }\n        finish(new Error(\`命令退出异常 (code=\${code ?? 'null'}, signal=\${signal || 'none'})\`))\n      })\n\n      if (pid === 'weixin' && act === 'login') {\n        _emitChannelActionProgress(pid, act, 15, 'waiting_for_qr')\n      }\n    })\n  },\n\n`,
  'run_channel_action handler',
)

devApi = insertBefore(
  devApi,
  `  async pairing_list_channel({ channel }) {\n`,
  `  async check_weixin_plugin_status() {\n    const extDir = path.join(OPENCLAW_DIR, 'extensions', 'openclaw-weixin')\n    const pkgJson = path.join(extDir, 'package.json')\n    let installed = false\n    let installedVersion = null\n\n    if (fs.existsSync(pkgJson)) {\n      installed = true\n      try {\n        installedVersion = JSON.parse(fs.readFileSync(pkgJson, 'utf8')).version || null\n      } catch {}\n    }\n\n    let latestVersion = null\n    try {\n      const resp = await fetch('https://registry.npmjs.org/@tencent-weixin/openclaw-weixin/latest', {\n        headers: { Accept: 'application/json' },\n        signal: AbortSignal.timeout(8000),\n      })\n      if (resp.ok) {\n        const body = await resp.json()\n        latestVersion = body?.version || null\n      }\n    } catch {}\n\n    const updateAvailable = !!(installedVersion && latestVersion && versionCompare(latestVersion, installedVersion) > 0)\n\n    let compatible = true\n    let compatError = ''\n    const hostVersion = baseVersion(getLocalOpenclawVersion() || '')\n    if (installed && hostVersion && versionCompare(hostVersion, '2026.3.22') < 0) {\n      compatible = false\n      compatError = \`插件版本与当前 OpenClaw \${hostVersion} 不兼容（要求 >= 2026.3.22），请先升级 OpenClaw 或在终端执行: npx -y @tencent-weixin/openclaw-weixin-cli install\`\n    }\n\n    return {\n      installed,\n      installedVersion,\n      latestVersion,\n      updateAvailable,\n      compatible,\n      compatError,\n    }\n  },\n\n`,
  'check_weixin_plugin_status handler',
)

devApi = insertBefore(
  devApi,
  `  if (cmd === 'auth_check') {\n`,
  `  if (cmd === 'events') {\n    if (!isAuthenticated(req)) {\n      res.statusCode = 401\n      res.setHeader('Content-Type', 'application/json')\n      res.end(JSON.stringify({ error: '未登录' }))\n      return\n    }\n    _subscribeUiEvents(req, res)\n    return\n  }\n\n`,
  'events endpoint',
)

fs.writeFileSync(path.join(APP_DIR, 'scripts/dev-api.js'), devApi)

let serveJs = fs.readFileSync(path.join(APP_DIR, 'scripts/serve.js'), 'utf8')

serveJs = insertBefore(
  serveJs,
  `async function main() {\n`,
  `const OPENCLAW_GATEWAY_HOST = process.env.OPENCLAW_GATEWAY_HOST || '127.0.0.1'\n\n`,
  'serve.js gateway host constant',
)

serveJs = replaceOnce(
  serveJs,
  `    const target = net.createConnection(gatewayPort, '127.0.0.1', () => {\n`,
  `    const target = net.createConnection(gatewayPort, OPENCLAW_GATEWAY_HOST, () => {\n`,
  'serve.js websocket proxy gateway host',
)

fs.writeFileSync(path.join(APP_DIR, 'scripts/serve.js'), serveJs)

let channels = fs.readFileSync(path.join(APP_DIR, 'src/pages/channels.js'), 'utf8')

channels = insertBefore(
  channels,
  `// ── 渠道注册表：面板内置向导，覆盖 OpenClaw 官方渠道 + 国内扩展渠道 ──\n`,
  `let _webPanelEventSource = null\n\nfunction ensureWebPanelEventSource() {\n  if (_webPanelEventSource) return _webPanelEventSource\n  _webPanelEventSource = new EventSource('/__api/events', { withCredentials: true })\n  _webPanelEventSource.onerror = () => {}\n  return _webPanelEventSource\n}\n\nasync function listenPanelEvent(eventName, cb) {\n  if (window.__TAURI_INTERNALS__) {\n    const { listen } = await import('@tauri-apps/api/event')\n    return listen(eventName, cb)\n  }\n  const es = ensureWebPanelEventSource()\n  const handler = (evt) => {\n    let payload = evt.data\n    try { payload = JSON.parse(evt.data) } catch {}\n    cb({ payload })\n  }\n  es.addEventListener(eventName, handler)\n  return () => es.removeEventListener(eventName, handler)\n}\n\n`,
  'channels web event helper',
)

channels = replaceRegex(
  channels,
  /^(\s*)const \{ listen \} = await import\('@tauri-apps\/api\/event'\)\n/gm,
  `$1const listen = listenPanelEvent\n`,
  'channels listen replacements',
)

channels = replaceOnce(
  channels,
  `      let unlistenLog = null
      let unlistenProgress = null
      let unlistenDone = null
      let unlistenError = null
      const cleanup = () => {
        unlistenLog?.()
        unlistenProgress?.()
        unlistenDone?.()
        unlistenError?.()
      }
`,
  `      let unlistenLog = null
      let unlistenProgress = null
      let _qrTimer = null
      const cleanup = () => {
        unlistenLog?.()
        unlistenProgress?.()
        clearTimeout(_qrTimer)
      }
`,
  'channels second action cleanup replacement',
)

channels = replaceOnce(
  channels,
  `      try {
        btn.disabled = true
        btn.textContent = t('channels.executingShort')
        unlistenLog = await listen('channel-action-log', (e) => {
          if (e.payload?.platform !== pid || e.payload?.action !== actionId) return
          if (logBox) {
            logBox.textContent += (logBox.textContent ? '\\n' : '') + (e.payload?.message || '')
            logBox.scrollTop = logBox.scrollHeight
          }
        })
        unlistenProgress = await listen('channel-action-progress', (e) => {
          if (e.payload?.platform !== pid || e.payload?.action !== actionId) return
          const pct = Number(e.payload?.progress || 0)
          if (progressBar) progressBar.style.width = \`\${pct}%\`
          if (progressText) progressText.textContent = \`\${pct}%\`
        })
        unlistenDone = await listen('channel-action-done', (e) => {
          if (e.payload?.platform !== pid || e.payload?.action !== actionId) return
          if (progressBar) progressBar.style.width = '100%'
          if (progressText) progressText.textContent = '100%'
        })
        unlistenError = await listen('channel-action-error', (e) => {
          if (e.payload?.platform !== pid || e.payload?.action !== actionId) return
          if (logBox) {
            logBox.textContent += (logBox.textContent ? '\\n' : '') + t('channels.executionFailed') + ': ' + (e.payload?.message || t('channels.unknownError'))
            logBox.scrollTop = logBox.scrollHeight
          }
        })

        // 微信/QQ 等第三方插件版本号独立，不 pin；run_channel_action 的 version 参数仅用于 npx 包名
        const output = await api.runChannelAction(pid, actionId, null)
        toast(t('channels.actionDone'), 'success')
        if (logBox && output && !String(output).includes(logBox.textContent)) {
          logBox.textContent += (logBox.textContent ? '\\n' : '') + String(output)
        }
`,
  `      try {
        btn.disabled = true
        btn.textContent = t('channels.executingShort')
        if (logBox) {
          const hint = document.createElement('div')
          hint.style.cssText = 'color:var(--text-tertiary);font-style:italic'
          hint.id = 'action-loading-hint'
          hint.textContent = t('channels.downloadingPlugin') || '正在下载，请稍候（首次安装可能需要几分钟）...'
          logBox.appendChild(hint)
        }
        const _qrBuf = []
        let _qrDone = false
        const _flushQr = () => {
          if (!_qrBuf.length || _qrDone) return
          _qrDone = true
          const hasHalf = _qrBuf.some(l => /[\\u2580\\u2584]/.test(l))
          const matrix = []
          for (const line of _qrBuf) {
            if (hasHalf) {
              const top = [], bot = []
              for (const ch of line) {
                if (ch === '\\u2588') { top.push(1); bot.push(1) }
                else if (ch === '\\u2580') { top.push(1); bot.push(0) }
                else if (ch === '\\u2584') { top.push(0); bot.push(1) }
                else { top.push(0); bot.push(0) }
              }
              matrix.push(top, bot)
            } else {
              matrix.push([...line].map(ch => ch === '\\u2588' ? 1 : 0))
            }
          }
          if (!matrix.length) return
          const mod = 4, w = Math.max(...matrix.map(r => r.length)), h = matrix.length
          const cvs = document.createElement('canvas')
          cvs.width = w * mod; cvs.height = h * mod
          const ctx = cvs.getContext('2d')
          ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, cvs.width, cvs.height)
          ctx.fillStyle = '#000'
          for (let y = 0; y < h; y++) for (let x = 0; x < (matrix[y]?.length || 0); x++) {
            if (matrix[y][x]) ctx.fillRect(x * mod, y * mod, mod, mod)
          }
          const wrap = document.createElement('div')
          wrap.style.cssText = 'text-align:center;margin:12px 0;padding:16px;background:#fff;border-radius:var(--radius-md);border:1px solid var(--border-primary)'
          wrap.innerHTML = \`<div style="font-size:var(--font-size-sm);font-weight:600;color:#000;margin-bottom:8px">\${t('channels.weixinScanQr')}</div>\`
          const img = document.createElement('img')
          img.src = cvs.toDataURL()
          img.style.cssText = 'display:block;margin:0 auto;image-rendering:pixelated;max-width:280px'
          wrap.appendChild(img)
          logBox?.appendChild(wrap)
        }
        unlistenLog = await listen('channel-action-log', (e) => {
          if (e.payload?.platform !== pid || e.payload?.action !== actionId) return
          if (!logBox) return
          const msg = e.payload?.message || ''
          const isQrLine = /[\\u2580\\u2584\\u2588]/.test(msg)
          if (isQrLine && (actionId === 'login' || actionId === 'install')) {
            _qrBuf.push(msg)
            clearTimeout(_qrTimer)
            _qrTimer = setTimeout(_flushQr, 500)
          } else if (!isQrLine) {
            if (_qrBuf.length && !_qrDone) _flushQr()
            const weixinUrlMatch = msg.match(/(https:\\/\\/liteapp\\.weixin\\.qq\\.com\\/q\\/[^\\s]+)/)
            if (weixinUrlMatch && !_qrDone) {
              _qrDone = true
              const qrUrl = weixinUrlMatch[1]
              const wrap = document.createElement('div')
              wrap.style.cssText = 'text-align:center;margin:12px 0;padding:16px;background:#fff;border-radius:var(--radius-md);border:1px solid var(--border-primary)'
              wrap.innerHTML = \`
                <div style="font-size:var(--font-size-sm);font-weight:600;color:#000;margin-bottom:8px">\${t('channels.weixinScanQr')}</div>
                <img src="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=\${encodeURIComponent(qrUrl)}" alt="WeChat QR" style="width:200px;height:200px;image-rendering:pixelated;border-radius:4px;margin:0 auto;display:block" loading="eager">
                <div style="margin-top:8px"><a href="\${escapeAttr(qrUrl)}" target="_blank" rel="noopener" style="color:var(--accent);font-size:var(--font-size-xs);word-break:break-all">\${t('channels.weixinOpenInBrowser') || '或点击此链接在浏览器中打开'}</a></div>
              \`
              logBox.appendChild(wrap)
            } else if (msg.trim()) {
              const loadingHint = logBox.querySelector('#action-loading-hint')
              if (loadingHint) loadingHint.remove()
              const div = document.createElement('div')
              div.textContent = msg
              logBox.appendChild(div)
            }
          }
          logBox.scrollTop = logBox.scrollHeight
        })
        unlistenProgress = await listen('channel-action-progress', (e) => {
          if (e.payload?.platform !== pid || e.payload?.action !== actionId) return
          const pct = Number(e.payload?.progress || 0)
          if (progressBar) progressBar.style.width = \`\${pct}%\`
          if (progressText) progressText.textContent = \`\${pct}%\`
        })

        // 微信/QQ 等第三方插件版本号独立，不 pin；run_channel_action 的 version 参数仅用于 npx 包名
        const output = await api.runChannelAction(pid, actionId, null)
        _flushQr()
        if (progressBar) progressBar.style.width = '100%'
        if (progressText) progressText.textContent = '100%'
        toast(t('channels.actionDone'), 'success')
        if (logBox && output && !String(output).includes(logBox.textContent)) {
          const loadingHint = logBox.querySelector('#action-loading-hint')
          if (loadingHint) loadingHint.remove()
          logBox.textContent += (logBox.textContent ? '\\n' : '') + String(output)
        }
`,
  'channels second action runtime replacement',
)

fs.writeFileSync(path.join(APP_DIR, 'src/pages/channels.js'), channels)
NODE
