# Worlds

A world is a JSON document (`pw/world/document.h`): terrain spec, water (ocean, lakes, rivers), vegetation, objects
(props / breakables), environment (sun, wind, fog) and a spawn. WORLD → **New** builds one from a preset.

## Saving and picking worlds

- **Save** (Ctrl+S) asks for a name the first time and warns before replacing another saved world of that name.
  Saved worlds live in the library (`<data dir>/worlds`). **Save As…** saves a copy under a new name, or to another
  folder.
- **Open…** (Ctrl+O) shows the saved worlds, newest first: open one, move one to the Trash, or open a file elsewhere.
- Opening or starting a world, picking a saved world in FLY, and quitting all ask first when the open world has
  unsaved edits.
- **FLY › World** picks flat ground, the open world or any saved world. **EVOLVE › Training worlds** picks one or
  several worlds to train in ([EVOLUTION.md §8](EVOLUTION.md#8-experiment-aero-and-worlds)).
- Code: `WorldModel` (library, save by name, delete to Trash), `WorldFlow.qml` (the shared actions) and
  `WorldDialogs.qml` (their dialogs).

## New-world presets

| Preset | What it builds |
|---|---|
| Flat | Flat ground at 0 m |
| Rolling hills / Islands / Mountains | Procedural terrain (GPU erosion), random seed, trees; Islands adds an ocean |
| **Manhattan (Midtown)** | Midtown Manhattan on flat ground, generated from rules (`src/core/src/world/presets.cpp`) |

Also in the command palette: *WORLD: new Manhattan (Midtown) world*.

### Manhattan (Midtown)

Deterministic and procedural (no map data or downloads). About 37 000 instanced primitives and 5 500 trees.

- **Grid:** the real street grid, rotated 29° like the real one, 30th to 96th St between the Hudson and the East
  River. Avenues at their real spacing (≈280 m on the West Side, 130 to 200 m on the East Side; Park Ave is wider,
  with a planted median). Streets are 80 m apart; 34th, 42nd, 57th, 59th, 72nd, 79th, 86th and 96th are wider.
  Broadway runs on its diagonal and opens out at Herald Square and Times Square. Streets are asphalt with double
  yellow centre lines, and sidewalks are raised curbs.
- **Lots:** every block is split into lots. Through-lots face the avenues; the middle of the block splits into north
  and south rows of 10 to 38 m lots. Heights follow districts: the Midtown core, the Grand Central / Park Ave
  corridor, Sixth Ave, Billionaires' Row, Hudson Yards, Murray Hill, the Garment District, low-rise Hell's Kitchen,
  and brownstones on the Upper East / West Side midblocks with taller avenue and park frontages.
- **Building types:** brownstones and tenements (cornices, water towers), pre-war masonry with setbacks, glass
  towers (podium, shaft, optional setback, mechanical crown, antenna), and pre-war "wedding cakes" (four tiers, a
  crown, a spire or mast). Facades use the `windows` and `glass` shader patterns.
- **Landmarks:** Empire State (setbacks and mast), Chrysler (stainless tiered crown and spire), One Vanderbilt,
  Grand Central and the MetLife Building, 30 Rock and Rockefeller Plaza, 432 Park, Central Park Tower, One57,
  111 W 57th, 220 CPS, 53W53, Bank of America Tower, Bryant Park and the Library, St Patrick's, the Plaza Hotel,
  the GM Building, Madison Square Garden, Macy's, Hudson Yards and the Vessel, the UN, the Time Warner Center and
  Columbus Circle, and lit billboards around Times Square.
- **Parks and water:** Central Park runs from 59th to 96th St with tree strokes, the Great Lawn, Sheep Meadow,
  transverse roads, and the Reservoir, the Lake and the Pond as water. The Hudson has piers (the Circle Line piers,
  the cruise terminal and Pier 86 with the Intrepid) and a tree-lined Hudson River Park. The East River flows around
  Roosevelt Island, and the Queensboro Bridge crosses it. Low-detail New Jersey (with the Palisades) and Long
  Island City fill the far shores.
- **Simplifications:** the park is cut at 96th St. Lake beds are carved with terrain edits
  (`TerrainSystem::carveLakeBeds`, 8 m deep), so the water has depth and the shoreline foam stays at the edges.
  Collision uses the building massing. Ground cover, cornices, rooftop details and billboards have
  `collide: false`. Spires and masts do collide.
- **Spawn:** the south end of the Great Lawn, facing up-town. *Air start* climbs out over the Reservoir. *Fly here*
  (`Ctrl+Shift+2`) starts anywhere else.

## Object params understood by the renderer

Objects are drawn as instanced primitives (`src/app/propbatches.h`), and rebuilt only when the object list changes.
All params are optional; objects without them still render as grey boxes, or brown boxes when breakable.

| Param | Values |
|---|---|
| `shape` | `box` (default), `cylinder`, `cone`: unit primitives scaled by the object's scale |
| `color` | `[r, g, b]` linear albedo |
| `pattern` | `windows`: punched windows, 3.6 m storeys, storefronts. `glass`: curtain wall with mullions. Both are drawn in world space by `scene.slang` |
| `roughness`, `metallic`, `emissive` | numbers (glow = albedo × emissive) |
| `collide` | `false`: FLY / EVOLVE obstacles skip the object |

## Review aids

- `PW_WORLD_VIEW="x,z,distance,pitch,yaw[,height]"` pins the WORLD orbit camera after every new scene. Use it for
  screenshots with `--command "WORLD: new Manhattan (Midtown) world" --screenshot …`.
- `PW_PERF_LOG=1` prints the WORLD and FLY viewports' frame rate and per-pass GPU times every 0.5 s.
- `PW_NOWATER` and `PW_NOVEG` hide water and vegetation in both viewports.
