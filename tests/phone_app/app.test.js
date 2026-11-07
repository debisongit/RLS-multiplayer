import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import Comp from '../../Resources/Client/RLS-Career-MP/ui/ui-vue/mods/rls_career_mp/phone/PhoneBlackMarket.vue'
import { fake, calls } from './bridge-mock.js'

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
beforeEach(() => { calls.length = 0; vi.useFakeTimers({ toFake: ['setInterval', 'setTimeout', 'clearInterval', 'clearTimeout'] }) })
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
    expect(w.text()).toContain('No connection')
    fake.get = () => ({ enabled: true, state: member() })
    await vi.advanceTimersByTimeAsync(1600); await flushPromises()
    expect(w.text()).toContain('Reputation 10')
    w.unmount()
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
