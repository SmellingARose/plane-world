# Germ War 3D: live-moddable

Run the server, then open the game:

```bash
node germwar/server.js
```

Open http://localhost:8787 in your browser.

## How live updates work (no restarts)

- `core.js` is the engine: rendering, entities, input, UI and the live channel. Changing it needs a page reload.
- `mods/*.js` holds all the content: `world.js`, `buildings.js`, `enemies.js` and `waves.js`. The server watches this folder, and when a file is saved the running game re-evaluates it. Existing units switch to the new code and the game state stays as it was. New files dropped into `mods/` are picked up the same way.
- `POST /eval` runs JavaScript inside the open game and returns the result, which is how Claude reads the game and controls it while you play:

  ```bash
  curl -s localhost:8787/eval -d 'GW.money += 1000'
  curl -s localhost:8787/eval -d 'GW.spawnBase("mother")'
  curl -s localhost:8787/eval -d 'GW.ents.filter(e=>e.side==="them").length'
  ```

A mod that throws an error shows a red toast in the game and the game keeps running.

## Mod API (global `GW`)

| Call | Purpose |
|---|---|
| `GW.type(name, def)` | Register or replace a building, unit, enemy or base. `def` can include `side`, `cat`, `cost`, `hp`, `r`, `range`, `dmg`, `rate`, `speed`, `maxLvl`, `upg`, `build(e,g)`, `tick(e,dt)`, `onDeath(e)` |
| `GW.spawn(type, {x,z})` | Create an entity |
| `GW.spawnBase(type)` | Spawn an enemy base at a sensible distance from the HQ |
| `GW.damage(e, amt)` / `GW.kill(e)` | Combat |
| `GW.nearest` / `GW.within` / `GW.acquire` | Targeting queries |
| `GW.lob` / `GW.homing` | Projectiles |
| `GW.fx.*` | Effects: explode, tracer, lightning, particle, ring, shock, puff |
| `GW.director(dt)` | Wave logic |
| `GW.frameHooks.x = dt => …` | Per-frame visuals, which keep running while paused |
| `GW.restart()`, `GW.paused`, `GW.speed`, `GW.god`, `GW.money` | Game control |
