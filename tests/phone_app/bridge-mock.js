export const calls = []
export const loads = []
export const fake = { loadFixes: false, get: () => ({ enabled: true, state: null, result: null }), act: () => true, direct: true, viaExtensions: true }
const make = () => ({
  uiGet: async () => fake.get(),
  uiAct: async (...args) => { calls.push(args); return fake.act(...args) },
})
// lua.rlsmp_market and lua.extensions.rlsmp_market are two routes to the same extension; a test can switch either off
export const lua = {
  get rlsmp_market() { if (!fake.direct) throw new Error('rlsmp_market is not defined'); return make() },
  extensions: { load: async (name) => { loads.push(name); if (fake.loadFixes) fake.viaExtensions = true; fake.direct = fake.direct || fake.loadFixes },
    get rlsmp_market() { if (!fake.viaExtensions) throw new Error('no such extension'); return make() } },
}
