// Delayed detached-eddy simulation (DDES, Spalart–Allmaras based). See ../README.md for the module spec.
// Everything sits in one closure so nothing leaks into the page shared with the other methods.
(() => {
// ---------- Spalart–Allmaras constants (Spalart & Allmaras 1994; NASA TMR "SA-noft2") and the DES constant ----------
const SA = {cb1: .1355, cb2: .622, sig: 2/3, kap: .41, cw2: .3, cw3: 2, cv1: 7.1, CDES: .65}; SA.cw1 = SA.cb1/SA.kap**2 + (1+SA.cb2)/SA.sig;
const clock = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());

// ---------- the Build solver: a zero-pressure-gradient turbulent boundary layer marched downstream ----------
// Boundary-layer form of the incompressible equations (U, V) + the SA equation for nu~, implicit in y, marched in x.
// Units: U_e = 1, plate length 1, nu = 1e-7 (Re = 1e7 per unit length). One model differs only in the length l.
const NU = 1e-7, X0 = .02, X1 = 1, NS = 240, J = 120, Y1 = 1.5e-6, YT = .06, NTINF = 3*NU;
let GR; { let a = 1.0001, b = 1.5; for (let i=0;i<80;i++){ const m = (a+b)/2, f = Y1*(m**(J-1)-1)/(m-1); if (f > YT) b = m; else a = m; } GR = (a+b)/2; }
const Y = new Float64Array(J); for (let j=1;j<J;j++) Y[j] = Y1*(GR**j-1)/(GR-1);
const DY = new Float64Array(J); for (let j=0;j<J;j++) DY[j] = j === 0 ? Y[1] : j === J-1 ? Y[J-1]-Y[J-2] : (Y[j+1]-Y[j-1])/2;
const XS = new Float64Array(NS); for (let n=0;n<NS;n++) XS[n] = X0*(X1/X0)**(n/(NS-1));
const cv13 = SA.cv1**3, cw36 = SA.cw3**6, k2 = SA.kap*SA.kap;
const fv1 = v => { const ch = v/NU, c3 = ch*ch*ch; return c3/(c3+cv13); };
const fwOf = r => { const g = r + SA.cw2*(r**6 - r); return g*((1+cw36)/(g**6+cw36))**(1/6); };
// SA terms at one point for a given vorticity S and length l: returns {St, P, D, fw, r, fv1}
function saPoint(n, S, l){ const chi = n/NU, c3 = chi*chi*chi, f1 = c3/(c3+cv13), fv2 = 1 - chi/(1+chi*f1), kl = k2*l*l;
  let St = S + n*fv2/kl; if (St < .3*S) St = .3*S; let r = St > 0 ? n/(St*kl) : 10; if (r > 10) r = 10; const fw = fwOf(r);
  return {St, P: SA.cb1*St*n, D: SA.cw1*fw*n*n/(l*l), fw, r, fv1: f1}; }
// net source P − D with the total shear stress tau held fixed (S = tau/(nu+nu_t)): the linearisation that keeps the march stable
function srcHeld(n, tau, l){ const o = saPoint(n, tau/(NU + n*fv1(n)), l); return o.P - o.D; }
const A_ = new Float64Array(J), B_ = new Float64Array(J), C_ = new Float64Array(J), R_ = new Float64Array(J), X_ = new Float64Array(J);
const Uo = new Float64Array(J), No = new Float64Array(J), Lw = new Float64Array(J), FDw = new Float64Array(J);
function tri(n1){ for (let j=2;j<=n1;j++){ const m = A_[j]/B_[j-1]; B_[j] -= m*C_[j-1]; R_[j] -= m*R_[j-1]; }
  X_[n1] = R_[n1]/B_[n1]; for (let j=n1-1;j>=1;j--) X_[j] = (R_[j]-C_[j]*X_[j+1])/B_[j]; }
// model: 0 = RANS (l = d), 1 = DES97 (l = min(d, C_DES Δ)), 2 = DDES (shielded). del(x) = wall-parallel cell size Δx = Δz at station x.
function newRun(model, del, cd1){
  const R = {model, del, cd1: cd1 || 8, n: 0, U: new Float64Array(J), V: new Float64Array(J), N: new Float64Array(J),
    Cf: new Float64Array(NS), Rth: new Float64Array(NS), d99: new Float64Array(NS),
    FD: new Float32Array(NS*J), LD: new Float32Array(NS*J), NUT: new Float32Array(NS*J), TAU: new Float32Array(NS*J), RD: new Float32Array(NS*J), UU: new Float32Array(NS*J), NN: new Float32Array(NS*J)};
  // turbulent start: Reichardt's law of the wall cut at a 1/5-power-law thickness; SA forgets this within a few δ
  const x = XS[0], ut = Math.sqrt(0.0045/2), d0 = 0.37*x*(x/NU)**-0.2;
  for (let j=0;j<J;j++){ const yp = Y[j]*ut/NU, up = Math.log(1+SA.kap*yp)/SA.kap + 7.8*(1-Math.exp(-yp/11)-yp/11*Math.exp(-yp/3));
    R.U[j] = Math.min(1, ut*up); R.N[j] = Y[j] < d0 ? Math.max(NTINF, SA.kap*ut*Y[j]*(1-Y[j]/d0)) : NTINF; }
  R.U[J-1] = 1; R.N[0] = 0; lengths(R, x, R.U, R.U, 1, R.N); record(R, 0);
  return R;
}
// the length at every height: the only place where RANS, DES97 and DDES differ
function lengths(R, x, U, Uold, dx, N){
  const del = R.del ? R.del(x) : 0;
  for (let j=1;j<J-1;j++){ const d = Y[j];
    if (R.model === 0) { Lw[j] = d; FDw[j] = 0; continue; }
    const lc = SA.CDES*Math.max(del, DY[j]);                                   // C_DES Δ, Δ = max(Δx, Δy, Δz)
    if (R.model === 1) { Lw[j] = Math.min(d, lc); FDw[j] = 1; continue; }
    const uy = (U[j+1]-U[j-1])/(Y[j+1]-Y[j-1]), ux = (U[j]-Uold[j])/dx, g = Math.sqrt(uy*uy + 2*ux*ux) + 1e-12;   // √(∂_j u_i ∂_j u_i)
    const rd = (N[j]*fv1(N[j]) + NU)/(k2*d*d*g), fd = 1 - Math.tanh((R.cd1*rd)**3);
    FDw[j] = fd; Lw[j] = d - fd*Math.max(0, d - lc);
  }
}
function stepRun(R, K){
  K = K || 2; const n = R.n; if (n >= NS-1) return false;
  const x = XS[n+1], dx = XS[n+1]-XS[n], U = R.U, V = R.V, N = R.N;
  Uo.set(U); No.set(N);
  for (let k=0;k<K;k++){
    for (let j=1;j<J-1;j++){   // momentum: U ∂U/∂x + V ∂U/∂y = ∂/∂y[(ν+ν_t) ∂U/∂y]
      const hm = Y[j]-Y[j-1], hp = Y[j+1]-Y[j], hb = (hm+hp)/2, nm = .5*(N[j]+N[j-1]), np = .5*(N[j]+N[j+1]);
      const mm = NU + nm*fv1(nm), mp = NU + np*fv1(np), v = V[j], uk = Math.max(U[j], 1e-6);
      A_[j] = -mm/(hm*hb) - (v > 0 ? v/hm : 0); C_[j] = -mp/(hp*hb) + (v < 0 ? v/hp : 0);
      B_[j] = uk/dx + mm/(hm*hb) + mp/(hp*hb) + (v > 0 ? v/hm : -v/hp); R_[j] = uk*Uo[j]/dx;
    }
    R_[J-2] -= C_[J-2]; tri(J-2); for (let j=1;j<J-1;j++) U[j] = X_[j];
    lengths(R, x, U, Uo, dx, N);
    for (let j=1;j<J-1;j++){   // SA: U ∂ν̃/∂x + V ∂ν̃/∂y = P − D + (1/σ)[∂(ν+ν̃)∂ν̃ + c_b2 (∂ν̃)²]
      const hm = Y[j]-Y[j-1], hp = Y[j+1]-Y[j], hb = (hm+hp)/2, l = Lw[j];
      const km = (NU + .5*(N[j]+N[j-1]))/SA.sig, kp = (NU + .5*(N[j]+N[j+1]))/SA.sig;
      const Ny = (N[j+1]-N[j-1])/(hm+hp), ve = V[j] - SA.cb2/SA.sig*Ny;
      const S = Math.abs((U[j+1]-U[j-1])/(hm+hp)), n0 = Math.max(N[j], 1e-30), tau = (NU + n0*fv1(n0))*S;
      const F = srcHeld(n0, tau, l), dn = n0*1e-4, Fp = (srcHeld(n0+dn, tau, l) - F)/dn, uk = Math.max(U[j], 1e-6);
      A_[j] = -km/(hm*hb) - (ve > 0 ? ve/hm : 0); C_[j] = -kp/(hp*hb) + (ve < 0 ? ve/hp : 0);
      B_[j] = uk/dx + km/(hm*hb) + kp/(hp*hb) + (ve > 0 ? ve/hm : -ve/hp) + (Fp < 0 ? -Fp : 0);
      R_[j] = uk*No[j]/dx + F - (Fp < 0 ? Fp*n0 : 0);
    }
    R_[J-2] -= C_[J-2]*NTINF; tri(J-2); for (let j=1;j<J-1;j++) N[j] = Math.max(0, X_[j]);
    V[0] = 0; for (let j=1;j<J;j++) V[j] = V[j-1] - (Y[j]-Y[j-1])*.5*((U[j]-Uo[j]) + (U[j-1]-Uo[j-1]))/dx;   // continuity
  }
  R.n = n+1; lengths(R, x, U, Uo, dx, N); record(R, n+1); return true;
}
function record(R, n){
  const U = R.U, N = R.N, o = n*J, y1 = Y[1], y2 = Y[2];
  R.Cf[n] = 2*NU*(U[1]*y2*y2 - U[2]*y1*y1)/(y1*y2*(y2-y1));
  let th = 0; for (let j=1;j<J;j++) th += .5*(Y[j]-Y[j-1])*(U[j]*(1-U[j]) + U[j-1]*(1-U[j-1])); R.Rth[n] = th/NU;
  let d99 = Y[J-1]; for (let j=1;j<J;j++) if (U[j] >= .99) { d99 = Y[j-1] + (Y[j]-Y[j-1])*(.99-U[j-1])/(U[j]-U[j-1]); break; } R.d99[n] = d99;
  for (let j=0;j<J;j++){ const nut = N[j]*fv1(N[j]), inn = j > 0 && j < J-1, uy = inn ? (U[j+1]-U[j-1])/(Y[j+1]-Y[j-1]) : 0;
    R.NUT[o+j] = nut; R.TAU[o+j] = nut*uy; R.UU[o+j] = U[j]; R.NN[o+j] = N[j];
    R.FD[o+j] = inn ? FDw[j] : 0; R.LD[o+j] = inn ? Lw[j]/Y[j] : 1; R.RD[o+j] = inn ? (nut+NU)/(k2*Y[j]*Y[j]*(Math.abs(uy)+1e-12)) : 0; }
}
const runAll = R => { while (stepRun(R)); return R; };
// Coles–Fernholz skin friction (Nagib, Chauhan & Monkewitz 2007): the accuracy check of the RANS march
const coles = Rth => 2/((1/0.384)*Math.log(Rth) + 4.127)**2;
const stAt = x => { let n = 0; while (n < NS-1 && XS[n+1] <= x) n++; return n; };
const NP = stAt(0.7);   // the station used for profiles in the Learn blocks
const jAt = y => { let j = 1; while (j < J-2 && Y[j+1] <= y) j++; return j; };
// interpolate a stored field (NS × J) at station n and height y
const fAt = (F, n, y) => { const j = jAt(y), s = Math.max(0, Math.min(1, (y-Y[j])/(Y[j+1]-Y[j]))); return F[n*J+j]*(1-s) + F[n*J+j+1]*s; };
// refinement used by the Build: coarse "RANS-quality" Δ upstream, refined Δ∥ from x = 0.4 to 0.5 on
const XR = .4, DC = .04;
const refined = f => x => x < XR ? DC : x > XR+.1 ? f : DC*(f/DC)**((x-XR)/.1);
const uniform = f => () => f;

// ---------- Block C: a separated shear layer carrying the boundary layer's ν̃ (Lagrangian SA ODE) ----------
// units: ΔU = 1, initial vorticity thickness δ_ω = 1, convection speed U_c = ΔU/2; S = ΔU/δ_ω.
// returns ν_t(x) and the damping ratio D = ν_t (π/h)² / S along x/δ_ω ∈ [0, XL]
// (ν̃ ≫ ν here, so f_v1 ≈ 1 and the molecular viscosity drops out of the source)
function shearLayer(nt0, l, h, XL, M){
  M = M || 400; const out = {x: new Float64Array(M+1), nut: new Float64Array(M+1), D: new Float64Array(M+1), xg: null};
  const S = 1, Uc = .5, dxs = XL/M, sub = 8, f = n => { const o = saPoint(n, S, l); return (o.P - o.D)/Uc; };
  let n = nt0;
  for (let m=0;m<=M;m++){
    if (m) for (let s=0;s<sub;s++){ const hh = dxs/sub, a1 = f(n), a2 = f(n+.5*hh*a1), a3 = f(n+.5*hh*a2), a4 = f(n+hh*a3); n = Math.max(1e-12, n + hh*(a1+2*a2+2*a3+a4)/6); }
    const nut = n*fv1(n);
    out.x[m] = m*dxs; out.nut[m] = nut; out.D[m] = nut*(Math.PI/h)**2/S; if (out.xg === null && out.D[m] < 1) out.xg = out.x[m];
  }
  return out;
}

// ---------- MathML helpers (string builders) ----------
const tg = (k, x) => `<mrow data-t="${k}">${x}</mrow>`;
const mi = (s, k) => k ? `<mi data-t="${k}">${s}</mi>` : `<mi>${s}</mi>`;
const mo = s => `<mo>${s}</mo>`, mn = s => `<mn>${s}</mn>`, mr = x => `<mrow>${x}</mrow>`, mt = s => `<mtext>${s}</mtext>`;
const sb = (b, s) => `<msub>${b}${s}</msub>`, sp = (b, s) => `<msup>${b}${s}</msup>`, ssp = (b, s, p) => `<msubsup>${b}${s}${p}</msubsup>`;
const fr = (a, b) => `<mfrac>${a}${b}</mfrac>`, sq = x => `<msqrt>${x}</msqrt>`, pa = x => `<mo>(</mo>${x}<mo>)</mo>`;
const ub = (x, op, txt) => `<munder><munder><mrow>${x}</mrow><mo stretchy="true">⏟</mo></munder><mtext data-t="${op}" class="opl">${txt}</mtext></munder>`;
const tl = s => `<mover accent="true"><mi>${s}</mi><mo>~</mo></mover>`;
// symbols
const iI = mi('i','i'), jI = mi('j','j');
const U_i = tg('u', sb(mi('u'), iI)), U_j = tg('u', sb(mi('u'), jI));
const dJ = tg('grad', sb(mo('∂'), jI)), dI = tg('grad', sb(mo('∂'), iI));
const GU = tg('gu', sb(mo('∂'), jI) + sb(mi('u'), iI));
const D_ = mi('d','d'), DEL = mi('Δ','Del'), CDES = tg('CD', sb(mi('C'), mt('DES'))), L_ = mi('l','l');
const NT = tg('nt', tl('ν')), NUT = tg('nut', sb(mi('ν'), mi('t'))), NU_ = mi('ν','nu');
const FD = tg('fd', sb(mi('f'), mi('d'))), RD = tg('rd', sb(mi('r'), mi('d'))), KAP = mi('κ','kap');
const ST = tg('St', tl('S')), SV = mi('S','Sv');
const CB1 = tg('cb1', sb(mi('c'), mr(mi('b')+mn(1)))), CW1 = tg('cw1', sb(mi('c'), mr(mi('w')+mn(1)))), CB2 = tg('cb2', sb(mi('c'), mr(mi('b')+mn(2))));
const FW = tg('fw', sb(mi('f'), mi('w'))), FV1 = tg('fv1', sb(mi('f'), mr(mi('v')+mn(1)))), SIG = mi('σ','sig');
const HX = tg('hx', mi('Δ')+mi('x')), HY = tg('hx', mi('Δ')+mi('y')), HZ = tg('hx', mi('Δ')+mi('z'));
const TT = mi('t','t'), DT = tg('dt', mi('Δ')+mi('t')), QQ = mi('q','q');
const NN = tg('N', sb(mi('N'), mi('x'))+mo('×')+sb(mi('N'), mi('y'))+mo('×')+sb(mi('N'), mi('z')));
const SPACE = n => sp(mi('ℝ'), mr((n ? mn(n)+mo('×') : '')+NN));
const ixyz = mi('x','ix')+mi('y','iy')+mi('z','iz');

// ---------- terms: every symbol, what it is and where it lives ----------
const Rn = n => sp('<mi>ℝ</mi>', n), RNX = (n) => sp('<mi>ℝ</mi>', mr((n ? mn(n)+mo('×') : '')+sb(mi('N'),mi('x'))+mo('×')+sb(mi('N'),mi('y'))+mo('×')+sb(mi('N'),mi('z'))));
const Rpos = sb('<mi>ℝ</mi>', mr(mo('&gt;')+mn(0))), Rnn = sb('<mi>ℝ</mi>', mr(mo('≥')+mn(0)));
const FIELD = `<mtext>field: </mtext>${RNX(0)}`;
const Nc = n => sp('<mi>ℝ</mi>', mr((n ? mn(n)+mo('×') : '')+sb(mi('N'), mi('c')))), NcT = ' <mtext>(</mtext><msub><mi>N</mi><mi>c</mi></msub><mo>=</mo><msub><mi>N</mi><mi>x</mi></msub><msub><mi>N</mi><mi>y</mi></msub><msub><mi>N</mi><mi>z</mi></msub><mtext>)</mtext>';
const terms = {
 q: {sym: '<mi>q</mi>', name: 'State', def: 'Everything one cell stores: the three velocity components, the pressure, and the SA variable ν̃. Five numbers per cell.', space: `<mi>q</mi><mo>∈</mo>${RNX(5)}`, col: '--ink'},
 cq: {sym: '<mi>c</mi>', name: 'Component index', def: 'Which of the five stored numbers: 0, 1, 2 = u_x, u_y, u_z; 3 = p; 4 = ν̃.', space: '<mi>c</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mn>4</mn><mo>}</mo>', col: '--ink'},
 ix: {sym: '<mi>x</mi>', name: 'Cell column', def: 'Which cell along the flow, 0 … Nₓ−1. As a subscript it picks the cell.', space: '<mi>x</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>x</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>', col: '--ink'},
 iy: {sym: '<mi>y</mi>', name: 'Cell row', def: 'Which cell away from the wall, 0 … N_y−1. Rows crowd together near the wall.', space: '<mi>y</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>', col: '--ink'},
 iz: {sym: '<mi>z</mi>', name: 'Cell layer', def: 'Which cell across the span, 0 … N_z−1.', space: '<mi>z</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>', col: '--ink'},
 N: {sym: '<msub><mi>N</mi><mi>x</mi></msub><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub>', name: 'Grid size', def: 'Cells along x, y and z. A DDES of a wing easily has 10⁷–10⁸ cells, most of them in the LES region.', space: '<msub><mi>N</mi><mi>x</mi></msub><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>∈</mo><mi>ℕ</mi>', col: '--ink'},
 t: {sym: '<mi>t</mi>', name: 'Time level', def: 'Which time step: 0, Δt, 2Δt, … As a superscript (qᵗ) it is a label, not a power. (The t in ν_t is different: it means "turbulent".)', space: '<mi>t</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mi>Δ</mi><mi>t</mi><mo>,</mo><mn>2</mn><mi>Δ</mi><mi>t</mi><mo>,</mo><mo>…</mo><mo>}</mo>', col: '--c-w'},
 dt: {sym: '<mi>Δ</mi><mi>t</mi>', name: 'Time step', def: 'DDES is unsteady: the eddies in the LES region must be followed in time, so Δt is set by the small LES cells (CFL ≈ 1).', space: `<mi>Δ</mi><mi>t</mi><mo>∈</mo>${Rpos}`, col: '--c-w'},
 i: {sym: '<mi>i</mi>', name: 'Axis index i', def: 'x, y or z: which component (u_i is the velocity along axis i).', space: '<mi>i</mi><mo>∈</mo><mo>{</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>}</mo>', col: '--ink'},
 j: {sym: '<mi>j</mi>', name: 'Axis index j', def: 'x, y or z. Written twice in one term it is summed (Einstein): u_j∂_j = u_x∂_x + u_y∂_y + u_z∂_z.', space: '<mi>j</mi><mo>∈</mo><mo>{</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>}</mo>', col: '--ink'},
 u: {sym: '<msub><mi>u</mi><mi>i</mi></msub>', name: 'Velocity', def: 'Component i of the resolved velocity in the cell. In RANS cells it is the mean flow; in LES cells it also carries the big eddies.', space: `<msub><mi>u</mi><mi>i</mi></msub><mo>∈</mo><mi>ℝ</mi><mo>,</mo><mspace width=".5em"/><mtext>field: </mtext>${RNX(3)}`, col: '--c-u'},
 p: {sym: '<mi>p</mi>', name: 'Pressure', def: 'Kinematic pressure (divided by density). Found every step by a Poisson equation that keeps ∂_j u_j = 0.', space: `<mi>p</mi><mo>∈</mo><mi>ℝ</mi><mo>,</mo><mspace width=".5em"/>${FIELD}`, col: '--c-w'},
 grad: {sym: '<msub><mo>∂</mo><mi>j</mi></msub>', name: 'Partial derivative', def: 'Rate of change along axis j, taken from neighbouring cells (a finite difference).', space: '<msub><mo>∂</mo><mi>j</mi></msub><mo>:</mo><mtext>field → field (linear)</mtext>', col: '--ink'},
 gu: {sym: '<msub><mo>∂</mo><mi>j</mi></msub><msub><mi>u</mi><mi>i</mi></msub>', name: 'Velocity gradient', def: 'How each velocity component changes along each axis: a 3 × 3 matrix per cell. √(∂_j u_i ∂_j u_i) adds up all nine squares: the total shear.', space: `<msub><mo>∂</mo><mi>j</mi></msub><msub><mi>u</mi><mi>i</mi></msub><mo>∈</mo>${Rn(mr(mn(3)+mo('×')+mn(3)))}<mtext> per cell</mtext>`, col: '--c-u'},
 Sv: {sym: '<mi>S</mi>', name: 'Vorticity magnitude', def: 'How fast the fluid spins: |∇ × u|. In a boundary layer it is about ∂U/∂y.', space: `<mi>S</mi><mo>∈</mo>${Rnn}`, col: '--c-u'},
 St: {sym: '<mover accent="true"><mi>S</mi><mo>~</mo></mover>', name: 'Modified vorticity', def: 'S plus a near-wall correction ν̃ f_v2/(κ²l²). Note: l, not d. In LES mode the correction uses the grid length too.', space: `<mover accent="true"><mi>S</mi><mo>~</mo></mover><mo>∈</mo>${Rnn}`, col: '--c-u'},
 Sij: {sym: '<msub><mi>S</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Strain rate', def: 'The stretching part of the velocity gradient: ½(∂_j u_i + ∂_i u_j). Symmetric 3 × 3.', space: `<msub><mi>S</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo>${Rn(mr(mn(3)+mo('×')+mn(3)))}<mtext>, symmetric</mtext>`, col: '--c-u'},
 nt: {sym: '<mover accent="true"><mi>ν</mi><mo>~</mo></mover>', name: 'SA working variable', def: 'The quantity the Spalart–Allmaras model transports. Far from walls it equals ν_t; near the wall it stays linear in d, which is easy to solve for.', space: `<mover accent="true"><mi>ν</mi><mo>~</mo></mover><mo>∈</mo>${Rnn}<mo>,</mo><mspace width=".5em"/>${FIELD}`, col: '--c-nu', op: 'T'},
 nut: {sym: '<msub><mi>ν</mi><mi>t</mi></msub>', name: 'Eddy viscosity', def: 'Extra viscosity standing in for eddies the grid does not carry. RANS: all of them. LES: only the ones smaller than a cell. The t means turbulent.', space: `<msub><mi>ν</mi><mi>t</mi></msub><mo>=</mo><mover accent="true"><mi>ν</mi><mo>~</mo></mover><msub><mi>f</mi><mrow><mi>v</mi><mn>1</mn></mrow></msub><mo>∈</mo>${Rnn}`, col: '--c-nu', op: 'M'},
 nu: {sym: '<mi>ν</mi>', name: 'Molecular viscosity', def: 'The fluid\'s own viscosity: 1.5 × 10⁻⁵ m²/s for air. In the Build, ν = 10⁻⁷ (Re = 10⁷ per unit length).', space: `<mi>ν</mi><mo>∈</mo>${Rpos}<mtext> (constant)</mtext>`, col: '--c-w'},
 d: {sym: '<mi>d</mi>', name: 'Wall distance', def: 'Distance from the cell centre to the nearest wall. Computed once before time stepping (if the mesh does not move).', space: `<mi>d</mi><mo>∈</mo>${Rnn}<mo>,</mo><mspace width=".5em"/>${FIELD}`, col: '--c-rho'},
 Del: {sym: '<mi>Δ</mi>', name: 'Grid width', def: 'One length per cell that says how fine the grid is there. DES and DDES use the largest side: Δ = max(Δx, Δy, Δz).', space: `<mi>Δ</mi><mo>∈</mo>${Rpos}<mo>,</mo><mspace width=".5em"/>${FIELD}`, col: '--c-cs', op: 'G'},
 hx: {sym: '<mi>Δ</mi><mi>x</mi><mo>,</mo><mi>Δ</mi><mi>y</mi><mo>,</mo><mi>Δ</mi><mi>z</mi>', name: 'Cell sides', def: 'The three edge lengths of the cell. Near a wall Δy is tiny (to resolve the steep profile) while Δx and Δz stay large.', space: `<mi>Δ</mi><mi>x</mi><mo>,</mo><mi>Δ</mi><mi>y</mi><mo>,</mo><mi>Δ</mi><mi>z</mi><mo>∈</mo>${Rpos}`, col: '--c-cs', op: 'G'},
 dw: {sym: '<msub><mi>Δ</mi><mi>ω</mi></msub>', name: 'Vorticity-aligned grid width', def: 'Uses only the two cell sides across the spin axis. A long cell along the vortex axis does not count against it.', space: `<msub><mi>Δ</mi><mi>ω</mi></msub><mo>∈</mo>${Rpos}`, col: '--c-cs', op: 'G'},
 nv: {sym: '<msub><mi>n</mi><mi>i</mi></msub>', name: 'Spin direction', def: 'Unit vector along the local vorticity: n_i = ω_i/|ω|. In a 2D shear layer it points along z.', space: `<msub><mi>n</mi><mi>i</mi></msub><mo>∈</mo>${Rn(mn(3))}<mo>,</mo><mspace width=".4em"/><msub><mi>n</mi><mi>i</mi></msub><msub><mi>n</mi><mi>i</mi></msub><mo>=</mo><mn>1</mn>`, col: '--c-u'},
 CD: {sym: '<msub><mi>C</mi><mtext>DES</mtext></msub>', name: 'DES constant', def: '0.65, calibrated so that LES mode decays isotropic turbulence at the right rate (Shur et al. 1999).', space: '<msub><mi>C</mi><mtext>DES</mtext></msub><mo>=</mo><mn>0.65</mn><mo>∈</mo><mi>ℝ</mi>', col: '--c-cs'},
 l: {sym: '<mi>l</mi>', name: 'Model length scale', def: 'The length the SA model uses where plain RANS uses d. Equal to d: RANS. Equal to C_DES Δ: LES (subgrid model).', space: `<mi>l</mi><mo>∈</mo>${Rpos}<mo>,</mo><mspace width=".5em"/><mi>l</mi><mo>≤</mo><mi>d</mi>`, col: '--c-tau', op: 'L'},
 fd: {sym: '<msub><mi>f</mi><mi>d</mi></msub>', name: 'Shielding (delay) function', def: '0 inside an attached boundary layer (stay RANS), 1 elsewhere (LES allowed). Computed from the flow, so the grid cannot fool it.', space: '<msub><mi>f</mi><mi>d</mi></msub><mo>∈</mo><mo>[</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>]</mo>', col: '--c-c', op: 'F'},
 rd: {sym: '<msub><mi>r</mi><mi>d</mi></msub>', name: 'Boundary-layer sensor', def: 'Ratio of the actual viscosity to what a log layer would have at this d. About 1 in the log layer, large near the wall, near 0 outside the layer.', space: `<msub><mi>r</mi><mi>d</mi></msub><mo>∈</mo>${Rnn}`, col: '--c-c', op: 'F'},
 cd1: {sym: '<mn>8</mn>', name: 'Shielding constant', def: 'Sets where f_d switches: f_d = ½ at r_d ≈ 0.10. DDES with SST uses 20 instead (Gritskevich et al. 2012).', space: '<msub><mi>C</mi><mrow><mi>d</mi><mn>1</mn></mrow></msub><mo>=</mo><mn>8</mn><mo>,</mo><mspace width=".4em"/><msub><mi>C</mi><mrow><mi>d</mi><mn>2</mn></mrow></msub><mo>=</mo><mn>3</mn>', col: '--c-c'},
 kap: {sym: '<mi>κ</mi>', name: 'von Kármán constant', def: '0.41. In the log layer the mixing length is κd.', space: '<mi>κ</mi><mo>=</mo><mn>0.41</mn>', col: '--c-w'},
 prod: {sym: '<msub><mi>c</mi><mrow><mi>b</mi><mn>1</mn></mrow></msub><mover accent="true"><mi>S</mi><mo>~</mo></mover><mover accent="true"><mi>ν</mi><mo>~</mo></mover>', name: 'Production', def: 'Shear makes eddy viscosity: proportional to how fast the flow spins and to ν̃ itself.', space: `<mi>P</mi><mo>∈</mo>${Rnn}<mo>,</mo><mspace width=".4em"/><mtext>per cell, nonlinear</mtext>`, col: '--c-f', op: 'T'},
 dest: {sym: '<msub><mi>c</mi><mrow><mi>w</mi><mn>1</mn></mrow></msub><msub><mi>f</mi><mi>w</mi></msub><msup><mrow><mo>(</mo><mover accent="true"><mi>ν</mi><mo>~</mo></mover><mo>/</mo><mi>l</mi><mo>)</mo></mrow><mn>2</mn></msup>', name: 'Destruction', def: 'Walls (and in DES, the grid) kill eddy viscosity. Grows like 1/l²: a shorter l destroys much more.', space: `<mi>D</mi><mo>∈</mo>${Rnn}<mo>,</mo><mspace width=".4em"/><mtext>per cell, nonlinear</mtext>`, col: '--c-eq', op: 'T'},
 diff: {sym: '<mfrac><mn>1</mn><mi>σ</mi></mfrac><mo>[</mo><mo>…</mo><mo>]</mo>', name: 'Diffusion', def: 'ν̃ spreads to neighbouring cells, faster where there is more of it. The c_b2 part makes fronts sharp.', space: '<mtext>field → field, couples neighbours</mtext>', col: '--c-w', op: 'T'},
 cb1: {sym: '<msub><mi>c</mi><mrow><mi>b</mi><mn>1</mn></mrow></msub>', name: 'Production constant', def: '0.1355 (Spalart & Allmaras 1994).', space: '<msub><mi>c</mi><mrow><mi>b</mi><mn>1</mn></mrow></msub><mo>=</mo><mn>0.1355</mn>', col: '--c-f'},
 cw1: {sym: '<msub><mi>c</mi><mrow><mi>w</mi><mn>1</mn></mrow></msub>', name: 'Destruction constant', def: 'c_b1/κ² + (1 + c_b2)/σ ≈ 3.239: chosen so ν̃ = κu_τd balances exactly in the log layer.', space: '<msub><mi>c</mi><mrow><mi>w</mi><mn>1</mn></mrow></msub><mo>≈</mo><mn>3.239</mn>', col: '--c-eq'},
 fw: {sym: '<msub><mi>f</mi><mi>w</mi></msub>', name: 'Destruction shape', def: 'A function of r = ν̃/(S̃κ²l²); equals 1 at r = 1 (log layer) and levels off for large r.', space: '<msub><mi>f</mi><mi>w</mi></msub><mo>:</mo><mo>[</mo><mn>0</mn><mo>,</mo><mn>10</mn><mo>]</mo><mo>→</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>', col: '--c-eq'},
 fv1: {sym: '<msub><mi>f</mi><mrow><mi>v</mi><mn>1</mn></mrow></msub>', name: 'Near-wall damping', def: 'χ³/(χ³ + 7.1³) with χ = ν̃/ν. Close to 1 away from the wall, small in the viscous sublayer.', space: '<msub><mi>f</mi><mrow><mi>v</mi><mn>1</mn></mrow></msub><mo>∈</mo><mo>[</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>)</mo>', col: '--c-nu'},
 sig: {sym: '<mi>σ</mi>', name: 'Diffusion constant', def: '2/3: ν̃ diffuses with coefficient (ν + ν̃)/σ.', space: '<mi>σ</mi><mo>=</mo><mfrac><mn>2</mn><mn>3</mn></mfrac>', col: '--c-w'},
 cb2: {sym: '<msub><mi>c</mi><mrow><mi>b</mi><mn>2</mn></mrow></msub>', name: 'Gradient constant', def: '0.622: weights the (∂ν̃)² term in the diffusion.', space: '<msub><mi>c</mi><mrow><mi>b</mi><mn>2</mn></mrow></msub><mo>=</mo><mn>0.622</mn>', col: '--c-w'},
 Dt: {sym: '<mfrac><mi>D</mi><mrow><mi>D</mi><mi>t</mi></mrow></mfrac>', name: 'Material derivative', def: '∂_t + u_j∂_j: the change seen while riding along with the fluid.', space: '<mfrac><mi>D</mi><mrow><mi>D</mi><mi>t</mi></mrow></mfrac><mo>=</mo><msub><mo>∂</mo><mi>t</mi></msub><mo>+</mo><msub><mi>u</mi><mi>j</mi></msub><msub><mo>∂</mo><mi>j</mi></msub><mspace width=".4em"/><mtext>(field → field)</mtext>', col: '--ink'},
 tau: {sym: '<msubsup><mi>τ</mi><mrow><mi>i</mi><mi>j</mi></mrow><mtext>mod</mtext></msubsup>', name: 'Modelled stress', def: 'The momentum the eddy viscosity moves: −2ν_t S_ij. In RANS cells it is all the turbulent stress; in LES cells only the subgrid part.', space: `<msubsup><mi>τ</mi><mrow><mi>i</mi><mi>j</mi></mrow><mtext>mod</mtext></msubsup><mo>∈</mo>${Rn(mr(mn(3)+mo('×')+mn(3)))}<mtext>, symmetric</mtext>`, col: '--c-nu', op: 'M'},
 res: {sym: '<mo>⟨</mo><msubsup><mi>u</mi><mi>i</mi><mo>″</mo></msubsup><msubsup><mi>u</mi><mi>j</mi><mo>″</mo></msubsup><mo>⟩</mo>', name: 'Resolved stress', def: 'Momentum moved by eddies the grid actually carries: average the product of resolved fluctuations u″ over time. Zero in steady RANS cells.', space: `<mo>⟨</mo><msubsup><mi>u</mi><mi>i</mi><mo>″</mo></msubsup><msubsup><mi>u</mi><mi>j</mi><mo>″</mo></msubsup><mo>⟩</mo><mo>∈</mo>${Rn(mr(mn(3)+mo('×')+mn(3)))}`, col: '--c-f'},
 bl: {sym: '<mi>δ</mi>', name: 'Boundary-layer thickness', def: 'Height where the flow reaches 99 % of the outer speed. About 1 cm at the end of the Build plate.', space: `<mi>δ</mi><mo>∈</mo>${Rpos}`, col: '--ink'},
 kc: {sym: '<msub><mi>k</mi><mi>c</mi></msub>', name: 'Grid cut-off wavenumber', def: 'π/Δ: the smallest eddy a grid can carry is about two cells wide. Smaller ones must be modelled.', space: `<msub><mi>k</mi><mi>c</mi></msub><mo>=</mo><mi>π</mi><mo>/</mo><mi>Δ</mi><mo>∈</mo>${Rpos}`, col: '--c-cs'},
 Ek: {sym: '<mi>E</mi><mo>(</mo><mi>k</mi><mo>)</mo>', name: 'Energy spectrum', def: 'How the turbulent energy is shared between eddy sizes; k = 2π/size. In the inertial range E ∝ k^(−5/3).', space: `<mi>E</mi><mo>:</mo>${Rpos}<mo>→</mo>${Rnn}`, col: '--c-f'},
 G: {sym: '<mi>G</mi>', name: 'Grid-width map', def: 'Turns the three sides of every cell into one length Δ. Pure geometry: computed once for a fixed mesh. (N_c = NₓN_yN_z cells.)', space: `<mi>G</mi><mo>:</mo>${Nc(3)}<mo>→</mo>${Nc(0)}`, col: '--c-cs', op: 'G'},
 F: {sym: '<mi>F</mi>', name: 'Shielding map', def: 'Looks at the flow in each cell (ν_t, shear, d) and answers: is this inside an attached boundary layer? Output f_d ∈ [0, 1]. (N_c = NₓN_yN_z cells.)', space: `<mi>F</mi><mo>:</mo>${Nc(5)}<mo>→</mo>${sp('<mrow><mo>[</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>]</mo></mrow>', sb(mi('N'), mi('c')))}`, col: '--c-c', op: 'F'},
 L: {sym: '<mi>L</mi>', name: 'Length switch', def: 'Picks the length the model uses in each cell: the wall distance (RANS) or the grid length (LES), blended by f_d.', space: `<mi>L</mi><mo>:</mo><mo>(</mo><mi>d</mi><mo>,</mo><mi>Δ</mi><mo>,</mo><msub><mi>f</mi><mi>d</mi></msub><mo>)</mo><mo>↦</mo><mi>l</mi><mo>,</mo><mspace width=".4em"/><mtext>cell by cell</mtext>`, col: '--c-tau', op: 'L'},
 T: {sym: '<mi>T</mi>', name: 'SA transport', def: 'Advances ν̃ one time step: carried by the flow, made by shear, destroyed with length l, spread by diffusion. (N_c = NₓN_yN_z cells.)', space: `<mi>T</mi><mo>:</mo>${Nc(5)}<mo>×</mo>${Nc(0)}<mo>→</mo>${Nc(0)}`, col: '--c-nu', op: 'T'},
 M: {sym: '<mi>M</mi>', name: 'Momentum + pressure step', def: 'The flow solver: advances u_i and p with viscosity ν + ν_t. The only way the turbulence model touches the flow. (N_c = NₓN_yN_z cells.)', space: `<mi>M</mi><mo>:</mo>${Nc(5)}<mo>×</mo>${Nc(0)}<mo>→</mo>${Nc(5)}`, col: '--c-u', op: 'M'},
};

terms.utau = {sym: '<msub><mi>u</mi><mi>τ</mi></msub>', name: 'Friction velocity', def: '√(wall shear stress / density): the velocity scale of the wall layer. Log layer: ∂U/∂y = u_τ/(κd).', space: `<msub><mi>u</mi><mi>τ</mi></msub><mo>∈</mo>${Rpos}`, col: '--c-u'};
terms.Rij = {sym: '<mo>⟨</mo><msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup><msubsup><mi>u</mi><mi>j</mi><mo>′</mo></msubsup><mo>⟩</mo>', name: 'Total turbulent stress', def: 'All the momentum the turbulence moves (the Reynolds stress). Modelled part + resolved part; their split is what DDES changes from place to place.', space: `<mo>⟨</mo><msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup><msubsup><mi>u</mi><mi>j</mi><mo>′</mo></msubsup><mo>⟩</mo><mo>∈</mo>${Rn(mr(mn(3)+mo('×')+mn(3)))}<mtext>, symmetric</mtext>`, col: '--ink'};
const UT = tg('utau', sb(mi('u'), mi('τ')));
const SIJ = tg('Sij', sb(mi('S'), mr(iI+jI)));
const qt = sp(QQ, TT);
const idxRow = (k, sym, rg, im) => `<div class="ir" data-t="${k}"><span class="is"><math>${sym}</math></span><span class="rg"><math>${rg}</math></span><span class="im">${im}</span></div>`;
const dstep = (k, m, p) => `<div class="dstep"><span class="k">${k}</span><div class="dm"><math display="block">${m}</math></div><p>${p}</p></div>`;
const deep = (n, steps) => `<details class="deep"><summary>Going a bit deeper <span class="note">· ${n} steps</span></summary>${steps}</details>`;
const range = (a, b) => `<mn>${a}</mn><mo>,</mo><mo>…</mo><mo>,</mo>${b}`;
const MAXD = mr(mi('max')+pa(HX+mo(',')+HY+mo(',')+HZ));
const LMIN = mr(mi('min')+pa(D_+mo(',')+CDES+DEL));
const LDD = mr(D_+mo('−')+FD+mi('max')+pa(mn(0)+mo(',')+D_+mo('−')+CDES+DEL));
const FDEQ = mr(mn(1)+mo('−')+mi('tanh')+pa(sp(pa(tg('cd1', mn(8))+RD), mn(3))));
const RDEQ = fr(mr(NUT+mo('+')+NU_), mr(sp(KAP, mn(2))+sp(D_, mn(2))+sq(GU+sb(mo('∂'), jI)+sb(mi('u'), iI))));
const PROD = tg('prod', CB1+ST+NT), DEST = tg('dest', CW1+FW+sp(pa(fr(NT, L_)), mn(2)));
const DIFF = tg('diff', fr(mn(1), SIG)+mo('[')+dJ+pa(pa(NU_+mo('+')+NT)+dJ+NT)+mo('+')+CB2+dJ+NT+dJ+NT+mo(']'));
const DNDT = tg('Dt', fr(mr(mi('D')+NT), mr(mi('D')+TT)));
const DOMEGA = sq(sp(sb(mi('n'), mi('x')), mn(2))+HY+HZ+mo('+')+sp(sb(mi('n'), mi('y')), mn(2))+HZ+HX+mo('+')+sp(sb(mi('n'), mi('z')), mn(2))+HX+HY);

const blocks = [
{ key: '0', title: 'The objects', note: 'what goes in, what comes out', html: `<div class="eqhero">
  <math display="block">${tg('q', ssp(mi('q'), mr(mi('c','cq')+ixyz), TT))}<mo>∈</mo>${SPACE(5)}<mspace width="2em"/>${sb(D_, ixyz)}<mo>,</mo><mspace width=".3em"/>${sb(DEL, ixyz)}<mo>∈</mo>${SPACE(0)}</math>
  <math display="block" class="sm">${L_}<mo>=</mo>${mi('L','L')}<mo>(</mo>${D_}<mo>,</mo>${mi('G','G')}<mo>(</mo>${HX}<mo>,</mo>${HY}<mo>,</mo>${HZ}<mo>)</mo><mo>,</mo>${mi('F','F')}<mo>(</mo>${qt}<mo>,</mo>${D_}<mo>)</mo><mo>)</mo></math>
  <math display="block" class="sm">${NUT}<mo>=</mo>${FV1}<mo>⋅</mo>${mi('T','T')}<mo>(</mo>${qt}<mo>,</mo>${L_}<mo>)</mo><mspace width="2em"/>${sp(QQ, mr(TT+mo('+')+DT))}<mo>=</mo>${mi('M','M')}<mo>(</mo>${qt}<mo>,</mo>${NUT}<mo>)</mo></math>
</div>
<div class="idx"><span class="eyebrow">Every index</span>
 ${idxRow('cq', '<mi>c</mi>', range(0, '<mn>4</mn>'), 'Which stored number: 0–2 velocity u<sub>x</sub>, u<sub>y</sub>, u<sub>z</sub>; 3 pressure p; 4 the SA variable ν̃.')}
 ${idxRow('ix', '<mi>x</mi>', range(0, '<msub><mi>N</mi><mi>x</mi></msub><mo>−</mo><mn>1</mn>'), 'Cell column, along the flow.')}
 ${idxRow('iy', '<mi>y</mi>', range(0, '<msub><mi>N</mi><mi>y</mi></msub><mo>−</mo><mn>1</mn>'), 'Cell row, away from the wall. Rows are packed tightly near the wall.')}
 ${idxRow('iz', '<mi>z</mi>', range(0, '<msub><mi>N</mi><mi>z</mi></msub><mo>−</mo><mn>1</mn>'), 'Cell layer, across the span.')}
 ${idxRow('t', '<mi>t</mi>', '<mn>0</mn><mo>,</mo><mi>Δ</mi><mi>t</mi><mo>,</mo><mn>2</mn><mi>Δ</mi><mi>t</mi><mo>,</mo><mo>…</mo>', 'Time level. qᵗ is a label, not a power. DDES is always unsteady: the LES regions hold moving eddies. (In ν<sub>t</sub> the t means “turbulent”.)')}
 ${idxRow('i', '<mi>i</mi>', '<mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi>', 'Free axis index: which component (u<sub>i</sub>, ∂<sub>i</sub>p). An equation with a free i is three equations.')}
 ${idxRow('j', '<mi>j</mi>', '<mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi>', 'Summed axis index (Einstein): appears twice in a term → add x, y, z. u<sub>j</sub>∂<sub>j</sub>ν̃ = u<sub>x</sub>∂<sub>x</sub>ν̃ + u<sub>y</sub>∂<sub>y</sub>ν̃ + u<sub>z</sub>∂<sub>z</sub>ν̃.')}
</div>
<div class="dims">
 <div class="dim"><b>Fix c, x, y, z</b><math>${sb(mi('q'), mr(mi('c','cq')+ixyz))}<mo>∈</mo><mi>ℝ</mi></math><span>one number, e.g. ν̃ in one cell</span></div>
 <div class="dim"><b>Fix x, y, z</b><math>${sb(mi('q'), mi('c','cq'))}<mo>∈</mo>${Rn(mn(5))}</math><span>one cell: u<sub>x</sub>, u<sub>y</sub>, u<sub>z</sub>, p, ν̃</span></div>
 <div class="dim"><b>Nothing fixed (the state)</b><math>${mi('q','q')}<mo>∈</mo>${SPACE(5)}</math><span>400 × 200 × 100 cells → 40 000 000 numbers</span></div>
 <div class="dim"><b>Geometry, computed once</b><math>${D_}<mo>,</mo>${DEL}<mo>∈</mo>${SPACE(0)}</math><span>two more numbers per cell; fixed while the mesh does not move</span></div>
</div>
<span class="eyebrow">What the operators do, two cells at a time</span>
<figure class="viz"><div class="scrollx"><canvas id="ddes-opviz" data-w="880" data-h="372" aria-label="Animated walkthrough: for a cell inside an attached boundary layer and a cell in a separated shear layer, G finds the grid width, F the shielding, L the length, T the eddy-viscosity balance and M the modelled stress, for DES97 and DDES"></canvas></div>
  <div class="opctl"><button class="b" id="ddes-opplay">Pause</button><div id="ddes-opsteps" class="btns"></div></div>
  <p class="opcap" id="ddes-opcap"></p></figure>
<aside class="insp" data-terms="G,F,L,T,M,q,d,Del,l,fd,nut"></aside>
${deep(3,
  dstep('M', `${tg('grad', sb(mo('∂'), TT))}${U_i}<mo>+</mo>${U_j}${dJ}${U_i}<mo>=</mo><mo>−</mo>${dI}${mi('p','p')}<mo>+</mo>${dJ}<mo>[</mo><mn>2</mn>${pa(NU_+mo('+')+NUT)}${SIJ}<mo>]</mo><mo>,</mo><mspace width="1em"/>${dJ}${U_j}<mo>=</mo><mn>0</mn>`,
    'M is an ordinary incompressible Navier–Stokes step. The turbulence model enters only through ν + ν<sub>t</sub>: the same code runs RANS cells and LES cells. The pressure keeps ∂<sub>j</sub>u<sub>j</sub> = 0.') +
  dstep('T', `${NUT}<mo>=</mo>${NT}${FV1}<mo>,</mo><mspace width="1em"/>${FV1}<mo>=</mo>${fr(sp(mi('χ'), mn(3)), mr(sp(mi('χ'), mn(3))+mo('+')+sp(mn('7.1'), mn(3))))}<mo>,</mo><mspace width="1em"/><mi>χ</mi><mo>=</mo>${fr(NT, NU_)}`,
    'Why carry ν̃ and not ν<sub>t</sub>? Near the wall ν<sub>t</sub> falls off steeply, which is hard to solve accurately. ν̃ stays close to κu<sub>τ</sub>d right down to the wall; f<sub>v1</sub> does the damping.') +
  dstep('d', `${D_}${pa(mi('𝐱'))}<mo>=</mo>${sb(mi('min'), mr(sb(mi('𝐱'), mi('w'))+mo('∈')+mt('wall')))}<mo>|</mo><mi>𝐱</mi><mo>−</mo>${sb(mi('𝐱'), mi('w'))}<mo>|</mo><mspace width="1em"/><mo>⇔</mo><mspace width="1em"/>${sq(sb(mo('∂'), jI)+D_+sb(mo('∂'), jI)+D_)}<mo>=</mo><mn>1</mn><mo>,</mo><mspace width=".5em"/>${D_}<mo>=</mo><mn>0</mn><mtext> on walls</mtext>`,
    'The wall distance is pure geometry. Codes find it with a search tree over wall faces or by solving the Eikonal equation on the right; on a fixed mesh it is done once, on a moving mesh every step.'))}` },

{ key: 'A', title: 'One model, two roles', note: 'DES97: the length decides RANS or LES', html: `<div class="eqhero">
  <math display="block">${DNDT}<mo>=</mo>${ub(PROD, 'prod', 'T: production')}<mo>−</mo>${ub(DEST, 'dest', 'T: destruction')}<mo>+</mo>${ub(DIFF, 'diff', 'T: diffusion')}</math>
  <math display="block" class="sm">${tg('l', sb(mi('l'), mt('DES')))}<mo>=</mo>${ub(LMIN, 'L', 'L: the shorter one wins')}<mo>,</mo><mspace width="1.2em"/>${DEL}<mo>=</mo>${ub(MAXD, 'G', 'G: the largest side')}</math>
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="ddes-aviz" data-w="460" data-h="440" aria-label="A column of cells above a wall in 3D: cells where the wall distance exceeds C_DES times the grid width switch to LES (orange); below, the length scale and the eddy-viscosity profile computed by the boundary-layer solver; drag to rotate"></canvas>
    <div class="lg"><span style="color:var(--c-f)"><i class="ln"></i>RANS mode (l = d)</span><span style="color:var(--c-eq)"><i class="ln"></i>LES mode (l = C<sub>DES</sub>Δ)</span><span style="color:var(--c-tau)"><i class="ln"></i>length l</span><span class="note">drag to rotate</span></div>
    <div class="ctl"><label for="ddes-adel" class="sym" style="color:var(--c-cs)">Δ∥/δ</label><input type="range" id="ddes-adel" min="0.1" max="2" step="0.05" value="0.3"><output id="ddes-adelv">0.30</output></div>
    <div class="note" id="ddes-acap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="T,L,G,prod,dest,diff,nt,nut,l,d,Del,hx,CD,St,cb1,cw1,fw,sig,cb2,Dt,j"></aside>
</div>
${deep(3,
  dstep('1', `${CB1}${sp(UT, mn(2))}<mo>−</mo>${CW1}${sp(KAP, mn(2))}${sp(UT, mn(2))}<mo>+</mo>${fr(mr(pa(mn(1)+mo('+')+CB2)+sp(KAP, mn(2))+sp(UT, mn(2))), SIG)}<mo>=</mo><mn>0</mn><mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${CW1}<mo>=</mo>${fr(CB1, sp(KAP, mn(2)))}<mo>+</mo>${fr(mr(mn(1)+mo('+')+CB2), SIG)}`,
    'RANS role. Put ν̃ = κu<sub>τ</sub>d and S̃ = u<sub>τ</sub>/(κd) (the log layer) into the equation: production, destruction and diffusion are each a constant times u<sub>τ</sub>². They cancel only if c<sub>w1</sub> ≈ 3.239. That is how the wall distance d got into the model.') +
  dstep('2', `${CB1}${SV}${NT}<mo>=</mo>${CW1}${FW}${sp(pa(fr(NT, mr(CDES+DEL))), mn(2))}<mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${NUT}<mo>≈</mo><mn>0.042</mn><mspace width=".2em"/>${SV}${sp(DEL, mn(2))}<mo>=</mo>${sp(pa(mn('0.20')+DEL), mn(2))}${SV}`,
    'LES role. Far from walls, put l = C<sub>DES</sub>Δ and let production balance destruction (local equilibrium). Solving it with the SA constants gives the Smagorinsky subgrid model with C<sub>s</sub> ≈ 0.20 (computed here; f<sub>w</sub> ≈ 0.42 at the balance). Same equation, new role.') +
  dstep('3', `${D_}<mo>&gt;</mo>${CDES}${DEL}<mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${fr(tg('dest', mi('D')), tg('dest', sb(mi('D'), mt('RANS'))))}<mo>=</mo>${sp(pa(fr(D_, mr(CDES+DEL))), mn(2))}<mo>&gt;</mo><mn>1</mn>`,
    'The trap: refine Δx and Δz inside an attached boundary layer (δ/3, say) and the switch moves inside it. Destruction jumps by (d/l)², ν̃ and the modelled stress fall, but the grid is still far too coarse to carry the eddies that should replace them. This is <b>modelled-stress depletion</b>: skin friction drops, and under an adverse pressure gradient the flow can separate early (grid-induced separation).'))}` },

{ key: 'B', title: 'DDES: shield the boundary layer', note: 'the flow decides, not the grid', html: `<div class="eqhero">
  <math display="block">${tg('l', sb(mi('l'), mt('DDES')))}<mo>=</mo>${ub(LDD, 'L', 'L: subtract only where f_d = 1')}</math>
  <math display="block" class="sm">${FD}<mo>=</mo>${ub(FDEQ, 'F', 'F: 0 inside, 1 outside the layer')}<mo>,</mo><mspace width="1.2em"/>${RD}<mo>=</mo>${ub(RDEQ, 'F', 'F: ≈ 1 in the log layer')}</math>
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="ddes-bviz" data-w="460" data-h="440" aria-label="The shielding function f_d against r_d, and r_d, f_d and the eddy viscosity across a boundary layer computed with RANS, DES97 and DDES"></canvas>
    <div class="lg"><span style="color:var(--c-f)"><i class="ln dash"></i>RANS</span><span style="color:var(--c-eq)"><i class="ln"></i>DES97</span><span style="color:var(--c-c)"><i class="ln"></i>DDES</span></div>
    <div class="ctl3"><label for="ddes-bdel" class="sym" style="color:var(--c-cs)">Δ∥/δ</label><input type="range" id="ddes-bdel" min="0.1" max="2" step="0.05" value="0.3"><output id="ddes-bdelv">0.30</output>
      <label for="ddes-bcd" class="sym" style="color:var(--c-c)">C<sub>d1</sub></label><input type="range" id="ddes-bcd" min="2" max="24" step="1" value="8"><output id="ddes-bcdv">8</output></div>
    <div class="note" id="ddes-bcap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="F,L,fd,rd,cd1,nut,nu,kap,d,gu,i,j,l,Del,CD"></aside>
</div>
${deep(3,
  dstep('1', `${NUT}<mo>=</mo>${KAP}${UT}${D_}<mo>,</mo><mspace width=".6em"/>${sq(GU+sb(mo('∂'), jI)+sb(mi('u'), iI))}<mo>≈</mo>${fr(UT, mr(KAP+D_))}<mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${RD}<mo>≈</mo><mn>1</mn><mo>,</mo><mspace width=".6em"/>${FD}<mo>=</mo><mn>1</mn><mo>−</mo><mi>tanh</mi><mo>(</mo><mn>512</mn><mo>)</mo><mo>≈</mo><mn>0</mn>`,
    'Why r<sub>d</sub> is a boundary-layer sensor: the denominator is what a log layer would have (mixing length κd, squared, times the shear). In the log layer numerator and denominator match. Closer to the wall ν makes r<sub>d</sub> larger: still RANS.') +
  dstep('2', `${NUT}<mo>→</mo><mn>0</mn><mspace width=".6em"/><mtext>or</mtext><mspace width=".6em"/>${D_}<mo>≫</mo><mi>δ</mi><mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${RD}<mo>≪</mo><mn>0.1</mn><mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${FD}<mo>→</mo><mn>1</mn>`,
    'At the edge of the layer ν<sub>t</sub> drops while there is still shear; in a separated shear layer d is large. Either way r<sub>d</sub> is tiny and f<sub>d</sub> = 1: l becomes the DES97 min(d, C<sub>DES</sub>Δ) and LES may start.') +
  dstep('3', `${FD}<mo>=</mo>${FD}${pa(NUT+mo(',')+NU_+mo(',')+D_+mo(',')+GU)}<mspace width="1em"/><mtext>no </mtext>${DEL}<mtext> inside</mtext>`,
    'The fix in one line: f<sub>d</sub> reads the flow, not the grid, so refining Δx inside an attached layer no longer depletes it. The price: DDES keeps any attached layer in RANS however fine the grid, so it never becomes wall-resolved LES. IDDES (Shur et al. 2008) adds a wall-modelled LES branch for that.'))}` },

{ key: 'C', title: 'Grid width, grey area, who carries the stress', note: 'modelled where, resolved where', html: `<div class="eqhero">
  <math display="block">${tg('Rij', mo('⟨')+ssp(mi('u'), iI, mo('′'))+ssp(mi('u'), jI, mo('′'))+mo('⟩'))}<mo>≈</mo>${ub(tg('tau', mo('−')+mn(2)+NUT+SIJ), 'M', 'M: modelled (ν_t)')}<mo>+</mo>${ub(tg('res', mo('⟨')+ssp(mi('u'), iI, mo('″'))+ssp(mi('u'), jI, mo('″'))+mo('⟩')), 'res', 'resolved: eddies on the grid')}</math>
  <math display="block" class="sm">${tg('Del', sb(mi('Δ'), mt('max')))}<mo>=</mo>${ub(MAXD, 'G', 'G: DES97, DDES')}<mo>,</mo><mspace width="1.2em"/>${tg('dw', sb(mi('Δ'), mi('ω')))}<mo>=</mo>${ub(DOMEGA, 'G', 'G: only the sides across the spin axis')}</math>
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="ddes-cviz" data-w="460" data-h="440" aria-label="A separated shear layer leaving a step in 3D: the eddy viscosity carried from the boundary layer decays along it; resolved rollers appear only where it has dropped enough. Below: the decay and the grey area for the chosen grid width"></canvas>
    <div class="btns"><button class="b pri" id="ddes-cmax">Δ<sub>max</sub></button><button class="b" id="ddes-com">Δ<sub>ω</sub></button></div>
    <div class="ctl3"><label for="ddes-ch" class="sym" style="color:var(--c-cs)">Δx/δ<sub>ω</sub></label><input type="range" id="ddes-ch" min="0.04" max="0.3" step="0.01" value="0.1"><output id="ddes-chv">0.10</output>
      <label for="ddes-ca" class="sym" style="color:var(--c-cs)">Δz/Δx</label><input type="range" id="ddes-ca" min="1" max="8" step="0.5" value="4"><output id="ddes-cav">4.0</output></div>
    <div class="note" id="ddes-ccap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="G,Del,dw,hx,nv,M,tau,res,Rij,nut,Sij,kc,CD"></aside>
</div>
${deep(3,
  dstep('1', `${tg('Ek', mi('E')+pa(mi('k')))}<mo>=</mo>${sb(mi('C'), mi('K'))}${sp(mi('ε'), fr(mn(2), mn(3)))}${sp(mi('k'), mr(mo('−')+fr(mn(5), mn(3))))}<mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${sb(mi('k'), mt('sgs'))}<mo>=</mo>${ssp(mo('∫'), tg('kc', sb(mi('k'), mi('c'))), mi('∞'))}${tg('Ek', mi('E'))}<mi>d</mi><mi>k</mi><mo>=</mo>${fr(mn(3), mn(2))}${sb(mi('C'), mi('K'))}${sp(mi('ε'), fr(mn(2), mn(3)))}${sp(tg('kc', sb(mi('k'), mi('c'))), mr(mo('−')+fr(mn(2), mn(3))))}`,
    'Who carries what. In an LES cell only eddies smaller than about two cells (k > k<sub>c</sub> = π/Δ) are modelled; with Kolmogorov’s spectrum (C<sub>K</sub> ≈ 1.5) their energy scales like Δ<sup>2/3</sup>: halve Δ and it drops by 2<sup>2/3</sup> ≈ 1.6×. In a RANS cell (f<sub>d</sub> = 0) everything is modelled and the resolved stress is ≈ 0.') +
  dstep('2', `${fr(mr(mi('d')+NT), mr(mi('d')+TT))}<mo>≈</mo>${CB1}${SV}${NT}<mo>−</mo>${CW1}${FW}${fr(sp(NT, mn(2)), sp(pa(CDES+DEL), mn(2)))}<mo>,</mo><mspace width="1em"/><mtext>small eddies survive if </mtext>${NUT}${sp(pa(fr(mi('π'), DEL)), mn(2))}<mo>&lt;</mo>${SV}`,
    'The grey area. A separating boundary layer brings RANS-level ν̃ into the shear layer. In LES mode it decays (left), but until it has, grid-scale eddies are damped faster than the shear can make them (right, a time-scale estimate). The canvas solves exactly this along the layer.') +
  dstep('3', `${sb(DEL, mt('max'))}<mo>=</mo>${HZ}<mspace width=".6em"/><mtext>(long cells along z)</mtext><mspace width="1em"/><mo>vs</mo><mspace width="1em"/>${tg('dw', sb(mi('Δ'), mi('ω')))}<mo>=</mo>${sq(HX+HY)}<mspace width=".6em"/><mtext>for </mtext>${tg('nv', sb(mi('n'), iI))}<mo>=</mo><mo>(</mo><mn>0</mn><mo>,</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>)</mo>`,
    'The fixes change only G. Δ<sub>ω</sub> (Chauvet, Deck &amp; Jacquin 2007) ignores the cell side along the spin axis, so spanwise-stretched cells no longer inflate ν<sub>t</sub>. Shur et al. (2015) add Δ̃<sub>SLA</sub>, which also lowers Δ where the flow is still quasi-2D.'))}` },
];

const checks = {
 '0': [
  ['How many numbers does one cell of the DDES state hold?', ['3: the velocity', '5: u_x, u_y, u_z, p and ν̃', '19'], 1, 'Three velocity components, the pressure and the one SA variable ν̃. The geometry (d, Δ) is stored too, but it never changes on a fixed mesh.'],
  ['Which of these needs only the mesh, not the flow?', ['G (the grid width Δ) and the wall distance d', 'F (the shielding f_d)', 'T (the SA step)'], 0, 'Δ and d are geometry: computed once before the first time step. F and T read the flow, so they run every step.'],
  ['Which map is the only one that changes the velocity?', ['L', 'T', 'M'], 2, 'L only picks a length and T only updates ν̃. The turbulence model touches the flow solely through ν_t inside M.'],
  ['Cell A sits halfway up an attached boundary layer whose wall-parallel spacing is δ/3. What do DES97 and DDES do there?', ['Both stay RANS', 'DES97 switches to LES; DDES stays RANS because f_d ≈ 0', 'Both switch to LES'], 1, 'd = δ/2 > C_DES Δ ≈ 0.2δ, so DES97 picks the grid length. DDES first asks f_d, which reads “attached boundary layer” and keeps l = d.'],
  ['The mesh moves every step (a deploying flap). What extra cost appears?', ['d must be recomputed every step: a global nearest-wall search', 'Δt must double', 'Nothing changes'], 0, 'On a fixed mesh d is computed once. On a moving mesh the nearest wall changes, so the global search (or Eikonal solve) repeats each step.'],
 ],
 A: [
  ['With l = min(d, C_DES Δ), where does a cell run in LES mode?', ['Where d > C_DES Δ: far from the wall compared with the grid', 'Where d < C_DES Δ', 'Only in the wake'], 0, 'The shorter length wins. Far from walls (or on a fine grid) the grid length C_DES Δ is shorter, and the model acts as a subgrid model.'],
  ['The length l is halved, ν̃ unchanged. What happens to destruction?', ['It halves', 'It grows 4×', 'It is unchanged'], 1, 'Destruction is c_w1 f_w (ν̃/l)²: half the length, four times the destruction (f_w changes a little too).'],
  ['In LES mode, what does the SA model effectively become?', ['A Smagorinsky-like subgrid model, ν_t ≈ (0.2Δ)² S', 'A wall function', 'A laminar flow'], 0, 'With production = destruction and l = C_DES Δ, ν_t is proportional to S Δ²: the Smagorinsky form.'],
  ['DES97 on a grid with Δx = Δz = 0.2δ inside an attached layer. What happens?', ['Resolved eddies take over the lost stress at once', 'The modelled stress drops, but the grid cannot carry the eddies that should replace it: skin friction falls (MSD)', 'Nothing changes'], 1, 'The switch moved inside the layer; ν̃ is destroyed there, but cells of δ/5 are far too coarse for near-wall eddies. Total stress is lost.'],
  ['Why is Δ the largest side of the cell, not the smallest?', ['So thin near-wall cells (tiny Δy) do not trigger LES: only the coarse wall-parallel sides count', 'It is cheaper to compute', 'Smagorinsky requires it'], 0, 'RANS meshes have Δy ≪ Δx near walls. With the smallest side, every near-wall cell would switch to LES. Δ_max keeps them RANS unless Δx and Δz are refined too.'],
 ],
 B: [
  ['In the log layer, r_d is about…', ['0', '1', '100'], 1, 'ν_t = κu_τd and the shear is u_τ/(κd), so r_d = 1 and f_d = 1 − tanh(512) ≈ 0: shielded.'],
  ['f_d = 1 means…', ['RANS is forced', 'The DES97 choice is allowed: LES wherever C_DES Δ < d', 'The flow is laminar'], 1, 'With f_d = 1, l = d − max(0, d − C_DES Δ) = min(d, C_DES Δ): exactly DES97.'],
  ['Why does DDES resist refining the grid inside the boundary layer?', ['Because f_d depends on the flow (ν_t, shear, d), not on Δ', 'Because Δ is ignored altogether', 'Because C_DES is larger'], 0, 'Refining Δ changes C_DES Δ, but inside the layer f_d ≈ 0 multiplies it away.'],
  ['Raising the constant 8 to 20 does what?', ['Shields more: a thicker part of the outer layer stays RANS', 'Shields less', 'Nothing'], 0, 'f_d = 1 − tanh((C r_d)³): a larger C makes f_d reach 0 at smaller r_d, i.e. further out in the layer.'],
  ['Far from walls in a separated shear layer, f_d is…', ['≈ 1, because d is large so r_d ≈ 0', '≈ 0', 'Undefined'], 0, 'd² in the denominator makes r_d tiny far from walls: f_d = 1 and LES runs as in DES97.'],
 ],
 C: [
  ['Which grid width do DES97 and DDES use?', ['Δ_max = max(Δx, Δy, Δz)', 'Δ_vol = (ΔxΔyΔz)^(1/3)', 'Δ_ω'], 0, 'Δ_max: the safe choice for walls. Δ_ω and Δ_SLA came later to speed up the switch in shear layers.'],
  ['A shear-layer cell is made 4× longer along z, the spin axis. Which Δ grows with it?', ['Δ_max', 'Δ_ω', 'Neither'], 0, 'Δ_max = Δz now. Δ_ω = √(ΔxΔy) ignores the side along the vortex axis, so it does not change.'],
  ['What is the grey area?', ['Just after the RANS→LES switch: the modelled stress is still high or already gone, and resolved eddies have not grown yet', 'The viscous sublayer', 'A plotting artefact'], 0, 'Neither modelled nor resolved stress is right there. It delays the shear-layer roll-up and shifts reattachment.'],
  ['In an LES cell, halving Δ does what to the modelled energy?', ['Halves it', 'Cuts it by about 2^(2/3) ≈ 1.6×', 'Nothing'], 1, 'With E ∝ k^(−5/3), the energy above k_c = π/Δ scales like Δ^(2/3).'],
  ['In a RANS cell (f_d = 0), how big is the resolved stress ⟨u″u″⟩?', ['≈ 0: the solution there is (nearly) steady, so all turbulent stress is modelled', 'Most of the stress', 'Exactly half'], 0, 'RANS cells carry the mean flow; the eddy viscosity stands in for all the turbulence.'],
 ],
};
const quiz = [
 ['What problem did DDES fix in the original DES (1997)?', ['A grid refined inside an attached boundary layer switched it to LES too early: modelled-stress depletion and grid-induced separation', 'Slow convergence of RANS', 'Shock waves'], 0, 'Spalart et al. (2006) added f_d so the switch depends on the flow, not only on the grid.'],
 ['Why is DDES far cheaper than wall-resolved LES at flight Reynolds numbers?', ['Attached boundary layers stay RANS on wall-parallel spacings of order δ; only separated regions need LES cells', 'It takes larger time steps everywhere', 'It skips the pressure equation'], 0, 'Wall-resolved LES needs cells set by viscous units near every wall (N ∝ Re^(13/7)); DDES does not.'],
 ['Which input does DDES need that a plain Navier–Stokes solver does not?', ['The wall distance d in every cell', 'The pressure', 'The velocity gradient'], 0, 'd sets the RANS length and r_d. It needs a global nearest-wall search, unlike the local stencils of the rest of the solver.'],
 ['A smooth wing has a thin separation bubble under an adverse pressure gradient. What does DDES give there?', ['About what its RANS model gives: the bubble sits in the shielded region', 'An LES-quality answer', 'No answer at all'], 0, 'DDES is “RANS where attached”. Mild, thin separation inside the shield is predicted only as well as Spalart–Allmaras predicts it.'],
 ['Why must DDES run unsteady with a small Δt, although its boundary layers are RANS?', ['Its LES regions carry moving eddies, and the small LES cells set Δt', 'RANS needs small steps', 'The wall distance requires it'], 0, 'One time step serves all cells; the finest LES cells and the eddy time scales set it.'],
 ['Right after a sharp edge, a DDES shows delayed, 2D-looking rollers. Most likely cause?', ['The grey area: ν_t brought from the RANS layer is still too high; Δ_ω or Δ_SLA, or finer cells, help', 'Time step too small', 'C_DES too small'], 0, 'High inherited ν_t damps the small eddies until it decays, so the shear layer stays quasi-laminar for a while.'],
 ['You refine the grid everywhere (Δ → 0). What does the shielded boundary layer become?', ['Still RANS: f_d ≈ 0 does not depend on Δ, so DDES does not turn into wall-resolved LES', 'Wall-resolved LES automatically', 'DNS'], 0, 'That is why IDDES adds a wall-modelled LES branch: DDES alone keeps attached layers in RANS.'],
];
const build = {
 intro: 'Put the steps of one DDES update in order. When it is right, your solver marches a real turbulent boundary layer down a 3D plate whose grid you can refine, with DES97 and DDES side by side.',
 html: `<div class="scrollx"><canvas class="sim" id="ddes-sim" data-w="760" data-h="430" aria-label="Your DDES solver: a flat plate in 3D with its grid; the side face shows where DES97 and DDES run RANS or LES; right: skin friction along the plate and the modelled stress profile; drag to rotate"></canvas></div>
  <div class="btns" id="ddes-fields"><button class="b pri" data-f="0">DES97: RANS / LES</button><button class="b" data-f="1">DDES: f<sub>d</sub></button><button class="b" data-f="2">DDES: RANS / LES</button><button class="b" data-f="3">ν<sub>t</sub> lost by DES97</button></div>
  <div class="row"><label for="ddes-del">Δx = Δz in the refined zone = <span id="ddes-delv">0.30</span> δ<sub>ref</sub></label><input type="range" id="ddes-del" min="0.1" max="2" step="0.05" value="0.3"></div>
  <div class="row"><label for="ddes-px">profile at x = <span id="ddes-pxv">0.85</span></label><input type="range" id="ddes-px" min="0.1" max="1" step="0.01" value="0.85"></div>
  <p class="note" id="ddes-stat">&nbsp;</p>`,
 steps: ['Precompute wall distance d and cell size Δ (once)', 'Compute the velocity gradients ∂ⱼuᵢ', 'Shielding: r_d, then f_d', 'Blend the length: l = d − f_d·max(0, d − C_DES Δ)', 'Advance ν̃ with SA using l', 'Set ν_t = ν̃ f_v1 and advance momentum + pressure'],
 hint: 'Geometry comes first; f_d needs the gradients; l needs f_d; the SA step needs l; the flow step needs ν_t.',
 success: 'Your solver is running: it marches the boundary-layer form of the momentum and Spalart–Allmaras equations implicitly down the plate (240 stations × 120 wall-normal points), once with DES97 and once with DDES, on the grid you set. Honest reduction: the 3D grid only supplies Δ; the flow is spanwise-uniform and steady, so any “LES” cell here carries no resolved eddies. That is exactly the modelled-stress depletion DES97 suffers on this grid, and what DDES avoids.',
};
const parallel = { html: `<div class="par">
  <div class="stack">
   <p><strong>Same machinery as URANS and LES.</strong> The mesh is cut into blocks, one per core or GPU (domain decomposition). Each step a block swaps one or two layers of halo cells with its neighbours, then updates its own cells.</p>
   <p><strong>Pressure is global.</strong> The Poisson equation couples every cell. Multigrid (or a Krylov method preconditioned by multigrid) solves it; its coarse levels are the main communication cost.</p>
   <p><strong>One extra: the wall distance.</strong> d needs the nearest wall anywhere in the mesh, not just neighbours: a global search over wall faces, or an Eikonal solve. Once on a fixed mesh; every step on a moving one.</p>
   <p><strong>Where the cost sits.</strong> r<sub>d</sub>, f<sub>d</sub>, l and the SA source are local per cell. The LES region holds most cells and sets Δt.</p>
  </div>
  <canvas id="ddes-part" data-w="320" data-h="250" style="width:100%;max-width:320px;border-radius:8px;background:var(--bg)" aria-label="A domain with a coarse RANS region and a fine LES box, split between four processors"></canvas>
 </div>
 <p>Four processors share this mesh: coarse RANS cells around the body, a fine LES box in the wake. How should it be cut?</p>
 <div class="btns"><button class="b" id="ddes-pvol">Equal volumes</button><button class="b" id="ddes-pcell">Equal cell counts</button></div>
 <div class="fb" id="ddes-pfb"></div>
 <h3 style="font-size:16px">Cost against Reynolds number</h3>
 <p>Grid points and time steps for a plate of length L (span L), from simple sizing rules. Drag the Reynolds number toward flight values.</p>
 <div class="scrollx"><canvas id="ddes-cost" data-w="660" data-h="270" aria-label="Estimated grid points, time steps and total cost for RANS, DDES and wall-resolved LES against Reynolds number"></canvas></div>
 <div class="row"><label for="ddes-re">Re<sub>L</sub> = <span id="ddes-rev">10⁷</span></label><input type="range" id="ddes-re" min="5" max="9" step="0.05" value="7"></div>
 <p class="note" id="ddes-costcap">&nbsp;</p>
 <details><summary>Sizing rules used</summary><p>Skin friction C<sub>f</sub> = 0.455/ln²(0.06 Re<sub>x</sub>), δ = 0.37x Re<sub>x</sub><sup>−1/5</sup>. RANS: 200 × 200 wall-parallel cells, wall-normal points stretched by 1.2 from y⁺ = 1 to δ plus 20 outside, 1 000 iterations. DDES: the same RANS mesh plus an LES box 0.3L × 0.1L × L with cells of 0.002L (Re-independent: separated eddies scale with the body), Δt = 0.5 Δ/U over 20 L/U. Wall-resolved LES: Δx⁺ = 50, Δz⁺ = 15 and 60 points across each boundary layer (the Choi &amp; Moin 2012 style count, N ∝ Re<sup>13/7</sup>), Δt from the smallest Δx at CFL 0.5. Rough estimates, not benchmarks; Spalart (2000) quotes ~10⁸ points and 10⁴ steps for a wing DES.</p></details>` };
const sources = [
 ['Spalart, Jou, Strelets & Allmaras 1997, Comments on the feasibility of LES for wings, and on a hybrid RANS/LES approach (the original DES)', 'https://scholar.google.com/scholar?q=Comments+on+the+feasibility+of+LES+for+wings+and+on+a+hybrid+RANS%2FLES+approach'],
 ['Spalart, Deck, Shur, Squires, Strelets & Travin 2006, A new version of detached-eddy simulation, resistant to ambiguous grid densities (DDES), Theor. Comput. Fluid Dyn. 20', 'https://doi.org/10.1007/s00162-006-0015-0'],
 ['Shur, Spalart, Strelets & Travin 2008, A hybrid RANS-LES approach with delayed-DES and wall-modelled LES capabilities (IDDES), Int. J. Heat Fluid Flow 29', 'https://doi.org/10.1016/j.ijheatfluidflow.2008.07.001'],
 ['Spalart 2009, Detached-eddy simulation, Annu. Rev. Fluid Mech. 41 (review: C_DES, MSD, grey area)', 'https://doi.org/10.1146/annurev.fluid.010908.165130'],
 ['Spalart & Allmaras 1994, A one-equation turbulence model for aerodynamic flows: constants and SA-noft2 form (NASA Turbulence Modeling Resource)', 'https://turbmodels.larc.nasa.gov/spalart.html'],
 ['Shur, Spalart, Strelets & Travin 1999, Detached-eddy simulation of an airfoil at high angle of attack (C_DES = 0.65 calibration)', 'https://scholar.google.com/scholar?q=Shur+Spalart+Strelets+Travin+1999+Detached-eddy+simulation+of+an+airfoil+at+high+angle+of+attack'],
 ['Menter & Kuntz 2004, Adaptation of eddy-viscosity turbulence models to unsteady separated flow behind vehicles (grid-induced separation)', 'https://scholar.google.com/scholar?q=Menter+Kuntz+Adaptation+of+eddy-viscosity+turbulence+models+to+unsteady+separated+flow+behind+vehicles'],
 ['Gritskevich, Garbaruk, Schütze & Menter 2012, Development of DDES and IDDES formulations for the k-ω SST model (C_d1 = 20)', 'https://scholar.google.com/scholar?q=Gritskevich+Garbaruk+Schutze+Menter+Development+of+DDES+and+IDDES+formulations+for+the+k-omega+SST+model'],
 ['Chauvet, Deck & Jacquin 2007, Zonal detached eddy simulation of a controlled propulsive jet (Δ_ω)', 'https://scholar.google.com/scholar?q=Chauvet+Deck+Jacquin+Zonal+detached+eddy+simulation+of+a+controlled+propulsive+jet'],
 ['Shur, Spalart, Strelets & Travin 2015, An enhanced version of DES with rapid transition from RANS to LES in separated flows (Δ_SLA, grey area)', 'https://scholar.google.com/scholar?q=An+enhanced+version+of+DES+with+rapid+transition+from+RANS+to+LES+in+separated+flows'],
 ['Nagib, Chauhan & Monkewitz 2007, Approach to an asymptotic state for zero pressure gradient turbulent boundary layers (Coles–Fernholz C_f, the Build accuracy check)', 'https://scholar.google.com/scholar?q=Nagib+Chauhan+Monkewitz+2007+Approach+to+an+asymptotic+state+for+zero+pressure+gradient+turbulent+boundary+layers'],
 ['Choi & Moin 2012, Grid-point requirements for large eddy simulation: Chapman’s estimates revisited, Phys. Fluids 24', 'https://doi.org/10.1063/1.3676783'],
 ['Spalart 2000, Strategies for turbulence modelling and simulations, Int. J. Heat Fluid Flow 21', 'https://doi.org/10.1016/S0142-727X(00)00007-2'],
 ['Pope 2000, Turbulent Flows (Kolmogorov spectrum, C_K ≈ 1.5; filtering)', 'https://scholar.google.com/scholar?q=Pope+2000+Turbulent+Flows'],
];
// bench: the Build solver headless. Each frame advances both the DES97 and the DDES run by a few stations.
function bench(){
  const t0 = clock(), R = runAll(newRun(0)), t1 = clock(), dref = R.d99[NP], del = refined(.3*dref);
  const D1 = newRun(1, del), D2 = newRun(2, del); let steps = 0; const t2 = clock(); while (stepRun(D1) | stepRun(D2)) steps++; const t3 = clock();
  let worst = 0; for (let n=0;n<NS;n++) if (R.Rth[n] > 2000) worst = Math.max(worst, Math.abs(R.Cf[n]/coles(R.Rth[n]) - 1));
  const ut = Math.sqrt(R.Cf[NS-1]/2), jl = jAt(100*NU/ut), yp = Y[jl]*ut/NU, Bl = R.U[jl]/ut - Math.log(yp)/SA.kap;
  const pair = (t3-t2)/steps, nE = NS-1;
  return { RANS_full_march_ms: +(t1-t0).toFixed(1), DES97_plus_DDES_ms_per_station: +pair.toFixed(3), stations_per_9ms_frame: Math.floor(9/pair),
    frames_for_whole_plate: Math.ceil(steps/Math.floor(9/pair)), RANS_Cf_max_error_vs_Coles_Fernholz_pct: +(worst*100).toFixed(2),
    log_law_B_at_y_plus_100: +Bl.toFixed(2), Cf_ratio_at_x1: { DES97: +(D1.Cf[nE]/R.Cf[nE]).toFixed(3), DDES: +(D2.Cf[nE]/R.Cf[nE]).toFixed(3) } };
}

function mount(root, K){
const {$, P, hidpi, arrow, rr, pill, label, ease, lerp, clamp, proj, box, orbit, isAct, MONO, MATH, reduce} = K;
const triad = K.triad, F10 = '10px "IBM Plex Mono", monospace', F11 = '11px "IBM Plex Mono", monospace', B11 = '600 11px "IBM Plex Mono", monospace', SANS = '600 12px "IBM Plex Sans", sans-serif';
const fx = (v, d) => v.toFixed(d === undefined ? 3 : d), fe = v => sci(v);
const sup = s => String(s).replace(/[-0-9]/g, c => '⁻⁰¹²³⁴⁵⁶⁷⁸⁹'['-0123456789'.indexOf(c)]);
const sci = v => { const e = Math.floor(Math.log10(Math.abs(v))), m = v/10**e; return `${m.toFixed(2)}×10${sup(e)}`; };

// reference solutions, one-off (~0.1 s): RANS, and DES97 / DDES with a uniform wall-parallel spacing of 0.3 δ_ref
const REF = { R: runAll(newRun(0)) };
const DREF = REF.R.d99[NP];
REF.D = runAll(newRun(1, uniform(.3*DREF))); REF.DD = runAll(newRun(2, uniform(.3*DREF)));
const CfR = REF.R.Cf[NP];
// chunked jobs: advance runs inside the frame budget; with reduced motion they run from timers instead
const jobs = new Set();
function job(runs, stopAt, onStep, maxPer){ const jb = {runs, stopAt: stopAt || NS-1, onStep, maxPer: maxPer || 1e9, done: false}; jobs.add(jb); if (reduce) pumpTimer(); return jb; }
function pump(jb, budget){ const t0 = clock(); let k = 0;
  while (!jb.done && clock()-t0 < budget && k < jb.maxPer){ let any = false; for (const r of jb.runs) if (r.n < jb.stopAt) any = stepRun(r) || any; k++; if (!any) { jb.done = true; jobs.delete(jb); } }
  if (jb.onStep) jb.onStep(); }
let timer = null;
function pumpTimer(){ if (timer) return; timer = setTimeout(() => { timer = null; for (const jb of [...jobs]) { jb.maxPer = 1e9; pump(jb, 30); } K.redraw(); drawSim && simOn && drawSim(0); if (jobs.size) pumpTimer(); }, 0); }
const profile = (R, F, y) => fAt(F, NP, y);
const sAt = (R, n, y) => { const j = jAt(y), o = n*J; return Math.abs((R.UU[o+j+1]-R.UU[o+j-1])/(Y[j+1]-Y[j-1])); };

// ---------------- 0: operator walkthrough on two real cells ----------------
// cell A: halfway up the RANS boundary layer at x = 0.7, wall-parallel cells 0.3 δ (an "ambiguous" grid)
// cell B: a separated shear layer 4 δ from the wall, carrying the layer's peak ν̃, cubic cells of 0.1 δ
const jA = jAt(.5*DREF); let nBmax = 0; for (let j=0;j<J;j++) nBmax = Math.max(nBmax, REF.R.NN[NP*J+j]);
const mkCell = (name, d, hx, hy, hz, nt, S, tauR, tauD, tauDD) => { const D = Math.max(hx, hy, hz), lc = SA.CDES*D, nut = nt*fv1(nt), rd = (nut+NU)/(k2*d*d*S), fd = 1 - Math.tanh((8*rd)**3);
  const l97 = Math.min(d, lc), lDD = d - fd*Math.max(0, d - lc), pR = saPoint(nt, S, d), p97 = saPoint(nt, S, l97), pDD = saPoint(nt, S, lDD);
  return {name, d, hx, hy, hz, nt, S, D, lc, nut, rd, fd, l97, lDD, pR, p97, pDD, tauR, tauD, tauDD}; };
const cA = mkCell('A · attached layer, d = 0.5δ', Y[jA], .3*DREF, DY[jA], .3*DREF, REF.R.NN[NP*J+jA], sAt(REF.R, NP, Y[jA]), REF.R.TAU[NP*J+jA], REF.D.TAU[NP*J+jA], REF.DD.TAU[NP*J+jA]);
const eqNt = (S, l) => { let a = 1e-14, b = 1; for (let i=0;i<80;i++){ const m = Math.sqrt(a*b), o = saPoint(m, S, l); if (o.P > o.D) a = m; else b = m; } return Math.sqrt(a*b); };
const cB = (() => { const S = 1/DREF, c = mkCell('B · shear layer, d = 4δ', 4*DREF, .1*DREF, .1*DREF, .1*DREF, nBmax, S, 0, 0, 0), ne = eqNt(S, c.l97);
  c.tauR = c.nut*S; c.tauD = ne*fv1(ne)*S; c.tauDD = c.tauD; c.ntEq = ne; return c; })();
const CELLS = [cA, cB];
const OPS = [
 ['q', 'Two cells, two situations. A sits halfway up an attached boundary layer whose wall-parallel spacing was refined to δ/3. B sits in a separated shear layer far from the wall, still carrying the boundary layer’s eddy viscosity. Their numbers come from the boundary-layer solve.'],
 ['G', 'G squeezes three cell sides into one length: the largest. Like judging a parcel by its longest edge. Cell A is thin in y but long in x and z, so Δ is the long side.'],
 ['F', 'F asks each cell “am I inside an attached boundary layer?” r_d compares its eddy viscosity with what a log layer would have; f_d turns that into 0 (shield it) or 1 (free). A answers 0, B answers 1.'],
 ['L', 'L picks the length. DES97 always takes the shorter of d and C_DES Δ; DDES first multiplies the grid’s vote by f_d. A: DES97 jumps to the grid length (LES), DDES keeps d (RANS). B: both go LES. Click L to see how it works.'],
 ['T', 'T runs the SA balance with that length. Destruction grows like 1/l²: with the short grid length it beats production, so ν̃ will shrink, like a bath whose drain was opened wider. For A that is the mistake DES97 makes.'],
 ['M', 'M feeds ν_t into the momentum step as modelled stress. A: DES97 loses part of it and nothing on this coarse grid replaces it (depletion). B: the drop is wanted; resolved eddies carry the rest.']];
const OPK = [null, 'G', 'F', 'L', 'T', 'M'];
const CO = hidpi($('opviz')); let opStage = 0, opT = 0, opPlay = !reduce, opLast = null;
const opBtns = $('opsteps'); opBtns.innerHTML = OPS.map(([n], k) => `<button class="b opb" data-k="${k}">${k+1} · ${n}</button>`).join('');
opBtns.onclick = e => { const b = e.target.closest('.opb'); if (!b) return; opStage = +b.dataset.k; opT = 0; opCap(); K.pin(OPK[opStage]); if (reduce) drawOps(0); };
$('opplay').onclick = e => { opPlay = !opPlay; e.target.textContent = opPlay ? 'Pause' : 'Play'; };
function opCap(){ $('opcap').textContent = OPS[opStage][1]; opBtns.querySelectorAll('.opb').forEach((b, k) => b.classList.toggle('pri', k === opStage)); }
opCap();
function fdMini(c, x0, y0, w, h, rd, col, e, p, cd){ cd = cd || 8; const X = r => x0 + (Math.log10(r)+3)/5*w, Yf = f => y0 + h - f*h;
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x0, y0+h); c.lineTo(x0+w, y0+h); c.stroke();
  c.strokeStyle = p.c; c.lineWidth = 2; c.beginPath(); for (let q=0;q<=60;q++){ const r = 10**(-3+5*q/60), f = 1 - Math.tanh((cd*r)**3); q ? c.lineTo(X(r), Yf(f)) : c.moveTo(X(r), Yf(f)); } c.stroke();
  if (rd !== null) { const r = clamp(rd, 1e-3, 99), f = 1 - Math.tanh((cd*r)**3), xx = X(r); c.setLineDash([3,3]); c.strokeStyle = col; c.lineWidth = 1.2; c.beginPath(); c.moveTo(xx, y0+h); c.lineTo(xx, lerp(y0+h, Yf(f), e)); c.stroke(); c.setLineDash([]);
    c.fillStyle = col; c.beginPath(); c.arc(xx, lerp(y0+h, Yf(f), e), 4.5, 0, 7); c.fill(); }
  label(c, '10⁻³', x0, y0+h+12, p.mut, F10, 'center'); label(c, '1', X(1), y0+h+12, p.mut, F10, 'center'); label(c, '10²', x0+w, y0+h+12, p.mut, F10, 'center'); }
function drawOps(now){
  const dt = opLast === null ? 0 : Math.min(100, now - opLast); opLast = now;
  opT = Math.min(opPlay ? 99 : 3.8, opT + dt/1000); if (opPlay && opT > 4.2) { opT = 0; opStage = (opStage+1) % OPS.length; opCap(); }
  const c = CO, W = c.W, p = P(), e = reduce ? 1 : ease(opT/1.6); c.clearRect(0, 0, W, c.H);
  const COLS = [[10, 'inputs'], [168, 'G · grid width'], [292, 'F · r_d → f_d'], [440, 'L · length l'], [592, 'T · P vs D'], [748, 'M · modelled stress']];
  COLS.forEach(([x, t], k) => label(c, t, x, 18, k === opStage ? p.ink : k < opStage ? p.mut : p.rule, k === opStage ? SANS : F11));
  CELLS.forEach((C, r) => { const y0 = 34 + r*170, base = y0 + 118, on = k => opStage >= k, al = k => opStage > k ? 1 : opStage === k ? e : .14;
    c.fillStyle = p.panel; rr(c, 4, y0, W-8, 156, 10); c.fill();
    label(c, C.name, 12, y0+18, p.ink, SANS);
    [['d', fe(C.d), p.rho], ['Δx', fe(C.hx), p.cs], ['Δy', fe(C.hy), p.cs], ['Δz', fe(C.hz), p.cs], ['ν̃', fe(C.nt), p.nu], ['|∇u|', fx(C.S, 1), p.u]].forEach(([n, v, col], i) => { label(c, n, 14, y0+40+i*18, col, B11); label(c, v, 52, y0+40+i*18, p.ink, F11); });
    // G
    c.globalAlpha = Math.max(.14, al(1)); const hs = [C.hx, C.hy, C.hz], mx = Math.max(...hs);
    hs.forEach((v, i) => { const h = 80*v/mx, x = 172 + i*24, isM = v === mx; c.fillStyle = p.cs; c.globalAlpha = Math.max(.14, al(1))*(isM ? 1 : .45); rr(c, x, base-h, 16, h, 3); c.fill(); label(c, ['Δx','Δy','Δz'][i], x+8, base+14, p.mut, F10, 'center'); });
    c.globalAlpha = Math.max(.14, al(1)); if (on(1)) { c.strokeStyle = p.ink; c.lineWidth = 2; const k = hs.indexOf(mx), x = 172 + k*24; rr(c, x-2, base-82-(opStage === 1 ? 10*(1-e) : 0), 20, 84, 4); c.stroke(); label(c, `Δ = ${fe(C.D)}`, 172, base+28, p.cs, B11); }
    c.globalAlpha = 1;
    // F
    c.globalAlpha = Math.max(.14, al(2)); fdMini(c, 300, y0+30, 116, 74, on(2) ? C.rd : null, p.c, opStage === 2 ? e : 1, p);
    if (on(2)) { label(c, `r_d = ${C.rd < .01 ? fe(C.rd) : fx(C.rd, 2)}`, 300, base+12, p.ink, F11); label(c, `f_d = ${fx(C.fd, 2)}`, 300, base+26, p.c, B11); } c.globalAlpha = 1;
    // L
    c.globalAlpha = Math.max(.14, al(3)); const ls = [[C.d, p.rho, 'd'], [C.lc, p.cs, 'C·Δ'], [C.l97, p.tau, 'DES97'], [C.lDD, p.tau, 'DDES']], lm = Math.max(C.d, C.lc);
    ls.forEach(([v, col, n], i) => { const h = 76*v/lm*(i >= 2 && opStage === 3 ? e : 1), x = 446 + i*34; c.fillStyle = col; c.globalAlpha = Math.max(.14, al(3))*(i < 2 ? .5 : 1); rr(c, x, base-h, 22, h, 3); c.fill(); c.globalAlpha = Math.max(.14, al(3)); label(c, n, x+11, base+12, p.mut, F10, 'center'); });
    if (on(3)) [[C.l97, 'DES97'], [C.lDD, 'DDES']].forEach(([v, n], i) => { const les = v < .98*C.d; pill(c, 444 + i*72, y0+24, `${n} ${les ? 'LES' : 'RANS'}`, les ? p.eq : p.f, F10); });
    c.globalAlpha = 1;
    // T
    c.globalAlpha = Math.max(.14, al(4)); const pd = [[C.p97, 'DES97'], [C.pDD, 'DDES']], tm = Math.max(...pd.flatMap(([o]) => [o.P, o.D]));
    pd.forEach(([o, n], i) => { const x = 598 + i*72; [[o.P, p.f, 'P'], [o.D, p.eq, 'D']].forEach(([v, col, s], k) => { const h = Math.min(88, 76*v/tm)*(opStage === 4 ? e : 1); c.fillStyle = col; rr(c, x + k*24, base-h, 18, h, 3); c.fill(); label(c, s, x + k*24 + 9, base+12, col, B11, 'center'); });
      label(c, n, x+21, base+26, p.mut, F10, 'center'); if (on(4)) label(c, `D/P ${fx(o.D/o.P, 1)}`, x+21, y0+30, o.D > 1.2*o.P ? p.eq : p.mut, F10, 'center'); });
    c.globalAlpha = 1;
    // M
    c.globalAlpha = Math.max(.14, al(5)); const ts = [[C.tauR, p.f, 'RANS'], [C.tauD, p.eq, 'DES97'], [C.tauDD, p.c, 'DDES']];
    ts.forEach(([v, col, n], i) => { const h = 80*v/C.tauR*(opStage === 5 ? e : 1), x = 754 + i*38; c.fillStyle = col; rr(c, x, base-h, 24, h, 3); c.fill(); label(c, n, x+12, base+12, p.mut, F10, 'center'); if (on(5)) label(c, `${Math.round(100*v/C.tauR)}%`, x+12, base-h-5, col, F10, 'center'); });
    c.globalAlpha = 1;
  });
}

// ---------------- how-it-works panels: one per operator ----------------
const hm = (...ms) => `<div class="hm" style="width:0;min-width:100%;box-sizing:border-box">${ms.map(m => `<math display="block">${m}</math>`).join('')}</div>`, tc = (col, x) => `<mrow style="color:var(${col})">${x}</mrow>`, sw = col => `<i class="tb" style="background:var(${col})"></i>`;
const btnRow = (lab, key, vals, cur, fmt) => `<div class="eex"><span>${lab}</span>${vals.map((v, i) => `<button class="b${i === cur ? ' pri' : ''}" data-${key}="${i}">${fmt(v)}</button>`).join('')}</div>`;
const HS = { G: {c: 1, dz: 0}, F: {h: 1, cd: 0}, L: {f: 2, r: 1}, T: {h: 1, s: 1}, M: {h: 1} };
const bindRows = (root, st, keys, self) => keys.forEach(k => root.querySelectorAll(`[data-${k}]`).forEach(b => b.onclick = () => { st[k] = +b.getAttribute('data-'+k); root.querySelectorAll(`[data-${k}]`).forEach(x => x.classList.toggle('pri', x === b)); self.draw(root); }));
const GC = [['wall cell', [.3, .002, .3], [0,0,1]], ['shear-layer cell', [.1, .1, .4], [0,0,1]], ['cube', [.1, .1, .1], [0,0,1]], ['tilted vortex', [.1, .1, .4], [.6,0,.8]]];
const HTS = [.1, .3, .5, .7, .9, 1.1];
const HOW = {
 G: { html: () => `<span class="eyebrow">How G works</span>
  ${hm(`${tc('--c-cs','<msub><mi>Δ</mi><mtext>max</mtext></msub>')}<mo>=</mo><mi>max</mi><mo>(</mo><mi>Δ</mi><mi>x</mi><mo>,</mo><mi>Δ</mi><mi>y</mi><mo>,</mo><mi>Δ</mi><mi>z</mi><mo>)</mo>`, `${tc('--c-w','<msub><mi>Δ</mi><mtext>vol</mtext></msub>')}<mo>=</mo><msup><mrow><mo>(</mo><mi>Δ</mi><mi>x</mi><mi>Δ</mi><mi>y</mi><mi>Δ</mi><mi>z</mi><mo>)</mo></mrow><mrow><mn>1</mn><mo>/</mo><mn>3</mn></mrow></msup>`, `${tc('--c-u','<msub><mi>Δ</mi><mi>ω</mi></msub>')}<mo>=</mo><msqrt><msubsup><mi>n</mi><mi>x</mi><mn>2</mn></msubsup><mi>Δ</mi><mi>y</mi><mi>Δ</mi><mi>z</mi><mo>+</mo><msubsup><mi>n</mi><mi>y</mi><mn>2</mn></msubsup><mi>Δ</mi><mi>z</mi><mi>Δ</mi><mi>x</mi><mo>+</mo><msubsup><mi>n</mi><mi>z</mi><mn>2</mn></msubsup><mi>Δ</mi><mi>x</mi><mi>Δ</mi><mi>y</mi></msqrt>`)}
  <div class="eterms"><span>${sw('--c-cs')}Δ_max</span><span>Largest side. DES97/DDES: a thin near-wall cell (tiny Δy) does not count as fine, so RANS stays.</span>
   <span>${sw('--c-w')}Δ_vol</span><span>Classic LES: cube root of the volume. Near walls it would be small, switching RANS cells to LES.</span>
   <span>${sw('--c-u')}Δ_ω</span><span>Only the two sides across the spin axis n: a cell long along a vortex does not inflate ν_t.</span></div>
  ${btnRow('Cell', 'c', GC, HS.G.c, v => v[0])}${btnRow('Δz', 'dz', [1, 2, .5], HS.G.dz, v => '×' + v)}
  <canvas class="hc" data-w="420" data-h="130"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), [nm, s0, n] = GC[HS.G.c], f = [1, 2, .5][HS.G.dz], [hx, hy, hz0] = s0, hz = hz0*f;
   const dmax = Math.max(hx, hy, hz), dvol = Math.cbrt(hx*hy*hz), dom = Math.sqrt(n[0]**2*hy*hz + n[1]**2*hz*hx + n[2]**2*hx*hy); c.clearRect(0, 0, c.W, c.H);
   const V = {th: -.6, ph: .35, s: 110/Math.max(hx, hy, hz, .2), ox: 95, oy: 70}; box(c, V, hx/2, hy/2, hz/2, p.cs, 1.8);
   const a0 = proj(V, 0, 0, 0), a1 = proj(V, n[0]*.6*Math.max(hx,hz), n[1]*.6*Math.max(hx,hz), n[2]*.6*Math.max(hx,hz)); arrow(c, a0[0], a0[1], a1[0], a1[1], p.u, 2); label(c, 'n', a1[0]+6, a1[1], p.u, MATH);
   [['Δ_max', dmax, p.cs], ['Δ_vol', dvol, p.w], ['Δ_ω', dom, p.u]].forEach(([t, v, col], i) => { const y = 30 + i*32, w = 170*v/dmax; c.fillStyle = col; rr(c, 230, y, w, 18, 3); c.fill(); label(c, t, 226, y+13, col, B11, 'right'); label(c, fx(v, 3), 236 + w, y+13, p.ink, F10); });
   root.querySelector('.ecalc').textContent = `${nm}: Δx = ${hx}, Δy = ${hy}, Δz = ${fx(hz, 2)} (in δ) → Δ_max = ${fx(dmax)}, Δ_vol = ${fx(dvol)}, Δ_ω = ${fx(dom)}. DDES switch height C_DES·Δ_max = ${fx(.65*dmax)} δ.`; },
  bind(root){ bindRows(root, HS.G, ['c', 'dz'], this); } },
 F: { html: () => `<span class="eyebrow">How F works</span>
  ${hm(`<msub><mi>f</mi><mi>d</mi></msub><mo>=</mo><mn>1</mn><mo>−</mo><mi>tanh</mi><mo>(</mo>${tc('--c-c','<msup><mrow><mo>(</mo><mn>8</mn><msub><mi>r</mi><mi>d</mi></msub><mo>)</mo></mrow><mn>3</mn></msup>')}<mo>)</mo>`, `<msub><mi>r</mi><mi>d</mi></msub><mo>=</mo><mfrac>${tc('--c-nu','<msub><mi>ν</mi><mi>t</mi></msub><mo>+</mo><mi>ν</mi>')}<mrow>${tc('--c-rho','<msup><mi>κ</mi><mn>2</mn></msup><msup><mi>d</mi><mn>2</mn></msup>')}${tc('--c-u','<msqrt><msub><mo>∂</mo><mi>j</mi></msub><msub><mi>u</mi><mi>i</mi></msub><msub><mo>∂</mo><mi>j</mi></msub><msub><mi>u</mi><mi>i</mi></msub></msqrt>')}</mrow></mfrac>`)}
  <div class="eterms"><span>${sw('--c-nu')}ν_t + ν</span><span>The viscosity the cell actually has (turbulent plus molecular).</span>
   <span>${sw('--c-rho')}κ²d²</span><span>Squared log-layer mixing length…</span>
   <span>${sw('--c-u')}√(∂u ∂u)</span><span>…times the total shear: what ν_t would be in a log layer. So r_d ≈ 1 there.</span>
   <span>${sw('--c-c')}(8 r_d)³</span><span>A steep switch: f_d is ½ at r_d ≈ 0.10, ≈ 0 above 0.2, ≈ 1 below 0.05.</span></div>
  ${btnRow('Height y/δ', 'h', HTS, HS.F.h, v => v)}${btnRow('Constant', 'cd', [8, 20], HS.F.cd, v => v)}
  <canvas class="hc" data-w="420" data-h="110"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), y = HTS[HS.F.h]*DREF, cd = [8, 20][HS.F.cd], nut = profile(REF.R, REF.R.NUT, y), S = sAt(REF.R, NP, y), rd = (nut+NU)/(k2*y*y*S), fd = 1 - Math.tanh((cd*rd)**3);
   c.clearRect(0, 0, c.W, c.H); fdMini(c, 40, 10, 340, 80, rd, p.ink, 1, p, cd); label(c, 'f_d', 20, 16, p.c, B11, 'center'); label(c, 'r_d', 395, 94, p.c, B11);
   root.querySelector('.ecalc').textContent = `RANS layer at x = 0.7, y = ${HTS[HS.F.h]}δ: ν_t = ${fe(nut)}, ν = 1e-7, d = ${fe(y)}, shear = ${fx(S, 1)} → r_d = (${fe(nut+NU)}) / (0.168 × ${fe(y*y)} × ${fx(S, 1)}) = ${fx(rd, 3)} → f_d = 1 − tanh((${cd} × ${fx(rd, 3)})³) = ${fx(fd, 3)}: ${fd < .5 ? 'shielded, stays RANS' : 'not shielded, LES allowed'}.`; },
  bind(root){ bindRows(root, HS.F, ['h', 'cd'], this); } },
 L: { html: () => `<span class="eyebrow">How L works</span>
  ${hm(`<mi>l</mi><mo>=</mo>${tc('--c-rho','<mi>d</mi>')}<mo>−</mo>${tc('--c-c','<msub><mi>f</mi><mi>d</mi></msub>')}<mi>max</mi><mo>(</mo><mn>0</mn><mo>,</mo>${tc('--c-cs','<mi>d</mi><mo>−</mo><msub><mi>C</mi><mtext>DES</mtext></msub><mi>Δ</mi>')}<mo>)</mo>`)}
  <div class="eterms"><span>${sw('--c-rho')}d</span><span>Start from the RANS length, the wall distance.</span>
   <span>${sw('--c-cs')}d − C_DES Δ</span><span>How much longer d is than the grid length; max(0, ·) keeps only positive excess.</span>
   <span>${sw('--c-c')}f_d</span><span>The shield’s vote: f_d = 1 removes the whole excess (l = min(d, C_DES Δ), DES97); f_d = 0 keeps l = d (RANS).</span></div>
  ${btnRow('f_d', 'f', [0, .5, 1], HS.L.f, v => v)}${btnRow('d / C_DES Δ', 'r', [.5, 2, 4], HS.L.r, v => v)}
  <canvas class="hc" data-w="420" data-h="120"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), f = [0, .5, 1][HS.L.f], r = [.5, 2, 4][HS.L.r], lc = 1, d = r*lc, lv = d - f*Math.max(0, d - lc);
   const X = v => 40 + v/5*340, Yv = v => 105 - v/5*95; c.clearRect(0, 0, c.W, c.H);
   c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(40, 10); c.lineTo(40, 105); c.lineTo(385, 105); c.stroke();
   c.setLineDash([4,4]); c.strokeStyle = p.rho; c.beginPath(); c.moveTo(X(0), Yv(0)); c.lineTo(X(5), Yv(5)); c.stroke(); c.strokeStyle = p.cs; c.beginPath(); c.moveTo(X(1), Yv(0)); c.lineTo(X(1), Yv(5)); c.stroke(); c.setLineDash([]);
   c.strokeStyle = p.tau; c.lineWidth = 2.6; c.beginPath(); for (let q=0;q<=50;q++){ const dd = 5*q/50, ll = dd - f*Math.max(0, dd - 1); q ? c.lineTo(X(dd), Yv(ll)) : c.moveTo(X(dd), Yv(ll)); } c.stroke();
   c.fillStyle = p.ink; c.beginPath(); c.arc(X(d), Yv(lv), 5, 0, 7); c.fill(); label(c, 'd', 390, 108, p.rho, MATH); label(c, 'l', 30, 16, p.tau, MATH); label(c, 'C_DES Δ', X(1)+4, 20, p.cs, F10);
   root.querySelector('.ecalc').textContent = `d = ${d} C_DESΔ, f_d = ${f}: l = ${d} − ${f} × max(0, ${d} − 1) = ${fx(lv, 2)} C_DESΔ → ${lv < d*.98 ? 'LES-like (grid length)' : 'RANS (wall distance)'}${f === .5 && d > 1 ? ', half way: a blend' : ''}.`; },
  bind(root){ bindRows(root, HS.L, ['f', 'r'], this); } },
 T: { html: () => `<span class="eyebrow">How T works</span>
  ${hm(`<mfrac><mrow><mi>D</mi><mover accent="true"><mi>ν</mi><mo>~</mo></mover></mrow><mrow><mi>D</mi><mi>t</mi></mrow></mfrac><mo>=</mo>${tc('--c-f','<msub><mi>c</mi><mrow><mi>b</mi><mn>1</mn></mrow></msub><mover accent="true"><mi>S</mi><mo>~</mo></mover><mover accent="true"><mi>ν</mi><mo>~</mo></mover>')}<mo>−</mo>${tc('--c-eq','<msub><mi>c</mi><mrow><mi>w</mi><mn>1</mn></mrow></msub><msub><mi>f</mi><mi>w</mi></msub><msup><mrow><mo>(</mo><mover accent="true"><mi>ν</mi><mo>~</mo></mover><mo>/</mo><mi>l</mi><mo>)</mo></mrow><mn>2</mn></msup>')}<mo>+</mo>${tc('--c-w','<mtext>diffusion</mtext>')}`, `<msub><mi>ν</mi><mi>t</mi></msub><mo>=</mo><mover accent="true"><mi>ν</mi><mo>~</mo></mover><msub><mi>f</mi><mrow><mi>v</mi><mn>1</mn></mrow></msub>`)}
  <div class="eterms"><span>${sw('--c-f')}production</span><span>Shear makes eddy viscosity. S̃ also contains l, but weakly.</span>
   <span>${sw('--c-eq')}destruction</span><span>Grows like 1/l²: the term the length switch really acts on.</span>
   <span>${sw('--c-w')}diffusion</span><span>Spreads ν̃ to neighbours; in the log layer it closes the balance exactly.</span></div>
  ${btnRow('Height y/δ', 'h', [.2, .5, .8], HS.T.h, v => v)}${btnRow('Δ∥/δ', 's', [.15, .3, .6, 1.5], HS.T.s, v => v)}
  <canvas class="hc" data-w="420" data-h="110"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), y = [.2, .5, .8][HS.T.h]*DREF, D = [.15, .3, .6, 1.5][HS.T.s]*DREF, nt = profile(REF.R, REF.R.NN, y), S = sAt(REF.R, NP, y), lc = Math.min(y, SA.CDES*D);
   const a = saPoint(nt, S, y), b = saPoint(nt, S, lc), m = Math.max(a.P, a.D, b.P, b.D); c.clearRect(0, 0, c.W, c.H);
   [[a, 'l = d (RANS)'], [b, `l = ${fx(lc/DREF, 2)}δ (DES97)`]].forEach(([o, t], i) => { const y0 = 12 + i*48; label(c, t, 8, y0+10, p.ink, F11);
     [[o.P, p.f, 'P'], [o.D, p.eq, 'D']].forEach(([v, col, s], k) => { const w = 260*v/m; c.fillStyle = col; rr(c, 140, y0 + k*18, w, 14, 3); c.fill(); label(c, s, 134, y0 + k*18 + 11, col, B11, 'right'); label(c, fe(v), 146 + w, y0 + k*18 + 11, p.mut, F10); }); });
   root.querySelector('.ecalc').textContent = `y = ${fx(y/DREF, 1)}δ, ν̃ = ${fe(nt)}, S = ${fx(S, 1)}. With l = d: P = ${fe(a.P)}, D = ${fe(a.D)} (the surplus is spread by diffusion and carried downstream). With l = ${fx(lc/DREF, 2)}δ: D grows ×${fx(b.D/a.D, 2)} → P − D = ${fe(b.P - b.D)}: ${b.D > b.P ? 'destruction wins, ν̃ shrinks' : b.D > 1.05*a.D ? 'ν̃ is pushed down' : 'unchanged: here l = d still'}.`; },
  bind(root){ bindRows(root, HS.T, ['h', 's'], this); } },
 M: { html: () => `<span class="eyebrow">How M works</span>
  ${hm(`<msub><mo>∂</mo><mi>t</mi></msub><msub><mi>u</mi><mi>i</mi></msub><mo>+</mo><msub><mi>u</mi><mi>j</mi></msub><msub><mo>∂</mo><mi>j</mi></msub><msub><mi>u</mi><mi>i</mi></msub><mo>=</mo>${tc('--c-w','<mo>−</mo><msub><mo>∂</mo><mi>i</mi></msub><mi>p</mi>')}<mo>+</mo><msub><mo>∂</mo><mi>j</mi></msub><mo>[</mo><mn>2</mn><mo>(</mo>${tc('--c-u','<mi>ν</mi>')}<mo>+</mo>${tc('--c-nu','<msub><mi>ν</mi><mi>t</mi></msub>')}<mo>)</mo><msub><mi>S</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>]</mo>`)}
  <div class="eterms"><span>${sw('--c-w')}−∂ᵢp</span><span>Pressure pushes; a Poisson solve keeps the flow divergence-free.</span>
   <span>${sw('--c-u')}ν</span><span>The fluid’s own viscosity.</span>
   <span>${sw('--c-nu')}ν_t</span><span>Modelled stress 2ν_tS_ij: the whole turbulent stress in RANS cells, only the subgrid part in LES cells.</span></div>
  ${btnRow('Height y/δ', 'h', [.1, .3, .6, .9], HS.M.h, v => v)}
  <canvas class="hc" data-w="420" data-h="100"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), y = [.1, .3, .6, .9][HS.M.h]*DREF, t = [REF.R, REF.D, REF.DD].map(R => profile(R, R.TAU, y)); c.clearRect(0, 0, c.W, c.H);
   [['RANS', p.f], ['DES97', p.eq], ['DDES', p.c]].forEach(([n, col], i) => { const w = 280*t[i]/t[0], y0 = 12 + i*28; c.fillStyle = col; rr(c, 70, y0, w, 18, 3); c.fill(); label(c, n, 64, y0+13, col, B11, 'right'); label(c, `${Math.round(100*t[i]/t[0])}%`, 76 + w, y0+13, p.ink, F10); });
   root.querySelector('.ecalc').textContent = `Δ∥ = 0.3δ, x = 0.7, y = ${[.1, .3, .6, .9][HS.M.h]}δ: modelled shear stress ν_t ∂U/∂y = RANS ${fe(t[0])}, DES97 ${fe(t[1])} (${Math.round(100*t[1]/t[0]-100)} %), DDES ${fe(t[2])} (${Math.round(100*t[2]/t[0]-100)} %). Nothing resolved replaces the DES97 loss on this grid.`; },
  bind(root){ bindRows(root, HS.M, ['h'], this); } },
};
this.ops = HOW;

// ---------------- shared profile plotting (y/δ upward) ----------------
const YM = 1.3;
function axes(c, x0, x1, y0, y1, p, title, xl){ c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x0, y1); c.lineTo(x1, y1); c.stroke();
  label(c, title, (x0+x1)/2, y0-8, p.ink, SANS, 'center'); if (xl) label(c, xl, x1, y1+14, p.mut, F10, 'right');
  [0, .5, 1].forEach(v => label(c, String(v), x0-5, y1 - v/YM*(y1-y0) + 4, p.mut, F10, 'right')); }
function curve(c, fn, x0, x1, y0, y1, xmax, col, lw, dash, alpha){ c.save(); c.globalAlpha = alpha || 1; c.strokeStyle = col; c.lineWidth = lw; c.setLineDash(dash ? [5,4] : []); c.beginPath(); let st = false;
  for (let q=0;q<=90;q++){ const yd = YM*q/90, v = fn(yd*DREF); if (!(v === v)) continue; const X = x0 + clamp(v/xmax, 0, 1.05)*(x1-x0), Yp = y1 - q/90*(y1-y0); st ? c.lineTo(X, Yp) : c.moveTo(X, Yp); st = true; }
  c.stroke(); c.restore(); }
let probeT = 0, lastP = null;
function probeY(now){ const dt = lastP === null ? 0 : Math.min(100, now - lastP); lastP = now; if (!reduce) probeT += dt/1000; return reduce ? .5 : .03 + (YM - .08)*(.5 - .5*Math.cos(probeT*2*Math.PI/7)); }
const nutMax = (() => { let m = 0; for (let j=0;j<J;j++) m = Math.max(m, REF.R.NUT[NP*J+j]); return m; })();

// ---------------- A: DES97, one equation in two roles ----------------
const CA = hidpi($('aviz')), VA = {th: -.55, ph: .38, s: 118, ox: 232, oy: 196}; orbit($('aviz'), VA);
let sA = .3, runA = null, jobA = null, ghostA = [];
function startA(){ if (runA && runA.n >= NP) ghostA = [{s: sA0, nut: Float32Array.from({length: J}, (_, j) => runA.NUT[NP*J+j])}, ...ghostA].slice(0, 3);
  runA = newRun(1, uniform(sA*DREF)); sA0 = sA; jobA = job([runA], NP); }
let sA0 = sA;
$('adel').oninput = () => { sA = +$('adel').value; $('adelv').textContent = sA.toFixed(2); startA(); if (reduce) drawA(0); };
startA();
function drawA(now){
  const c = CA, p = P(), W = c.W, yp = probeY(now), ready = runA.n >= NP, lc = SA.CDES*sA; c.clearRect(0, 0, W, c.H);
  if (!VA.drag && !reduce && lastA !== null) VA.th += Math.min(100, now - lastA)*.00008; lastA = now;
  const P3 = (x, y, z) => proj(VA, x, y, z), hx = .9, hz = .5;
  // wall with its wall-parallel grid
  const q = [[-hx,0,-hz],[hx,0,-hz],[hx,0,hz],[-hx,0,hz]].map(v => P3(...v)); c.fillStyle = p.panel; c.beginPath(); q.forEach(([x, y], i) => i ? c.lineTo(x, y) : c.moveTo(x, y)); c.closePath(); c.fill();
  const hon = isAct('Del', 'hx', 'G'); c.strokeStyle = hon ? p.cs : p.rule; c.lineWidth = hon ? 1.3 : .8; c.beginPath();
  const stepL = Math.max(sA, .06); for (let x = -hx; x <= hx+1e-6; x += stepL) { const a = P3(x,0,-hz), b = P3(x,0,hz); c.moveTo(a[0],a[1]); c.lineTo(b[0],b[1]); }
  for (let z = -hz; z <= hz+1e-6; z += stepL) { const a = P3(-hx,0,z), b = P3(hx,0,z); c.moveTo(a[0],a[1]); c.lineTo(b[0],b[1]); } c.stroke();
  // back plane: cell rows coloured by mode (l < d → LES)
  for (let j=1;j<J-1;j++){ const y0 = Y[j]/DREF, y1 = Y[j+1]/DREF; if (y0 > YM) break; const les = Y[j]/DREF > lc; const cs = [[-hx,y0,-hz],[hx,y0,-hz],[hx,Math.min(y1,YM),-hz],[-hx,Math.min(y1,YM),-hz]].map(v => P3(...v));
    c.fillStyle = les ? p.eq : p.f; c.globalAlpha = (les ? .22 : .14)*(y0 < 1 ? 1 : .45); c.beginPath(); cs.forEach(([x, y], i) => i ? c.lineTo(x, y) : c.moveTo(x, y)); c.closePath(); c.fill(); c.globalAlpha = 1;
    const a = P3(-hx,y0,-hz), b = P3(hx,y0,-hz); if (j % 4 === 0) { c.strokeStyle = p.rule; c.lineWidth = .6; c.beginPath(); c.moveTo(a[0],a[1]); c.lineTo(b[0],b[1]); c.stroke(); } }
  for (let x = -hx; x <= hx+1e-6; x += stepL) { const a = P3(x,0,-hz), b = P3(x,YM,-hz); c.strokeStyle = hon ? p.cs : p.rule; c.lineWidth = .7; c.beginPath(); c.moveTo(a[0],a[1]); c.lineTo(b[0],b[1]); c.stroke(); }
  // switch plane d = C_DES Δ and boundary-layer edge
  if (lc < YM) { const s = [[-hx,lc,-hz],[hx,lc,-hz],[hx,lc,hz],[-hx,lc,hz]].map(v => P3(...v)); c.fillStyle = p.tau; c.globalAlpha = isAct('CD','l','L') ? .3 : .13; c.beginPath(); s.forEach(([x, y], i) => i ? c.lineTo(x, y) : c.moveTo(x, y)); c.closePath(); c.fill(); c.globalAlpha = 1; c.strokeStyle = p.tau; c.lineWidth = 1.4; c.stroke(); label(c, 'd = C_DES Δ', s[1][0]+4, s[1][1], p.tau, F10); }
  { const s = [[-hx,1,-hz],[hx,1,-hz],[hx,1,hz],[-hx,1,hz]].map(v => P3(...v)); c.setLineDash([4,4]); c.strokeStyle = p.mut; c.lineWidth = 1; c.beginPath(); s.forEach(([x, y], i) => i ? c.lineTo(x, y) : c.moveTo(x, y)); c.closePath(); c.stroke(); c.setLineDash([]); label(c, 'δ', s[2][0]+6, s[2][1]+4, p.mut, MATH); }
  // mean velocity arrows on the mid plane
  for (let k=1;k<=9;k++){ const yd = k*.13, U = fAt(REF.R.UU, NP, yd*DREF), a = P3(-hx, yd, 0), b = P3(-hx + .55*U, yd, 0); arrow(c, a[0], a[1], b[0], b[1], p.u, isAct('u') ? 2.2 : 1.4); }
  // eddies the grid should carry where DES97 went LES inside the layer: on this coarse grid they are missing
  const tt = reduce ? 0 : now/1000;
  for (let k=0;k<9;k++){ const yd = lc + (1 - lc)*((k*.37) % 1), xw = -hx + ((k*.53 + tt*.08) % 1)*2*hx, zw = -hz*.6 + ((k*.29) % 1)*hz*1.2; if (yd >= 1 || yd <= lc) continue;
    const [X, Yp] = P3(xw, yd, zw), r = Math.max(5, 30*Math.min(yd, .4)); c.setLineDash([3,3]); c.strokeStyle = p.eq; c.lineWidth = 1.2; c.globalAlpha = .75; c.beginPath(); c.arc(X, Yp, r, 0, 5.2); c.stroke(); c.setLineDash([]); c.globalAlpha = 1; }
  // probe
  { const a = P3(-hx, yp, -hz), b = P3(hx, yp, -hz); c.strokeStyle = p.ink; c.lineWidth = 1.6; c.beginPath(); c.moveTo(a[0],a[1]); c.lineTo(b[0],b[1]); c.stroke(); if (isAct('d')) { const w0 = P3(hx, 0, -hz); arrow(c, w0[0]+6, w0[1], b[0]+6, b[1], p.rho, 2); label(c, 'd', b[0]+12, (w0[1]+b[1])/2, p.rho, MATH); } }
  triad(c, VA, 30, 205, p);
  label(c, `Δx = Δz = ${sA.toFixed(2)}δ`, 12, 18, p.cs, B11); label(c, 'dashed: eddies the grid would need, missing', 12, 34, p.eq, F10);
  // plots: l and ν_t across the layer
  const y0 = 284, y1 = 424; axes(c, 40, 205, y0, y1, p, 'length l / δ', 'l/δ'); axes(c, 255, 445, y0, y1, p, 'eddy viscosity ν_t', 'ν_t/max');
  label(c, 'y/δ', 22, y0-4, p.mut, F10);
  curve(c, y => y/DREF, 40, 205, y0, y1, YM, p.rho, isAct('d') ? 2.4 : 1.3, true);
  { const X = 40 + lc/YM*165; c.strokeStyle = p.cs; c.lineWidth = isAct('CD','Del') ? 2.4 : 1.2; c.beginPath(); c.moveTo(X, y0); c.lineTo(X, y1); c.stroke(); }
  curve(c, y => Math.min(y, lc*DREF)/DREF, 40, 205, y0, y1, YM, p.tau, isAct('l','L') ? 4 : 2.6);
  ghostA.forEach((g, i) => curve(c, y => { const j = jAt(y); return g.nut[j]/nutMax; }, 255, 445, y0, y1, 1.15, p.eq, 1.2, false, .35 - .1*i));
  curve(c, y => fAt(REF.R.NUT, NP, y)/nutMax, 255, 445, y0, y1, 1.15, p.f, isAct('nut','nt','T') ? 3 : 2, true);
  if (ready) curve(c, y => fAt(runA.NUT, NP, y)/nutMax, 255, 445, y0, y1, 1.15, p.eq, isAct('nut','nt','T') ? 3.6 : 2.6);
  else label(c, `solving… x = ${fx(XS[runA.n], 2)}`, 350, y0+20, p.mut, F11, 'center');
  const Yp = y1 - yp/YM*(y1-y0); c.strokeStyle = p.ink; c.globalAlpha = .5; c.lineWidth = 1; c.beginPath(); c.moveTo(40, Yp); c.lineTo(445, Yp); c.stroke(); c.globalAlpha = 1;
  if (ready) { const y = yp*DREF, l = Math.min(y, lc*DREF), les = l < .98*y, nt = fAt(runA.NN, NP, y), S = sAt(runA, NP, y), o = saPoint(nt, S, l), oR = saPoint(nt, S, y);
    pill(c, 12, 240, `y = ${yp.toFixed(2)}δ · ${les ? 'LES' : 'RANS'} · destruction ×${fx(o.D/oR.D, 2)}`, les ? p.eq : p.f, F11);
    if (isAct('prod','dest')) { const m = Math.max(o.P, o.D); [[o.P, p.f, 'P'], [o.D, p.eq, 'D']].forEach(([v, col, s], k) => { c.fillStyle = col; rr(c, 330, 26 + k*18, 110*v/m, 13, 3); c.fill(); label(c, s, 324, 37 + k*18, col, B11, 'right'); }); } }
  if (ready) $('acap').textContent = `Switch at d = C_DES Δ = ${lc.toFixed(2)}δ ${lc < 1 ? '→ inside the boundary layer (ambiguous grid)' : '→ above the layer: natural DES, all RANS inside'}. Solved C_f at x = 0.7: RANS ${fx(CfR*1e3, 3)}·10⁻³, DES97 ${fx(runA.Cf[NP]*1e3, 3)}·10⁻³ (${Math.round(100*runA.Cf[NP]/CfR - 100)} %).`;
}
let lastA = null;

// ---------------- B: DDES shielding ----------------
const CB = hidpi($('bviz')); let sB = .3, cdB = 8, cdOld = 8, runB = null, jobB = null;
function startB(){ runB = [newRun(1, uniform(sB*DREF)), newRun(2, uniform(sB*DREF), cdB)]; jobB = job(runB, NP); }
$('bdel').oninput = () => { sB = +$('bdel').value; $('bdelv').textContent = sB.toFixed(2); startB(); if (reduce) drawB(0); };
$('bcd').addEventListener('pointerdown', () => cdOld = cdB);
$('bcd').oninput = () => { cdB = +$('bcd').value; $('bcdv').textContent = cdB; startB(); if (reduce) drawB(0); };
startB();
function drawB(now){
  const c = CB, p = P(), W = c.W, yp = probeY(now), ready = runB[1].n >= NP, [R1, R2] = runB; c.clearRect(0, 0, W, c.H);
  // f_d(r_d)
  const x0 = 50, x1 = 430, ty = 30, th = 120, X = r => x0 + (Math.log10(r)+3)/5*(x1-x0), Yf = f => ty + th - f*th;
  label(c, 'f_d = 1 − tanh((C_d1 r_d)³)', x0, 16, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, ty); c.lineTo(x0, ty+th); c.lineTo(x1, ty+th); c.stroke();
  c.fillStyle = p.f; c.globalAlpha = .08; c.fillRect(X(.5), ty, X(2)-X(.5), th); c.globalAlpha = 1; label(c, 'log layer', X(1), ty+12, p.f, F10, 'center');
  [[cdOld, .35, true], [cdB, 1, false]].forEach(([cd, al, ds]) => { if (ds && cd === cdB) return; c.globalAlpha = al; c.strokeStyle = p.c; c.lineWidth = isAct('fd','F','cd1') ? 3.4 : 2.4; c.setLineDash(ds ? [5,4] : []); c.beginPath();
    for (let q=0;q<=100;q++){ const r = 10**(-3+5*q/100), f = 1 - Math.tanh((cd*r)**3); q ? c.lineTo(X(r), Yf(f)) : c.moveTo(X(r), Yf(f)); } c.stroke(); c.setLineDash([]); c.globalAlpha = 1; });
  ['10⁻³','10⁻²','10⁻¹','1','10','10²'].forEach((s, i) => label(c, s, x0 + i/5*(x1-x0), ty+th+13, p.mut, F10, 'center')); label(c, 'r_d', x1+4, ty+th+4, isAct('rd') ? p.c : p.mut, B11);
  label(c, '1', x0-6, ty+4, p.mut, F10, 'right'); label(c, '0', x0-6, ty+th+4, p.mut, F10, 'right');
  // sensor along the profile: every height of the DDES solution as a dot on the curve
  if (ready) for (let j=4;j<J-1;j+=2){ if (Y[j] > YM*DREF) break; const r = clamp(R2.RD[NP*J+j], 1e-3, 99); c.fillStyle = p.c; c.globalAlpha = .35; c.beginPath(); c.arc(X(r), Yf(1 - Math.tanh((cdB*r)**3)), 2.2, 0, 7); c.fill(); c.globalAlpha = 1; }
  let rdp = 0, fdp = 0; if (ready) { rdp = fAt(R2.RD, NP, yp*DREF); fdp = 1 - Math.tanh((cdB*clamp(rdp, 1e-3, 99))**3); c.fillStyle = p.ink; c.beginPath(); c.arc(X(clamp(rdp, 1e-3, 99)), Yf(fdp), 5.5, 0, 7); c.fill(); }
  // profiles
  const y0 = 232, y1 = 424; axes(c, 40, 205, y0, y1, p, 'f_d and l/d', '0 … 1'); axes(c, 255, 445, y0, y1, p, 'eddy viscosity ν_t', 'ν_t/max');
  label(c, 'y/δ', 22, y0-4, p.mut, F10);
  if (ready) { curve(c, y => fAt(R2.FD, NP, y), 40, 205, y0, y1, 1.05, p.c, isAct('fd','F') ? 3.4 : 2.4);
    curve(c, y => fAt(R1.LD, NP, y), 40, 205, y0, y1, 1.05, p.eq, isAct('l','L') ? 2.6 : 1.6, true);
    curve(c, y => fAt(R2.LD, NP, y), 40, 205, y0, y1, 1.05, p.tau, isAct('l','L') ? 3.4 : 2.2);
    curve(c, y => fAt(REF.R.NUT, NP, y)/nutMax, 255, 445, y0, y1, 1.15, p.f, 2, true);
    curve(c, y => fAt(R1.NUT, NP, y)/nutMax, 255, 445, y0, y1, 1.15, p.eq, 2.4);
    curve(c, y => fAt(R2.NUT, NP, y)/nutMax, 255, 445, y0, y1, 1.15, p.c, isAct('nut') ? 3.4 : 2.6);
    label(c, 'f_d', 120, y1-8, p.c, B11); label(c, 'l/d DDES', 60, y0+14, p.tau, F10); label(c, 'l/d DES97', 120, y0+30, p.eq, F10);
  } else label(c, `solving… x = ${fx(XS[R2.n], 2)}`, 240, y0+40, p.mut, F11, 'center');
  const Yp = y1 - yp/YM*(y1-y0); c.strokeStyle = p.ink; c.globalAlpha = .5; c.lineWidth = 1; c.beginPath(); c.moveTo(40, Yp); c.lineTo(445, Yp); c.stroke(); c.globalAlpha = 1;
  if (ready) { pill(c, 12, 190, `y = ${yp.toFixed(2)}δ · r_d = ${rdp < .01 ? fe(rdp) : fx(rdp, 2)} · f_d = ${fx(fdp, 2)} → DDES ${fdp > .5 && yp > SA.CDES*sB ? 'LES allowed' : 'stays RANS'}`, fdp > .5 ? p.c : p.f, F11);
    $('bcap').textContent = `Δ∥ = ${sB.toFixed(2)}δ, C_d1 = ${cdB}. Solved C_f at x = 0.7: RANS ${fx(CfR*1e3, 3)}·10⁻³, DES97 ${Math.round(100*R1.Cf[NP]/CfR - 100)} %, DDES ${Math.round(100*R2.Cf[NP]/CfR - 100)} %.`; }
}

// ---------------- C: shear layer, grid width and grey area ----------------
const CC = hidpi($('cviz')), VC = {th: -.5, ph: .42, s: 105, ox: 215, oy: 150}; orbit($('cviz'), VC);
let cDef = 0, cH = .1, cAsp = 4, SL = null, XL = 20, lastC = null;
// ν̃ that arrives from the layer: its peak at x = 0.7, made dimensionless with ΔU = 1 and δ_ω = δ
const NT0 = nBmax/DREF;
function solveC(){ const dm = cH*Math.max(1, cAsp), dw = cH; SL = [shearLayer(NT0, SA.CDES*dm, cH, XL), shearLayer(NT0, SA.CDES*dw, cH, XL)];
  const a = SL[cDef], o = SL[1-cDef], nm = ['Δ_max', 'Δ_ω'], xs = s => s.xg === null ? `not within ${XL} δ_ω` : `from x = ${fx(s.xg, 1)} δ_ω`;
  $('ccap').textContent = `${nm[cDef]} = ${fx(cDef ? dw : dm, 2)} δ_ω: grid-scale eddies can survive ${xs(a)} (with ${nm[1-cDef]}: ${xs(o)}). Inherited ν_t = ${fx(NT0, 4)} ΔUδ_ω.`; }
$('ch').oninput = () => { cH = +$('ch').value; $('chv').textContent = cH.toFixed(2); solveC(); if (reduce) drawC(0); };
$('ca').oninput = () => { cAsp = +$('ca').value; $('cav').textContent = cAsp.toFixed(1); solveC(); if (reduce) drawC(0); };
const setDef = k => { cDef = k; $('cmax').classList.toggle('pri', !k); $('com').classList.toggle('pri', !!k); solveC(); if (reduce) drawC(0); };
$('cmax').onclick = () => setDef(0); $('com').onclick = () => setDef(1);
solveC();
function drawC(now){
  const c = CC, p = P(), W = c.W, a = SL[cDef], o = SL[1-cDef]; c.clearRect(0, 0, W, c.H);
  if (!VC.drag && !reduce && lastC !== null) VC.th += Math.min(100, now - lastC)*.00006; lastC = now;
  const P3 = (x, y, z) => proj(VC, x, y, z), hz = .55, XW = v => v/XL*1.9, poly = (pts, fill, al) => { c.globalAlpha = al; c.fillStyle = fill; c.beginPath(); pts.map(v => P3(...v)).forEach(([x, y], i) => i ? c.lineTo(x, y) : c.moveTo(x, y)); c.closePath(); c.fill(); c.globalAlpha = 1; };
  // step: upper wall, step face, lower wall
  poly([[-1.3,0,-hz],[0,0,-hz],[0,0,hz],[-1.3,0,hz]], p.mut, .25); poly([[0,0,-hz],[0,-.6,-hz],[0,-.6,hz],[0,0,hz]], p.mut, .35); poly([[0,-.6,-hz],[1.9,-.6,-hz],[1.9,-.6,hz],[0,-.6,hz]], p.mut, .18);
  // attached RANS layer upstream (f_d = 0)
  poly([[-1.3,0,-hz],[0,0,-hz],[0,.1,-hz],[-1.3,.1,-hz]], p.f, .35); label(c, 'RANS, f_d = 0', P3(-1.25,.12,-hz)[0], P3(-1.25,.12,-hz)[1]-6, p.f, F10);
  // shear layer: coloured by the modelled ν_t it still carries
  const M = a.x.length - 1;
  for (let m=0;m<M;m+=4){ const x0 = XW(a.x[m]), x1 = XW(a.x[Math.min(M, m+4)]), sp0 = .05 + .03*x0, r = clamp(a.nut[m]/NT0, 0, 1.5);
    poly([[x0,-sp0*x0*.6,-hz],[x1,-sp0*x1*.6,-hz],[x1,-sp0*x1*.6,hz],[x0,-sp0*x0*.6,hz]], p.nu, .12 + .45*Math.min(1, r)*(isAct('nut','M','tau') ? 1.3 : 1)); }
  // resolved rollers only where the eddies can survive
  const tt = reduce ? 0 : now/1000;
  if (a.xg !== null) for (let k=0;k<14;k++){ const xd = a.xg + ((k*1.7 + tt*1.3) % (XL - a.xg)), xw = XW(xd), grow = clamp((xd - a.xg)/4, 0, 1), rad = .03 + .07*grow*Math.min(1, xd/8);
    if (xw > 1.85) continue; const yc = -(.05 + .03*xw)*xw*.6, A1 = P3(xw, yc, -hz), A2 = P3(xw, yc, hz), pr = VC.s*rad;
    c.strokeStyle = p.f; c.globalAlpha = .25 + .6*grow; c.lineWidth = isAct('res') ? 2.4 : 1.5; c.beginPath(); c.ellipse(A1[0], A1[1], pr*.6, pr, 0, 0, 7); c.stroke(); c.beginPath(); c.moveTo(A1[0], A1[1]-pr); c.lineTo(A2[0], A2[1]-pr); c.moveTo(A1[0], A1[1]+pr); c.lineTo(A2[0], A2[1]+pr); c.stroke(); c.globalAlpha = 1; }
  if (a.xg !== null) { const g = XW(a.xg), b0 = P3(g, .15, -hz), b1 = P3(g, -.6, -hz); c.setLineDash([4,4]); c.strokeStyle = p.ink; c.lineWidth = 1.2; c.beginPath(); c.moveTo(b0[0], b0[1]); c.lineTo(b1[0], b1[1]); c.stroke(); c.setLineDash([]); label(c, 'eddies survive →', b0[0]+4, b0[1], p.ink, F10); }
  // one sample cell behind the corner, drawn 3× for visibility, with its spin axis
  { const s = Math.min(.3, 2.8*cH), cx0 = .45, Vb = {...VC, ox: P3(cx0, -.25, 0)[0], oy: P3(cx0, -.25, 0)[1]}, on = isAct('hx','Del','dw','G','nv');
    box(c, Vb, s/2, s/2, Math.min(.5, s*cAsp/2), on ? p.cs : p.mut, on ? 2 : 1.2);
    const n0 = proj(Vb, 0, 0, 0), n1 = proj(Vb, 0, 0, Math.min(.5, s*cAsp/2) + .25); arrow(c, n0[0], n0[1], n1[0], n1[1], p.u, isAct('nv') ? 2.6 : 1.6); label(c, 'n', n1[0]+5, n1[1]+4, p.u, MATH);
    label(c, `cell: Δz = ${cAsp}Δx`, n0[0]+12, n0[1]+30, p.cs, F10); }
  triad(c, VC, 30, 225, p);
  // plot: ν_t/ν_t0 and the damping ratio along the layer (log scale)
  const x0 = 50, x1 = 440, y0 = 278, y1 = 418, Xp = v => x0 + v/XL*(x1-x0), Yl = v => y1 - (Math.log10(clamp(v, 1e-3, 1e3)) + 3)/6*(y1-y0);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x0, y1); c.lineTo(x1, y1); c.stroke();
  label(c, 'along the shear layer', (x0+x1)/2, y0-10, p.ink, SANS, 'center'); label(c, 'x/δ_ω', x1, y0+2, p.mut, F10, 'right');
  ['10⁻³','1','10³'].forEach((s, i) => label(c, s, x0-5, y1 - i*.5*(y1-y0) + 4, p.mut, F10, 'right')); [0, 5, 10, 15, 20].forEach(v => label(c, String(v), Xp(v), y1+14, p.mut, F10, 'center'));
  const gEnd = a.xg === null ? XL : a.xg; c.fillStyle = p.mut; c.globalAlpha = .12; c.fillRect(x0, y0, Xp(gEnd) - x0, y1-y0); c.globalAlpha = 1; label(c, 'grey area', x0+6, y0+12, p.mut, F10);
  c.setLineDash([4,4]); c.strokeStyle = p.ink; c.beginPath(); c.moveTo(x0, Yl(1)); c.lineTo(x1, Yl(1)); c.stroke(); c.setLineDash([]); label(c, 'damping = shear', x1-2, Yl(1)-4, p.ink, F10, 'right');
  const ln = (arr, col, lw, al, ds) => { c.globalAlpha = al; c.strokeStyle = col; c.lineWidth = lw; c.setLineDash(ds ? [5,4] : []); c.beginPath(); for (let m=0;m<=M;m+=2){ const X = Xp(a.x[m]), Yv = Yl(arr[m]); m ? c.lineTo(X, Yv) : c.moveTo(X, Yv); } c.stroke(); c.setLineDash([]); c.globalAlpha = 1; };
  ln(o.D, p.cs, 1.3, .45, true); ln(a.D, p.cs, isAct('Del','dw','G') ? 3.4 : 2.4, 1);
  ln(a.nut.map(v => v/NT0), p.nu, isAct('nut','M','tau') ? 3 : 2, 1);
  label(c, 'ν_t / inherited', x0+8, Yl(a.nut[8]/NT0)-6, p.nu, F10); label(c, 'damping ν_t(π/Δx)² / S', Xp(10), Math.min(y1-4, Yl(a.D[200])-6), p.cs, F10, 'center');
}

// ---------------- BUILD: the plate in 3D, DES97 and DDES marched live ----------------
const SC = hidpi($('sim')), VS = {th: -.45, ph: .5, s: 136, ox: 250, oy: 280}; orbit($('sim'), VS);
const YD = 1.6*REF.R.d99[NS-1], IW = 200, IH = 64, img = new ImageData(IW, IH), off = document.createElement('canvas'); off.width = IW; off.height = IH;
const colN = new Float32Array(IW); for (let i=0;i<IW;i++){ const x = (i+.5)/IW; colN[i] = x < X0 ? -1 : (NS-1)*Math.log(x/X0)/Math.log(X1/X0); }
const rowJ = new Int32Array(IH); for (let r=0;r<IH;r++) rowJ[r] = jAt((IH-1-r+.5)/IH*YD);
let simOn = false, sBld = .3, simRuns = null, simJob = null, field = 0, probeX = .85, ghostS = [], sBld0 = .3, lastS = null;
function startSim(){ if (simRuns && simRuns[0].n >= NS-1) ghostS = [{s: sBld0, cf: Float64Array.from(simRuns[0].Cf)}, ...ghostS.filter(g => g.s !== sBld)].slice(0, 3);
  sBld0 = sBld; simRuns = [newRun(1, refined(sBld*DREF)), newRun(2, refined(sBld*DREF))]; simJob = job(simRuns, NS-1, null, reduce ? 1e9 : 5); }
$('del').oninput = () => { sBld = +$('del').value; $('delv').textContent = sBld.toFixed(2); if (simOn) startSim(); if (reduce) drawSim(0); };
$('px').oninput = () => { probeX = +$('px').value; $('pxv').textContent = probeX.toFixed(2); if (reduce) drawSim(0); };
$('fields').onclick = e => { const b = e.target.closest('[data-f]'); if (!b) return; field = +b.dataset.f; $('fields').querySelectorAll('[data-f]').forEach(x => x.classList.toggle('pri', x === b)); if (reduce) drawSim(0); };
function drawSim(now){
  const c = SC, p = P(), [R1, R2] = simRuns || [null, null], nDone = R1 ? R1.n : -1; c.clearRect(0, 0, c.W, c.H);
  if (!VS.drag && !reduce && lastS !== null && now) VS.th = -.45 + .18*Math.sin(now/5000); lastS = now;
  const WX = x => -1.5 + 3*x, WY = y => y/YD*.9, hz = .45, P3 = (x, y, z) => proj(VS, x, y, z), del = refined(sBld*DREF);
  // back face (z = −hz): the chosen field, rasterised and mapped with the projection (orthographic → affine)
  const pal = [P().f, p.eq, p.c, p.nu].map(K.hex), bg = K.hex(p.bg), d = img.data;
  for (let r=0;r<IH;r++) for (let i=0;i<IW;i++){ const o = (r*IW+i)*4, nf = colN[i], n = Math.round(nf); let col = null, al = 0;
    if (n >= 0 && n <= nDone) { const k = n*J + rowJ[r], inBL = Y[rowJ[r]] < REF.R.d99[n];
      if (field === 0 || field === 2) { const R = field ? R2 : R1, les = R.LD[k] < .98; col = les ? pal[1] : pal[0]; al = (les ? .75 : .45)*(inBL ? 1 : .35); }
      else if (field === 1) { col = pal[2]; al = .1 + .8*R2.FD[k]; }
      else { const loss = 1 - R1.NUT[k]/Math.max(1e-20, REF.R.NUT[k]); col = pal[3]; al = clamp(loss, 0, 1)*(inBL ? 1 : .3); } }
    for (let t=0;t<3;t++) d[o+t] = col ? bg[t] + (col[t]-bg[t])*al : bg[t]; d[o+3] = col ? 255 : 120; }
  off.getContext('2d').putImageData(img, 0, 0);
  { const O = P3(-1.5, .9, -hz), Ex = P3(1.5, .9, -hz), Ey = P3(-1.5, 0, -hz); c.save(); c.transform((Ex[0]-O[0])/IW, (Ex[1]-O[1])/IW, (Ey[0]-O[0])/IH, (Ey[1]-O[1])/IH, O[0], O[1]); c.imageSmoothingEnabled = true; c.drawImage(off, 0, 0); c.restore(); }
  box(c, {...VS, ox: P3(0, .45, 0)[0], oy: P3(0, .45, 0)[1]}, 1.5, .45, hz, p.rule, .8);
  // plate with its wall-parallel grid (coarse upstream, refined downstream)
  const q = [[-1.5,0,-hz],[1.5,0,-hz],[1.5,0,hz],[-1.5,0,hz]].map(v => P3(...v)); c.fillStyle = p.panel; c.globalAlpha = .82; c.beginPath(); q.forEach(([x, y], i) => i ? c.lineTo(x, y) : c.moveTo(x, y)); c.closePath(); c.fill(); c.globalAlpha = 1;
  c.strokeStyle = p.rule; c.lineWidth = .7; c.beginPath(); let skip = 0;
  for (let x = 0, k = 0; x <= 1; x += del(x), k++){ const d3 = 3*del(x)*VS.s, ev = Math.max(1, Math.ceil(2.5/d3)); if (k % ev) continue; const a = P3(WX(x),0,-hz), b = P3(WX(x),0,hz); c.moveTo(a[0],a[1]); c.lineTo(b[0],b[1]); if (ev > 1) skip = ev; }
  for (const [xa, xb, dz] of [[0, XR, DC], [XR+.1, 1, sBld*DREF]]) { const ev = Math.max(1, Math.ceil(2.5/(3*dz*VS.s))); if (ev > 1) skip = Math.max(skip, ev); for (let z = -hz, k = 0; z <= hz; z += 3*dz, k++){ if (k % ev) continue; const a = P3(WX(xa),0,z), b = P3(WX(xb),0,z); c.moveTo(a[0],a[1]); c.lineTo(b[0],b[1]); } }
  c.stroke();
  // boundary-layer edge and the DES switch height on the side face
  c.setLineDash([4,4]); c.strokeStyle = p.ink; c.lineWidth = 1.2; c.beginPath(); for (let n=0;n<NS;n+=4){ const A = P3(WX(XS[n]), WY(REF.R.d99[n]), -hz); n ? c.lineTo(A[0], A[1]) : c.moveTo(A[0], A[1]); } c.stroke(); c.setLineDash([]);
  c.strokeStyle = p.tau; c.lineWidth = 1.8; c.beginPath(); for (let i=0;i<=100;i++){ const x = .02 + .98*i/100, A = P3(WX(x), Math.min(.9, WY(SA.CDES*del(x))), -hz); i ? c.lineTo(A[0], A[1]) : c.moveTo(A[0], A[1]); } c.stroke();
  { const A = P3(1.5, WY(REF.R.d99[NS-1]), -hz); label(c, 'δ', A[0]+6, A[1]+4, p.ink, MATH); const B = P3(1.5, Math.min(.9, WY(SA.CDES*sBld*DREF)), -hz); label(c, 'C_DES Δ', B[0]+6, B[1]+4, p.tau, F10); }
  // the march front and the probe station
  if (R1 && nDone < NS-1) { const A = P3(WX(XS[nDone]), 0, -hz), B = P3(WX(XS[nDone]), .9, -hz); c.strokeStyle = p.acc; c.lineWidth = 2.5; c.beginPath(); c.moveTo(A[0], A[1]); c.lineTo(B[0], B[1]); c.stroke(); label(c, `marching x = ${fx(XS[nDone], 2)}`, B[0], B[1]-8, p.acc, B11, 'center'); }
  { const A = P3(WX(probeX), 0, -hz), B = P3(WX(probeX), .9, -hz); c.setLineDash([2,3]); c.strokeStyle = p.ink; c.lineWidth = 1.2; c.beginPath(); c.moveTo(A[0], A[1]); c.lineTo(B[0], B[1]); c.stroke(); c.setLineDash([]); }
  { const f0 = P3(-1.85, .45, hz), f1 = P3(-1.55, .45, hz); arrow(c, f0[0], f0[1], f1[0], f1[1], p.ink, 2); label(c, 'flow', f0[0], f0[1]-8, p.mut, F10, 'center'); }
  triad(c, VS, 34, 400, p);
  label(c, `wall-normal scale ×${Math.round(.9/YD/3)} · grid refined from x = 0.4 · back face: field`, 12, 18, p.mut, F10); if (skip > 1) label(c, `grid: every ${skip}th line drawn`, 12, 32, p.mut, F10);
  label(c, ['DES97: blue RANS, orange LES (strong inside δ)', 'DDES: shielding f_d (green = 1, LES allowed)', 'DDES: blue RANS, orange LES', 'share of RANS ν_t lost by DES97'][field], 12, 46, p.ink, F11);
  // Cf(x)
  const gx0 = 520, gx1 = 748, gy0 = 30, gy1 = 190, Xc = x => gx0 + x*(gx1-gx0), Yc = v => gy1 - (v*1e3 - 1)/3*(gy1-gy0);
  label(c, 'skin friction C_f × 10³', (gx0+gx1)/2, 16, p.ink, SANS, 'center');
  c.fillStyle = p.tau; c.globalAlpha = .07; c.fillRect(Xc(XR), gy0, Xc(1)-Xc(XR), gy1-gy0); c.globalAlpha = 1;
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(gx0, gy0); c.lineTo(gx0, gy1); c.lineTo(gx1, gy1); c.stroke();
  [1, 2, 3, 4].forEach(v => label(c, String(v), gx0-5, Yc(v/1e3)+4, p.mut, F10, 'right')); [0, .5, 1].forEach(v => label(c, String(v), Xc(v), gy1+13, p.mut, F10, 'center')); label(c, 'x', gx1-4, gy1-6, p.mut, MATH);
  const cfl = (cf, nmax, col, lw, ds, al) => { c.globalAlpha = al || 1; c.strokeStyle = col; c.lineWidth = lw; c.setLineDash(ds ? [5,4] : []); c.beginPath(); for (let n=12;n<=nmax;n++){ const X = Xc(XS[n]), Yv = Yc(clamp(cf[n], .001, .0045)); n > 12 ? c.lineTo(X, Yv) : c.moveTo(X, Yv); } c.stroke(); c.setLineDash([]); c.globalAlpha = 1; };
  ghostS.forEach((g, i) => cfl(g.cf, NS-1, p.eq, 1.1, false, .35 - .1*i));
  c.globalAlpha = .7; c.fillStyle = p.ink; for (let n=10;n<NS;n+=12){ c.beginPath(); c.arc(Xc(XS[n]), Yc(coles(REF.R.Rth[n])), 1.6, 0, 7); c.fill(); } c.globalAlpha = 1;
  cfl(REF.R.Cf, NS-1, p.f, 2, true); if (R1) { cfl(R1.Cf, nDone, p.eq, 2.4); cfl(R2.Cf, nDone, p.c, 2.4); }
  c.setLineDash([2,3]); c.strokeStyle = p.ink; c.beginPath(); c.moveTo(Xc(probeX), gy0); c.lineTo(Xc(probeX), gy1); c.stroke(); c.setLineDash([]);
  label(c, '┄ RANS — DES97 — DDES · Coles–F.', gx0, gy1+28, p.mut, F10);
  // modelled stress profile at the probe
  const np = stAt(probeX), hy0 = 248, hy1 = 412, utR2 = REF.R.Cf[np]/2, dl = REF.R.d99[np], Xs = v => gx0 + v/1.1*(gx1-gx0), Ys = yd => hy1 - yd/YM*(hy1-hy0);
  label(c, `modelled stress ν_t∂U/∂y at x = ${probeX.toFixed(2)}`, (gx0+gx1)/2, hy0-12, p.ink, SANS, 'center');
  c.strokeStyle = p.rule; c.beginPath(); c.moveTo(gx0, hy0); c.lineTo(gx0, hy1); c.lineTo(gx1, hy1); c.stroke(); label(c, 'y/δ', gx0-6, hy0-2, p.mut, F10, 'right'); label(c, '÷ u_τ²', gx1, hy1+13, p.mut, F10, 'right');
  [0, .5, 1].forEach(v => label(c, String(v), gx0-5, Ys(v)+4, p.mut, F10, 'right'));
  const prof = (R, col, lw, ds) => { c.strokeStyle = col; c.lineWidth = lw; c.setLineDash(ds ? [5,4] : []); c.beginPath(); for (let q=1;q<=80;q++){ const yd = YM*q/80, v = fAt(R.TAU, np, yd*dl)/utR2; q > 1 ? c.lineTo(Xs(clamp(v, 0, 1.1)), Ys(yd)) : c.moveTo(Xs(clamp(v, 0, 1.1)), Ys(yd)); } c.stroke(); c.setLineDash([]); };
  prof(REF.R, p.f, 2, true); if (R1 && nDone >= np) { prof(R1, p.eq, 2.4); prof(R2, p.c, 2.4); }
  if (R1 && nDone >= NS-1) { const n9 = stAt(.9), g1 = R1.Cf[n9]/REF.R.Cf[n9] - 1, g2 = R2.Cf[n9]/REF.R.Cf[n9] - 1, lc = SA.CDES*sBld;
    $('stat').textContent = `Δx = Δz = ${sBld.toFixed(2)}δ_ref → switch height C_DES Δ ≈ ${lc.toFixed(2)}δ_ref: ${lc < 1 ? 'inside the boundary layer (ambiguous grid)' : 'above the layer (natural DES grid)'}. C_f at x = 0.9: RANS ${fx(REF.R.Cf[n9]*1e3, 3)}·10⁻³, DES97 ${g1 >= 0 ? '+' : ''}${(100*g1).toFixed(1)} %, DDES ${g2 >= 0 ? '+' : ''}${(100*g2).toFixed(1)} %${g1 < -.05 ? ' → modelled-stress depletion' : ''}.`; }
}

// ---------------- PARALLEL: partitioning and cost against Re ----------------
const PT = hidpi($('part')); let pmode = null;
const PX = 48, PCOL = Array.from({length: PX}, (_, i) => (i >= 26 && i < 42) ? 24 : 3);   // cells per column: LES box fine, RANS coarse
function cuts(mode){ if (mode === 'vol') return [0, 12, 24, 36, 48];
  const tot = PCOL.reduce((a, b) => a+b, 0), cum = [0]; PCOL.forEach(v => cum.push(cum[cum.length-1] + v));
  const cs = [0]; for (let k=1;k<4;k++){ let best = cs[k-1]+1; for (let i=cs[k-1]+1;i<PX;i++) if (Math.abs(cum[i] - k*tot/4) < Math.abs(cum[best] - k*tot/4)) best = i; cs.push(best); } cs.push(PX); return cs; }
function drawPart(){ const c = PT, p = P(); c.clearRect(0, 0, c.W, c.H); const cw = 6, x0 = 16, y0 = 20, h = 120, cols = [p.f, p.eq, p.c, p.tau];
  label(c, 'mesh (cells drawn per column)', x0, 12, p.mut, F10);
  const cs = pmode ? cuts(pmode) : null, rank = i => cs ? cs.findIndex((v, k) => i >= v && i < cs[k+1]) : -1;
  for (let i=0;i<PX;i++){ const n = PCOL[i], rk = rank(i); c.fillStyle = rk >= 0 ? cols[rk] : p.rule; c.globalAlpha = rk >= 0 ? .35 : .5; c.fillRect(x0 + i*cw, y0, cw-1, h); c.globalAlpha = 1;
    c.strokeStyle = p.panel; c.lineWidth = .5; const m = Math.sqrt(n); for (let k=1;k<m;k++){ c.beginPath(); c.moveTo(x0 + i*cw, y0 + k*h/m); c.lineTo(x0 + i*cw + cw-1, y0 + k*h/m); c.stroke(); } }
  label(c, 'LES box', x0 + 34*cw, y0+h+12, p.eq, F10, 'center');
  if (cs) { cs.slice(1, -1).forEach(v => { c.strokeStyle = p.ink; c.lineWidth = 2; c.beginPath(); c.moveTo(x0 + v*cw - .5, y0-4); c.lineTo(x0 + v*cw - .5, y0+h+4); c.stroke(); });
    const load = [0,1,2,3].map(r => PCOL.slice(cs[r], cs[r+1]).reduce((a, b) => a+b, 0)), mx = Math.max(...load), avg = load.reduce((a, b) => a+b, 0)/4;
    load.forEach((v, r) => { c.fillStyle = cols[r]; rr(c, x0 + r*72, 228 - 40*v/mx, 50, 40*v/mx, 3); c.fill(); label(c, `rank ${r}: ${v}`, x0 + r*72 + 25, 242, p.mut, F10, 'center'); });
    label(c, `slowest / average = ${fx(mx/avg, 2)}`, x0, y0+h+30, p.ink, B11); } }
$('pvol').onclick = () => { pmode = 'vol'; drawPart(); const fb = $('pfb'); fb.className = 'fb bad'; fb.textContent = 'Equal volumes: the rank holding the LES box gets most of the cells, and the other three wait for it every step (and at every halo exchange).'; };
$('pcell').onclick = () => { pmode = 'cell'; drawPart(); const fb = $('pfb'); fb.className = 'fb good'; fb.textContent = '✓ Equal cell counts: the LES box is split across ranks, so all four finish each step together. Real codes weight cells by cost (graph partitioners such as METIS) and re-balance if the LES region moves.'; K.done('parallel'); };
const CT = hidpi($('cost'));
function costs(Re){ const nu = 1/Re, cf = x => .455/Math.log(.06*x*Re)**2, ut = x => Math.sqrt(cf(x)/2), dl = x => .37*x*(x*Re)**-.2;
  let nwr = 0, dxmin = 1; for (let q=0;q<400;q++){ const x = .01 + .99*(q+.5)/400, dxp = 50*nu/ut(x), dzp = 15*nu/ut(x); nwr += 60*(.99/400)/(dxp*dzp); dxmin = Math.min(dxmin, dxp); }
  const ny = 20 + Math.log(dl(1)*ut(1)/nu)/Math.log(1.2), nR = 200*200*ny, nL = (.3/.002)*(.1/.002)*(1/.002);
  return { N: [nR, nR + nL, nwr], S: [1e3, 20/(.5*.002), 20/(.5*dxmin)] }; }
function drawCost(){ const Re = 10**+$('re').value, c = CT, p = P(), {N, S} = costs(Re); c.clearRect(0, 0, c.W, c.H); $('rev').textContent = `10${sup(Math.round(+$('re').value*10)/10)}`.replace('.', '·');
  const groups = [['grid points', N], ['time steps', S], ['cost = points × steps', N.map((v, i) => v*S[i])]], nm = ['RANS', 'DDES', 'WRLES'], cols = [p.f, p.c, p.eq], Yl = v => 230 - (Math.log10(v) - 2)/18*200;
  c.strokeStyle = p.rule; c.beginPath(); c.moveTo(50, 30); c.lineTo(50, 230); c.lineTo(650, 230); c.stroke(); [2, 8, 14, 20].forEach(e => label(c, `10${sup(e)}`, 44, Yl(10**e)+4, p.mut, F10, 'right'));
  groups.forEach(([g, v], gi) => { const gx = 80 + gi*195; label(c, g, gx + 75, 250, p.ink, SANS, 'center'); v.forEach((val, k) => { const x = gx + k*52, y = Yl(val); c.fillStyle = cols[k]; rr(c, x, y, 40, 230-y, 3); c.fill(); label(c, nm[k], x+20, 264, cols[k], F10, 'center'); label(c, sci(val).replace(/\.\d\d/, m => m.slice(0, 2)), x+20, y-5, p.ink, F10, 'center'); }); });
  const r = N[2]*S[2]/(N[1]*S[1]); $('costcap').textContent = `At Re_L = ${sci(Re)}: wall-resolved LES costs ≈ ${sci(r)} × a DDES of the same plate. DDES pays ~${Math.round(S[1]/S[0])}× more steps than steady RANS for the LES region; its cell count barely grows with Re because the boundary layers stay RANS.`; }
$('re').oninput = drawCost;

drawA(0); drawB(0); drawC(0); drawOps(0);
let openB = '0';
return {
  frame(now, stp){
    if (stp === 0) { for (const jb of [jobA, jobB]) if (jb && !jb.done) pump(jb, 4);
      if (openB === '0') drawOps(now); else if (openB === 'A') drawA(now); else if (openB === 'B') drawB(now); else if (openB === 'C') drawC(now); }
    if (stp === 1 && simOn) { if (simJob && !simJob.done) pump(simJob, 8); drawSim(now); }
  },
  onBlock(k){ openB = k; if (reduce) K.redraw(); },
  onStep(stp){ if (stp === 2) { drawPart(); drawCost(); } if (stp === 1 && reduce && simOn) drawSim(0); },
  buildReset(){ simOn = false; simRuns = null; drawSim(0); $('stat').textContent = 'Put the steps in order to start the solver.'; },
  buildStart(){ simOn = true; startSim(); drawSim(0); },
};
}
CFD.register({ id: 'ddes', name: 'DDES', sub: 'hybrid RANS–LES',
  lede: 'One eddy-viscosity model plays two roles: <strong>RANS</strong> near walls, a <strong>subgrid (LES) model</strong> away from them. A length scale decides which, and a <strong>shielding function</strong> keeps attached boundary layers in RANS.',
  blocks, checks, quiz, build, parallel, sources, terms, bench, mount,
  unlock: 'The DDES row of the comparison is now visible: RANS cost in attached boundary layers, LES fidelity in separated regions, and the grey area between them. Complete the other methods to open the full page.' });
})();
