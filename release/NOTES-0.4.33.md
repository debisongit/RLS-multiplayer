- Traffic variety no longer misses the first traffic group: a real log showed RLS built it about 1 s before the server's settings arrived, so every car kept its model for the whole session. Now the built-in defaults are used until the server speaks. (Claude A)
- Live swapping of hidden traffic cars is **on by default** on new servers (`trafficVariety.swap.enabled` and `live`), so respawned cars change model. It stops itself after 3 failures. Existing servers: set both to `true` in `config.json` or in the traffic menu. Untested in-game.


Install: unzip, copy the Resources folder into your BeamMP server folder (see INSTALL.txt inside). Full history: CHANGELOG.md.
