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
| `multirotor` | Angle-mode flight controller for 3+ rotors: throttle commands a climb rate (released = altitude hold), pitch/roll command a tilt up to 35° (released = self-level), yaw commands a turn rate. Its mixer comes from each rotor's position about the CoM and its spin direction, in thrust units (throttle = thrust^1.5), with "air mode" so it keeps authority at low throttle. Motors stay idle on the ground until you throttle up. | `throttle`, `yaw`, `pitch`, `roll` |

The evolved autopilot (EVOLVE → "Fly it with the evolved autopilot") takes the outputs over while it is on; any
bound key hands control back.

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
