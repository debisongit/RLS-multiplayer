<!-- RLS-Career-MP · SPDX-License-Identifier: AGPL-3.0-only

     Phone app "Black Market". Only a screen: all rules, prices and money live on the server (server/market.lua).
     It polls the client extension rlsmp_market (lua/ge/extensions/rlsmp/market.lua) about every 1.5 s and sends taps to it.
     Nothing here imports from the RLS mod, so it keeps working when RLS moves its own files. -->
<template>
  <div class="bm">
    <header>
      <p v-if="member">Reputation {{ state.rep }} · Invites left {{ state.invitesLeft }} · {{ money(state.money) }}</p>
      <p v-else>Invite only</p>
    </header>

    <main bng-nav-scroll>
      <p v-if="message" class="note" role="status">{{ message }}</p>

      <section v-if="!problem && orderList.length" class="card">
        <h2>Your orders</h2>
        <article v-for="o in orderList" :key="o.id" class="row">
          <div>
            <strong>{{ o.label }}<span v-if="o.n > 1"> × {{ o.n }}</span></strong>
            <small>{{ o.ready ? 'Waiting at ' + o.spot : 'At ' + o.spot + ' in ' + Math.round(o.readyIn) + ' s' }}</small>
          </div>
          <span class="tag" :class="{ ready: o.ready }">{{ o.ready ? 'Ready' : 'On the way' }}</span>
        </article>
        <button type="button" class="primary" bng-nav-item :disabled="busy || !anyReady" @click="act('pickup')">Collect here</button>
        <small class="hint">Packages are collected by themselves when you stop inside the marked circle at the drop spot (not while the police chase you). This button is only a backup.</small>
      </section>

      <section v-if="!problem && ownedList.length" class="card">
        <h2>Your items</h2>
        <article v-for="it in ownedList" :key="it.name" class="row">
          <strong>{{ it.label }}</strong>
          <span class="tag">{{ it.count > 1 ? '× ' + it.count : 'owned' }}</span>
        </article>
      </section>

      <section v-if="problem" class="card center">
        <h2>{{ problem.title }}</h2>
        <p>{{ problem.text }}</p>
        <p v-if="problem.detail" class="hint">{{ problem.detail }}</p>
      </section>

      <template v-else-if="state && !member">
        <section class="card">
          <h2>You are not in</h2>
          <p>A member has to invite you. When they do, an invite shows up here and you can accept it.</p>
        </section>
        <section v-if="state.invite" class="card">
          <h2>{{ state.invite.from }} invited you</h2>
          <p>Accept within {{ Math.max(0, Math.round(state.invite.seconds)) }} s.</p>
          <button type="button" class="primary" bng-nav-item :disabled="busy" @click="act('accept')">Accept</button>
        </section>
      </template>

      <template v-else-if="member">
        <section class="card">
          <h2>For sale</h2>
          <p v-if="state.spot" class="hint">Packages arrive at today's drop spot: {{ state.spot }}</p>
          <article v-for="it in available" :key="it.name" class="row">
            <div>
              <strong>{{ it.label }}</strong>
              <small>{{ money(it.price) }}{{ it.durable ? ' · a tool, kept forever' : ' each' }}<template v-if="it.have > 0"> · you have {{ it.have }}</template></small>
            </div>
            <div class="buy">
              <template v-if="!it.durable">
                <button type="button" class="step" bng-nav-item :disabled="count(it) <= 1" aria-label="Fewer" @click="setCount(it, count(it) - 1)">−</button>
                <span class="qty">{{ count(it) }}</span>
                <button type="button" class="step" bng-nav-item :disabled="count(it) >= 10" aria-label="More" @click="setCount(it, count(it) + 1)">+</button>
              </template>
              <button type="button" class="primary" bng-nav-item :disabled="busy || !canBuy(it)" @click="act('buy', it.name, it.durable ? 1 : count(it))">
                {{ buyLabel(it) }}
              </button>
            </div>
          </article>
          <p v-if="!available.length" class="hint">Nothing for you yet.</p>
          <template v-if="locked.length">
            <h3>Unlocks with reputation</h3>
            <article v-for="it in locked" :key="it.name" class="row dim">
              <div><strong>{{ it.label }}</strong><small>Needs reputation {{ it.minRep }}</small></div>
            </article>
          </template>
        </section>

        <section class="card">
          <h2>Invite someone</h2>
          <p class="hint">Type the exact name of a player who is online. You have {{ state.invitesLeft }} invite{{ state.invitesLeft === 1 ? '' : 's' }} left; more come with reputation.</p>
          <div class="invite">
            <input v-model="who" type="text" maxlength="40" placeholder="Player name" @keydown.enter="invite" />
            <button type="button" class="primary" bng-nav-item :disabled="busy || !who.trim() || state.invitesLeft < 1" @click="invite">Invite</button>
          </div>
        </section>

        <section v-if="state.scout" class="card">
          <h2>Scout tip</h2>
          <p>A scout marks {{ state.scout.minCount }} to {{ state.scout.maxCount }} easy parked cars within about {{ Math.round(state.scout.radius) }} m of you for about {{ state.scout.minutes }} minutes. Small dots float over them. Too many tips in an hour cost reputation.</p>
          <button type="button" class="primary" bng-nav-item :disabled="busy || state.scout.locked || state.scout.wait > 0 || state.money < state.scout.price" @click="act('scout')">
            {{ scoutLabel }}
          </button>
        </section>

        <section class="card">
          <h2>Stolen cars</h2>
          <p v-if="!stolenList.length">You have no stolen car right now.</p>
          <template v-else>
            <article v-for="c in stolenList" :key="c.plate" class="row">
              <div>
                <strong>{{ c.model }} {{ c.plate }}</strong>
                <small>Strip {{ money(c.strip) }} · Sell {{ money(c.sell) }} · Resell {{ c.resell ? money(c.resell) : 'needs 3 papers' }} · Gamble {{ c.gamble ? money(c.gamble) : 'needs a paper' }}</small>
              </div>
            </article>
            <p class="hint">Drive to {{ state.spot || 'the drop spot' }}, get out and stand next to the car, then pick how to sell it. The garage computer offers the same without the drive. Gambling can end in a police trap.</p>
            <div class="fence">
              <button v-for="m in FENCE_MODES" :key="m.mode" type="button" class="primary" bng-nav-item :disabled="busy" @click="act('fence', m.mode)">{{ m.label }}</button>
            </div>
            <template v-if="state.meetup">
              <p class="hint">A buyer waits at {{ state.meetup.spot }}.</p>
              <button type="button" bng-nav-item :disabled="busy" @click="act('meetupCancel')">Drop the meetup</button>
            </template>
            <button v-else type="button" bng-nav-item :disabled="busy" @click="act('meetup')">Sell by meetup (sit in the car or stand next to it)</button>
          </template>
        </section>
      </template>

      <section v-else class="card center"><p>Connecting…</p></section>
    </main>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { lua, useBridge } from '@/bridge'

const POLL_MS = 1500
const MESSAGE_MS = 9000

const view = ref(null)         // what rlsmp_market.uiGet() returned last
const failed = ref(false)
const detail = ref('')        // the text of the last error, shown under "No connection" so a screenshot tells what went wrong
const busy = ref(false)
const message = ref('')
const who = ref('')
const counts = ref({})         // item name -> how many to buy (consumables)

let alive = true
let pollTimer = null
let messageTimer = null
let seenSeq = null             // null until the first poll: an old result from an earlier visit is not shown again

const state = computed(() => (view.value && view.value.state) || null)
const member = computed(() => !!(state.value && state.value.ready && state.value.member))
const problem = computed(() => {
  if (failed.value && !state.value) return { title: 'No connection', text: 'The phone could not reach the game. Try again in a moment.', detail: detail.value }
  if (view.value && view.value.missing) return { title: 'Not loaded', text: 'The game has not loaded the Black Market extension (rlsmp_market). Update the mod and restart the game.' }
  if (view.value && view.value.enabled === false) return { title: 'Not available', text: 'The black market only works while you are on a server running RLS-Career-MP.' }
  if (state.value && state.value.ready === false) return { title: 'Wait a moment', text: 'Your career is still loading.' }
  return null
})
// Lists can arrive as {} when empty (the game's Lua tables), so only real arrays count.
const asList = v => (Array.isArray(v) ? v : [])
const items = computed(() => asList(state.value && state.value.items))
const orderList = computed(() => asList(state.value && state.value.orders))
const ownedList = computed(() => asList(state.value && state.value.owned))
const stolenList = computed(() => asList(state.value && state.value.stolen))
const FENCE_MODES = [{ mode: 'strip', label: 'Strip' }, { mode: 'sell', label: 'Sell' }, { mode: 'resell', label: 'Resell' }, { mode: 'gamble', label: 'Gamble' }]
const available = computed(() => items.value.filter(it => !it.locked))
const locked = computed(() => items.value.filter(it => it.locked))
const scoutLabel = computed(() => {
  const sc = state.value && state.value.scout
  if (!sc) return ''
  if (sc.locked) return 'Needs reputation ' + sc.minRep
  if (sc.wait > 0) return 'Wait ' + Math.ceil(sc.wait) + ' s'
  if ((Number(state.value.money) || 0) < sc.price) return 'Too expensive'
  return 'Buy scout tip ' + money(sc.price)
})
const anyReady = computed(() => orderList.value.some(o => o.ready))

function money(n) {
  const v = Math.floor(Number(n) || 0)
  return '$' + v.toLocaleString('en-US')
}
function count(it) { return counts.value[it.name] || 1 }
function setCount(it, n) { counts.value = { ...counts.value, [it.name]: Math.max(1, Math.min(10, n)) } }
function canBuy(it) {
  if (it.locked) return false
  if (it.durable && (it.have > 0 || it.onOrder)) return false
  const total = it.price * (it.durable ? 1 : count(it))
  return (Number(state.value && state.value.money) || 0) >= total
}
function buyLabel(it) {
  if (it.durable && it.have > 0) return 'Owned'
  if (it.durable && it.onOrder) return 'On order'
  if (!canBuy(it) && !it.locked) return 'Too expensive'
  return 'Buy ' + money(it.price * (it.durable ? 1 : count(it)))
}

function show(text) {
  if (!text) return
  message.value = text
  clearTimeout(messageTimer)
  messageTimer = setTimeout(() => { message.value = '' }, MESSAGE_MS)
}

// How the screen talks to the game. First game test: `lua.rlsmp_market.uiGet` was "not a function": the `lua` proxy only knows the extensions it was
// told about (RLS's own file installLuaBridgeFallbacks.js says stub namespaces exist before Lua loads an extension, and PhoneFacilityWork.vue says
// "use raw engineLua to ensure it works even if proxy is stale"). So the first way is raw `api.engineLua(code, callback)`, exactly as RLS does it;
// the two proxy ways stay as fallbacks.
const bridge = useBridge()
const GAME_TIMEOUT_MS = 4000

// A Lua string literal: plain letters, digits and a few signs as they are, every other byte as a \ddd escape (valid in Lua 5.1 / LuaJIT).
function luaString(value) {
  const bytes = new TextEncoder().encode(String(value))
  let out = '"'
  for (const b of bytes) {
    const plain = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b === 32 || b === 95 || b === 45 || b === 46
    out += plain ? String.fromCharCode(b) : '\\' + String(b).padStart(3, '0')
  }
  return out + '"'
}
function luaValue(v) {
  if (v === undefined || v === null) return 'nil'
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : 'nil'
  if (typeof v === 'boolean') return v ? 'true' : 'false'
  return luaString(v)
}

function rawCall(fn, args) {
  return new Promise((resolve, reject) => {
    const api = bridge && bridge.api
    if (!api || typeof api.engineLua !== 'function') return reject(new Error('the bridge has no engineLua'))
    const timer = setTimeout(() => reject(new Error('the game did not answer')), GAME_TIMEOUT_MS)
    // rawget: indexing a missing global is a fatal engine error; a missing extension or function answers {missing = true} instead
    const code = '(function() local m = rawget(_G, "rlsmp_market") if type(m) ~= "table" then return {missing = true} end '
      + 'local f = m[' + luaString(fn) + '] if type(f) ~= "function" then return {missing = true} end return f(' + args.map(luaValue).join(', ') + ') end)()'
    try {
      api.engineLua(code, result => { clearTimeout(timer); resolve(result) })
    } catch (e) {
      clearTimeout(timer)
      reject(e)
    }
  })
}

const PROXY_ROUTES = [() => lua.rlsmp_market, () => lua.extensions.rlsmp_market]
async function callGame(fn, ...args) {
  const errors = []
  try {
    return await rawCall(fn, args)
  } catch (e) {
    errors.push(String((e && e.message) || e))
  }
  for (const route of PROXY_ROUTES) {
    try {
      return await route()[fn](...args)
    } catch (e) {
      errors.push(String((e && e.message) || e))
    }
  }
  throw new Error(errors.join(' | '))
}

async function poll() {
  try {
    const v = await callGame('uiGet')
    if (!alive) return
    view.value = v || { enabled: false }
    failed.value = false
    const seq = v && v.result ? v.result.seq : 0
    if (seenSeq === null) seenSeq = seq
    else if (seq !== seenSeq) { seenSeq = seq; show(v.result.text) }
  } catch (e) {
    detail.value = String((e && (e.message || e)) || 'unknown error').slice(0, 200)
    console.warn('[RLSMP] Black Market could not reach the game:', e)
    if (alive) failed.value = true
  }
}

async function act(action, a, b) {
  if (busy.value) return
  busy.value = true
  try {
    await callGame('uiAct', action, a, b)
  } catch (e) {
    show('Could not reach the game. Try again.')
  } finally {
    busy.value = false
    setTimeout(poll, 700)      // the server's answer is on its way
  }
}

function invite() {
  const name = who.value.trim()
  if (!name || busy.value) return
  who.value = ''
  act('invite', name)
}

onMounted(() => {
  poll()
  pollTimer = setInterval(poll, POLL_MS)
})
onBeforeUnmount(() => {
  alive = false
  clearInterval(pollTimer)
  clearTimeout(messageTimer)
})
</script>

<style scoped>
.bm { height: 100%; display: flex; flex-direction: column; background: #0c0d12; color: #f1f5f9; }
header { padding: calc(var(--phone-status-bar-height, 40px) + var(--phone-status-bar-content-gap, 8px)) 18px 12px; background: linear-gradient(135deg, #2a1a0c, #15100a); }
header p { margin: 0; font-size: 12px; line-height: 1.5; color: #fdba74; }
main { flex: 1; min-height: 0; overflow-y: auto; padding: 14px; }
.card { padding: 13px; margin-bottom: 10px; background: #15161d; border: 1px solid #2c2e3a; border-radius: 13px; }
.card.center { text-align: center; }
h2 { margin: 0 0 6px; font-size: 14px; }
h3 { margin: 14px 0 6px; font-size: 11px; text-transform: uppercase; letter-spacing: 1.4px; color: #fdba74; }
p { margin: 0 0 8px; font-size: 12px; line-height: 1.5; color: #cbd5e1; }
.hint, small.hint { display: block; font-size: 11px; color: #94a3b8; margin: 6px 0 0; }
.note { padding: 10px 12px; margin: 0 0 10px; border-radius: 10px; background: #1f2a1c; border: 1px solid #3f6b34; color: #d9f99d; }
.row { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 9px 0; border-top: 1px solid #23252f; }
.row:first-of-type { border-top: 0; }
.row.dim { opacity: .55; }
.row strong { display: block; font-size: 13px; }
.row small { display: block; font-size: 11px; color: #94a3b8; margin-top: 2px; }
.buy { display: flex; align-items: center; gap: 6px; flex-shrink: 0; }
.qty { min-width: 18px; text-align: center; font-size: 12px; }
.tag { font-size: 10px; padding: 3px 8px; border-radius: 999px; background: #2c2e3a; color: #cbd5e1; white-space: nowrap; }
.tag.ready { background: #14532d; color: #bbf7d0; }
.invite { display: flex; gap: 8px; }
.fence { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 8px; }
.card > button { margin-top: 6px; }
input { flex: 1; min-width: 0; padding: 8px 10px; border-radius: 8px; border: 1px solid #3b3e4e; background: #0f1016; color: #f1f5f9; font: inherit; font-size: 12px; }
button { min-height: 34px; padding: 7px 11px; border-radius: 9px; border: 1px solid #3b3e4e; background: #23252f; color: #f1f5f9; font: inherit; font-size: 11px; font-weight: 700; cursor: pointer; }
button.primary { background: #f97316; border-color: #f97316; color: #1a0e02; }
button.step { min-width: 30px; padding: 4px 8px; }
button:disabled { opacity: .4; cursor: default; }
.card > button.primary { margin-top: 8px; }
</style>
