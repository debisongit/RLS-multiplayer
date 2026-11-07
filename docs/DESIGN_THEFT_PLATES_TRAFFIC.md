# Design: smart traffic, plate reading, car theft (decided with the owner)

Build order (owner's choice): **1. smart traffic, 2. plate reading and police records, 3. car theft**. Each gets tested in-game before the next.
Everything below is a decision, not a promise: nothing is built or played yet unless the changelog says so.

## 1. Smart traffic
- Built-in AI settings only (no custom steering yet). Ordinary traffic keeps its lane (right side on US maps); RLS already sets `ai.driveInLane('on')`.
  Real overtaking on the left is a possible later step.
- Mix (all configurable): normal 80, slow 10, aggressive 6, racer 3, drunk 1 (percent). Chosen once per traffic car.
- Drunk: weaves (lane keeping toggled off/on), uneven speed, sudden braking. Racers: very high aggression, speed pushed.
- No hints for players (no horn, lights or markers). You spot bad drivers by how they drive.
- Police react: a cop that sees a racer or drunk driver starts a chase (rate limited). Config `smartTraffic.policeReact`.

## 2. Plate reading and police records
- A cop can read your plate when within about **15 m**, under about **50 km/h**, over **3 to 6 seconds**, letter by letter. The player sees a "reading plate..." progress. Leaving range resets it.
- Reading also happens at random while a cop is near and you drive normally after an escape.
- The record belongs to the **plate**, shared by all cops on the server. Flag lasts about **2 real hours**; changing the plate clears the plate flag at once.
- Cops also remember **car model and color** after a recent chase for about **20 minutes**; repainting clears it.
- A flagged plate (or remembered model and color) means an **instant chase**; a cop may skip it about 1 time in 5.
- A chase you escaped flags the plate; being caught or reported stolen flags it too.

## 3. Car theft
- The server picks a few parked cars per area each session (same for every player). They spawn non-simplified (real physics) so they can be driven.
- Steps: short timed actions (hold a key, progress bar, noise). Harder for newer or more valuable cars:
  easy = break the window and start it with a screwdriver, harder = clone the key signal with a cloning device, hardest = other ways (to be defined).
- Witness check on theft (nearby cars, other players, open area). Reported 30 to 120 s later if seen, about 10 minutes later if not.
  Cops chase if they catch you in a reported car.
- At your garage: **strip for parts** (safe, parts go to part inventory, fraction of the car's value),
  **resell with swapped papers** (must change plate + VIN + a part number such as engine or ECU, pays more),
  or **gamble** (swap only some, sell for more, risk getting caught on the sale).
- Caught in a reported stolen car: chase and fine, the car is taken back (removed from your garage if you got it home).
- **Methods by car age and tier (from real-world patterns, game version only; research: older cars without immobilizers are the classic target, newer keyless cars are hit with electronic attacks):**
  - Old, no immobilizer (about before the mid 1990s): smash the window, then start it with a screwdriver on the ignition. Cheap, fast, loud (breaking glass).
  - Immobilizer era (about mid 1990s to 2010): the car will not run without the right key signal. Needs a key programmer plugged in at the diagnostic port plus a blank key. Quiet, slow, must sit inside.
  - Keyless / smart key (about 2010 on): relay box (needs the owner's key to be near the car, fails otherwise) or a signal cloner that captures the fob signal, or injecting commands through a car connector (pop a headlight/mirror connector, timer, then a programmed blank key). Each method has a failure chance and noise.
  - Luxury and newest: may need two steps (injection plus programmed key), has an alarm and a GPS tracker (reported faster, police can ping it until you find and block it).
  - No tow trucks or flatbeds (too expensive, owner said no).
- **Black market** (custom, RLS has none): sells and buys what theft needs. See the open questions in the handoff; stock, prices and access rules are being decided.
- Items needed (screwdriver, cloning device, fake plate, VIN plate, part numbers) have to be added by us; RLS may have no item system (research pending).
