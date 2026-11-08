import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import Comp from '../../Resources/Client/RLS-Career-MP/ui/ui-vue/mods/rls_career_mp/phone/PhoneBlackMarket.vue'
import { fake, calls, luaCode, parseCall } from './bridge-mock.js'

const member = (over = {}) => ({ ready: true, member: true, rep: 10, invitesLeft: 3, money: 5000, spot: "Joe's Junkyard",
  items: [
    { name: 'screwdriver', label: 'Screwdriver', price: 400, minRep: 0, durable: true, locked: false, have: 0, onOrder: false },
    { name: 'fake_plate', label: 'Fake plate', price: 1500, minRep: 0, durable: false, locked: false, have: 1, onOrder: false },
    { name: 'jammer', label: 'Signal jammer', price: 40000, minRep: 50, durable: true, locked: true, have: 0, onOrder: false },
  ], orders: [], ...over })

async function open(view) {
  fake.get = () => view
  const w = mount(Comp)
  await flushPromises()
  return w
}
beforeEach(() => { luaCode.length = 0; fake.raw = 'ok'; fake.direct = false; fake.viaExtensions = false; calls.length = 0; vi.useFakeTimers({ toFake: ['setInterval', 'setTimeout', 'clearInterval', 'clearTimeout'] }) })
afterEach(() => { vi.useRealTimers() })

describe('PhoneBlackMarket', () => {
  it('says connecting before the first answer, then not available when the mod is off', async () => {
    const w = await open({ enabled: false })
    expect(w.text()).toContain('Not available')
  })
  it('non-member sees invite only and an accept button for an invite', async () => {
    const w = await open({ enabled: true, state: { ready: true, member: false, invite: { from: 'ann', seconds: 80 }, money: 1 } })
    expect(w.text()).toContain('You are not in')
    expect(w.text()).toContain('ann invited you')
    const accept = w.findAll('button').find(b => b.text() === 'Accept')
    await accept.trigger('click'); await flushPromises()
    expect(calls).toEqual([['accept', undefined, undefined]])
  })
  it('member sees reputation, shop, locked items, and can buy a tool and a counted consumable', async () => {
    const w = await open({ enabled: true, state: member() })
    expect(w.text()).toContain('Reputation 10')
    expect(w.text()).toContain('Screwdriver')
    expect(w.text()).toContain('Unlocks with reputation')
    expect(w.text()).toContain('Needs reputation 50')
    const buttons = () => w.findAll('button')
    await buttons().find(b => b.text() === 'Buy $400').trigger('click'); await flushPromises()
    expect(calls[0].slice(0, 3)).toEqual(['buy', 'screwdriver', 1])
    calls.length = 0
    await buttons().find(b => b.attributes('aria-label') === 'More').trigger('click')
    await buttons().find(b => b.attributes('aria-label') === 'More').trigger('click')
    expect(w.text()).toContain('Buy $4,500')
    await buttons().find(b => b.text() === 'Buy $4,500').trigger('click'); await flushPromises()
    expect(calls[0].slice(0, 3)).toEqual(['buy', 'fake_plate', 3])
  })
  it('does not let you buy what you cannot afford or already own', async () => {
    const v = member({ money: 1000, items: [
      { name: 'screwdriver', label: 'Screwdriver', price: 400, minRep: 0, durable: true, locked: false, have: 0, onOrder: false },
      { name: 'window_punch', label: 'Window punch', price: 600, minRep: 0, durable: true, locked: false, have: 1, onOrder: false },
      { name: 'lockout_kit', label: 'Lockout kit', price: 700, minRep: 0, durable: true, locked: false, have: 0, onOrder: true },
      { name: 'relay_box', label: 'Relay box', price: 30000, minRep: 0, durable: true, locked: false, have: 0, onOrder: false }] })
    const w = await open({ enabled: true, state: v })
    const find = t => w.findAll('button').find(b => b.text() === t)
    expect(find('Buy $400').attributes('disabled')).toBeUndefined()      // affordable and not owned: allowed
    expect(find('Owned').attributes('disabled')).toBeDefined()           // affordable, but a tool you already have
    expect(find('On order').attributes('disabled')).toBeDefined()        // affordable, but already on its way
    expect(find('Too expensive').attributes('disabled')).toBeDefined()
  })
  it('shows orders and collects only when one is ready', async () => {
    let w = await open({ enabled: true, state: member({ orders: [{ id: 'o1', item: 'fake_plate', label: 'Fake plate', n: 1, spot: 'Dockyards parking', readyIn: 40, ready: false }] }) })
    expect(w.text()).toContain('On the way')
    expect(w.findAll('button').find(b => b.text() === 'Collect here').attributes('disabled')).toBeDefined()
    w = await open({ enabled: true, state: member({ orders: [{ id: 'o1', item: 'fake_plate', label: 'Fake plate', n: 2, spot: 'Dockyards parking', readyIn: 0, ready: true }] }) })
    expect(w.text()).toContain('Ready')
    expect(w.text()).toContain('× 2')
    await w.findAll('button').find(b => b.text() === 'Collect here').trigger('click'); await flushPromises()
    expect(calls[0][0]).toBe('pickup')
  })
  it('invites by name, clears the box, and blocks it with no invites left', async () => {
    const w = await open({ enabled: true, state: member() })
    await w.find('input').setValue('  fay ')
    await w.findAll('button').find(b => b.text() === 'Invite').trigger('click'); await flushPromises()
    expect(calls[0].slice(0, 2)).toEqual(['invite', 'fay'])
    expect(w.find('input').element.value).toBe('')
    const none = await open({ enabled: true, state: member({ invitesLeft: 0 }) })
    await none.find('input').setValue('fay')
    expect(none.findAll('button').find(b => b.text() === 'Invite').attributes('disabled')).toBeDefined()
  })
  it('the name field takes the keyboard from the game (setCEFTyping) and gives it back on Enter, Esc, blur and close', async () => {
    const w = await open({ enabled: true, state: member() })
    const typed = () => luaCode.filter(c => c.startsWith('setCEFTyping'))
    const input = w.find('input')
    await input.trigger('pointerdown')
    expect(typed()).toEqual(['setCEFTyping(true)'])
    await input.setValue('fay')
    await input.trigger('keydown', { key: 'Enter' }); await flushPromises()
    expect(calls[0].slice(0, 2)).toEqual(['invite', 'fay'])
    await input.trigger('keydown', { key: 'Escape' })
    expect(typed().at(-1)).toBe('setCEFTyping(false)')
    await input.trigger('focus'); w.unmount()
    expect(typed().at(-1)).toBe('setCEFTyping(false)')
  })
  it('shows a server answer once, hides an old one from an earlier visit, and polls', async () => {
    let seq = 4
    fake.get = () => ({ enabled: true, state: member(), result: { text: 'Paid $400.', seq } })
    const w = mount(Comp)
    await flushPromises()
    expect(w.text()).not.toContain('Paid $400.')          // seq 4 was already there when the app opened
    seq = 5
    await vi.advanceTimersByTimeAsync(1600); await flushPromises()
    expect(w.text()).toContain('Paid $400.')
    await vi.advanceTimersByTimeAsync(10000); await flushPromises()
    expect(w.text()).not.toContain('Paid $400.')          // fades after a few seconds
    w.unmount()
  })
  it('survives the game not answering', async () => {
    fake.get = () => { throw new Error('bridge down') }
    const w = mount(Comp)
    await flushPromises()
    await vi.advanceTimersByTimeAsync(4100); await flushPromises()
    expect(w.text()).toContain('No connection')
    fake.get = () => ({ enabled: true, state: member() })
    await vi.advanceTimersByTimeAsync(1600); await flushPromises()
    expect(w.text()).toContain('Reputation 10')
    w.unmount()
  })
  it('copes with empty lists that arrive as {} from the game', async () => {
    const w = await open({ enabled: true, state: member({ items: {}, orders: {} }) })
    expect(w.text()).toContain('Reputation 10')
    expect(w.text()).toContain('Nothing for you yet')
  })
  it('an ex-member with paid orders still sees and can collect them', async () => {
    const w = await open({ enabled: true, state: { ready: true, member: false, money: 5,
      orders: [{ id: 'o1', item: 'fake_plate', label: 'Fake plate', n: 1, spot: 'Joe', readyIn: 0, ready: true }] } })
    expect(w.text()).toContain('You are not in')
    expect(w.text()).toContain('Your orders')
    await w.findAll('button').find(b => b.text() === 'Collect here').trigger('click'); await flushPromises()
    expect(calls[0][0]).toBe('pickup')
  })
  it('talks to the game with the raw engineLua call RLS itself uses, not the lua proxy', async () => {
    const w = await open({ enabled: true, state: member() })
    expect(w.text()).toContain('Reputation 10')
    expect(luaCode.length).toBeGreaterThan(0)
    expect(luaCode[0]).toContain('rawget(_G, "rlsmp_market")')
    expect(parseCall(luaCode[0]).fn).toBe('uiGet')
    await w.findAll('button').find(b => b.text() === 'Buy $400').trigger('click'); await flushPromises()
    const call = parseCall(luaCode[luaCode.length - 1])
    expect(call.fn).toBe('uiAct')
    expect(call.args).toEqual(['buy', 'screwdriver', 1])
  })
  it('the lua proxy is only a fallback (in the real game it is a stub without functions for our extension)', async () => {
    fake.raw = 'absent'; fake.direct = true
    const w = await open({ enabled: true, state: member() })
    expect(w.text()).toContain('Reputation 10')
    fake.direct = false; fake.viaExtensions = true
    const w2 = await open({ enabled: true, state: member() })
    expect(w2.text()).toContain('Reputation 10')
  })
  it('when the raw call never answers, it waits a few seconds and then uses the proxy', async () => {
    fake.raw = 'timeout'; fake.viaExtensions = true
    fake.get = () => ({ enabled: true, state: member() })
    const w = mount(Comp)
    await flushPromises()
    expect(w.text()).not.toContain('Reputation 10')
    await vi.advanceTimersByTimeAsync(4100); await flushPromises()
    expect(w.text()).toContain('Reputation 10')
    w.unmount()
  })
  it('says the extension is not loaded when the game answers that', async () => {
    fake.raw = 'missing'
    const w = await open({ enabled: true, state: null })
    expect(w.text()).toContain('Not loaded')
  })
  it('shows every error when no way works', async () => {
    fake.raw = 'throws'
    const w = mount(Comp)
    await flushPromises()
    expect(w.text()).toContain('No connection')
    expect(w.text()).toContain('engineLua exploded')
    expect(w.text()).toContain('is not a function')
    expect(w.text()).toContain('no such extension')
  })
  it('escapes names safely into the Lua it sends (quotes, backslashes, non-ASCII)', async () => {
    const w = await open({ enabled: true, state: member() })
    const nasty = 'fay"; os.exit() --\\ é漢'   // (a single-line text box cannot hold a newline)
    await w.find('input').setValue(nasty)
    await w.findAll('button').find(b => b.text() === 'Invite').trigger('click'); await flushPromises()
    const call = parseCall(luaCode[luaCode.length - 1])
    expect(call.fn).toBe('uiAct')
    expect(call.args.slice(0, 2)).toEqual(['invite', nasty.trim()])
    expect(luaCode[luaCode.length - 1]).not.toContain('os.exit()')
  })
  it('copes with empty lists that arrive as {} from the game', async () => {
    const w = await open({ enabled: true, state: member({ items: {}, orders: {} }) })
    expect(w.text()).toContain('Reputation 10')
    expect(w.text()).toContain('Nothing for you yet')
  })
  it('an ex-member with paid orders still sees and can collect them', async () => {
    const w = await open({ enabled: true, state: { ready: true, member: false, money: 5,
      orders: [{ id: 'o1', item: 'fake_plate', label: 'Fake plate', n: 1, spot: 'Joe', readyIn: 0, ready: true }] } })
    expect(w.text()).toContain('You are not in')
    expect(w.text()).toContain('Your orders')
    await w.findAll('button').find(b => b.text() === 'Collect here').trigger('click'); await flushPromises()
    expect(calls[0][0]).toBe('pickup')
  })
  it('falls back to the second way into Lua when the first one fails', async () => {
    fake.direct = false
    const w = await open({ enabled: true, state: member() })
    expect(w.text()).toContain('Reputation 10')
    await w.findAll('button').find(b => b.text() === 'Buy $400').trigger('click'); await flushPromises()
    expect(calls[0].slice(0, 3)).toEqual(['buy', 'screwdriver', 1])
  })
  it('stolen cars: every car has Strip, Sell and Resell (no gamble) and the papers it can be fitted with', async () => {
    const stolen = [
      { plate: 'AB 123', model: 'etk800', strip: 4500, sell: 4000, resell: null, fit: [{ name: 'fake_plate', label: 'Fake plate' }], fitted: ['VIN plate'], age: 30, trend: 1 },
      { plate: 'CD 456', model: 'pickup', strip: 3000, sell: 2600, resell: 5000, fit: {}, fitted: {} },
    ]
    const w = await open({ enabled: true, state: member({ stolen }) })
    const text = w.text()
    expect(text).toContain('etk800 AB 123')
    expect(text).toContain('pickup CD 456')
    expect(text).not.toMatch(/gambl/i)
    expect(text).toContain('Fitted: VIN plate')
    const buttons = () => w.findAll('button')
    expect(buttons().filter(b => b.text().startsWith('Strip $')).length).toBe(2)
    expect(buttons().find(b => b.text() === 'Resell (needs 3 papers)').attributes('disabled')).toBeDefined()
    expect(buttons().find(b => b.text() === 'Resell $5,000').attributes('disabled')).toBeUndefined()
    await buttons().find(b => b.text() === 'Sell $4,000').trigger('click'); await flushPromises()
    let call = parseCall(luaCode[luaCode.length - 1])
    expect(call.fn).toBe('uiAct')
    expect(call.args.slice(0, 3)).toEqual(['stolenDo', 'AB 123', 'sell'])
    await buttons().find(b => b.text() === 'Fit Fake plate').trigger('click'); await flushPromises()
    call = parseCall(luaCode[luaCode.length - 1])
    expect(call.args.slice(0, 3)).toEqual(['stolenDo', 'AB 123', 'fit:fake_plate'])
    await buttons().find(b => b.text() === 'Resell $5,000').trigger('click'); await flushPromises()
    call = parseCall(luaCode[luaCode.length - 1])
    expect(call.args.slice(0, 3)).toEqual(['stolenDo', 'CD 456', 'resell'])
  })
  it('stops polling when closed', async () => {
    let n = 0
    fake.get = () => { n++; return { enabled: true, state: member() } }
    const w = mount(Comp)
    await flushPromises()
    const after = n
    w.unmount()
    await vi.advanceTimersByTimeAsync(5000)
    expect(n).toBe(after)
  })
})
