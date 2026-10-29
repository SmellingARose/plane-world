# Controls

How a pilot (keyboard, slider, script or autopilot) flies a craft. Code: `src/core/pw/sim/controls.h`,
`multirotor.h`; FLY wiring in `AppController::stepControls`.

```
keys / sliders / scripts ──► AXES ──► CONTROLLER ──► OUTPUTS (servos, motors, jets, boosters)
```

- **Axis**: a named pilot command (`pitch`, `throttle`, ...) with an optional key pair. Keys spring back or ramp,
  as before. Scripts and sliders can set an axis directly (`ControlSystem::setAxis`).
- **Controller**: turns axis values into output values every physics step. One key can drive many outputs, and one
  output can take several axes.
- **Outputs**: what the physics sees (`CraftSim::setOutput`). The FLY sliders still set outputs directly; outputs a
  controller writes every step show as read-only.

## Controllers

| Controller | What it does | Axes |
|---|---|---|
| `direct` | Each output = Σ gain × axis (a mix table). Elevons, flaperons, twin throttles. | any |
| `rocket` | Attitude hold for a single gimballed liquid engine (`rocket` part): pitch/yaw command a tilt of the long axis up to 20° (released = hold vertical), throttle passes through (W/S ramp: it stays where you leave it). The gimbal-to-torque mapping is measured from the engine's gimbal pivot about the CoM and its mounting, so any layout works. The loop asks for an angular acceleration (ω_n = 1.2 rad/s, ζ = 0.9, small integral) and converts it to a gimbal command with the craft's inertia and the engine's current thrust, so a 2 t hopper and the 35 t New Shepard fly alike. | `throttle`, `pitch`, `yaw` |
| `multirotor` | Angle-mode flight controller for 3+ rotors: throttle commands a climb rate (released = altitude hold), pitch/roll command a tilt up to 35° (released = self-level), yaw commands a turn rate. Its mixer comes from each rotor's position about the CoM and its spin direction, in thrust units (throttle = thrust^1.5), with "air mode" so it keeps authority at low throttle. Motors stay idle on the ground until you throttle up. | `throttle`, `yaw`, `pitch`, `roll` |

## Behaviours (evolved controllers on keys)

A craft can carry behaviours (docs/CRAFTS.md › Behaviours), each on its own key. In FLY:

| Key | What it does |
|---|---|
| a behaviour's key (e.g. H) | Hands the outputs to that behaviour from where the craft is; press again to take control back. Another behaviour's key switches to it. |
| any flight key (axes / output keybinds) | Takes control back at once (axes restart from neutral). |
| O | The last behaviour flown on / off, unless a behaviour has O itself (older crafts' single autopilot is on O). |

Only one behaviour flies at a time; FLY › Behaviours lists them (click a row to engage or take over, ⋯ to rename,
clear the key or remove) and the HUD shows "Hover — press H to take over". A behaviour that learned from an air start
and is engaged on the ground starts in the air (it can't take off). EVOLVE's "Fly it with the evolved autopilot"
opens the new craft and starts its behaviour from the experiment's spawn. Behaviour keys can't be R, P, Space, C, E
or one of the craft's flight keys; if a flight key added later clashes, the flight key wins and the list says so.

## Craft JSON

Optional top-level block:

```json
"controls": {
  "controller": "direct",
  "axes": [
    { "name": "pitch", "keys": { "pos": "up", "neg": "down", "mode": "spring", "rate": 3 } },
    { "name": "roll",  "keys": { "pos": "right", "neg": "left", "mode": "spring", "rate": 3 } }
  ],
  "mix": [
    { "axis": "pitch", "output": "Elevon L", "gain": 1 }, { "axis": "roll", "output": "Elevon L", "gain": -1 },
    { "axis": "pitch", "output": "Elevon R", "gain": 1 }, { "axis": "roll", "output": "Elevon R", "gain": 1 }
  ]
}
```

`output` is an output's part id or name. A multirotor needs only `{ "controller": "multirotor" }`: it gets W/S
throttle, A/D yaw and arrow-key pitch/roll unless `axes` overrides them (the racer quad does this).

**No `controls` block** (all older crafts): each output with part keybinds (`"keys"` on the part, edited in
BUILD › Outputs) becomes its own axis, mixed 1:1. That is the original per-output behaviour.

## Adding a controller

1. Add a `ControllerKind` and its name in `controllerName`.
2. Parse it in `ControlScheme::fromDocument` (and default axes if it has fixed ones).
3. Drive the outputs in `ControlSystem::step`, and list them in `owned_` so FLY shows them read-only.
4. Add a physics self-test that flies it (see `physics.multirotor-fc`).
