- Black Market phone app: FOUND THE CAUSE of "No connection". The owner's screenshot of 0.4.31 showed the error `...[fn] is not a function`: the phone's `lua.rlsmp_market` is only an empty stub for an extension the RLS phone was never told about (RLS's own code says so and uses raw `engineLua` for that reason). The app now talks to the game with the raw `engineLua(code, callback)` call that RLS itself uses (the two `lua` proxy ways stay as fallbacks), says "Not loaded" if the game answers that the market extension is missing, escapes everything it sends into the Lua text, and still shows every error text when nothing works. (untested in game) (Claude B)


Install: unzip, copy the Resources folder into your BeamMP server folder (see INSTALL.txt inside). Full history: CHANGELOG.md.
