// GENERATED from reference/flightsim.html presetPlane/presetJet/presetRover/presetRocket (ids made deterministic p1..pN).
// Regenerate rather than hand-edit. OWNED BY import builder.
import PWCore

public enum CraftPresetData {
    static let trainer = #"""
{
 "name": "Trainer",
 "parts": [
  {
   "id": "p1",
   "type": "servo",
   "name": "Ailerons",
   "color": "#ffb020",
   "mass": 0.5,
   "pos": [
    0.4,
    0.6,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "axis": "z",
    "range": 20,
    "torque": 400,
    "speed": 120
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "d",
    "neg": "a",
    "mode": "spring",
    "rate": 3
   }
  },
  {
   "id": "p2",
   "type": "servo",
   "name": "Elevator",
   "color": "#ffb020",
   "mass": 0.5,
   "pos": [
    -3.6,
    0.2,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "axis": "z",
    "range": 20,
    "torque": 400,
    "speed": 120
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "s",
    "neg": "w",
    "mode": "spring",
    "rate": 3
   }
  },
  {
   "id": "p3",
   "type": "servo",
   "name": "Rudder",
   "color": "#ffb020",
   "mass": 0.5,
   "pos": [
    -3.6,
    0.9,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "axis": "y",
    "range": 25,
    "torque": 400,
    "speed": 120
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "e",
    "neg": "q",
    "mode": "spring",
    "rate": 3
   }
  },
  {
   "id": "p4",
   "type": "motor",
   "name": "Engine",
   "color": "#5a6270",
   "mass": 120,
   "pos": [
    3.2,
    0,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "torque": 300,
    "vmax": 20,
    "reversible": 0
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "up",
    "neg": "down",
    "mode": "ramp",
    "rate": 0.8
   }
  },
  {
   "id": "p5",
   "type": "box",
   "name": "Fuselage",
   "color": "#d8dce2",
   "mass": 330,
   "pos": [
    0,
    0,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "sx": 6,
    "sy": 1.1,
    "sz": 1.1,
    "cd": 0.12
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p6",
   "type": "cone",
   "name": "Spinner",
   "color": "#d8dce2",
   "mass": 2,
   "pos": [
    3.55,
    0,
    0
   ],
   "rot": [
    0,
    0,
    -90
   ],
   "p": {
    "r": 0.3,
    "h": 0.4,
    "cd": 0.1
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p7",
   "type": "prop",
   "name": "Propeller",
   "color": "#333",
   "mass": 8,
   "pos": [
    3.7,
    0,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "d": 1.9,
    "thrust": 2800,
    "vmax": 75
   },
   "servo": null,
   "invert": false,
   "motor": "p4"
  },
  {
   "id": "p8",
   "type": "wing",
   "name": "Wing L",
   "color": "#e8eaee",
   "mass": 45,
   "pos": [
    0.4,
    0.6,
    -2.6
   ],
   "rot": [
    0,
    0,
    2
   ],
   "p": {
    "span": 4.2,
    "chord": 1.5,
    "thick": 0.1,
    "camber": 0.25,
    "ar": 7
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p9",
   "type": "wing",
   "name": "Wing R",
   "color": "#e8eaee",
   "mass": 45,
   "pos": [
    0.4,
    0.6,
    2.6
   ],
   "rot": [
    0,
    0,
    2
   ],
   "p": {
    "span": 4.2,
    "chord": 1.5,
    "thick": 0.1,
    "camber": 0.25,
    "ar": 7
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p10",
   "type": "wing",
   "name": "Aileron L",
   "color": "#c0302a",
   "mass": 6,
   "pos": [
    0.4,
    0.6,
    -5.45
   ],
   "rot": [
    0,
    0,
    2
   ],
   "p": {
    "span": 1.5,
    "chord": 1.3,
    "thick": 0.1,
    "camber": 0.25,
    "ar": 7
   },
   "servo": "p1",
   "invert": false,
   "motor": null
  },
  {
   "id": "p11",
   "type": "wing",
   "name": "Aileron R",
   "color": "#c0302a",
   "mass": 6,
   "pos": [
    0.4,
    0.6,
    5.45
   ],
   "rot": [
    0,
    0,
    2
   ],
   "p": {
    "span": 1.5,
    "chord": 1.3,
    "thick": 0.1,
    "camber": 0.25,
    "ar": 7
   },
   "servo": "p1",
   "invert": true,
   "motor": null
  },
  {
   "id": "p12",
   "type": "wing",
   "name": "Stabilator",
   "color": "#c0302a",
   "mass": 15,
   "pos": [
    -3.6,
    0.2,
    0
   ],
   "rot": [
    0,
    0,
    -1.5
   ],
   "p": {
    "span": 3.4,
    "chord": 1,
    "thick": 0.1,
    "camber": 0,
    "ar": 4
   },
   "servo": "p2",
   "invert": true,
   "motor": null
  },
  {
   "id": "p13",
   "type": "wing",
   "name": "Fin",
   "color": "#c0302a",
   "mass": 10,
   "pos": [
    -3.6,
    0.95,
    0
   ],
   "rot": [
    90,
    0,
    0
   ],
   "p": {
    "span": 1.5,
    "chord": 1.1,
    "thick": 0.1,
    "camber": 0,
    "ar": 2
   },
   "servo": "p3",
   "invert": false,
   "motor": null
  },
  {
   "id": "p14",
   "type": "wheel",
   "name": "Nose wheel",
   "color": "#222428",
   "mass": 8,
   "pos": [
    2.2,
    -1,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.25,
    "width": 0.15,
    "grip": 0.9,
    "roll": 0.02
   },
   "servo": "p3",
   "invert": true,
   "motor": null
  },
  {
   "id": "p15",
   "type": "wheel",
   "name": "Main L",
   "color": "#222428",
   "mass": 8,
   "pos": [
    -0.2,
    -1,
    -1.3
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.3,
    "width": 0.15,
    "grip": 0.9,
    "roll": 0.02
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p16",
   "type": "wheel",
   "name": "Main R",
   "color": "#222428",
   "mass": 8,
   "pos": [
    -0.2,
    -1,
    1.3
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.3,
    "width": 0.15,
    "grip": 0.9,
    "roll": 0.02
   },
   "servo": null,
   "invert": false,
   "motor": null
  }
 ]
}
"""#
    static let jetTrainer = #"""
{
 "name": "Jet trainer",
 "parts": [
  {
   "id": "p1",
   "type": "servo",
   "name": "Ailerons",
   "color": "#ffb020",
   "mass": 0.5,
   "pos": [
    0.4,
    0.6,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "axis": "z",
    "range": 20,
    "torque": 400,
    "speed": 120
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "d",
    "neg": "a",
    "mode": "spring",
    "rate": 3
   }
  },
  {
   "id": "p2",
   "type": "servo",
   "name": "Elevator",
   "color": "#ffb020",
   "mass": 0.5,
   "pos": [
    -3.6,
    0.2,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "axis": "z",
    "range": 20,
    "torque": 400,
    "speed": 120
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "s",
    "neg": "w",
    "mode": "spring",
    "rate": 3
   }
  },
  {
   "id": "p3",
   "type": "servo",
   "name": "Rudder",
   "color": "#ffb020",
   "mass": 0.5,
   "pos": [
    -3.6,
    0.9,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "axis": "y",
    "range": 25,
    "torque": 400,
    "speed": 120
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "e",
    "neg": "q",
    "mode": "spring",
    "rate": 3
   }
  },
  {
   "id": "p5",
   "type": "box",
   "name": "Fuselage",
   "color": "#d8dce2",
   "mass": 250,
   "pos": [
    0,
    0,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "sx": 6,
    "sy": 1.1,
    "sz": 1.1,
    "cd": 0.12
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p8",
   "type": "wing",
   "name": "Wing L",
   "color": "#e8eaee",
   "mass": 45,
   "pos": [
    0.4,
    0.6,
    -2.6
   ],
   "rot": [
    0,
    0,
    2
   ],
   "p": {
    "span": 4.2,
    "chord": 1.5,
    "thick": 0.1,
    "camber": 0.25,
    "ar": 7
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p9",
   "type": "wing",
   "name": "Wing R",
   "color": "#e8eaee",
   "mass": 45,
   "pos": [
    0.4,
    0.6,
    2.6
   ],
   "rot": [
    0,
    0,
    2
   ],
   "p": {
    "span": 4.2,
    "chord": 1.5,
    "thick": 0.1,
    "camber": 0.25,
    "ar": 7
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p10",
   "type": "wing",
   "name": "Aileron L",
   "color": "#c0302a",
   "mass": 6,
   "pos": [
    0.4,
    0.6,
    -5.45
   ],
   "rot": [
    0,
    0,
    2
   ],
   "p": {
    "span": 1.5,
    "chord": 1.3,
    "thick": 0.1,
    "camber": 0.25,
    "ar": 7
   },
   "servo": "p1",
   "invert": false,
   "motor": null
  },
  {
   "id": "p11",
   "type": "wing",
   "name": "Aileron R",
   "color": "#c0302a",
   "mass": 6,
   "pos": [
    0.4,
    0.6,
    5.45
   ],
   "rot": [
    0,
    0,
    2
   ],
   "p": {
    "span": 1.5,
    "chord": 1.3,
    "thick": 0.1,
    "camber": 0.25,
    "ar": 7
   },
   "servo": "p1",
   "invert": true,
   "motor": null
  },
  {
   "id": "p12",
   "type": "wing",
   "name": "Stabilator",
   "color": "#c0302a",
   "mass": 15,
   "pos": [
    -3.6,
    0.2,
    0
   ],
   "rot": [
    0,
    0,
    -1.5
   ],
   "p": {
    "span": 3.4,
    "chord": 1,
    "thick": 0.1,
    "camber": 0,
    "ar": 4
   },
   "servo": "p2",
   "invert": true,
   "motor": null
  },
  {
   "id": "p13",
   "type": "wing",
   "name": "Fin",
   "color": "#c0302a",
   "mass": 10,
   "pos": [
    -3.6,
    0.95,
    0
   ],
   "rot": [
    90,
    0,
    0
   ],
   "p": {
    "span": 1.5,
    "chord": 1.1,
    "thick": 0.1,
    "camber": 0,
    "ar": 2
   },
   "servo": "p3",
   "invert": false,
   "motor": null
  },
  {
   "id": "p14",
   "type": "wheel",
   "name": "Nose wheel",
   "color": "#222428",
   "mass": 8,
   "pos": [
    2.2,
    -1,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.25,
    "width": 0.15,
    "grip": 0.9,
    "roll": 0.02
   },
   "servo": "p3",
   "invert": true,
   "motor": null
  },
  {
   "id": "p15",
   "type": "wheel",
   "name": "Main L",
   "color": "#222428",
   "mass": 8,
   "pos": [
    -0.2,
    -1,
    -1.3
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.3,
    "width": 0.15,
    "grip": 0.9,
    "roll": 0.02
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p16",
   "type": "wheel",
   "name": "Main R",
   "color": "#222428",
   "mass": 8,
   "pos": [
    -0.2,
    -1,
    1.3
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.3,
    "width": 0.15,
    "grip": 0.9,
    "roll": 0.02
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p17",
   "type": "jet",
   "name": "Turbojet",
   "color": "#7d858f",
   "mass": 180,
   "pos": [
    0.5,
    0,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "thrust": 4500,
    "flow": 0.18,
    "r": 0.35,
    "len": 2
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "up",
    "neg": "down",
    "mode": "ramp",
    "rate": 0.8
   }
  },
  {
   "id": "p18",
   "type": "tank",
   "name": "Fuel tank",
   "color": "#c9a24a",
   "mass": 15,
   "pos": [
    1.8,
    0,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "capacity": 250,
    "fill": 1,
    "r": 0.35,
    "len": 1.6
   },
   "servo": null,
   "invert": false,
   "motor": null
  }
 ]
}
"""#
    static let rover = #"""
{
 "name": "Rover",
 "parts": [
  {
   "id": "p1",
   "type": "motor",
   "name": "Drive",
   "color": "#5a6270",
   "mass": 30,
   "pos": [
    0,
    0,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "torque": 180,
    "vmax": 20,
    "reversible": 1
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "w",
    "neg": "s",
    "mode": "spring",
    "rate": 2
   }
  },
  {
   "id": "p2",
   "type": "servo",
   "name": "Steering",
   "color": "#ffb020",
   "mass": 0.5,
   "pos": [
    0.9,
    0,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "axis": "y",
    "range": 30,
    "torque": 200,
    "speed": 60
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "d",
    "neg": "a",
    "mode": "spring",
    "rate": 2
   }
  },
  {
   "id": "p3",
   "type": "box",
   "name": "Chassis",
   "color": "#d8dce2",
   "mass": 150,
   "pos": [
    0,
    0.1,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "sx": 2.4,
    "sy": 0.4,
    "sz": 1.3,
    "cd": 0.6
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p4",
   "type": "wheel",
   "name": "Front L",
   "color": "#222428",
   "mass": 8,
   "pos": [
    0.9,
    -0.15,
    -0.85
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.35,
    "width": 0.2,
    "grip": 1,
    "roll": 0.02
   },
   "servo": "p2",
   "invert": true,
   "motor": "p1"
  },
  {
   "id": "p5",
   "type": "wheel",
   "name": "Front R",
   "color": "#222428",
   "mass": 8,
   "pos": [
    0.9,
    -0.15,
    0.85
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.35,
    "width": 0.2,
    "grip": 1,
    "roll": 0.02
   },
   "servo": "p2",
   "invert": true,
   "motor": "p1"
  },
  {
   "id": "p6",
   "type": "wheel",
   "name": "Rear L",
   "color": "#222428",
   "mass": 8,
   "pos": [
    -0.9,
    -0.15,
    -0.85
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.35,
    "width": 0.2,
    "grip": 1,
    "roll": 0.02
   },
   "servo": null,
   "invert": true,
   "motor": "p1"
  },
  {
   "id": "p7",
   "type": "wheel",
   "name": "Rear R",
   "color": "#222428",
   "mass": 8,
   "pos": [
    -0.9,
    -0.15,
    0.85
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.35,
    "width": 0.2,
    "grip": 1,
    "roll": 0.02
   },
   "servo": null,
   "invert": true,
   "motor": "p1"
  }
 ]
}
"""#
    static let soundingRocket = #"""
{
 "name": "Sounding rocket",
 "parts": [
  {
   "id": "p1",
   "type": "cylinder",
   "name": "Body tube",
   "color": "#d8dce2",
   "mass": 6,
   "pos": [
    0,
    1.7,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.12,
    "h": 3,
    "cd": 0.15
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p2",
   "type": "cone",
   "name": "Nose cone",
   "color": "#c0302a",
   "mass": 1.5,
   "pos": [
    0,
    3.5,
    0
   ],
   "rot": [
    0,
    0,
    0
   ],
   "p": {
    "r": 0.12,
    "h": 0.6,
    "cd": 0.1
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p3",
   "type": "solid",
   "name": "Booster",
   "color": "#e0e0e0",
   "mass": 3,
   "pos": [
    0,
    0.45,
    0
   ],
   "rot": [
    0,
    0,
    90
   ],
   "p": {
    "thrust": 700,
    "burn": 5,
    "fuel": 10,
    "r": 0.1,
    "len": 0.9
   },
   "servo": null,
   "invert": false,
   "motor": null,
   "keys": {
    "pos": "space",
    "neg": null,
    "mode": "spring",
    "rate": 5
   }
  },
  {
   "id": "p4",
   "type": "wing",
   "name": "Fin",
   "color": "#c0302a",
   "mass": 0.5,
   "pos": [
    0.3,
    0.35,
    0
   ],
   "rot": [
    -90,
    90,
    0
   ],
   "p": {
    "span": 0.3,
    "chord": 0.5,
    "thick": 0.02,
    "camber": 0,
    "ar": 1.2
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p5",
   "type": "wing",
   "name": "Fin",
   "color": "#c0302a",
   "mass": 0.5,
   "pos": [
    -0.3,
    0.35,
    0
   ],
   "rot": [
    90,
    -90,
    0
   ],
   "p": {
    "span": 0.3,
    "chord": 0.5,
    "thick": 0.02,
    "camber": 0,
    "ar": 1.2
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p6",
   "type": "wing",
   "name": "Fin",
   "color": "#c0302a",
   "mass": 0.5,
   "pos": [
    0,
    0.35,
    0.3
   ],
   "rot": [
    0,
    0,
    -90
   ],
   "p": {
    "span": 0.3,
    "chord": 0.5,
    "thick": 0.02,
    "camber": 0,
    "ar": 1.2
   },
   "servo": null,
   "invert": false,
   "motor": null
  },
  {
   "id": "p7",
   "type": "wing",
   "name": "Fin",
   "color": "#c0302a",
   "mass": 0.5,
   "pos": [
    0,
    0.35,
    -0.3
   ],
   "rot": [
    -180,
    0,
    90
   ],
   "p": {
    "span": 0.3,
    "chord": 0.5,
    "thick": 0.02,
    "camber": 0,
    "ar": 1.2
   },
   "servo": null,
   "invert": false,
   "motor": null
  }
 ]
}
"""#
}
