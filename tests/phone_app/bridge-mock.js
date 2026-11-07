// A fake of the game's UI bridge (@/bridge): the raw `api.engineLua(code, callback)` that RLS itself uses, and the `lua` proxy,
// which in the real game only knows the extensions it was told about (so for ours it can be "not a function").
export const calls = []
export const loads = []
export const luaCode = []
export const fake = {
  get: () => ({ enabled: true, state: null, result: null }),
  act: () => true,
  raw: 'ok',            // 'ok' | 'missing' (extension not loaded) | 'timeout' (never answers) | 'absent' (no engineLua) | 'throws'
  direct: false,       // lua.rlsmp_market works (a stub without functions otherwise, like the real game)
  viaExtensions: false,
}
const make = () => ({
  uiGet: async () => fake.get(),
  uiAct: async (...args) => { calls.push(args); return fake.act(...args) },
})

// parses the Lua the view sends: (function() ... local f = m["uiAct"] ... return f(args) end)()
function splitArgs(text) {
  const out = []
  let cur = '', inStr = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (inStr) {
      cur += c
      if (c === '\\') { cur += text[++i] }
      else if (c === '"') inStr = false
    } else if (c === '"') { inStr = true; cur += c }
    else if (c === ',') { out.push(cur.trim()); cur = '' }
    else cur += c
  }
  if (cur.trim() !== '') out.push(cur.trim())
  return out
}
function luaToJs(token) {
  if (token === 'nil') return undefined
  if (token === 'true') return true
  if (token === 'false') return false
  if (token.startsWith('"')) {
    const bytes = []
    const body = token.slice(1, -1)
    for (let i = 0; i < body.length; i++) {
      if (body[i] === '\\') {
        const digits = body.slice(i + 1, i + 4)
        if (!/^\d{3}$/.test(digits)) throw new Error('bad Lua escape in: ' + token)
        bytes.push(parseInt(digits, 10)); i += 3
      } else bytes.push(body.charCodeAt(i))
    }
    return new TextDecoder().decode(new Uint8Array(bytes))
  }
  return Number(token)
}
export function parseCall(code) {
  const fn = /m\["([A-Za-z]+)"\]|m\[\"([A-Za-z]+)\"\]/.exec(code)
  const argsText = /return f\((.*)\) end\)\(\)$/s.exec(code)
  if (!fn || !argsText) throw new Error('unexpected Lua: ' + code)
  return { fn: fn[1] || fn[2], args: splitArgs(argsText[1]).map(luaToJs) }
}

const rawApi = {
  engineLua(code, callback) {
    luaCode.push(code)
    if (fake.raw === 'throws') throw new Error('engineLua exploded')
    if (fake.raw === 'timeout') return
    if (fake.raw === 'missing') return callback({ missing: true })
    const { fn, args } = parseCall(code)
    Promise.resolve().then(() => make()[fn](...args)).then(callback, () => {})   // a Lua error: the game never calls back
  },
}
export const useBridge = () => ({ api: fake.raw === 'absent' ? {} : rawApi })

export const lua = {
  get rlsmp_market() { return fake.direct ? make() : {} },     // like the real game: a stub with no functions
  extensions: {
    load: async (name) => { loads.push(name) },
    get rlsmp_market() { if (!fake.viaExtensions) throw new Error('no such extension'); return make() },
  },
}
