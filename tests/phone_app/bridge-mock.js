export const calls = []
export const fake = { get: () => ({ enabled: true, state: null, result: null }), act: () => true }
export const lua = { rlsmp_market: {
  uiGet: async () => fake.get(),
  uiAct: async (...args) => { calls.push(args); return fake.act(...args) },
} }
