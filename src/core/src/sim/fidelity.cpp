#include "pw/sim/fidelity.h"

namespace pw::sim {

const EquationInfo& equationInfo(EquationID id) {
    static const std::vector<EquationInfo> table = {
        {"\xE2\x80\x94", "", {}, ""},
        {"Strip lift", "C_L = a·(α − α₀),  a = 2πAR/(2 + √(AR²β²/κ² + 4)),  L = ½ρV²S·C_L",
         {"a (1/rad)", "α (°)", "α₀ (°)", "ρ (kg/m³)", "V (m/s)", "S (m²)", "C_L", "L (N)"},
         "Helmbold / DATCOM finite-AR lift slope with Prandtl–Glauert β = √(1−M²), κ = 0.95 (Anderson, Fundamentals of Aerodynamics §5.3)"},
        {"Strip drag", "D = ½ρV²S·(C_D0 + φ·C_L²/(π·AR·e) + 0.02 sin²α + ΔC_D,flap),  C_D0 = 2·C_f·(1 + 2t + 60t⁴),  C_f = 0.455/(log₁₀Re)^2.58",
         {"ρ (kg/m³)", "V (m/s)", "S (m²)", "C_D0", "C_L", "AR", "e", "φ (ground effect)", "C_D", "D (N)"},
         "parabolic drag polar; Prandtl–Schlichting turbulent skin friction; Hoerner form factor"},
        {"Centre of pressure / hinge", "x_cp = 0.25c (attached), → 0.45c post-stall;  C_h = −0.55δ − 0.2α,  H = |C_h|·½ρV²S·c_f·(c_f c)",
         {"x_cp/c", "c (m)", "C_h", "hinge load (N·m)"},
         "thin-airfoil quarter-chord AC; plain-flap hinge coefficient (Abbott & von Doenhoff); prototype hinge model"},
        {"Plain-flap lift increment", "ΔC_L = a·τ·η·δ,  τ = 1 − (θ_f − sin θ_f)/π,  θ_f = acos(2c_f/c − 1),  η = 0.75 − 0.25·smoothstep(15°, 40°, |δ|)",
         {"τ", "η", "δ (°)", "a (1/rad)", "ΔC_L"},
         "thin-airfoil flap effectiveness (Glauert); viscous loss factor η (inviscid theory overpredicts flap lift 10–20%)"},
        {"Stall", "α_s = (11° + 5°·smoothstep(5, 7, log₁₀Re) − 3°·(1 − t̂));  |α_ZL| > α_s ⇒ C_L blends to 1.05·sin 2α over 12°",
         {"α_ZL (°)", "α_stall (°)", "Re", "excess (°)", "C_L"},
         "empirical Re-dependent stall (Abbott & von Doenhoff data) + flat-plate post-stall"},
        {"Prop thrust (momentum)", "T·(V + v_i) = η·P,  v_i = −V/2 + √(V²/4 + T/(2ρA)),  T ×= 1 − (V/V_pitch)³",
         {"η", "P (W)", "V_axial (m/s)", "v_i (m/s)", "ρ (kg/m³)", "A (m²)", "T (N)"},
         "actuator-disk momentum theory (Rankine–Froude; McCormick, Aerodynamics of V/STOL Flight)"},
        {"Prop reaction torque", "Q = η·P/Ω  (full Q on the airframe with slipstream on; 0.25·Q in the isolated model)",
         {"η", "P (W)", "Ω (rad/s)", "Q (N·m)"}, "shaft power balance P = QΩ at the operating point"},
        {"Slipstream", "Δv(s) = v_i·(1 + s/√(s² + R²)),  R_s = R·√((V + v_i)/(V + Δv)),  decay e^(−s/14R)",
         {"v_i (m/s)", "R (m)", "Δv far (m/s)", "inflow from other wakes (m/s)"},
         "vortex-cylinder actuator-disk wake (McCormick); continuity contraction; empirical mixing"},
        {"Ducted rotor", "T = ρA·(V + w)·w (exit area = disk area), solved at the power of an open rotor of √2·d",
         {"ducted", "d (m)", "d_eff (m)", "T (N)"}, "ducted-fan momentum theory (σ = 1, Pereira 2008)"},
        {"Rotor ground effect", "T_IGE/T_OGE = 1/(1 − (R/4z)²),  z ≥ R/2",
         {"h (m)", "R (m)", "z/R", "wake-down cosine", "gain"}, "Cheeseman & Bennett 1955 (ARC R&M 3021)"},
        {"Panel pressure (modified Newtonian)", "windward: C_p = C_p,max·cos²θ, C_p,max = 1 + M²/4;  leeward: C_p = −0.25·cos θ;  shadowed panels: 0",
         {"panels", "windward", "shadowed", "q̄ max (Pa)", "|F_p| (N)"},
         "modified Newtonian impact theory (Lees); leeward base suction is an empirical constant (no clean low-speed error figure)"},
        {"Panel skin friction", "τ_w = C_f·q̄ along the surface flow,  C_f = 0.455/(log₁₀Re_L)^2.58",
         {"Re_L (mean)", "C_f (mean)", "|F_f| (N)"}, "Prandtl–Schlichting turbulent flat plate"},
        {"Gyroscopic rotor coupling", "dL_body/dt = T − ω × h_r,  h_r = I_r·Ω·n̂,  I_prop = m R²/3,  I_wheel = m r²/2",
         {"I_r (kg·m²)", "Ω (rad/s)", "|ω| body (rad/s)", "|h_r| (N·m·s)", "|τ| (N·m)"},
         "Euler equations with an internal rotor (Wittenburg, Dynamics of Systems of Rigid Bodies)"},
        {"P-factor (asymmetric disk loading)", "μ = v_c/(ΩR),  e = min(0.3R, ½μR) toward Ω̂ × v̂_c,  M = e × T,  N = ½·ρA(V_ax + v_i)·v_c",
         {"α_p (°)", "v_c (m/s)", "Ω (rad/s)", "R (m)", "μ", "e (m)", "T (N)", "N (N)", "|M| (N·m)"},
         "blade-element thrust ∝ (Ωr + v_c sin ψ)² (Ribner 1945, NACA ARR 3L02 for normal force); ½ factors are assumed inflow relief"},
        {"Wing downwash (horseshoe vortex)", "Γ = L/(ρVb'),  b' = (π/4)·b;  w = Biot–Savart(bound + trailing legs);  ε = atan(w/V)  (far field ε → 16C_L/(π³AR) ≈ 0.52 C_L/AR; textbook 2C_L/(πAR))",
         {"Γ (m²/s)", "b' (m)", "w (m/s)", "V (m/s)", "ε (°)"},
         "Prandtl lifting line / horseshoe vortex (Katz & Plotkin, Low-Speed Aerodynamics §§2, 8)"},
        {"Body blockage of a wake", "f = 1 − 0.8·w(r/r_b)·e^(−(s − s_b − ℓ)/(6r_b)),  r_b = √(A_proj/π);  coaxial: swirl of the upper wake ends at the lower disk and is added to the lower wake",
         {"s (m)", "r_b (m)", "A_proj (m²)", "R wake (m)", "f just behind body"},
         "engineering wake-shadow model (assumed constants); angular-momentum flux conservation for coaxial rotors"},
        {"CAD panels in wash", "V_rel,k = v_body + ω × r_k − (V_wind + Σ wakes(p_k) + Σ horseshoes(p_k))  per panel",
         {"panels", "mean |wash| (m/s)", "max |wash| (m/s)"}, "superposition of the slipstream and downwash models per panel"},
        {"Body drag (projected area)", "D = ½ρV²·C_d·A_proj,  A_proj = |v̂ₓ|s_y s_z + |v̂_y|s_x s_z + |v̂_z|s_x s_y,  C_d ×= 1 + 6(M − 0.8)² above M 0.8",
         {"ρ (kg/m³)", "V (m/s)", "C_d", "A_proj (m²)", "D (N)"}, "bluff-body drag with box projected area (Hoerner, Fluid-Dynamic Drag)"},
    };
    std::size_t i = std::size_t(id);
    return table[i < table.size() ? i : 0];
}

const std::vector<AeroProfile>& fastAeroProfiles() {
    static const std::vector<AeroProfile> list = [] {
        std::vector<AeroProfile> l;
        FastAeroToggles c; c.slipstream = c.gyro = c.pFactor = c.downwash = c.blockage = c.cadWash = false;
        l.push_back({"fast.classic", "Fast · classic",
                     "Isolated parts: strip-theory wings, momentum props, Newtonian bodies. No part-to-part air interaction.", c});
        FastAeroToggles s = c; s.slipstream = true;
        l.push_back({"fast.slipstream", "Fast · slipstream",
                     "Classic + actuator-disk prop wakes feeding downstream parts, ducts, rotor ground effect.", s});
        l.push_back({"fast.plus", "Fast+ (all effects)",
                     "Slipstream + gyroscopic rotors, P-factor, wing downwash, body blockage, CAD prop wash. Default.", FastAeroToggles{}});
        return l;
    }();
    return list;
}

const AeroProfile* fastAeroProfile(const std::string& id) {
    for (auto& p : fastAeroProfiles()) if (p.id == id) return &p;
    return nullptr;
}

} // namespace pw::sim
