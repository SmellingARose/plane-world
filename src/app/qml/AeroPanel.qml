import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// FLY › Aero model: model picker from the registry (fast profiles + Full CFD), fast-model effect toggles, and for
// Full: CFD settings, live quality diagnostics and the flow overlay controls.
ColumnLayout {
    id: aero
    spacing: Theme.s3
    readonly property var c: App.cfd
    readonly property var d: App.cfdDiagnostics
    function pct(v) { return v === undefined || v === null ? "pending" : (v * 100).toFixed(1) + " %" }

    PwSection {
        title: "Aero model"
        hint: "Fast models are formulas (see EQUATIONS); Full CFD simulates the air on the GPU. Cycle with " + Theme.shortcutText("Ctrl+Shift+M")
        trailing: Rectangle {
            radius: 3; implicitWidth: badge.implicitWidth + 10; implicitHeight: badge.implicitHeight + 4
            color: Theme.alpha(App.fullModel ? Theme.cfd : Theme.accent, 0.18)
            Text { id: badge; anchors.centerIn: parent; font.pixelSize: Theme.micro + 1; font.weight: Font.DemiBold
                color: App.fullModel ? Theme.cfd : Theme.accent; text: App.fullModel ? "CFD" : "ANALYTIC" }
        }
        PwCard {
            AeroModelPicker {
                Layout.fillWidth: true
                currentId: App.aeroModel
                onPicked: (id) => App.aeroModel = id
            }
            Label {
                visible: App.aeroError !== ""
                text: "⚠ " + App.aeroError
                color: Theme.warn; font.pixelSize: Theme.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true
            }
            PwSection {
                title: "Fast-model effects"
                expanded: false
                Repeater {
                    model: [
                        { k: "slipstream", t: "Prop slipstream (wakes, ducts)", h: "Actuator-disk prop wakes feed downstream parts; duct and rotor ground effect." },
                        { k: "gyro", t: "Gyroscopic rotors", h: "Prop / wheel angular momentum couples into body rotation (ω × H)." },
                        { k: "pFactor", t: "Prop P-factor", h: "Asymmetric disk loading at incidence: normal force + yaw / pitch moment." },
                        { k: "downwash", t: "Wing downwash", h: "Horseshoe-vortex induced velocity from upstream wings onto the tail." },
                        { k: "blockage", t: "Wake blockage", h: "Bodies attenuate / deflect prop wakes behind them." },
                        { k: "cadWash", t: "CAD panels in slipstream", h: "CAD panels sample the slipstream per panel." } ]
                    CheckBox {
                        required property var modelData
                        text: modelData.t
                        font.pixelSize: Theme.small
                        enabled: modelData.k === "slipstream" || App.fastToggles.slipstream
                        checked: App.fastToggles[modelData.k] === true
                        onToggled: App.setFastToggle(modelData.k, checked)
                        ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: modelData.h
                    }
                }
                Label { text: "Effects other than slipstream need the slipstream model on."; color: Theme.textFaint; font.pixelSize: Theme.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }
        }
    }

    PwSection {
        title: "CFD settings"
        visible: App.fullModel
        PwCard {
            Label {
                text: (aero.c.preset ? aero.c.preset.charAt(0).toUpperCase() + aero.c.preset.slice(1) + " · " : "") + "dx = " + ((aero.c.dxRequested || 0) * 100).toFixed(1) + " cm · max " + aero.c.maxCellsPerAxis + " cells/axis · "
                      + aero.c.lattice + " · " + aero.c.collision + " · " + aero.c.turbulence
                font.family: Theme.mono; font.pixelSize: Theme.caption; color: Theme.textMuted; wrapMode: Text.WordWrap; Layout.fillWidth: true
            }
            PwSlider { label: "Resolution (cells / m)"; from: 4; to: 128; step: 1; decimals: 0; value: aero.c.cellsPerMeter || 16
                tip: "Grid cells per metre. Cost grows ~ (cells/m)^4. The padded domain is coarsened if it exceeds Max cells/axis."
                onCommitted: (v) => App.setCfd("cellsPerMeter", v) }
            Label {
                readonly property bool capped: aero.d.dx > 0 && aero.d.dx > (aero.c.dxRequested || 0) * 1.02
                visible: true
                text: aero.d.dx > 0 ? "Effective dx " + (aero.d.dx * 100).toFixed(1) + " cm" + (capped ? " — capped by max cells/axis; raise it or shrink padding" : " — as requested")
                                    : "Effective dx appears once a domain runs."
                color: capped ? Theme.warn : Theme.textMuted; font.pixelSize: Theme.caption; wrapMode: Text.WordWrap; Layout.fillWidth: true
            }
            PwSlider { label: "Lattice Mach"; from: 0.02; to: 0.3; step: 0.01; value: aero.c.latticeMach || 0.1
                tip: "Reference speed in lattice units ÷ c_s. Lower = more accurate but more steps per second of flight."
                onCommitted: (v) => App.setCfd("latticeMach", v) }
            PwSection {
                title: "Domain, models & stepping"
                expanded: false
                PwPropertyRow { label: "Max cells/axis"; tip: "Caps grid size; the domain is shrunk (coarser dx) if the padded box would exceed it"
                    SpinBox { from: 32; to: 512; stepSize: 16; value: aero.c.maxCellsPerAxis || 192; editable: true; onValueModified: App.setCfd("maxCellsPerAxis", value) } }
                PwSlider { label: "Pad upstream (× craft length)"; from: 0.25; to: 4; value: aero.c.padUpstream || 1; onCommitted: (v) => App.setCfd("padUpstream", v) }
                PwSlider { label: "Pad downstream"; from: 0.5; to: 8; value: aero.c.padDownstream || 2.5; onCommitted: (v) => App.setCfd("padDownstream", v) }
                PwSlider { label: "Pad lateral"; from: 0.25; to: 4; value: aero.c.padLateral || 1; onCommitted: (v) => App.setCfd("padLateral", v) }
                PwSlider { label: "Max Mach (flag above)"; from: 0.1; to: 0.5; value: aero.c.maxMach || 0.3; onCommitted: (v) => App.setCfd("maxMach", v) }
                PwPropertyRow { label: "Lattice"; tip: "D3Q27 is more isotropic (better at high Re) and ~40% more expensive"
                    ComboBox { model: ["D3Q19", "D3Q27"]; currentIndex: Math.max(0, model.map(s => s.toLowerCase()).indexOf((aero.c.lattice || "").toLowerCase())); onActivated: (i) => App.setCfd("lattice", model[i]) } }
                PwPropertyRow { label: "Collision"; tip: "BGK is cheapest but unstable at low viscosity; cumulant (runs regularized) is the most robust"
                    ComboBox { model: ["BGK", "MRT", "Regularized", "Cumulant"]; currentIndex: Math.max(0, model.map(s => s.toLowerCase()).indexOf((aero.c.collision || "").toLowerCase())); onActivated: (i) => App.setCfd("collision", model[i]) } }
                PwPropertyRow { label: "Turbulence"; tip: "LES sub-grid model; required at flight Reynolds numbers"
                    ComboBox { model: ["None", "Smagorinsky", "WALE"]; currentIndex: Math.max(0, model.map(s => s.toLowerCase()).indexOf((aero.c.turbulence || "").toLowerCase())); onActivated: (i) => App.setCfd("turbulence", model[i]) } }
                PwSlider { visible: (aero.c.turbulence || "").toLowerCase() !== "none"; label: "C_s (Smagorinsky)"; from: 0.05; to: 0.3; value: aero.c.smagorinskyCs || 0.17; onCommitted: (v) => App.setCfd("smagorinskyCs", v) }
                PwPropertyRow { label: "Walls"; tip: "Interpolated bounce-back places the wall at its true sub-cell position (2nd order)"
                    ComboBox { model: ["BounceBack", "InterpolatedBounceBack"]; displayText: currentIndex === 1 ? "Interpolated BB" : "Bounce-back"
                        currentIndex: Math.max(0, model.map(s => s.toLowerCase()).indexOf((aero.c.wall || "").toLowerCase())); onActivated: (i) => App.setCfd("wall", model[i]) } }
                PwPropertyRow { label: "LBM steps/update"; tip: "0 = derived from dt and the lattice time step"
                    SpinBox { from: 0; to: 64; value: aero.c.substeps || 0; editable: true; onValueModified: App.setCfd("substeps", value) } }
                PwPropertyRow { label: "Update every"; tip: "Physics runs at 1 kHz; CFD forces refresh every N substeps (forces lag by one update)"
                    SpinBox { from: 1; to: 32; value: aero.c.updateEvery || 4; editable: true; onValueModified: App.setCfd("updateEvery", value) } }
                CheckBox { text: "Ground plane boundary"; checked: aero.c.ground === true; onToggled: App.setCfd("ground", checked) }
                PwPropertyRow { label: "Convergence"; tip: "Every N steps a half-resolution grid estimates discretisation error (0 = off)"
                    SpinBox { from: 0; to: 2000; stepSize: 50; value: aero.c.convergenceEvery || 0; editable: true; onValueModified: App.setCfd("convergenceEvery", value) } }
            }
        }
    }

    PwSection {
        title: "CFD quality (live)"
        visible: App.fullModel
        PwCard {
            PwEmptyState { visible: !(aero.d.steps > 0); text: "No CFD steps yet — unpause the flight with the Full model to populate." }
            ColumnLayout {
                visible: aero.d.steps > 0
                Layout.fillWidth: true
                spacing: 2
                PwStatRow { label: "Grid"; value: aero.d.grid ? aero.d.grid.join("×") + "  (" + (aero.d.cells / 1e6).toFixed(2) + " M)" : "–" }
                PwStatRow { label: "dx / dt"; value: ((aero.d.dx || 0) * 100).toFixed(1) + " cm / " + (aero.d.dt || 0).toExponential(2) + " s" }
                PwStatRow { label: "Max lattice Mach"; value: Theme.fixed(aero.d.maxMach, 3); warn: aero.d.maxMach > (aero.c.maxMach || 0.3) }
                PwStatRow { label: "Mass drift"; value: (aero.d.massDrift || 0).toExponential(2); warn: Math.abs(aero.d.massDrift || 0) > 1e-3 }
                PwStatRow { label: "Coarse-grid Δ (force)"; value: aero.pct(aero.d.coarseDelta); warn: aero.d.coarseDelta > 0.1 }
                PwStatRow { label: "Richardson error est."; value: aero.pct(aero.d.richardson); warn: aero.d.richardson > 0.1 }
                PwStatRow { label: "GPU / CPU wait per step"; value: Theme.fixed(aero.d.gpuMs, 2) + " / " + Theme.fixed(aero.d.cpuMs, 2) + " ms" }
                PwStatRow { label: "Steps · updates"; value: (aero.d.steps || 0) + " · " + (aero.d.updates || 0) }
                Label { visible: aero.d.diverged === true; text: "✕ Diverged — lower lattice Mach or raise resolution"; color: Theme.bad; font.pixelSize: Theme.caption }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.textMuted; font.pixelSize: Theme.caption
                    text: {
                        const e = aero.d.richardson !== undefined && aero.d.richardson !== null ? aero.d.richardson : aero.d.coarseDelta
                        if (e === undefined || e === null) return "Grid-convergence estimate pending (needs a coarse-grid comparison; set Convergence > 0)."
                        if (e < 0.03) return "Grid converged to within ~3 %."
                        if (e < 0.10) return "Moderate grid error — High / Ultra will change forces noticeably."
                        return "Under-resolved — forces are qualitative."
                    }
                }
            }
        }
    }

    PwSection {
        title: "Flow visualisation"
        visible: App.fullModel
        PwCard {
            CheckBox { text: "Show flow slice"; checked: aero.c.visEnabled === true; onToggled: App.setCfd("visEnabled", checked)
                ToolTip.visible: hovered; ToolTip.delay: Theme.tooltipDelay; ToolTip.text: Theme.tip("Colour-mapped slice through the CFD domain", "V") }
            ColumnLayout {
                visible: aero.c.visEnabled === true
                Layout.fillWidth: true
                PwSegmented { model: ["Speed", "Pressure", "Vorticity"]; currentIndex: Math.max(0, model.map(s => s.toLowerCase()).indexOf((aero.c.visField || "").toLowerCase()))
                    onActivated: (i) => App.setCfd("visField", model[i]) }
                PwSegmented { model: [{ text: "YZ", tip: "Slice normal X" }, { text: "XZ", tip: "Slice normal Y" }, { text: "XY", tip: "Slice normal Z" }]
                    currentIndex: aero.c.visAxis || 0; onActivated: (i) => App.setCfd("visAxis", i) }
                PwSlider { label: "Slice offset"; from: -3; to: 3; step: 0.01; value: aero.c.visOffset || 0; defaultValue: 0; format: (v) => (v >= 0 ? "+" : "") + v.toFixed(2) + " m"
                    onMoved: (v) => App.setCfd("visOffset", v) }
                CheckBox { text: "Tracer particles"; checked: aero.c.visParticles === true; onToggled: App.setCfd("visParticles", checked) }
                PwPropertyRow { visible: aero.c.visParticles === true; label: "Particles"
                    SpinBox { from: 256; to: 65536; stepSize: 1024; value: aero.c.visParticleCount || 4096; editable: true; onValueModified: App.setCfd("visParticleCount", value) } }
            }
        }
    }
}
