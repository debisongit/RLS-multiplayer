- Black Market phone app: first game test showed the app opens but said "No connection". The app now tries both ways RLS reaches the game (`lua.rlsmp_market` and `lua.extensions.rlsmp_market`), asks the game to load the market extension if it is missing, and shows the real error text under "No connection" so a screenshot tells what failed. The game log gets one line `RLSMP-MARKET the phone app reached the market extension` the first time the app calls in. Whether this fixes it is not known yet. (untested in game) (Claude B)


Install: unzip, copy the Resources folder into your BeamMP server folder (see INSTALL.txt inside). Full history: CHANGELOG.md.
