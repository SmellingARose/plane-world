#!/usr/bin/env python3
"""Generates examples/crafts/{heavy-hex,lopsided-penta}.json: two multirotors with very different geometry,
used to show one geometry-aware controller (ctx.craft) wiring itself to any craft. Re-run after editing."""
import json, math, os, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
quad = json.load(open(os.path.join(root, "data/crafts/racer-quad.json")))
SENSORS = [p for p in quad["parts"] if p["type"] == "sensor"]

def part(pid, typ, name, color, mass, pos, rot, p, motor=None):
    return {"id": pid, "type": typ, "name": name, "color": color, "mass": mass, "pos": [round(v, 4) for v in pos],
            "rot": rot, "p": p, "servo": None, "invert": False, "motor": motor}

def multirotor(name, body, rotors, sensor_y):
    parts = list(body)
    n = len(parts)
    for k, r in enumerate(rotors):
        th = math.radians(r["deg"])
        dx, dz = math.cos(th), -math.sin(th)
        R = r["r"]
        tag = r["tag"]
        parts.append(part(f"a{k}", "box", f"Arm {tag}", r.get("arm", "#2a2d33"), r["armMass"], (dx * R / 2, 0, dz * R / 2), [0, r["deg"], 0],
                          {"sx": R, "sy": 0.012, "sz": 0.025, "cd": 0.1}))
        parts.append(part(f"b{k}", "cylinder", f"Motor bell {tag}", "#5a6270", r["motorMass"], (dx * R, 0.02, dz * R), [0, 0, 0],
                          {"r": 0.022 * r["d"] / 0.2, "h": 0.03, "cd": 0.6}))
        parts.append(part(f"m{k}", "motor", f"Motor {tag}", "#5a6270", 0.001, (0.0, 0, 0), [0, 0, 90],
                          {"torque": 0.5, "vmax": 3000, "reversible": 0, "cd": 0, "size": 0.04}))
        spin = r["spin"]
        parts.append(part(f"p{k}", "prop", f"Prop {tag} ({'CW' if spin > 0 else 'CCW'})", r["color"], 0.012 * r["d"] / 0.2,
                          (dx * R, 0.045, dz * R), [0, 0, 90],
                          {"d": r["d"], "thrust": r["thrust"], "vmax": 60, "spin": spin, "chord": 0.02 * r["d"] / 0.2, "thick": 0.005},
                          motor=f"m{k}"))
    for s in SENSORS:
        s = json.loads(json.dumps(s))
        s["pos"] = [0, sensor_y, 0]
        parts.append(s)
    return {"name": name, "controls": {"controller": "multirotor"}, "parts": parts}

# --- Heavy-lift hexacopter: 6 x 13" props on 0.45 m arms, 2.9 kg, T/W ~3.4
hex_body = [
    part("h0", "cylinder", "Hub", "#1d2027", 0.55, (0, 0, 0), [0, 0, 0], {"r": 0.13, "h": 0.05, "cd": 0.3}),
    part("h1", "cylinder", "Hub cap", "#f2b134", 0.08, (0, 0.04, 0), [0, 0, 0], {"r": 0.09, "h": 0.03, "cd": 0.2}),
    part("h2", "box", "Battery (12S)", "#2f6fd6", 0.95, (0, -0.07, 0), [0, 0, 0], {"sx": 0.2, "sy": 0.07, "sz": 0.1, "cd": 0.3}),
    part("h3", "sphere", "Gimbal camera", "#111318", 0.2, (0.14, -0.1, 0), [0, 0, 0], {"r": 0.05, "cd": 0.2}),
    part("h4", "box", "Skid L", "#c9ccd2", 0.05, (0, -0.2, -0.16), [0, 0, 0], {"sx": 0.42, "sy": 0.02, "sz": 0.02, "cd": 0.2}),
    part("h5", "box", "Skid R", "#c9ccd2", 0.05, (0, -0.2, 0.16), [0, 0, 0], {"sx": 0.42, "sy": 0.02, "sz": 0.02, "cd": 0.2}),
    part("h6", "box", "Leg FL", "#c9ccd2", 0.02, (0.1, -0.13, -0.13), [25, 0, 0], {"sx": 0.02, "sy": 0.15, "sz": 0.02, "cd": 0.2}),
    part("h7", "box", "Leg FR", "#c9ccd2", 0.02, (0.1, -0.13, 0.13), [-25, 0, 0], {"sx": 0.02, "sy": 0.15, "sz": 0.02, "cd": 0.2}),
    part("h8", "box", "Leg RL", "#c9ccd2", 0.02, (-0.1, -0.13, -0.13), [25, 0, 0], {"sx": 0.02, "sy": 0.15, "sz": 0.02, "cd": 0.2}),
    part("h9", "box", "Leg RR", "#c9ccd2", 0.02, (-0.1, -0.13, 0.13), [-25, 0, 0], {"sx": 0.02, "sy": 0.15, "sz": 0.02, "cd": 0.2}),
]
hex_rotors = []
for k in range(6):
    hex_rotors.append({"tag": str(k + 1), "deg": 30 + 60 * k, "r": 0.45, "d": 0.33, "thrust": 16.5, "spin": 1 if k % 2 == 0 else -1,
                       "armMass": 0.06, "motorMass": 0.09, "color": "#ff6a1f" if k in (0, 5) else "#e8e9ec"})
heavy_hex = multirotor("Heavy hex", hex_body, hex_rotors, 0.07)

# --- Lopsided pentacopter: five mismatched rotors at irregular angles and radii, battery hung off to one side.
#     No symmetry at all: equal thrust would flip it, so the mixer has to come from the geometry.
penta_body = [
    part("q0", "box", "Plate", "#232830", 0.25, (0, 0, 0), [0, 17, 0], {"sx": 0.2, "sy": 0.02, "sz": 0.14, "cd": 0.3}),
    part("q1", "box", "Battery (off-centre)", "#2f6fd6", 0.45, (0.05, -0.04, 0.09), [0, 17, 0], {"sx": 0.13, "sy": 0.045, "sz": 0.06, "cd": 0.3}),
    part("q2", "cone", "Sensor mast", "#e23a2e", 0.04, (-0.06, 0.06, -0.04), [0, 0, 0], {"r": 0.02, "h": 0.08, "cd": 0.2}),
    part("q3", "box", "Skid", "#c9ccd2", 0.04, (0, -0.1, 0), [0, 17, 0], {"sx": 0.3, "sy": 0.02, "sz": 0.24, "cd": 0.2}),
]
penta_spec = [  # angle (deg from nose, towards left), arm length, prop diameter, spin, colour
    (5, 0.30, 0.20, 1, "#ff3b6b"), (85, 0.42, 0.28, -1, "#ffd23f"), (150, 0.24, 0.18, 1, "#3bd1ff"),
    (215, 0.38, 0.25, -1, "#7dff6a"), (292, 0.33, 0.23, 1, "#c08bff"),
]
penta_rotors = []
for k, (deg, r, d, spin, col) in enumerate(penta_spec):
    penta_rotors.append({"tag": "ABCDE"[k], "deg": deg, "r": r, "d": d, "thrust": round(9.0 * (d / 0.23) ** 2, 2), "spin": spin,
                         "armMass": 0.03 + 0.04 * r, "motorMass": 0.03 + 0.2 * d * d, "color": col, "arm": "#3a3f48"})
lopsided = multirotor("Lopsided penta", penta_body, penta_rotors, 0.03)

for fname, doc in (("heavy-hex.json", heavy_hex), ("lopsided-penta.json", lopsided)):
    out = os.path.join(root, "examples/crafts", fname)
    with open(out, "w") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    m = sum(p["mass"] for p in doc["parts"])
    t = sum(p["p"]["thrust"] for p in doc["parts"] if p["type"] == "prop")
    print(f"{fname}: {len(doc['parts'])} parts, {m:.2f} kg, {t:.0f} N static, T/W {t / (m * 9.81):.2f}")
