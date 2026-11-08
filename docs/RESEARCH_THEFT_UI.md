# Research: stealing without chat commands (read from RLS source, nothing played)

Owner rule: nothing about stealing may need typing. RLS paths are relative to `lua/ge/extensions/overhaul/`. "Verified" = I read the code. "Unverified" = needs a game test.

## What RLS uses for on-foot interactions (verified)
- Entering a car on foot (`avatar/walkEnterVehicle.lua`, `walkEnterVehicle/approach.lua`) has no prompt of its own. It uses the vanilla walking-mode toggle action, then shows `guihooks.trigger("Message", {category = "walkingmode", msg = "Entering vehicle..."})` while it walks. There is no "press F" widget to reuse.
- Interactions at places (garage, gas station, dealership) use the **activity prompt**: `ui_missionInfo.openActivityAcceptDialogue(list)` with entries `{icon, heading, preheadings, buttonLabel, buttonFun}`, collected through the hook `onActivityAcceptGatherData` (`world/facilities.lua:826`, `world/fuel/gasStations.lua:188`, `integration/services/markerInteraction/markerPrompt.lua`). Overhaul patches it to its own prompt (`shell/patches.lua:380`). It is opened and closed by `markerPrompt` from map markers, and it locks competing vehicle input while open.
- The key name of an action is read from `core_input_bindings.bindings[].contents.bindings[]` (`action`, `control`), as `career/guide/guide.lua:488` does for the phone key.
- The vanilla `showConfirmationDialog` guihook (used by `rlsmp/garage.lua`) is a plain small dialog with buttons and a `luaCallback` string each.

## What each step uses
| Step | Mechanism | Status |
|---|---|---|
| Hint near a parked car | `toastrMsg` toast, text "Press [key]", key name read like `guide.lua` (fallback "Y") | toast: same as before; key lookup unverified |
| Open the choices | **Input action `rlsmpInteract`** in our `core/input/actions/rlsmp.json` (category `rlsmp`, same file as the `[` menu), default key Y in `settings/inputmaps/keyboard_rlsmp.json` -> `rlsmp_theft.interact()` | unverified: Y may already be bound in some setups (the player can rebind in Controls, category RLS Multiplayer); no gamepad default |
| The popup | `guihooks.trigger("showConfirmationDialog", ...)`: Inspect, one button per steal method with tools, Cancel (same shape as `rlsmp/garage.lua`) | unverified: that it shows while on foot, closes after a click, and fits the longer labels |
| Inspect / steal action | unchanged: timed action, progress toasts, walking away cancels | as before |
| Fence at the garage | RLS garage computer buttons (`onOverhaulComputerAddFunctions`) + the same dialog: Strip, Sell, Resell, Gamble for the stolen car near the player | unverified (see `RESEARCH_GARAGE_STRIP.md`) |
| Fence at the drop spot, orders, items, invites, scout | Black Market phone app (`PhoneBlackMarket.vue`, raw `engineLua` into `rlsmp_market.uiAct`) | unverified in game; view test needs `npm install` |
| Collect a package | automatic when the player is inside the 15 m drop circle; popup via `showConfirmationDialog` with an OK button | unverified |
| Meetup sale | Marketplace app hook (`sellVehicle` wrapper) for garage cars; Black Market app button for a stolen car | hook unverified, see `RESEARCH_MEETUP_SALE.md` |

## Why not the RLS activity prompt
`ui_missionInfo.openActivityAcceptDialogue` is the closest thing to "what RLS shows for a walking avatar", but `markerPrompt` owns its open state: it closes and re-fills it on its own update from map markers, and a parked car is not a marker. A prompt we open could be closed by RLS in the next frame, or lock vehicle input while open. A key plus a small dialog needs none of that. If the owner prefers the RLS look, the next step is registering `onActivityAcceptGatherData` and testing whether `markerPrompt` leaves a prompt alone that it did not open.

## Unverified list
1. Key Y free, and `core_input_bindings` structure as read from `guide.lua` (we fall back to "Y" in the text).
2. `showConfirmationDialog` while walking (no vehicle), button `enabled=false` rendering, closing after a click.
3. The input action runs with `ctx = "tlua"` the same way the `[` menu does (copied from it).
4. Phone app `fence`/`meetup` buttons and the automatic pickup popup.
5. The server's `rlsmpTheftCan.methods` list is only sent after the client asks near a stealable car (radius 3 m); the popup shows steal buttons only for that car.

## Chat commands
Kept as hidden developer fallbacks (`/steal /inspect /fence /market /meetup /items`), switched off by default with config `ui.chatCommands = false`. No text names them; `tests/no_chat_hints_test.lua` checks that.
