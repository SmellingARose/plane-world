// Potential flow: a 3D constant-source panel method (Hess & Smith). See ../README.md for the spec.
// Wrapped in a closure so its helpers do not collide with other modules in the built page.
(() => {
const tnow = () => (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
const FP = 1/(4*Math.PI);

// ================= SOLVER CORE (shared by the Learn visuals, the Build solver and bench) =================
// Cubed-sphere mesh: each cube face cut into n×n equiangular cells, vertices pushed onto the sphere,
// then scaled to an ellipsoid with semi-axes (ax, 1, 1). Panels are flat quads: N = 6n².
function mesh(n, ax){
  ax = ax || 1;
  const F = [[[1,0,0],[0,1,0],[0,0,1]],[[-1,0,0],[0,0,1],[0,1,0]],[[0,1,0],[0,0,1],[1,0,0]],[[0,-1,0],[1,0,0],[0,0,1]],[[0,0,1],[1,0,0],[0,1,0]],[[0,0,-1],[0,1,0],[1,0,0]]];
  const N = 6*n*n, V = new Float64Array(N*12), C = new Float64Array(N*3), Nn = new Float64Array(N*3), S = new Float64Array(N);
  const pt = (f, a, b) => { const [o,u,v] = F[f], s = Math.tan(Math.PI/4*(2*a/n-1)), t = Math.tan(Math.PI/4*(2*b/n-1));
    const x = o[0]+s*u[0]+t*v[0], y = o[1]+s*u[1]+t*v[1], z = o[2]+s*u[2]+t*v[2], L = Math.hypot(x,y,z); return [ax*x/L, y/L, z/L]; };
  let k = 0;
  for (let f=0;f<6;f++) for (let a=0;a<n;a++) for (let b=0;b<n;b++, k++){
    const q = [pt(f,a,b), pt(f,a+1,b), pt(f,a+1,b+1), pt(f,a,b+1)];
    for (let m=0;m<4;m++) for (let d=0;d<3;d++) V[k*12+m*3+d] = q[m][d];
    const cx = (q[0][0]+q[1][0]+q[2][0]+q[3][0])/4, cy = (q[0][1]+q[1][1]+q[2][1]+q[3][1])/4, cz = (q[0][2]+q[1][2]+q[2][2]+q[3][2])/4;
    const d1 = [q[2][0]-q[0][0], q[2][1]-q[0][1], q[2][2]-q[0][2]], d2 = [q[3][0]-q[1][0], q[3][1]-q[1][1], q[3][2]-q[1][2]];
    let nx = d1[1]*d2[2]-d1[2]*d2[1], ny = d1[2]*d2[0]-d1[0]*d2[2], nz = d1[0]*d2[1]-d1[1]*d2[0]; const L = Math.hypot(nx,ny,nz);
    nx /= L; ny /= L; nz /= L; if (nx*cx+ny*cy+nz*cz < 0) { nx = -nx; ny = -ny; nz = -nz; }
    C[k*3] = cx; C[k*3+1] = cy; C[k*3+2] = cz; Nn[k*3] = nx; Nn[k*3+1] = ny; Nn[k*3+2] = nz; S[k] = L/2;
  }
  return {N, V, C, Nn, S, n, ax};
}
// near-field quadrature: each panel also stored as QM×QM sub-quads (point + area), used when the target is close
const QM = 4, QQ = QM*QM;
function prep(M){ const N = M.N, V = M.V; M.QP = new Float64Array(N*QQ*3); M.QW = new Float64Array(N*QQ);
  for (let j=0;j<N;j++){ const o = j*12, at = (s,t,d) => (1-s)*(1-t)*V[o+d] + s*(1-t)*V[o+3+d] + s*t*V[o+6+d] + (1-s)*t*V[o+9+d];
    let ws = 0, q = 0;
    for (let a=0;a<QM;a++) for (let b=0;b<QM;b++, q++){ const s0=a/QM, s1=(a+1)/QM, t0=b/QM, t1=(b+1)/QM, P = [], d1 = [], d2 = [];
      for (let d=0;d<3;d++){ d1.push(at(s1,t1,d)-at(s0,t0,d)); d2.push(at(s0,t1,d)-at(s1,t0,d)); M.QP[(j*QQ+q)*3+d] = at((s0+s1)/2,(t0+t1)/2,d); }
      const w = Math.hypot(d1[1]*d2[2]-d1[2]*d2[1], d1[2]*d2[0]-d1[0]*d2[2], d1[0]*d2[1]-d1[1]*d2[0])/2; M.QW[j*QQ+q] = w; ws += w; }
    for (let q2=0;q2<QQ;q2++) M.QW[j*QQ+q2] *= M.S[j]/ws; }
  return M; }
// velocity at (x,y,z) induced by a unit source density on panel j (j ≠ the panel the point sits on)
function infl(M, j, x, y, z, o){
  const C = M.C, dx = x-C[j*3], dy = y-C[j*3+1], dz = z-C[j*3+2], r2 = dx*dx+dy*dy+dz*dz;
  if (r2 >= 9*M.S[j]) { const s = M.S[j]*FP/(r2*Math.sqrt(r2)); o[0] = s*dx; o[1] = s*dy; o[2] = s*dz; return; }
  o[0] = o[1] = o[2] = 0;
  for (let q=0;q<QQ;q++){ const k = (j*QQ+q)*3, ex = x-M.QP[k], ey = y-M.QP[k+1], ez = z-M.QP[k+2], e2 = ex*ex+ey*ey+ez*ez, s = M.QW[j*QQ+q]*FP/(e2*Math.sqrt(e2));
    o[0] += s*ex; o[1] += s*ey; o[2] += s*ez; } }
const _o = [0,0,0];
// operator A, one row: A_ij = ½δ_ij + (normal velocity at centroid i from unit σ on panel j)
function assembleRow(M, A, i){ const N = M.N, C = M.C, Nn = M.Nn, x = C[i*3], y = C[i*3+1], z = C[i*3+2], nx = Nn[i*3], ny = Nn[i*3+1], nz = Nn[i*3+2];
  for (let j=0;j<N;j++){ if (j === i) { A[i*N+j] = 0.5; continue; } infl(M, j, x, y, z, _o); A[i*N+j] = _o[0]*nx+_o[1]*ny+_o[2]*nz; } }
// operator V, one panel: u_iα = U∞α + ½σ_i n_iα + Σ_j≠i σ_j × (velocity from panel j)
function velRow(M, sig, U, i, out){ const N = M.N, C = M.C, x = C[i*3], y = C[i*3+1], z = C[i*3+2];
  let u = U[0] + .5*sig[i]*M.Nn[i*3], v = U[1] + .5*sig[i]*M.Nn[i*3+1], w = U[2] + .5*sig[i]*M.Nn[i*3+2];
  for (let j=0;j<N;j++){ if (j === i) continue; infl(M, j, x, y, z, _o); u += _o[0]*sig[j]; v += _o[1]*sig[j]; w += _o[2]*sig[j]; }
  out[0] = u; out[1] = v; out[2] = w; }
// direct solve, one pivot column at a time (Gaussian elimination with partial pivoting = LU)
function luCol(A, N, b, k){ let p = k, mx = Math.abs(A[k*N+k]);
  for (let r=k+1;r<N;r++){ const v = Math.abs(A[r*N+k]); if (v > mx) { mx = v; p = r; } }
  if (p !== k) { for (let c=0;c<N;c++){ const t = A[k*N+c]; A[k*N+c] = A[p*N+c]; A[p*N+c] = t; } const t = b[k]; b[k] = b[p]; b[p] = t; }
  const piv = A[k*N+k], ko = k*N;
  for (let r=k+1;r<N;r++){ const ro = r*N, f = A[ro+k]/piv; if (!f) continue; A[ro+k] = 0; for (let c=k+1;c<N;c++) A[ro+c] -= f*A[ko+c]; b[r] -= f*b[k]; } }
function backSub(A, N, b){ const x = new Float64Array(N); for (let k=N-1;k>=0;k--){ let s = b[k]; for (let c=k+1;c<N;c++) s -= A[k*N+c]*x[c]; x[k] = s/A[k*N+k]; } return x; }
function solveSmall(A, b){ const N = b.length, M = new Float64Array(N*N), r = Float64Array.from(b); A.forEach((row,i) => row.forEach((v,j) => M[i*N+j] = v)); for (let k=0;k<N;k++) luCol(M, N, r, k); return backSub(M, N, r); }
// iterative solve: GMRES (Saad & Schultz 1986), one Arnoldi step per call
const nrm = v => { let s = 0; for (let i=0;i<v.length;i++) s += v[i]*v[i]; return Math.sqrt(s); };
function gmInit(A, N, b, tol){ const beta = nrm(b), v0 = new Float64Array(N); for (let i=0;i<N;i++) v0[i] = b[i]/beta;
  return {A, N, beta, V: [v0], H: [], cs: [], sn: [], g: [beta], m: 0, hist: [1], tol: tol || 1e-10, mmax: 80}; }
function gmStep(G){ const {A, N} = G, m = G.m, v = G.V[m], w = new Float64Array(N);
  for (let i=0;i<N;i++){ let s = 0; const o = i*N; for (let j=0;j<N;j++) s += A[o+j]*v[j]; w[i] = s; }
  const h = new Float64Array(m+2);
  for (let k=0;k<=m;k++){ const Vk = G.V[k]; let s = 0; for (let i=0;i<N;i++) s += w[i]*Vk[i]; h[k] = s; for (let i=0;i<N;i++) w[i] -= s*Vk[i]; }
  const hn = nrm(w); h[m+1] = hn;
  for (let k=0;k<m;k++){ const t = G.cs[k]*h[k] + G.sn[k]*h[k+1]; h[k+1] = -G.sn[k]*h[k] + G.cs[k]*h[k+1]; h[k] = t; }
  const r = Math.hypot(h[m], h[m+1]); G.cs[m] = h[m]/r; G.sn[m] = h[m+1]/r; h[m] = r; h[m+1] = 0;
  G.g[m+1] = -G.sn[m]*G.g[m]; G.g[m] = G.cs[m]*G.g[m]; G.H.push(h); G.m++;
  const res = Math.abs(G.g[m+1])/G.beta; G.hist.push(res);
  if (res < G.tol || G.m >= G.mmax || hn === 0) return true;
  for (let i=0;i<N;i++) w[i] /= hn; G.V.push(w); return false; }
function gmSol(G){ const m = G.m, y = new Float64Array(m); for (let k=m-1;k>=0;k--){ let s = G.g[k]; for (let c=k+1;c<m;c++) s -= G.H[c][k]*y[c]; y[k] = s/G.H[k][k]; }
  const x = new Float64Array(G.N); for (let k=0;k<m;k++) for (let i=0;i<G.N;i++) x[i] += y[k]*G.V[k][i]; return x; }
function gmres(A, N, b, tol){ const G = gmInit(A, N, b, tol); while (!gmStep(G)); return {x: gmSol(G), it: G.m, hist: G.hist}; }
// exact answer (Lamb 1932, §114): on an ellipsoid in a stream along x the surface velocity is the tangential part of k·U∞,
// k = 2/(2 − α₀), α₀ = abc ∫₀^∞ dλ / ((a²+λ)√((a²+λ)(b²+λ)(c²+λ))). Sphere: α₀ = 2/3, k = 3/2 → Cp = 1 − (9/4) sin²θ.
function ellK(a, b, c){ let s = 0; const M = 6000;
  for (let k=0;k<M;k++){ const th = (k+.5)/M*Math.PI/2, tn = Math.tan(th), l = tn*tn, dl = 2*tn/(Math.cos(th)**2)*(Math.PI/2/M);
    s += a*b*c/((a*a+l)*Math.sqrt((a*a+l)*(b*b+l)*(c*c+l)))*dl; }
  return 2/(2-s); }
function system(n, ax){ const M = prep(mesh(n, ax)), N = M.N, A = new Float64Array(N*N), b = new Float64Array(N);
  for (let i=0;i<N;i++){ assembleRow(M, A, i); b[i] = -M.Nn[i*3]; } return {M, N, A, b}; }

// The Build job: assemble → solve → velocity → Cp, in small units so the browser can spread it over frames
function makeJob(n, body, solver){
  const ax = body === 'spheroid' ? 2 : 1, M = prep(mesh(n, ax)), N = M.N, U = [1,0,0], A = new Float64Array(N*N), b = new Float64Array(N);
  for (let i=0;i<N;i++) b[i] = -M.Nn[i*3];
  const kf = ellK(ax,1,1), th = new Float64Array(N), cpx = new Float64Array(N);
  for (let i=0;i<N;i++){ let px = M.C[i*3]/ax, py = M.C[i*3+1], pz = M.C[i*3+2]; const L = Math.hypot(px,py,pz); px /= L; py /= L; pz /= L;
    let gx = px/ax; const G = Math.hypot(gx, py, pz); gx /= G; th[i] = Math.acos(Math.max(-1, Math.min(1, gx))); cpx[i] = 1 - kf*kf*(1-gx*gx); }
  const J = {M, N, n, body, solver, kf, th, cpx, A, b, phase: 'assemble', row: 0, k: 0, it: 0, hist: [1], sig: null, cp: new Float64Array(N), done: new Uint8Array(N),
    t: {assemble: 0, solve: 0, velocity: 0}, maxCall: 0, rms: 0, emax: 0, resid: 0};
  let LUm = null, bb = null, G = null; const o = [0,0,0];
  function unit(){
    if (J.phase === 'assemble') { assembleRow(M, A, J.row); J.done[J.row++] = 1; if (J.row === N) { J.phase = 'solve'; J.row = 0; if (solver === 'lu') { LUm = A.slice(); bb = b.slice(); } else G = gmInit(A, N, b); } return; }
    if (J.phase === 'solve') {
      if (solver === 'lu') { if (J.k < N) luCol(LUm, N, bb, J.k++); else { J.sig = backSub(LUm, N, bb); LUm = null; J.phase = 'velocity'; } }
      else if (gmStep(G)) { J.sig = gmSol(G); J.it = G.m; J.hist = G.hist; G = null; J.phase = 'velocity'; }
      if (J.sig) { let r2 = 0; for (let i=0;i<N;i++){ let s = -b[i]; for (let j=0;j<N;j++) s += A[i*N+j]*J.sig[j]; r2 += s*s; } J.resid = Math.sqrt(r2)/nrm(b); }
      return; }
    if (J.phase === 'velocity') { const i = J.row++; velRow(M, J.sig, U, i, o); J.cp[i] = 1 - (o[0]*o[0]+o[1]*o[1]+o[2]*o[2]);
      if (J.row === N) { let e2 = 0, em = 0; for (let k=0;k<N;k++){ const e = J.cp[k]-cpx[k]; e2 += e*e; em = Math.max(em, Math.abs(e)); } J.rms = Math.sqrt(e2/N); J.emax = em; J.phase = 'done'; } }
  }
  J.run = budget => { const t0 = tnow(); let seg = t0, ph = J.phase;
    while (J.phase !== 'done' && tnow()-t0 < budget) { unit(); if (J.phase !== ph) { const t = tnow(); J.t[ph] += t-seg; seg = t; ph = J.phase; } }
    const t1 = tnow(); if (ph in J.t) J.t[ph] += t1-seg; J.maxCall = Math.max(J.maxCall, t1-t0); };
  J.frac = () => J.phase === 'assemble' ? J.row/N : J.phase === 'solve' ? (solver === 'lu' ? J.k/N : Math.min(1, (G ? G.m : 0)/8)) : J.phase === 'velocity' ? J.row/N : 1;
  return J;
}

// The 6-panel "sphere" (a cube) used for the operator walkthrough and the worked examples: every number is computed here
const CUBE = (() => {
  const nm = ['+x','−x','+y','−y','+z','−z'], C = [], S = 4;
  for (let f=0;f<6;f++){ const e = [0,0,0]; e[f>>1] = f&1 ? -1 : 1; C.push(e); }
  const Ul = Math.hypot(1,.45,.25), U = [1/Ul, .45/Ul, .25/Ul], dot = (a,b) => a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
  const A = C.map((ci,i) => C.map((cj,j) => { if (i === j) return .5; const d = [ci[0]-cj[0], ci[1]-cj[1], ci[2]-cj[2]], r = Math.hypot(...d); return S*FP*dot(d, ci)/r**3; }));
  const b = C.map(n => -dot(U, n)), sig = Array.from(solveSmall(A, b));
  const parts = C.map((ci,i) => C.map((cj,j) => { if (i === j) return ci.map(v => .5*sig[i]*v); const d = [ci[0]-cj[0], ci[1]-cj[1], ci[2]-cj[2]], r = Math.hypot(...d); return d.map(v => S*FP*v/r**3*sig[j]); }));
  const vel = parts.map(row => row.reduce((a,p) => [a[0]+p[0], a[1]+p[1], a[2]+p[2]], U.slice()));
  const cp = vel.map(v => 1 - dot(v,v));
  const verts = C.map((n,f) => { const a = f>>1, u = (a+1)%3, v = (a+2)%3; return [[-1,-1],[1,-1],[1,1],[-1,1]].map(([p,q]) => { const P = [0,0,0]; P[a] = n[a]; P[u] = p; P[v] = q; return P; }); });
  return {nm, C, S, U, A, b, sig, parts, vel, cp, verts, dot};
})();

// ================= MathML helpers =================
const I = '<mi data-t="i">i</mi>', Jx = '<mi data-t="j">j</mi>', AL = '<mi data-t="alpha">α</mi>';
const sb = (base, s, t) => `<msub${t ? ` data-t="${t}"` : ''}>${base}${s}</msub>`;
const ub = (inner, k, txt) => `<munder><munder><mrow>${inner}</mrow><mo stretchy="true">⏟</mo></munder><mtext data-t="${k}" class="opl">${txt}</mtext></munder>`;
const PHI = '<mi data-t="phi">φ</mi>', UA = `<msub data-t="u"><mi>u</mi>${AL}</msub>`, DA = `<mrow data-t="grad"><msub><mo>∂</mo>${AL}</msub></mrow>`;
const UINF = `<msub data-t="U"><mi>U</mi><mrow><mi>∞</mi>${AL}</mrow></msub>`, XA = `<msub data-t="x"><mi>x</mi>${AL}</msub>`;
const SIGJ = `<msub data-t="sig"><mi>σ</mi>${Jx}</msub>`, NIA = `<msub data-t="n"><mi>n</mi><mrow>${I}${AL}</mrow></msub>`;
const AIJ = `<msub data-t="Am"><mi>A</mi><mrow>${I}${Jx}</mrow></msub>`, BI = `<msub data-t="b"><mi>b</mi>${I}</msub>`;
const XIA = `<msub data-t="xc"><mi>x</mi><mrow>${I}${AL}</mrow></msub>`, XJA = `<msub data-t="xc"><mi>x</mi><mrow>${Jx}${AL}</mrow></msub>`;
const DSJ = `<mrow data-t="dS"><mi>Δ</mi><msub><mi>S</mi>${Jx}</msub></mrow>`, RIJ = `<msubsup data-t="r"><mi>r</mi><mrow>${I}${Jx}</mrow><mn>3</mn></msubsup>`;
const DIJ = `<msub data-t="delta"><mi>δ</mi><mrow>${I}${Jx}</mrow></msub>`, CPI = `<msub data-t="Cp"><mi>C</mi><mrow><mi>p</mi><mo>,</mo>${I}</mrow></msub>`;
const UIA = `<msub data-t="u"><mi>u</mi><mrow>${I}${AL}</mrow></msub>`, BIJ = `<msub data-t="Bv"><mi>B</mi><mrow>${I}${Jx}${AL}</mrow></msub>`;
const AINV = '<msup data-t="Ainv"><mi>A</mi><mrow><mo>−</mo><mn>1</mn></mrow></msup>', UI2 = '<msubsup data-t="U"><mi>U</mi><mi>∞</mi><mn>2</mn></msubsup>';
const RN = (e) => `<msup><mi>ℝ</mi>${e}</msup>`, NN = '<mi data-t="N">N</mi>';
const idxRow = (t, sym, rg, txt) => `<div class="ir" data-t="${t}"><span class="is"><math>${sym}</math></span><span class="rg"><math>${rg}</math></span><span class="im">${txt}</span></div>`;
const dstep = (k, m, p) => `<div class="dstep"><span class="k">${k}</span><div class="dm"><math display="block">${m}</math></div><p>${p}</p></div>`;
const deep = (steps) => `<details class="deep"><summary>Going a bit deeper <span class="note">· ${steps.length} steps</span></summary>${steps.join('')}</details>`;

// ================= BLOCK HTML =================
const B0 = `<div class="eqhero">
  <math display="block">${SIGJ}<mo>∈</mo>${RN(NN)}<mspace width="2em"/>${CPI}<mo>=</mo><mi data-t="P">P</mi><mo>(</mo><mi data-t="V">V</mi><mo>(</mo>${AINV}${BI}<mo>)</mo><mo>)</mo></math>
  <math display="block" class="sm">${AIJ}<mo>=</mo><mi data-t="Am">A</mi><mo>(</mo>${XIA}<mo>,</mo>${NIA}<mo>,</mo>${DSJ}<mo>)</mo><mo>∈</mo>${RN(`<mrow>${NN}<mo>×</mo>${NN}</mrow>`)}<mspace width="1.5em"/>${BI}<mo>=</mo><mo>−</mo>${UINF}${NIA}</math>
</div>
<div class="idx"><span class="eyebrow">Every index</span>
${idxRow('i', '<mi>i</mi>', '<mn>1</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>N</mi>', 'Collocation panel: the panel where we check that no fluid passes through (a row of A).')}
${idxRow('j', '<mi>j</mi>', '<mn>1</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>N</mi>', 'Source panel: the panel whose source does the pushing (a column of A). i and j run over the same panels.')}
${idxRow('alpha', '<mi>α</mi><mo>,</mo><mi>β</mi>', '<mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi>', 'Axis of a 3D vector (u<sub>α</sub>, n<sub>iα</sub>, x<sub>α</sub>). Twice in one term → summed: U<sub>∞α</sub>n<sub>iα</sub> = U<sub>∞x</sub>n<sub>ix</sub> + U<sub>∞y</sub>n<sub>iy</sub> + U<sub>∞z</sub>n<sub>iz</sub>. So is a repeated j: A<sub>ij</sub>σ<sub>j</sub> sums over all panels.')}
${idxRow('k', '<mi>k</mi>', '<mn>0</mn><mo>,</mo><mn>1</mn><mo>,</mo><mn>2</mn><mo>,</mo><mo>…</mo>', 'Iteration of an iterative solver (GMRES): σ<sup>(k)</sup> is the k-th guess. A direct solver has no k.')}
${idxRow('t', '<mi>t</mi>', '<mtext>none</mtext>', 'Absent: this flow is steady, so one linear solve gives the whole answer, with no time stepping. (Unsteady panel codes add ∂ₜφ to Bernoulli and shed new wake panels each step.)')}
</div>
<div class="dims">
  <div class="dim"><b>Fix j</b><math>${SIGJ}<mo>∈</mo><mi>ℝ</mi></math><span>one number: how hard panel j blows fluid out (+) or sucks it in (−)</span></div>
  <div class="dim"><b>Nothing fixed (the state)</b><math>${SIGJ}<mo>∈</mo>${RN(NN)}</math><span>unknowns live only on the surface: 864 numbers for the finest Build sphere, no volume grid at all</span></div>
  <div class="dim"><b>The matrix</b><math>${AIJ}<mo>∈</mo>${RN(`<mrow>${NN}<mo>×</mo>${NN}</mrow>`)}</math><span>dense: 864² = 746 496 numbers, 6 MB in double precision</span></div>
  <div class="dim"><b>The output</b><math>${UIA}<mo>∈</mo>${RN(`<mrow>${NN}<mo>×</mo><mn>3</mn></mrow>`)}<mo>,</mo><mspace width=".4em"/>${CPI}<mo>∈</mo>${RN(NN)}</math><span>a velocity and a pressure coefficient at every panel</span></div>
</div>
<span class="eyebrow">What the operators do, on a 6-panel body</span>
<figure class="viz"><div class="scrollx"><canvas id="potential-opviz" data-w="880" data-h="350" aria-label="Animated walkthrough on a 6-panel body: A builds the 6 by 6 matrix, b is the leak of the freestream, A inverse gives the source strengths, V the velocities and P the pressure coefficients"></canvas></div>
  <div class="opctl"><button class="b" id="potential-opplay">Pause</button><div id="potential-opsteps" class="btns"></div></div>
  <p class="opcap" id="potential-opcap"></p></figure>
<aside class="insp" data-terms="xc,n,dS,Am,b,sig,Ainv,V,P,Cp,N"></aside>
${deep([
  dstep('1', `<msub><mi>N</mi><mtext>surface</mtext></msub><mo>∼</mo><msup><mi>h</mi><mrow><mo>−</mo><mn>2</mn></mrow></msup><mspace width="1.5em"/><msub><mi>N</mi><mtext>volume</mtext></msub><mo>∼</mo><msup><mi>h</mi><mrow><mo>−</mo><mn>3</mn></mrow></msup>`, 'Why only the surface: the flow is fixed by sources sitting on the body, so panels of size h cover a 2D surface. A field solver must also fill the 3D volume around it, out to far away.'),
  dstep('2', `<mi data-t="P">P</mi><mo>∘</mo><mi data-t="V">V</mi><mo>∘</mo>${AINV}<mo>:</mo>${RN(NN)}<mo>→</mo>${RN(NN)}`, 'The whole method is one chain of maps: b → σ (linear solve) → u (affine) → Cₚ (quadratic). Only the last step is nonlinear, and it acts panel by panel.')
])}`;

const BA = `<div class="eqhero">
  <math display="block">${UA}<mo>=</mo>${DA}${PHI}<mspace width="2em"/><mrow data-t="lap">${DA}${DA}</mrow>${PHI}<mo>=</mo><mn>0</mn></math>
  <math display="block" class="sm">${PHI}<mo>(</mo><mi data-t="x">𝐱</mi><mo>)</mo><mo>=</mo>${ub(`${UINF}${XA}`, 'U', 'uniform flow')}<mo>+</mo>${ub(`<msub data-t="S"><mo>∮</mo><mi>S</mi></msub><mi data-t="G">G</mi><mo>(</mo><mi data-t="x">𝐱</mi><mo>,</mo><mi data-t="x">𝐱′</mi><mo>)</mo><mi data-t="sig">σ</mi><mo>(</mo><mi data-t="x">𝐱′</mi><mo>)</mo><mi data-t="dS">d</mi><msup><mi data-t="dS">S</mi><mo>′</mo></msup>`, 'G', 'G: add up the surface sources')}<mo>,</mo><mspace width="1em"/><mi data-t="G">G</mi><mo>=</mo><mfrac><mrow><mo>−</mo><mn>1</mn></mrow><mrow><mn>4</mn><mi>π</mi><mo>|</mo><mi data-t="x">𝐱</mi><mo>−</mo><mi data-t="x">𝐱′</mi><mo>|</mo></mrow></mfrac></math>
</div>
<div class="btns" id="potential-modes"><button class="b pri" data-mode="0">Source</button><button class="b" data-mode="1">Source + sink</button><button class="b" data-mode="2">Doublet (sphere)</button></div>
<div class="bb">
  <figure class="viz">
    <canvas id="potential-supviz" data-w="460" data-h="380" aria-label="Uniform flow plus a source, a source-sink pair or a doublet, in a slice through the axis of the 3D body; tap to move the probe"></canvas>
    <div class="lg"><span style="color:var(--c-u)"><i class="ln"></i>particles, streamlines</span><span style="color:var(--c-f)"><i class="ln dash"></i>equipotentials φ</span><span style="color:var(--c-eq)">● source / sink</span><span class="note">tap to move the probe</span></div>
    <div class="ctl"><label for="potential-q" class="sym" id="potential-qs" style="color:var(--c-eq)">Q</label><input type="range" id="potential-q" min="0.5" max="8" step="0.1" value="3"><output id="potential-qv">3.0</output></div>
  </figure>
  <aside class="insp" data-terms="phi,u,grad,lap,U,x,G,sig,Q,S,n,dS"></aside>
</div>
${deep([
  dstep('1', `${UA}<mo>=</mo>${DA}${PHI}<mspace width="1em"/><mo>⇒</mo><mspace width="1em"/><msub><mi>ω</mi><mi>α</mi></msub><mo>=</mo><msub><mi>ε</mi><mrow><mi>α</mi><mi>β</mi><mi>γ</mi></mrow></msub><msub><mo>∂</mo><mi>β</mi></msub><msub><mo>∂</mo><mi>γ</mi></msub>${PHI}<mo>=</mo><mn>0</mn>`, 'Assumption 1, no rotation: a velocity that is the gradient of one scalar has zero vorticity ω, because the mixed derivatives cancel. Kelvin\'s theorem keeps a flow that starts uniform irrotational, as long as there is no viscosity.'),
  dstep('2', `${DA}${UA}<mo>=</mo><mn>0</mn><mspace width="1em"/><mo>⇒</mo><mspace width="1em"/><mrow data-t="lap">${DA}${DA}</mrow>${PHI}<mo>=</mo><mn>0</mn>`, 'Assumption 2, incompressible: no fluid piles up anywhere. Put u = ∂φ in and you get Laplace\'s equation. It is linear, so solutions can simply be added: uniform flow + sources.'),
  dstep('3', `<mrow data-t="lap">${DA}${DA}</mrow><mi data-t="G">G</mi><mo>=</mo><mi>δ</mi><mo>(</mo><mi data-t="x">𝐱</mi><mo>−</mo><mi data-t="x">𝐱′</mi><mo>)</mo><mo>,</mo><mspace width="1em"/>${UA}<msub data-t="n"><mi>n</mi><mi>α</mi></msub><mo>=</mo><mn>0</mn><mtext> on </mtext><mi data-t="S">S</mi>`, 'G is the potential of one point source of unit strength: it solves Laplace everywhere except at 𝐱′. A sheet of such sources on the surface S, with the right strength σ, can make the velocity tangent to S. Finding that σ is the whole job.')
])}`;

const BB = `<div class="eqhero">
  <math display="block">${ub(`<munder><mo>∑</mo>${Jx}</munder>${AIJ}${SIGJ}`, 'Am', 'A: what the sources push through panel i')}<mo>=</mo>${ub(`<mo>−</mo>${UINF}${NIA}`, 'b', 'b: what the freestream would leak')}</math>
  <math display="block" class="sm">${AIJ}<mo>=</mo><mfrac><mn>1</mn><mn>2</mn></mfrac>${DIJ}<mo>+</mo><mo>(</mo><mn>1</mn><mo>−</mo>${DIJ}<mo>)</mo><mfrac>${DSJ}<mrow><mn>4</mn><mi>π</mi></mrow></mfrac><mfrac><mrow><mo>(</mo>${XIA}<mo>−</mo>${XJA}<mo>)</mo>${NIA}</mrow>${RIJ}</mfrac><mspace width="1.5em"/>${ub(`${SIGJ}<mo>=</mo><msub><mrow>${AINV}</mrow><mrow>${Jx}${I}</mrow></msub>${BI}`, 'Ainv', 'A⁻¹: solve, by LU or GMRES')}</math>
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="potential-matviz" data-w="460" data-h="420" aria-label="A panelled sphere with the influence of every panel on one collocation panel, the dense influence matrix, and the GMRES residual per iteration; drag the sphere to rotate"></canvas>
    <div class="lg"><span style="color:var(--c-tau)"><i class="ln"></i>influence A<sub>ij</sub> on panel i</span><span style="color:var(--c-f)">▢ panel i</span><span style="color:var(--c-eq)">▢ panel j</span><span class="note">drag the sphere</span></div>
    <div class="ctl3"><label for="potential-bn" class="sym">n</label><input type="range" id="potential-bn" min="2" max="7" step="1" value="4"><output id="potential-bnv">N = 96</output>
      <label for="potential-bi" class="sym" style="color:var(--c-f)">i</label><input type="range" id="potential-bi" min="0" max="95" step="1" value="0"><output id="potential-biv">auto</output></div>
  </figure>
  <aside class="insp" data-terms="Am,Ainv,sig,b,i,j,xc,n,dS,r,delta,N,k,res"></aside>
</div>
${deep([
  dstep('1', `<msub data-t="u"><mi>u</mi><mi>n</mi></msub><msub><mo>|</mo><mtext>outside</mtext></msub><mo>−</mo><msub data-t="u"><mi>u</mi><mi>n</mi></msub><msub><mo>|</mo><mtext>inside</mtext></msub><mo>=</mo><mi data-t="sig">σ</mi><mspace width="1em"/><mo>⇒</mo><mspace width="1em"/><msub><mi>A</mi><mrow><mi>i</mi><mi>i</mi></mrow></msub><mo>=</mo><mfrac><mn>1</mn><mn>2</mn></mfrac>`, 'Where the ½ comes from: a flat source sheet sends σ of outflow per unit area, half to each side (draw a thin box around it and count the flux). Seen from just outside, a panel\'s own source pushes ½σ through itself.'),
  dstep('2', `<mtext>LU</mtext><mo>:</mo><mfrac><mn>2</mn><mn>3</mn></mfrac><msup><mi data-t="N">N</mi><mn>3</mn></msup><mspace width="2em"/><mtext>GMRES</mtext><mo>:</mo><mi data-t="k">k</mi><mo>×</mo><mn>2</mn><msup><mi data-t="N">N</mi><mn>2</mn></msup>`, 'Two ways to solve. LU (Gaussian elimination) costs ⅔N³ operations whatever the matrix. GMRES improves a guess σ⁽ᵏ⁾ by one matrix-vector product per iteration, keeping the best combination of b, Ab, A²b, …'),
  dstep('3', `<mi data-t="Am">A</mi><mo>=</mo><mfrac><mn>1</mn><mn>2</mn></mfrac><mi>I</mi><mo>+</mo><mi>K</mi>`, 'Why GMRES needs so few iterations: A is ½ times the identity plus a smooth (compact) part K, a "second-kind" integral equation. Its eigenvalues cluster, so the iteration count barely grows with N. Here it stays at 5 to 7 for every N.')
])}`;

const BC = `<div class="eqhero">
  <math display="block">${ub(`${UIA}<mo>=</mo>${UINF}<mo>+</mo><munder><mo>∑</mo>${Jx}</munder>${BIJ}${SIGJ}`, 'V', 'V: velocity at panel i')}<mspace width="1.5em"/>${ub(`${CPI}<mo>=</mo><mn>1</mn><mo>−</mo><mfrac><mrow>${UIA}${UIA}</mrow>${UI2}</mfrac>`, 'P', 'P: Bernoulli, speed → pressure')}</math>
  <math display="block" class="sm">${ub(`<mo>|</mo>${UA}<mo>(</mo><msub><mi data-t="x">𝐱</mi><mtext>TE</mtext></msub><mo>)</mo><mo>|</mo><mo>&lt;</mo><mi>∞</mi><mspace width=".6em"/><mo>⇒</mo><mspace width=".6em"/><mi data-t="Gam">Γ</mi>`, 'K', 'K: Kutta condition fixes Γ')}<mspace width="1.5em"/><msup data-t="lift"><mi>L</mi><mo>′</mo></msup><mo>=</mo><mi data-t="rho">ρ</mi><msub data-t="U"><mi>U</mi><mi>∞</mi></msub><mi data-t="Gam">Γ</mi><mo>,</mo><mspace width="1em"/><mi data-t="D">D</mi><mo>=</mo><mn>0</mn></math>
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="potential-kviz" data-w="480" data-h="410" aria-label="Potential flow past a wing section with circulation Gamma, its stagnation points and its pressure distribution; a 3D inset shows where the section sits on the wing"></canvas>
    <div class="lg"><span style="color:var(--c-u)"><i class="ln"></i>streamlines</span><span style="color:var(--c-nu)"><i class="ln"></i>−C<sub>p</sub> upper</span><span style="color:var(--c-nu)"><i class="ln dash"></i>−C<sub>p</sub> lower</span><span style="color:var(--c-tau)"><i class="ln"></i>earlier settings</span></div>
    <div class="ctl3"><label for="potential-ka" class="sym">α</label><input type="range" id="potential-ka" min="-4" max="14" step="0.5" value="6"><output id="potential-kav">6.0°</output>
      <label for="potential-kg" class="sym" style="color:var(--c-tau)">Γ</label><input type="range" id="potential-kg" min="0" max="1.6" step="0.02" value="0"><output id="potential-kgv">0 × Kutta</output></div>
    <div class="btns"><button class="b" id="potential-kk">Apply the Kutta condition</button></div>
  </figure>
  <aside class="insp" data-terms="V,Bv,u,U,P,Cp,p,rho,K,Gam,lift,D,theta"></aside>
</div>
${deep([
  dstep('1', `<mi data-t="p">p</mi><mo>+</mo><mfrac><mn>1</mn><mn>2</mn></mfrac><mi data-t="rho">ρ</mi>${UA}${UA}<mo>=</mo><msub data-t="p"><mi>p</mi><mi>∞</mi></msub><mo>+</mo><mfrac><mn>1</mn><mn>2</mn></mfrac><mi data-t="rho">ρ</mi>${UI2}`, 'Bernoulli: for steady, inviscid, irrotational flow the Euler equation integrates to "pressure + kinetic energy per volume = constant" everywhere. Divide by ½ρU∞² and you get Cₚ = 1 − |u|²/U∞².'),
  dstep('2', `<msub><mo>∮</mo><mi>S</mi></msub><mo>(</mo><mi data-t="p">p</mi><mo>−</mo><msub><mi>p</mi><mi>∞</mi></msub><mo>)</mo><msub data-t="n"><mi>n</mi><mi>x</mi></msub><mi>d</mi><mi>S</mi><mo>=</mo><mn>0</mn>`, 'd\'Alembert\'s paradox: in steady potential flow the pressure on a closed body always adds up to zero drag (for the sphere, front and back are mirror images). Real drag comes from viscosity: skin friction and separation, both missing here.'),
  dstep('3', `<msub><mi>C</mi><mi>p</mi></msub><mo>≈</mo><mfrac><msub><mi>C</mi><mrow><mi>p</mi><mo>,</mo><mn>0</mn></mrow></msub><msqrt><mn>1</mn><mo>−</mo><msubsup><mi>M</mi><mi>∞</mi><mn>2</mn></msubsup></msqrt></mfrac>`, 'What else is dropped: compressibility. Linear corrections like Prandtl–Glauert stretch the result for subsonic Mach numbers, but shocks are out of reach. In 3D, the Kutta condition is applied all along the trailing edge, and the wake is a sheet of doublets carrying Γ downstream.')
])}`;

// ================= TERMS =================
const TERMS = {
  phi: {sym: '<mi>φ</mi>', name: 'Velocity potential', def: 'One number at every point in space whose slope is the velocity. Like a height map: the flow runs along the steepest climb.', space: '<mi>φ</mi><mo>:</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>∖</mo><mtext>body</mtext><mo>→</mo><mi>ℝ</mi><mspace width=".5em"/><mtext>(scalar field)</mtext>', col: '--c-f'},
  u: {sym: '<msub><mi>u</mi><mi>α</mi></msub>', name: 'Velocity', def: 'Component α of the fluid velocity. At panel i it is u_iα; u_αu_α = u_x² + u_y² + u_z² is the speed squared.', space: '<msub><mi>u</mi><mi>α</mi></msub><mo>:</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>∖</mo><mtext>body</mtext><mo>→</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>,</mo><mspace width=".5em"/><msub><mi>u</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mi>N</mi><mo>×</mo><mn>3</mn></mrow></msup>', col: '--c-u'},
  U: {sym: '<msub><mi>U</mi><mrow><mi>∞</mi><mi>α</mi></mrow></msub>', name: 'Freestream', def: 'The uniform wind far from the body, the same vector everywhere. Here U∞ = 1 along x.', space: '<msub><mi>U</mi><mrow><mi>∞</mi><mi>α</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mspace width=".5em"/><mtext>(constant)</mtext>', col: '--c-c'},
  grad: {sym: '<msub><mo>∂</mo><mi>α</mi></msub>', name: 'Partial derivative', def: 'Rate of change along axis α. Applied to φ it gives the three velocity components.', space: '<msub><mo>∂</mo><mi>α</mi></msub><mo>:</mo><mtext>scalar field</mtext><mo>→</mo><mtext>vector field</mtext><mspace width=".4em"/><mtext>(linear)</mtext>', col: '--ink'},
  lap: {sym: '<msub><mo>∂</mo><mi>α</mi></msub><msub><mo>∂</mo><mi>α</mi></msub>', name: 'Laplacian', def: '∂ₓ² + ∂ᵧ² + ∂_z²: how much φ at a point differs from the average around it. Zero means no fluid is created or lost there.', space: '<msub><mo>∂</mo><mi>α</mi></msub><msub><mo>∂</mo><mi>α</mi></msub><mo>:</mo><mtext>scalar field</mtext><mo>→</mo><mtext>scalar field</mtext><mspace width=".4em"/><mtext>(linear)</mtext>', col: '--ink'},
  x: {sym: '<mi>𝐱</mi>', name: 'Point in space', def: '𝐱 = (x, y, z) is where we evaluate the flow; 𝐱′ is a point on the body surface where a source sits.', space: '<mi>𝐱</mi><mo>,</mo><mi>𝐱′</mi><mo>∈</mo><msup><mi>ℝ</mi><mn>3</mn></msup>', col: '--ink'},
  G: {sym: '<mi>G</mi>', name: 'Green\'s function (point source)', def: 'The potential of one unit source: −1/(4πr). Every bit of surface source adds one of these; the integral adds them all up.', space: '<mi>G</mi><mo>:</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>×</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>→</mo><mi>ℝ</mi><mo>,</mo><mspace width=".4em"/><mi>σ</mi><mo>↦</mo><mi>φ</mi><mtext> is linear</mtext>', col: '--c-tau', op: 'G'},
  sig: {sym: '<msub><mi>σ</mi><mi>j</mi></msub>', name: 'Source strength', def: 'Volume of fluid a panel emits per unit area per second. Positive blows out, negative sucks in. These are the unknowns.', space: '<mi>σ</mi><mo>:</mo><mi>S</mi><mo>→</mo><mi>ℝ</mi><mo>,</mo><mspace width=".5em"/><msub><mi>σ</mi><mi>j</mi></msub><mo>∈</mo><msup><mi>ℝ</mi><mi>N</mi></msup><mtext> (one per panel)</mtext>', col: '--c-eq'},
  Q: {sym: '<mi>Q</mi>', name: 'Point source strength', def: 'Total outflow of one point source (volume per second). With uniform flow it makes a Rankine body whose far width is √(Q/πU∞).', space: '<mi>Q</mi><mo>∈</mo><mi>ℝ</mi>', col: '--c-eq'},
  S: {sym: '<mi>S</mi>', name: 'Body surface', def: 'The closed surface of the body. The ∮ adds over all of it.', space: '<mi>S</mi><mo>⊂</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mtext>, a closed 2D surface</mtext>', col: '--ink'},
  n: {sym: '<msub><mi>n</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub>', name: 'Unit normal', def: 'The outward direction of panel i, length 1. No-penetration: u_αn_α = 0 on the body.', space: '<msub><mi>n</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mi>N</mi><mo>×</mo><mn>3</mn></mrow></msup><mo>,</mo><mspace width=".4em"/><msub><mi>n</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><msub><mi>n</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>=</mo><mn>1</mn>', col: '--c-cs'},
  dS: {sym: '<mi>Δ</mi><msub><mi>S</mi><mi>j</mi></msub>', name: 'Panel area', def: 'Area of panel j (dS′ in the integral). A panel with source density σ_j emits σ_jΔS_j in total.', space: '<mi>Δ</mi><msub><mi>S</mi><mi>j</mi></msub><mo>∈</mo><msubsup><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow><mi>N</mi></msubsup>', col: '--c-w'},
  xc: {sym: '<msub><mi>x</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub>', name: 'Panel centre', def: 'The collocation point of panel i: where no-penetration is enforced and velocity is evaluated.', space: '<msub><mi>x</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mi>N</mi><mo>×</mo><mn>3</mn></mrow></msup>', col: '--c-w'},
  r: {sym: '<msub><mi>r</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Distance', def: 'r_ij = |𝐱_i − 𝐱_j|, between the centres of panels i and j. Influence falls like 1/r².', space: '<msub><mi>r</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--c-w'},
  delta: {sym: '<msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Kronecker delta', def: '1 if i = j, else 0. Picks out the diagonal: a panel acting on itself.', space: '<msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mi>N</mi><mo>×</mo><mi>N</mi></mrow></msup><mtext> (identity)</mtext>', col: '--c-w'},
  Am: {sym: '<msub><mi>A</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Influence matrix (operator A)', def: 'Entry ij: how fast a unit source on panel j pushes fluid through panel i. Built from geometry only. Every panel affects every other, so it is dense.', space: '<mi>A</mi><mo>:</mo><mo>(</mo><msub><mi>x</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>,</mo><msub><mi>n</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>,</mo><mi>Δ</mi><msub><mi>S</mi><mi>j</mi></msub><mo>)</mo><mo>↦</mo><msub><mi>A</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mi>N</mi><mo>×</mo><mi>N</mi></mrow></msup>', col: '--c-tau', op: 'A'},
  b: {sym: '<msub><mi>b</mi><mi>i</mi></msub>', name: 'Right-hand side', def: 'b_i = −U∞αn_iα: minus the freestream\'s flow through panel i. The sources must supply exactly this.', space: '<msub><mi>b</mi><mi>i</mi></msub><mo>∈</mo><msup><mi>ℝ</mi><mi>N</mi></msup>', col: '--c-c'},
  Ainv: {sym: '<msup><mi>A</mi><mrow><mo>−</mo><mn>1</mn></mrow></msup>', name: 'Linear solve', def: 'Finds the σ with Aσ = b. Direct (LU: exact, ⅔N³ work) or iterative (GMRES: a few matrix-vector products).', space: '<msup><mi>A</mi><mrow><mo>−</mo><mn>1</mn></mrow></msup><mo>:</mo><msup><mi>ℝ</mi><mi>N</mi></msup><mo>→</mo><msup><mi>ℝ</mi><mi>N</mi></msup><mo>,</mo><mspace width=".4em"/><mtext>linear</mtext>', col: '--c-rho', op: 'L'},
  V: {sym: '<mi>V</mi>', name: 'Velocity map', def: 'From source strengths to the velocity at every panel centre: freestream plus the push of every panel.', space: '<mi>V</mi><mo>:</mo><msup><mi>ℝ</mi><mi>N</mi></msup><mo>→</mo><msup><mi>ℝ</mi><mrow><mi>N</mi><mo>×</mo><mn>3</mn></mrow></msup><mo>,</mo><mspace width=".4em"/><mtext>affine</mtext>', col: '--c-u', op: 'V'},
  Bv: {sym: '<msub><mi>B</mi><mrow><mi>i</mi><mi>j</mi><mi>α</mi></mrow></msub>', name: 'Velocity influence', def: 'Velocity component α at panel i from a unit source on panel j: like A, but the full 3D vector instead of only its normal part.', space: '<msub><mi>B</mi><mrow><mi>i</mi><mi>j</mi><mi>α</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mi>N</mi><mo>×</mo><mi>N</mi><mo>×</mo><mn>3</mn></mrow></msup><mo>,</mo><mspace width=".4em"/><msub><mi>B</mi><mrow><mi>i</mi><mi>j</mi><mi>α</mi></mrow></msub><msub><mi>n</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>=</mo><msub><mi>A</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', col: '--c-u', op: 'V'},
  P: {sym: '<mi>P</mi>', name: 'Pressure map (Bernoulli)', def: 'Turns speed into pressure, panel by panel: faster means lower pressure. The only nonlinear step.', space: '<mi>P</mi><mo>:</mo><msup><mi>ℝ</mi><mrow><mi>N</mi><mo>×</mo><mn>3</mn></mrow></msup><mo>→</mo><msup><mi>ℝ</mi><mi>N</mi></msup><mo>,</mo><mspace width=".4em"/><mtext>quadratic</mtext>', col: '--c-nu', op: 'B'},
  Cp: {sym: '<msub><mi>C</mi><mi>p</mi></msub>', name: 'Pressure coefficient', def: '(p − p∞)/(½ρU∞²). 1 where the flow stops, 0 where it moves at U∞, negative where it speeds up (suction).', space: '<msub><mi>C</mi><mrow><mi>p</mi><mo>,</mo><mi>i</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mi>N</mi></msup><mo>,</mo><mspace width=".4em"/><msub><mi>C</mi><mi>p</mi></msub><mo>≤</mo><mn>1</mn>', col: '--c-nu', op: 'B'},
  p: {sym: '<mi>p</mi>', name: 'Pressure', def: 'Static pressure; p∞ far away. Only differences matter.', space: '<mi>p</mi><mo>:</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>∖</mo><mtext>body</mtext><mo>→</mo><mi>ℝ</mi>', col: '--c-rho'},
  rho: {sym: '<mi>ρ</mi>', name: 'Density', def: 'Constant here: the flow is incompressible.', space: '<mi>ρ</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub><mtext> (constant)</mtext>', col: '--c-rho'},
  K: {sym: '<mi>K</mi>', name: 'Kutta condition', def: 'Picks the one circulation that lets the flow leave a sharp trailing edge smoothly, instead of whipping round it at infinite speed. It is what gives a wing lift.', space: '<mi>K</mi><mo>:</mo><mo>(</mo><mtext>shape</mtext><mo>,</mo><mi>α</mi><mo>)</mo><mo>↦</mo><mi>Γ</mi><mo>∈</mo><mi>ℝ</mi>', col: '--c-tau', op: 'K'},
  Gam: {sym: '<mi>Γ</mi>', name: 'Circulation', def: 'Net swirl of the flow around the section (velocity summed round a loop). In 3D it is carried by a wake sheet of doublets behind the wing.', space: '<mi>Γ</mi><mo>∈</mo><mi>ℝ</mi><mtext> (per wing section)</mtext>', col: '--c-tau', op: 'K'},
  lift: {sym: '<msup><mi>L</mi><mo>′</mo></msup>', name: 'Lift per span', def: 'Kutta–Joukowski: L′ = ρU∞Γ, at right angles to the stream.', space: '<msup><mi>L</mi><mo>′</mo></msup><mo>∈</mo><mi>ℝ</mi>', col: '--c-cs'},
  D: {sym: '<mi>D</mi>', name: 'Drag', def: 'Force along the stream. Potential flow always gives zero (d\'Alembert\'s paradox).', space: '<mi>D</mi><mo>∈</mo><mi>ℝ</mi><mo>,</mo><mspace width=".4em"/><mi>D</mi><mo>=</mo><mn>0</mn>', col: '--c-nu'},
  theta: {sym: '<mi>θ</mi>', name: 'Angle from the nose', def: 'Angle between the surface normal and the freestream: 0° at the front stagnation point, 90° on the shoulder.', space: '<mi>θ</mi><mo>∈</mo><mo>[</mo><mn>0</mn><mo>,</mo><mi>π</mi><mo>]</mo>', col: '--c-cs'},
  N: {sym: '<mi>N</mi>', name: 'Number of panels', def: 'How many flat panels cover the body. The Build uses 6n²: 54 to 864.', space: '<mi>N</mi><mo>∈</mo><mi>ℕ</mi>', col: '--ink'},
  i: {sym: '<mi>i</mi>', name: 'Collocation index', def: 'The panel being checked: a row of A.', space: '<mi>i</mi><mo>∈</mo><mo>{</mo><mn>1</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>N</mi><mo>}</mo>', col: '--c-f'},
  j: {sym: '<mi>j</mi>', name: 'Source index', def: 'The panel doing the pushing: a column of A. Repeated in A_ijσ_j → summed over all panels.', space: '<mi>j</mi><mo>∈</mo><mo>{</mo><mn>1</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>N</mi><mo>}</mo>', col: '--c-eq'},
  alpha: {sym: '<mrow><mi>α</mi><mo>,</mo><mi>β</mi></mrow>', name: 'Axis index', def: 'x, y or z. Repeated twice in a term means sum over all three (Einstein convention).', space: '<mi>α</mi><mo>,</mo><mi>β</mi><mo>∈</mo><mo>{</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>}</mo>', col: '--ink'},
  k: {sym: '<mi>k</mi>', name: 'Iteration index', def: 'Which GMRES iteration: σ⁽ᵏ⁾ is the k-th guess, each costing one matrix-vector product.', space: '<mi>k</mi><mo>∈</mo><mi>ℕ</mi>', col: '--c-rho'},
  t: {sym: '<mi>t</mi>', name: 'Time', def: 'Not used: the flow is steady and is found by one solve.', space: '<mi>t</mi><mtext>: absent (steady)</mtext>', col: '--c-w'},
  res: {sym: '<msup><mi>r</mi><mrow><mo>(</mo><mi>k</mi><mo>)</mo></mrow></msup>', name: 'Residual', def: 'b − Aσ⁽ᵏ⁾: how much the current guess still leaks. GMRES makes its length as small as possible each iteration.', space: '<msup><mi>r</mi><mrow><mo>(</mo><mi>k</mi><mo>)</mo></mrow></msup><mo>∈</mo><msup><mi>ℝ</mi><mi>N</mi></msup>', col: '--c-rho', op: 'L'}
};

// ================= CHECKS + QUIZ =================
const CHECKS = {
  '0': [
    ['What are the unknowns of a panel method?', ['The velocity in every cell of a 3D grid', 'One source strength per surface panel', 'The pressure everywhere in the volume'], 1, 'Only σ_j, one number per panel. Velocity and pressure anywhere follow from them.'],
    ['What shape is the influence matrix A?', ['N × 3', 'N × N, and dense', 'N × N, mostly zeros'], 1, 'Every panel pushes on every other one, so all N² entries are non-zero.'],
    ['Which operator is nonlinear?', ['The solve A⁻¹', 'The velocity map V', 'The pressure map P, because it squares the speed'], 2, 'A⁻¹ and V are linear in σ (V adds the constant U∞). P = 1 − |u|²/U∞² is quadratic.'],
    ['You halve the panel size (n → 2n). How many times more work does a dense LU solve need?', ['4×', '16×', '64×'], 2, 'N = 6n² grows 4×; LU costs ⅔N³, so 4³ = 64×. The matrix itself takes 16× the memory.'],
    ['Why is there no time index t?', ['The flow is steady: one linear solve gives the answer', 'Time is hidden inside σ', 'The method is too slow to march in time'], 0, 'Steady potential flow is a boundary-value problem, solved once. Unsteady panel codes add ∂ₜφ and march a wake.']
  ],
  A: [
    ['What does ∂α∂αφ = 0 express?', ['Energy is conserved', 'No fluid is created or lost (incompressible) for a velocity u = ∂φ', 'The flow is steady'], 1, '∂αuα = 0 is mass conservation for constant density; with uα = ∂αφ it becomes Laplace\'s equation.'],
    ['Why may we simply add uniform flow and sources?', ['Laplace\'s equation is linear', 'The sources are small', 'Bernoulli allows it'], 0, 'A sum of solutions of a linear equation is a solution. Pressure is not linear, so add velocities, then compute pressure.'],
    ['How does a point source\'s velocity fall with distance r?', ['1/r', '1/r²', '1/r³'], 1, 'All of Q crosses every sphere around it: |u|·4πr² = Q, so |u| = Q/(4πr²).'],
    ['You double Q of the source in uniform flow. The body far downstream gets…', ['twice as wide', '√2 times as wide', 'no wider'], 1, 'Far downstream all of Q flows inside at speed U∞: πR²U∞ = Q, so R = √(Q/πU∞).'],
    ['Inside a boundary layer the flow rotates. What breaks?', ['Laplace still holds there', 'u = ∂φ: a rotating flow has no potential', 'Only Bernoulli'], 1, 'A gradient field has zero vorticity. Rotation (shear near the wall, wakes) needs viscosity, which this model drops.']
  ],
  B: [
    ['Why is A_ii = ½?', ['A choice that improves stability', 'Half of a source sheet\'s outflow goes to each side', 'The panel is half as large'], 1, 'Flux balance across a thin sheet: σ splits evenly, so just outside its own panel the normal velocity is ½σ.'],
    ['What does b_i = −U∞αn_iα measure?', ['The pressure on panel i', 'How much the freestream alone would flow through panel i, with a minus sign', 'The area of panel i'], 1, 'The sources must cancel that leak exactly, so the total normal velocity is zero.'],
    ['N = 10 000 panels. Roughly how many operations does LU need versus GMRES with 10 iterations?', ['About the same', '≈ 7×10¹¹ vs ≈ 2×10⁹', '≈ 10⁸ vs 10⁸'], 1, '⅔N³ ≈ 6.7×10¹¹; 10 × 2N² = 2×10⁹. Over 300 times fewer.'],
    ['You forget the ½ on the diagonal. What happens?', ['Nothing, it is small', 'Each panel ignores its own push, so σ is wrong and fluid leaks through', 'The matrix becomes sparse'], 1, 'The ½σ_i self-term is the biggest entry of every row. Without it the boundary condition is not met.'],
    ['Why does GMRES converge in about 6 iterations for every N here?', ['Luck', 'A = ½I + a smooth part: the eigenvalues cluster, a well-conditioned second-kind equation', 'Because the sphere is symmetric only'], 1, 'Second-kind integral equations have iteration counts that barely grow with N; that is why iterative solvers + fast matvecs win for large N.']
  ],
  C: [
    ['What is Cₚ at a stagnation point?', ['0', '1', '−1'], 1, 'u = 0 there, so Cₚ = 1: the full dynamic pressure is recovered.'],
    ['Where is the lowest pressure on a sphere, and what is it?', ['At the nose, Cₚ = 1', 'On the shoulder (θ = 90°), Cₚ = −1.25', 'At the back, Cₚ = −1'], 1, '|u| = 1.5 U∞ sinθ, so Cₚ = 1 − 2.25 sin²θ, lowest at 90°.'],
    ['What drag does potential flow give for a sphere?', ['Cd ≈ 0.47', 'Exactly zero', 'It depends on N'], 1, 'Front and back pressures mirror each other (d\'Alembert\'s paradox). Real drag needs viscosity.'],
    ['Without a Kutta condition, the wing section has…', ['the right lift anyway', 'any circulation you like; Γ = 0 gives no lift and infinite speed round the trailing edge', 'more drag'], 1, 'Every Γ satisfies no-penetration. The Kutta condition picks the one physical flow, which sets the lift.'],
    ['Which of these can potential flow NOT predict?', ['Lift of a thin wing at small angle', 'Pressure on the front of a sphere', 'Stall and separation behind a bluff body'], 2, 'No viscosity → no boundary layer → no separation. Real spheres separate around θ ≈ 80°–120°.']
  ]
};
const QUIZ = [
  ['Why is a panel method so much cheaper than a Navier–Stokes solver for the same body?', ['It runs on GPUs', 'Unknowns only on the surface, and one linear solve instead of time-stepping', 'It uses lower precision'], 1, 'A surface mesh has ~h⁻² unknowns instead of ~h⁻³, and the steady answer comes from a single solve.'],
  ['Which assumption makes u = ∂φ possible?', ['Incompressibility', 'Irrotational flow', 'Steady flow'], 1, 'A velocity has a potential exactly when its vorticity is zero.'],
  ['What does the Kutta condition decide?', ['The panel size', 'The circulation, and so the lift', 'The drag'], 1, 'It removes the infinite velocity at the sharp trailing edge; L′ = ρU∞Γ follows.'],
  ['A designer\'s panel code says a car has zero drag. Why?', ['A bug in the solver', 'd\'Alembert: inviscid potential flow cannot produce drag on a closed body', 'Too few panels'], 1, 'Drag comes from skin friction and separation, both missing. Panel codes are used for pressure and lift, not drag.'],
  ['Dense LU on N panels: double N. The solve takes…', ['2× longer', '4× longer', '8× longer'], 2, 'LU is O(N³).'],
  ['How does a fast multipole method reach ~O(N) per matrix-vector product?', ['It skips far panels', 'It lumps far-away groups of panels into one multipole expansion each', 'It uses a coarser mesh'], 1, 'Far groups look almost like one source to a distant panel; a tree of such groups gives O(N) work.'],
  ['On a real sphere, where does the panel method\'s Cₚ first go clearly wrong?', ['At the nose', 'On the rear half, where the boundary layer separates', 'Everywhere equally'], 1, 'The front is well predicted; behind separation the pressure stays low instead of recovering to Cₚ = 1.']
];

// ================= SPEC =================
const SPEC = {
  id: 'potential', name: 'Potential flow', sub: 'linear panel method',
  lede: 'No viscosity and no rotation: the flow is the slope of one scalar φ. Cover the body with <strong>source panels</strong>, solve <strong>one linear system</strong> so no fluid passes through, then read off speed and pressure.',
  uncoloured: ['grp'],
  blocks: [
    {key: '0', title: 'The objects', note: 'what goes in, what comes out', html: B0},
    {key: 'A', title: 'Laplace and superposition', note: 'add simple flows to make a body', html: BA},
    {key: 'B', title: 'Panels and the linear system', note: 'no flow through the surface', html: BB},
    {key: 'C', title: 'Velocity, pressure and lift', note: 'Bernoulli, Kutta, and what is missing', html: BC}
  ],
  checks: CHECKS, quiz: QUIZ,
  build: {
    intro: 'Put the steps of one panel-method solve in order. When it is right, your solver runs below on a real 3D body: it assembles the dense matrix, solves it, and compares Cₚ with the exact answer.',
    html: `<div class="scrollx"><canvas class="sim" id="potential-sim" data-w="720" data-h="350" aria-label="Your 3D panel method: surface pressure on a rotatable body, Cp against angle compared with the exact solution, and error against panel count"></canvas></div>
      <div class="row"><label for="potential-n">panels per cube edge n = <b id="potential-nv">8</b> → N = 6n² = <b id="potential-bigN">384</b></label><input type="range" id="potential-n" min="3" max="12" step="1" value="8"></div>
      <div class="btns"><button class="b pri" id="potential-bs">Sphere</button><button class="b" id="potential-be">Spheroid 2:1</button><button class="b pri" id="potential-slu">Direct LU</button><button class="b" id="potential-sgm">GMRES</button></div>
      <p class="note" id="potential-bnote">Drag the body to rotate it.</p>`,
    steps: ['Cut the surface into N flat panels', 'Assemble the influence matrix A_ij', 'Set b_i = −U∞·n_i (cancel the leak)', 'Solve Aσ = b for the source strengths', 'Sum the velocity u_i at each panel', 'Bernoulli: Cp = 1 − |u|²/U∞²'],
    hint: 'Geometry first. The matrix and right-hand side come before the solve; velocities need σ, and pressure needs the velocity.',
    success: 'Your panel method is running. Change n to watch the error shrink, and try GMRES: same answer, far less work.'
  },
  parallel: {html: `<div class="par">
      <div class="stack">
        <p><strong>Assembly</strong> (N² entries): every A<sub>ij</sub> needs only panels i and j. Give each core or GPU thread a block of rows: no communication at all, embarrassingly parallel.</p>
        <p><strong>Dense LU</strong> (⅔N³): at each of the N pivot steps the pivot row must reach every process (ScaLAPACK-style block-cyclic layout). Lots of communication, and the N² matrix must fit in memory.</p>
        <p><strong>GMRES + fast multipole (FMM) or H-matrices</strong>: far-away panels are grouped in an octree and act as one expansion, so a matrix-vector product costs ~O(N) or O(N log N), never storing A. Parallel over tree boxes; dot products need a global sum.</p>
      </div>
      <canvas id="potential-pviz" data-w="320" data-h="250" style="width:100%;max-width:320px;border-radius:8px;background:var(--bg)" aria-label="How the chosen method splits work between four cores"></canvas>
    </div>
    <h3 style="font-size:16px">Which method fits?</h3>
    <p>Task: a full aircraft needs about <strong>N = 100 000 panels</strong>, and your workstation has <strong>64 GB</strong> of memory. Pick a method and set N: the chart uses the speed measured in your browser.</p>
    <div class="btns"><button class="b" id="potential-mlu">Dense LU</button><button class="b" id="potential-mgm">GMRES, dense matrix</button><button class="b" id="potential-mfm">GMRES + FMM</button></div>
    <div class="ctl"><label for="potential-pn" class="sym">N</label><input type="range" id="potential-pn" min="2" max="7" step="0.05" value="3"><output id="potential-pnv">1 000</output></div>
    <div class="scrollx"><canvas id="potential-scale" data-w="620" data-h="300" style="width:100%;height:auto;display:block;border-radius:12px;background:var(--bg)" aria-label="Solve time and memory against number of panels for dense LU, dense GMRES and GMRES with a fast multipole method"></canvas></div>
    <div class="fb" id="potential-pfb"></div>
    <details><summary>Where the numbers come from</summary><p>LU: ⅔N³ operations, 8N² bytes. Dense GMRES: N² entries to assemble (≈ 20 operations each) and 20 iterations × 2N² (iteration count assumed; this sphere needs about 6). FMM: ~2×10⁴ operations per panel per product and ~1 kB per panel: order-of-magnitude estimates for 3D Laplace at about 6 digits, not measurements. The rate is measured from a small LU in your browser on one core.</p></details>`},
  unlock: 'The Potential flow row of the comparison is now visible: seconds on a laptop, exact for smooth attached flow, blind to viscosity, separation and drag. Complete the other seven methods to open the full page.',
  sources: [
    ['Hess, J. L. & Smith, A. M. O. (1967). Calculation of potential flow about arbitrary bodies. Progress in Aerospace Sciences 8, 1–138', 'https://doi.org/10.1016/0376-0421(67)90003-6'],
    ['Katz, J. & Plotkin, A. (2001). Low-Speed Aerodynamics, 2nd ed. Cambridge University Press', 'https://doi.org/10.1017/CBO9780511810329'],
    ['Erickson, L. L. (1990). Panel methods: an introduction. NASA TP-2995', 'https://ntrs.nasa.gov/citations/19910009745'],
    ['Batchelor, G. K. (1967). An Introduction to Fluid Dynamics (sphere and Rankine bodies, Bernoulli, d\'Alembert). Cambridge University Press', 'https://doi.org/10.1017/CBO9780511800955'],
    ['Lamb, H. (1932). Hydrodynamics, 6th ed., §114 (ellipsoid in a uniform stream). Cambridge University Press', 'https://archive.org/details/hydrodynamics0000lamb'],
    ['Joukowsky transform and the Kutta condition (overview with formulas)', 'https://en.wikipedia.org/wiki/Joukowsky_transform'],
    ['Achenbach, E. (1972). Experiments on the flow past spheres at very high Reynolds numbers. J. Fluid Mech. 54, 565–575', 'https://doi.org/10.1017/S0022112072000874'],
    ['Saad, Y. & Schultz, M. H. (1986). GMRES: a generalized minimal residual algorithm. SIAM J. Sci. Stat. Comput. 7, 856–869', 'https://doi.org/10.1137/0907058'],
    ['Greengard, L. & Rokhlin, V. (1987). A fast algorithm for particle simulations. J. Comput. Phys. 73, 325–348', 'https://doi.org/10.1016/0021-9991(87)90140-9'],
    ['Hackbusch, W. (1999). A sparse matrix arithmetic based on H-matrices. Part I. Computing 62, 89–108', 'https://doi.org/10.1007/s006070050015'],
    ['LU decomposition: cost ⅔n³ and pivoting', 'https://en.wikipedia.org/wiki/LU_decomposition']
  ],
  terms: TERMS,
  // headless check: run the Build job in ~9 ms slices and report per-phase time, the longest slice and the accuracy
  bench(){ const out = {};
    for (const [n, body, s] of [[8,'sphere','lu'], [12,'sphere','lu'], [12,'sphere','gmres'], [10,'spheroid','gmres']]) {
      const J = makeJob(n, body, s), sl = []; let calls = 0; while (J.phase !== 'done') { const t0 = tnow(); J.run(7.5); sl.push(tnow()-t0); calls++; } sl.sort((a,b) => a-b);
      out[`${body} N=${J.N} ${s}`] = {assemble_ms: +J.t.assemble.toFixed(0), solve_ms: +J.t.solve.toFixed(0), velocity_ms: +J.t.velocity.toFixed(0), frames: calls, median_slice_ms: +sl[sl.length>>1].toFixed(1), longest_slice_ms: +J.maxCall.toFixed(1), gmres_iters: J.it, residual: +J.resid.toExponential(1), rms_Cp_error: +J.rms.toFixed(4), max_Cp_error: +J.emax.toFixed(4)}; }
    return out; },
  mount(root, K){ return mountPotential.call(this, root, K); }
};

// ================= MOUNT: all the interactive parts =================
function mountPotential(root, K){
const {$, reduce, MONO, MATH, P, hex, hidpi, arrow, rr, pill, label, ease, lerp, clamp, proj, orbit, isAct} = K;
const triad = K.triad, F10 = '10px "IBM Plex Mono", monospace', F11 = '11px "IBM Plex Mono", monospace', B11 = '600 11px "IBM Plex Mono", monospace', SANS = '600 12px "IBM Plex Sans", sans-serif';
const mixc = (a, b, t) => `rgb(${a.map((v,i) => Math.round(v+(b[i]-v)*clamp(t,0,1))).join(',')})`;
const mixa = (a, b, t) => a.map((v,i) => v+(b[i]-v)*clamp(t,0,1));
const rgb = a => `rgb(${a.map(Math.round).join(',')})`;
const cpRGB = (p, cp) => { const base = hex(p.panel); return cp >= 0 ? mixa(base, hex(p.eq), cp) : mixa(base, hex(p.f), -cp/1.25); };
const sgRGB = (p, s, sc) => { const base = hex(p.panel); return s >= 0 ? mixa(base, hex(p.eq), s/sc) : mixa(base, hex(p.c), -s/sc); };
const fx = (v, d=3) => (v < 0 && Math.abs(v).toFixed(d) !== (0).toFixed(d) ? '−' : '') + Math.abs(v).toFixed(d);
const vec = (v, d=2) => `(${v.map(x => fx(x,d)).join(', ')})`;
let openB = '0';
// a symbol with a real subscript (unicode subscript letters are missing from most math fonts)
const SUBF = 'italic 600 11px "STIX Two Math","Cambria Math","Times New Roman",serif';
function subl(c, base, sub, x, y, col, align){ c.font = MATH; const bw = c.measureText(base).width; c.font = SUBF; const sw2 = c.measureText(sub).width;
  const x0 = align === 'center' ? x - (bw+sw2)/2 : align === 'right' ? x - bw - sw2 : x; label(c, base, x0, y, col, MATH); label(c, sub, x0+bw+1, y+5, col, SUBF); }
// draw a panelled body: back-facing panels are culled (the bodies are convex), light falls with the slope
function drawBody(c, V, M, colOf, edge){
  const st = Math.sin(V.th), ct = Math.cos(V.th), sp = Math.sin(V.ph), cq = Math.cos(V.ph), p = P(), bg = hex(p.bg);
  for (let j=0;j<M.N;j++){ const nx = M.Nn[j*3], ny = M.Nn[j*3+1], nz = M.Nn[j*3+2], dn = ny*sp + (-nx*st + nz*ct)*cq; if (dn <= 0) continue;
    c.beginPath(); for (let m=0;m<4;m++){ const o = j*12+m*3, Q = proj(V, M.V[o], M.V[o+1], M.V[o+2]); m ? c.lineTo(Q[0],Q[1]) : c.moveTo(Q[0],Q[1]); } c.closePath();
    c.fillStyle = rgb(mixa(colOf(j), bg, (1-dn)*.45)); c.fill(); if (edge) { c.strokeStyle = edge; c.lineWidth = .6; c.stroke(); } } }
const facing = (V, x, y, z) => y*Math.sin(V.ph) + (-x*Math.sin(V.th) + z*Math.cos(V.th))*Math.cos(V.ph) > 0;

// ---------- 0: operator walkthrough on the 6-panel body ----------
const CO = hidpi($('opviz')), VO = {th: -0.6, ph: 0.42, s: 52, ox: 140, oy: 190};
const OPS = [
  ['geometry', 'xc', 'Start: the surface is cut into N flat panels, here only 6 (a cube), so every number fits on screen. Panel j has a centre xⱼ, an outward normal nⱼ and an area ΔSⱼ = 4. Like tiling a ball with stickers and noting where each sits and which way it faces. The wind U∞ blows from the left.'],
  ['A', 'Am', 'A assembles the influence matrix, entry by entry: Aᵢⱼ is how fast a unit source spread over panel j pushes fluid through panel i. Like measuring how loud loudspeaker j is at seat i. The diagonal is ½: a panel\'s push on itself. Click A to see one entry worked out.'],
  ['b', 'b', 'The right-hand side bᵢ = −U∞·nᵢ: on its own the wind would blow straight through the front faces (b < 0) and out of the back ones (b > 0). The sources must cancel exactly this leak.'],
  ['A⁻¹', 'Ainv', 'Solve Aσ = b: every panel affects every other, so all 6 strengths are found together. Like adjusting 6 linked taps until none leaks. The front blows fluid out (σ > 0), the back sucks it in (σ < 0).'],
  ['V', 'V', 'V adds up the velocity at each panel centre: the wind plus every source\'s push. The normal parts cancel (no leak, to round-off); what is left slides along the surface.'],
  ['P', 'P', 'P is Bernoulli: faster flow, lower pressure. Cₚ = 1 − |u|²/U∞² is near 1 where the flow slows (the faces the wind hits) and negative where it speeds round the sides. Six panels are crude: the Build uses up to 864.']];
let opStage = 0, opT = 0, opPlay = !reduce, opLast = null;
const opBtns = $('opsteps');
opBtns.innerHTML = OPS.map(([n],k) => `<button class="b opb" data-k="${k}">${k+1} · ${n}</button>`).join('');
function opCap(){ $('opcap').textContent = OPS[opStage][2]; opBtns.querySelectorAll('.opb').forEach((b,k) => b.classList.toggle('pri', k === opStage)); }
opBtns.onclick = e => { const b = e.target.closest('.opb'); if (!b) return; opStage = +b.dataset.k; opT = 0; opCap(); K.pin(OPS[opStage][1]); if (reduce) drawOps(0); };
$('opplay').onclick = e => { opPlay = !opPlay; e.target.textContent = opPlay ? 'Pause' : 'Play'; };
opCap();
const OPD = 4.2;
function drawOps(now){
  const dt = opLast === null ? 0 : Math.min(100, now-opLast); opLast = now;
  opT = Math.min(opPlay ? 99 : OPD, opT + dt/1000); if (opPlay && opT > OPD) { opT = 0; opStage = (opStage+1) % OPS.length; opCap(); }
  if (!reduce && !VO.drag) VO.th += dt*0.00015;
  const c = CO, W = c.W, H = c.H, p = P(), Cb = CUBE, e = reduce ? 1 : ease(opT/2.6), st = opStage;
  c.clearRect(0,0,W,H);
  // assembly progress: which entry is being filled
  const nFill = st === 1 ? Math.floor(clamp(opT/3, 0, 1)*36) : st > 1 ? 36 : 0, cur = st === 1 ? Math.min(35, nFill) : -1, ci = cur >= 0 ? Math.floor(cur/6) : -1, cj = cur >= 0 ? cur%6 : -1;
  // --- the cube ---
  label(c, 'the body: 6 panels', 20, 24, p.ink, SANS);
  const sMax = Math.max(...Cb.sig.map(Math.abs)), bMax = Math.max(...Cb.b.map(Math.abs));
  const faces = Cb.C.map((n,f) => ({f, d: proj(VO, ...n)[2]})).filter(o => facing(VO, ...Cb.C[o.f])).sort((a,b) => a.d-b.d);
  // freestream arrows
  for (let k=0;k<4;k++){ const y = 80 + k*55; arrow(c, 14, y, 52, y + Cb.U[1]*-14, isAct('U') ? p.ink : p.c, isAct('U') ? 2.6 : 1.8); }
  label(c, 'U∞', 22, 70, p.c, MATH);
  faces.forEach(({f}) => { const pts = Cb.verts[f].map(v => proj(VO, ...v));
    let col = hex(p.panel);
    if (st === 2) col = sgRGB(p, Cb.b[f], bMax);
    else if (st === 3) col = mixa(hex(p.panel), sgRGB(p, Cb.sig[f], sMax), e);
    else if (st === 4) col = sgRGB(p, Cb.sig[f], sMax);
    else if (st === 5) col = mixa(hex(p.panel), cpRGB(p, Cb.cp[f]), e);
    if (st === 1 && (f === ci || f === cj)) col = mixa(hex(p.panel), hex(f === ci ? p.f : p.eq), .45);
    c.beginPath(); pts.forEach((q,k) => k ? c.lineTo(q[0],q[1]) : c.moveTo(q[0],q[1])); c.closePath();
    c.fillStyle = rgb(col); c.globalAlpha = .92; c.fill(); c.globalAlpha = 1; c.strokeStyle = isAct('dS') ? p.w : p.mut; c.lineWidth = isAct('dS') ? 2.2 : 1.2; c.stroke();
    const o = proj(VO, ...Cb.C[f]);
    c.fillStyle = isAct('xc') ? p.ink : p.w; c.beginPath(); c.arc(o[0], o[1], isAct('xc') ? 4.5 : 3, 0, 7); c.fill();
    if (st === 0 || isAct('n')) { const q = proj(VO, ...Cb.C[f].map(v => v*1.8)); arrow(c, o[0], o[1], q[0], q[1], p.cs, isAct('n') ? 2.6 : 1.8); }
    if (st >= 4) { const u = Cb.vel[f], q = proj(VO, Cb.C[f][0]+u[0]*.6, Cb.C[f][1]+u[1]*.6, Cb.C[f][2]+u[2]*.6); arrow(c, o[0], o[1], q[0], q[1], p.u, isAct('V','u') ? 3 : 2.2); }
    label(c, Cb.nm[f], o[0], o[1]-8, p.ink, F10, 'center'); });
  if (st === 1 && ci !== cj && ci >= 0) { const a = proj(VO, ...Cb.C[cj]), b = proj(VO, ...Cb.C[ci]); arrow(c, a[0], a[1], b[0], b[1], p.tau, 2.4, true); }
  triad(c, VO, 30, 320, p);
  // --- matrix, b, sigma ---
  const x0 = 300, y0 = 78, cw = 42, ch = 30;
  subl(c, 'A', 'ij', x0, 24, isAct('Am') ? p.tau : p.ink); label(c, '6 × 6, dense', x0+34, 24, p.mut, F10);
  Cb.nm.forEach((n,k) => { label(c, n, x0+k*cw+cw/2, y0-10, isAct('j') ? p.eq : p.mut, F10, 'center'); label(c, n, x0-8, y0+k*ch+ch/2+4, isAct('i') ? p.f : p.mut, F10, 'right'); });
  label(c, 'j →', x0+6*cw+2, y0-10, p.eq, F10); label(c, 'i ↓', x0-34, y0-10, p.f, F10);
  for (let i=0;i<6;i++) for (let j=0;j<6;j++){ const k = i*6+j, on = k < nFill || (st === 1 && k === cur), v = Cb.A[i][j], x = x0+j*cw, y = y0+i*ch;
    c.fillStyle = on ? (i === j ? p.accSoft : p.panel) : p.bg; c.strokeStyle = k === cur ? p.tau : p.rule; c.lineWidth = k === cur ? 2 : 1; rr(c, x+1, y+1, cw-2, ch-2, 4); c.fill(); c.stroke();
    if (on) label(c, v.toFixed(3), x+cw/2, y+ch/2+4, i === j || isAct('delta') && i === j ? p.tau : p.ink, F10, 'center'); }
  const col = (xx, vals, name, colr, on, t) => { subl(c, name[0], name[1], xx+22, 50, on ? colr : p.mut, 'center');
    vals.forEach((v,i) => { const y = y0+i*ch; c.fillStyle = p.bg; rr(c, xx, y+1, 46, ch-2, 4); c.fill(); if (!on) return;
      c.globalAlpha = t; c.fillStyle = colr; const w = Math.min(22, Math.abs(v)*14); c.globalAlpha = .18*t; rr(c, v >= 0 ? xx+23 : xx+23-w, y+4, w, ch-8, 3); c.fill(); c.globalAlpha = t;
      label(c, fx(v,2), xx+23, y+ch/2+4, colr, F10, 'center'); c.globalAlpha = 1; }); };
  col(x0+6*cw+14, Cb.b, ['b','i'], p.c, st >= 2, st === 2 ? e : 1);
  col(x0+6*cw+78, Cb.sig, ['σ','j'], p.eq, st >= 3, st === 3 ? e : 1);
  if (st === 3) { arrow(c, x0+6*cw+60, y0-30, x0+6*cw+92, y0-30, p.rho, 2); label(c, 'A⁻¹', x0+6*cw+76, y0-36, p.rho, MATH, 'center'); }
  // --- results per panel ---
  const xr = 730;
  subl(c, '|u', 'i', xr+16, 50, st >= 4 ? p.u : p.mut, 'center'); label(c, '|', xr+27, 50, st >= 4 ? p.u : p.mut, MATH); subl(c, 'C', 'p,i', xr+100, 50, st >= 5 ? p.nu : p.mut, 'center');
  Cb.nm.forEach((n,i) => { const y = y0+i*ch, sp = Math.hypot(...Cb.vel[i]);
    if (st >= 4) { const t = st === 4 ? e : 1; c.globalAlpha = t; arrow(c, xr-34, y+ch/2, xr-34+sp*26, y+ch/2, p.u, 2.4); label(c, sp.toFixed(2), xr+66, y+ch/2+4, p.u, F10, 'right'); c.globalAlpha = 1; }
    if (st >= 5) { const t = e; c.globalAlpha = t; c.fillStyle = rgb(cpRGB(p, Cb.cp[i])); rr(c, xr+78, y+3, 50, ch-6, 5); c.fill(); label(c, fx(Cb.cp[i],2), xr+103, y+ch/2+4, p.ink, B11, 'center'); c.globalAlpha = 1; } });
  // --- the computed line for this stage ---
  const ly = 290; let txt = '';
  if (st === 0) txt = `U∞ = ${vec(Cb.U)} · panel +x: centre (1, 0, 0), normal (1, 0, 0), area 4`;
  if (st === 1 && ci >= 0) { const d = Cb.C[ci].map((v,q) => v-Cb.C[cj][q]), r = Math.hypot(...d);
    txt = ci === cj ? `A(${Cb.nm[ci]},${Cb.nm[cj]}) = ½  (the panel's own source)` : `A(${Cb.nm[ci]},${Cb.nm[cj]}) = 4/(4π) × ${vec(d,0)}·${vec(Cb.C[ci],0)} / ${r.toFixed(3)}³ = ${Cb.A[ci][cj].toFixed(4)}`; }
  if (st === 2) txt = `b(+x) = −U∞·n = −${Cb.U[0].toFixed(3)} · b(+y) = −${Cb.U[1].toFixed(3)} · b(+z) = −${Cb.U[2].toFixed(3)}`;
  if (st === 3) { const r = Cb.A.map((row,i) => row.reduce((s,v,j) => s+v*Cb.sig[j], 0) - Cb.b[i]); txt = `check Aσ − b: largest entry ${Math.max(...r.map(Math.abs)).toExponential(1)} (zero to round-off)`; }
  if (st === 4) txt = `u(+x) = ${vec(Cb.vel[0])} · normal part u·n = ${Cb.dot(Cb.vel[0], Cb.C[0]).toExponential(1)}`;
  if (st === 5) txt = `Cp(−x) = 1 − ${Math.hypot(...Cb.vel[1]).toFixed(3)}² = ${fx(Cb.cp[1],3)} · Cp(+y) = 1 − ${Math.hypot(...Cb.vel[2]).toFixed(3)}² = ${fx(Cb.cp[2],3)}`;
  label(c, txt, x0, ly, p.ink, F11);
  // chain of maps along the bottom
  const chain = [['geometry', 'A', 0], ['b', 'A⁻¹', 2], ['σ', 'V', 3], ['u', 'P', 4], ['Cₚ', '', 5]];
  let cx0 = x0; chain.forEach(([n, opn, k], q) => { const on = st >= k; label(c, n, cx0, 328, on ? p.ink : p.mut, MATH); const w = c.measureText(n).width;
    if (opn) { const a0 = cx0+w+8, a1 = a0+58, act = st === [1,3,4,5][q]; arrow(c, a0, 324, a1, 324, act ? p.ink : p.rule, act ? 2.4 : 1.4); label(c, opn, (a0+a1)/2, 316, act ? p.ink : p.mut, MATH, 'center'); cx0 = a1+10; } });
}

// ---------- HOW IT WORKS: one panel per operator ----------
const mt = s => `<div class="hm"><math display="block">${s}</math></div>`, tc = (col, x) => `<mrow style="color:var(${col})">${x}</mrow>`, sw = col => `<i class="tb" style="background:var(${col})"></i>`;
const exb = (lab, attr, list, cur, nameOf) => `<div class="eex"><span>${lab}</span>${list.map(v => `<button class="b${v === cur ? ' pri' : ''}" data-${attr}="${v}">${nameOf ? nameOf(v) : v}</button>`).join('')}</div>`;
const HS = {G: 1, A: 2, L: 1, V: 0, B: 60, K: 6};
const bindEx = (k, attr) => function(root){ root.querySelectorAll(`[data-${attr}]`).forEach(b => b.onclick = () => { HS[k] = +b.dataset[attr]; root.querySelectorAll(`[data-${attr}]`).forEach(x => x.classList.toggle('pri', x === b)); this.draw(root); }); };
const sysCache = {};
const sysFor = n => sysCache[n] || (sysCache[n] = (() => { if (n === 1) { const N = 6, A = new Float64Array(36); CUBE.A.forEach((r,i) => r.forEach((v,j) => A[i*6+j] = v)); return {N, A, b: Float64Array.from(CUBE.b)}; } return system(n, 1); })());
const HOW = {
 G: {html: () => `<span class="eyebrow">How G works</span>
   <p>One point source of strength Q at 𝐱′ adds this to the potential and the velocity:</p>
   ${mt(`<mi>φ</mi><mo>=</mo>${tc('--c-eq','<mi>Q</mi>')}${tc('--c-tau','<mi>G</mi><mo>=</mo><mfrac><mrow><mo>−</mo><mn>1</mn></mrow><mrow><mn>4</mn><mi>π</mi><mi>r</mi></mrow></mfrac>')}<mo>,</mo><mspace width="1em"/><msub><mi>u</mi><mi>α</mi></msub><mo>=</mo>${tc('--c-eq','<mi>Q</mi>')}${tc('--c-tau','<mfrac><mn>1</mn><mrow><mn>4</mn><mi>π</mi><msup><mi>r</mi><mn>2</mn></msup></mrow></mfrac>')}${tc('--c-u','<mfrac><mrow><msub><mi>x</mi><mi>α</mi></msub><mo>−</mo><msubsup><mi>x</mi><mi>α</mi><mo>′</mo></msubsup></mrow><mi>r</mi></mfrac>')}`)}
   <div class="eterms"><span>${sw('--c-eq')}Q</span><span>How much fluid the source emits per second.</span>
     <span>${sw('--c-tau')}1/(4πr²)</span><span>Spread over a sphere of area 4πr²: the speed falls with the square of distance.</span>
     <span>${sw('--c-u')}direction</span><span>Straight away from the source (unit vector). A surface sheet is many of these, Q = σ dS.</span></div>
   ${exb('Example, r =', 'r', [0.5,1,2,4], HS.G)}<canvas class="hc" data-w="420" data-h="110"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), r = HS.G, ox = 70, oy = 55, sc = 24;
   c.clearRect(0,0,c.W,c.H); c.fillStyle = p.eq; c.beginPath(); c.arc(ox, oy, 5, 0, 7); c.fill();
   c.setLineDash([3,4]); c.strokeStyle = p.tau; c.lineWidth = 1.4; c.beginPath(); c.arc(ox, oy, Math.min(50, r*sc), 0, 7); c.stroke(); c.setLineDash([]);
   for (let k=0;k<8;k++){ const a = k*Math.PI/4, R0 = Math.min(50, r*sc), L = 14/(r*r); arrow(c, ox+R0*Math.cos(a), oy+R0*Math.sin(a), ox+(R0+Math.min(40,L))*Math.cos(a), oy+(R0+Math.min(40,L))*Math.sin(a), p.u, 1.8); }
   const gx = 180, gy = 92, gw = 220, X = q => gx + q/4.2*gw, Y = v => gy - Math.min(1, v/0.32)*76;
   c.strokeStyle = p.rule; c.beginPath(); c.moveTo(gx, gy-80); c.lineTo(gx, gy); c.lineTo(gx+gw, gy); c.stroke();
   c.beginPath(); for (let q=0.32;q<=4.2;q+=0.04){ q > .33 ? c.lineTo(X(q), Y(FP/(q*q))) : c.moveTo(X(q), Y(FP/(q*q))); } c.strokeStyle = p.tau; c.lineWidth = 2; c.stroke();
   c.fillStyle = p.u; c.beginPath(); c.arc(X(r), Y(FP/(r*r)), 5, 0, 7); c.fill(); label(c, '|u| vs r', gx+6, gy-70, p.mut, F10); label(c, 'r', gx+gw+6, gy+4, p.mut, MATH);
   root.querySelector('.ecalc').textContent = `Q = 1, r = ${r}: φ = −1/(4π·${r}) = ${fx(-FP/r,4)} · |u| = 1/(4π·${r}²) = ${(FP/(r*r)).toFixed(4)} · flux through the sphere = |u|·4πr² = ${(FP/(r*r)*4*Math.PI*r*r).toFixed(3)} (= Q at every r)`; }},
 A: {html: () => `<span class="eyebrow">How A works</span>
   <p>One entry: the normal velocity at the centre of panel i from a unit source over panel j (here as one point, as for far panels).</p>
   ${mt(`<msub><mi>A</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>=</mo>${tc('--c-w','<mfrac><mn>1</mn><mn>2</mn></mfrac><msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>')}<mo>+</mo>${tc('--c-eq','<mfrac><mrow><mi>Δ</mi><msub><mi>S</mi><mi>j</mi></msub></mrow><mrow><mn>4</mn><mi>π</mi></mrow></mfrac>')}${tc('--c-cs','<mo>(</mo><msub><mi>x</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>−</mo><msub><mi>x</mi><mrow><mi>j</mi><mi>α</mi></mrow></msub><mo>)</mo><msub><mi>n</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub>')}${tc('--c-tau','<mo>/</mo><msubsup><mi>r</mi><mrow><mi>i</mi><mi>j</mi></mrow><mn>3</mn></msubsup>')}`)}
   <div class="eterms"><span>${sw('--c-w')}½δᵢⱼ</span><span>A panel pushes ½ of its own source through itself.</span>
     <span>${sw('--c-eq')}ΔSⱼ/4π</span><span>Bigger panels emit more.</span>
     <span>${sw('--c-cs')}(xᵢ − xⱼ)·nᵢ</span><span>Only the part of the push along panel i's normal counts.</span>
     <span>${sw('--c-tau')}1/r³</span><span>Together with the length of (xᵢ − xⱼ): falls like 1/r².</span></div>
   ${exb('Example, i = +x, j =', 'j', [0,1,2,4], HS.A, j => CUBE.nm[j])}<canvas class="hc" data-w="420" data-h="130"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), j = HS.A, i = 0, V = {th: -0.75, ph: 0.4, s: 34, ox: 90, oy: 66};
   c.clearRect(0,0,c.W,c.H);
   CUBE.C.map((n,f) => f).filter(f => facing(V, ...CUBE.C[f])).forEach(f => { const pts = CUBE.verts[f].map(v => proj(V, ...v)); c.beginPath(); pts.forEach((q,k) => k ? c.lineTo(q[0],q[1]) : c.moveTo(q[0],q[1])); c.closePath();
     c.fillStyle = f === i ? p.accSoft : p.panel; c.fill(); c.strokeStyle = p.mut; c.lineWidth = 1; c.stroke(); });
   const a = proj(V, ...CUBE.C[j]), b = proj(V, ...CUBE.C[i]), nn = proj(V, 1.9, 0, 0);
   c.fillStyle = p.eq; c.beginPath(); c.arc(a[0], a[1], 5, 0, 7); c.fill(); c.fillStyle = p.f; c.beginPath(); c.arc(b[0], b[1], 5, 0, 7); c.fill();
   if (i !== j) arrow(c, a[0], a[1], b[0], b[1], p.tau, 2.2, true); arrow(c, b[0], b[1], nn[0], nn[1], p.cs, 2);
   subl(c, 'n', 'i', nn[0]+6, nn[1]+4, p.cs);
   const d = CUBE.C[i].map((v,q) => v-CUBE.C[j][q]), r = Math.hypot(...d), dn = CUBE.dot(d, CUBE.C[i]);
   const parts = i === j ? [['½', .5, p.w]] : [['ΔS/4π', 4*FP, p.eq], ['(xᵢ−xⱼ)·nᵢ', dn, p.cs], ['1/r³', 1/r**3, p.tau]];
   parts.forEach(([n,v,cl],k) => { const y = 24 + k*32; label(c, n, 200, y+4, cl, B11); c.fillStyle = cl; c.globalAlpha = .7; rr(c, 300, y-8, Math.min(110, v*60), 14, 3); c.fill(); c.globalAlpha = 1; label(c, v.toFixed(3), 300+Math.min(110, v*60)+6, y+4, p.ink, F10); });
   root.querySelector('.ecalc').textContent = i === j ? 'A(+x,+x) = ½ = 0.5000: the panel acting on itself.' :
     `A(+x,${CUBE.nm[j]}) = 4/(4π) × ${fx(dn,0)} / ${r.toFixed(3)}³ = ${(4*FP).toFixed(4)} × ${fx(dn,0)} × ${(1/r**3).toFixed(4)} = ${CUBE.A[i][j].toFixed(4)}${dn === 0 ? ' (its push runs along the panel, not through it)' : ''}`; }},
 L: {html: () => `<span class="eyebrow">How A⁻¹ works</span>
   ${mt(`<mtext>LU: </mtext>${tc('--c-rho','<mi>A</mi><mo>=</mo><mi>L</mi><mi>U</mi>')}<mo>,</mo><mspace width=".5em"/>${tc('--c-w','<mfrac><mn>2</mn><mn>3</mn></mfrac><msup><mi>N</mi><mn>3</mn></msup>')}<mspace width="1.5em"/><mtext>GMRES: </mtext><msup><mi>σ</mi><mrow><mo>(</mo><mi>k</mi><mo>)</mo></mrow></msup><mo>=</mo>${tc('--c-c','<mo>arg</mo><mo>min</mo><mo>|</mo><mi>b</mi><mo>−</mo><mi>A</mi><mi>σ</mi><mo>|</mo>')}<mo>,</mo><mspace width=".4em"/>${tc('--c-tau','<mi>σ</mi><mo>∈</mo><mtext>span</mtext><mo>{</mo><mi>b</mi><mo>,</mo><mi>A</mi><mi>b</mi><mo>,</mo><mo>…</mo><mo>}</mo>')}`)}
   <div class="eterms"><span>${sw('--c-rho')}A = LU</span><span>Gaussian elimination: subtract rows until triangular, then back-substitute. Exact, but ⅔N³ work.</span>
     <span>${sw('--c-c')}min |b − Aσ|</span><span>GMRES picks the guess with the smallest leak (residual)…</span>
     <span>${sw('--c-tau')}Krylov space</span><span>…among combinations of b, Ab, A²b, …: one matrix-vector product (2N² work) per iteration k.</span></div>
   ${exb('Example system', 'n', [1,4,8], HS.L, n => n === 1 ? 'cube, N = 6' : `sphere, N = ${6*n*n}`)}<canvas class="hc" data-w="420" data-h="120"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), S = sysFor(HS.L), N = S.N;
   if (!S.gm) S.gm = gmres(S.A, N, S.b, 1e-12);
   const h = S.gm.hist, x0 = 40, x1 = 400, y0 = 12, y1 = 100, X = k => x0 + k/Math.max(8, h.length-1)*(x1-x0), Y = r => y0 + (-Math.log10(Math.max(r, 1e-14)))/14*(y1-y0);
   c.clearRect(0,0,c.W,c.H); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x0, y1); c.lineTo(x1, y1); c.stroke();
   [0,-4,-8,-12].forEach(e => label(c, e ? `1e${e}` : '1', x0-4, Y(10**e)+4, p.mut, F10, 'right'));
   c.beginPath(); h.forEach((r,k) => k ? c.lineTo(X(k), Y(r)) : c.moveTo(X(k), Y(r))); c.strokeStyle = p.rho; c.lineWidth = 2.2; c.stroke();
   h.forEach((r,k) => { c.fillStyle = p.rho; c.beginPath(); c.arc(X(k), Y(r), 3, 0, 7); c.fill(); });
   label(c, 'residual |b − Aσ⁽ᵏ⁾| / |b|', x0+8, y0+10, p.mut, F10); label(c, 'iteration k', x1, y1+14, p.mut, F10, 'right');
   const it = h.length-1, lu = 2/3*N**3, gm = it*2*N*N;
   root.querySelector('.ecalc').textContent = `N = ${N}: LU ⅔N³ = ${Math.round(lu).toLocaleString('en')} operations · GMRES reached ${h[it].toExponential(0)} in ${it} iterations × 2N² = ${gm.toLocaleString('en')} (${(lu/gm).toFixed(1)}× fewer)`; }},
 V: {html: () => `<span class="eyebrow">How V works</span>
   ${mt(`<msub><mi>u</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>=</mo>${tc('--c-c','<msub><mi>U</mi><mrow><mi>∞</mi><mi>α</mi></mrow></msub>')}<mo>+</mo>${tc('--c-cs','<mfrac><mn>1</mn><mn>2</mn></mfrac><msub><mi>σ</mi><mi>i</mi></msub><msub><mi>n</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub>')}<mo>+</mo>${tc('--c-eq','<munder><mo>∑</mo><mrow><mi>j</mi><mo>≠</mo><mi>i</mi></mrow></munder><msub><mi>σ</mi><mi>j</mi></msub><mfrac><mrow><mi>Δ</mi><msub><mi>S</mi><mi>j</mi></msub></mrow><mrow><mn>4</mn><mi>π</mi></mrow></mfrac><mfrac><mrow><msub><mi>x</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>−</mo><msub><mi>x</mi><mrow><mi>j</mi><mi>α</mi></mrow></msub></mrow><msubsup><mi>r</mi><mrow><mi>i</mi><mi>j</mi></mrow><mn>3</mn></msubsup></mfrac>')}`)}
   <div class="eterms"><span>${sw('--c-c')}U∞</span><span>The wind.</span>
     <span>${sw('--c-cs')}½σᵢnᵢ</span><span>The panel's own source: straight out through itself.</span>
     <span>${sw('--c-eq')}Σ others</span><span>Every other panel's push. Head to tail, the normal parts cancel; the rest runs along the surface.</span></div>
   ${exb('Example, panel i =', 'i', [0,1,2,4], HS.V, i => CUBE.nm[i])}<canvas class="hc" data-w="420" data-h="120"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), i = HS.V, V = {th: -0.75, ph: 0.4, s: 70, ox: 130, oy: 70};
   c.clearRect(0,0,c.W,c.H);
   const self = CUBE.parts[i][i], oth = CUBE.parts[i].reduce((a,v,j) => j === i ? a : [a[0]+v[0], a[1]+v[1], a[2]+v[2]], [0,0,0]);
   let at = [0,0,0]; const step = (v, col, n) => { const a = proj(V, ...at), nx = at.map((x,q) => x+v[q]), b = proj(V, ...nx); arrow(c, a[0], a[1], b[0], b[1], col, 2.4); label(c, n, (a[0]+b[0])/2+4, (a[1]+b[1])/2-6, col, F10); at = nx; };
   step(CUBE.U, p.c, 'U∞'); step(self, p.cs, '½σn'); step(oth, p.eq, 'Σ others');
   const o = proj(V, 0,0,0), e = proj(V, ...CUBE.vel[i]); arrow(c, o[0], o[1], e[0], e[1], p.u, 3.2); subl(c, 'u', 'i', e[0]+6, e[1]+12, p.u);
   const nn = proj(V, ...CUBE.C[i].map(v => v*.6)); c.setLineDash([3,3]); c.strokeStyle = p.cs; c.lineWidth = 1; c.beginPath(); c.moveTo(o[0], o[1]); c.lineTo(nn[0], nn[1]); c.stroke(); c.setLineDash([]); label(c, 'nᵢ', nn[0]+4, nn[1], p.cs, F10);
   triad(c, V, 380, 90, p);
   root.querySelector('.ecalc').textContent = `panel ${CUBE.nm[i]}: U∞ ${vec(CUBE.U)} + ½σn ${vec(self)} + others ${vec(oth)} = u ${vec(CUBE.vel[i])} · u·n = ${CUBE.dot(CUBE.vel[i], CUBE.C[i]).toExponential(1)}`; }},
 B: {html: () => `<span class="eyebrow">How P works</span>
   <p>Bernoulli along the flow, divided by ½ρU∞². On a sphere the exact speed is |u| = (3/2) U∞ sin θ:</p>
   ${mt(`<msub><mi>C</mi><mi>p</mi></msub><mo>=</mo><mfrac><mrow><mi>p</mi><mo>−</mo><msub><mi>p</mi><mi>∞</mi></msub></mrow><mrow><mfrac><mn>1</mn><mn>2</mn></mfrac><mi>ρ</mi><msubsup><mi>U</mi><mi>∞</mi><mn>2</mn></msubsup></mrow></mfrac><mo>=</mo>${tc('--c-w','<mn>1</mn>')}<mo>−</mo>${tc('--c-u','<mfrac><mrow><msub><mi>u</mi><mi>α</mi></msub><msub><mi>u</mi><mi>α</mi></msub></mrow><msubsup><mi>U</mi><mi>∞</mi><mn>2</mn></msubsup></mfrac>')}`)}
   <div class="eterms"><span>${sw('--c-w')}1</span><span>All the wind's dynamic pressure, recovered where the flow stops.</span>
     <span>${sw('--c-u')}|u|²/U∞²</span><span>Speed squared takes it back: above U∞ the pressure drops below p∞ (suction).</span></div>
   ${exb('Example, θ =', 'th', [0,30,60,90,135], HS.B, v => v+'°')}<canvas class="hc" data-w="420" data-h="110"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), th = HS.B*Math.PI/180, x0 = 40, x1 = 400, X = t => x0+t/Math.PI*(x1-x0), Y = v => 14 + (1-v)/2.4*86;
   c.clearRect(0,0,c.W,c.H); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, Y(1)); c.lineTo(x0, Y(-1.4)); c.moveTo(x0, Y(0)); c.lineTo(x1, Y(0)); c.stroke();
   [1,0,-1].forEach(v => label(c, String(v), x0-4, Y(v)+4, p.mut, F10, 'right')); [0,90,180].forEach(d => label(c, d+'°', X(d*Math.PI/180), Y(-1.4)+12, p.mut, F10, 'center'));
   c.beginPath(); for (let k=0;k<=90;k++){ const t = k/90*Math.PI; k ? c.lineTo(X(t), Y(1-2.25*Math.sin(t)**2)) : c.moveTo(X(t), Y(1)); } c.strokeStyle = p.nu; c.lineWidth = 2.2; c.stroke();
   const sp = 1.5*Math.sin(th), cp = 1-sp*sp; c.fillStyle = p.nu; c.beginPath(); c.arc(X(th), Y(cp), 5, 0, 7); c.fill();
   root.querySelector('.ecalc').textContent = `θ = ${HS.B}°: |u|/U∞ = 1.5 × sin ${HS.B}° = ${sp.toFixed(3)} → Cp = 1 − ${sp.toFixed(3)}² = ${fx(cp,3)}${HS.B === 0 ? ' (stagnation point)' : HS.B === 90 ? ' (lowest: the shoulder)' : ''}`; }},
 K: {html: () => `<span class="eyebrow">How K works</span>
   <p>For the Joukowski section in block C (a circle of radius R mapped to a wing shape), the Kutta condition has a closed form:</p>
   ${mt(`<mi>Γ</mi><mo>=</mo>${tc('--c-tau','<mn>4</mn><mi>π</mi><mi>R</mi>')}${tc('--c-c','<msub><mi>U</mi><mi>∞</mi></msub>')}${tc('--c-cs','<mi>sin</mi><mo>(</mo><mi>α</mi><mo>+</mo><mi>β</mi><mo>)</mo>')}<mo>,</mo><mspace width="1em"/><msub><mi>C</mi><mi>l</mi></msub><mo>=</mo><mfrac><mrow><mn>2</mn><mi>Γ</mi></mrow><mrow><msub><mi>U</mi><mi>∞</mi></msub><mi>c</mi></mrow></mfrac>`)}
   <div class="eterms"><span>${sw('--c-tau')}4πR</span><span>Size of the circle that maps onto the section.</span>
     <span>${sw('--c-c')}U∞</span><span>Faster wind needs more swirl to stay smooth at the edge.</span>
     <span>${sw('--c-cs')}sin(α + β)</span><span>Angle of attack plus the camber angle β: a cambered section lifts even at α = 0.</span></div>
   ${exb('Example, α =', 'a', [0,4,8,12], HS.K, v => v+'°')}<canvas class="hc" data-w="420" data-h="110"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), x0 = 40, x1 = 400, X = a => x0+(a+4)/18*(x1-x0), Y = v => 96 - v/2*84;
   c.clearRect(0,0,c.W,c.H); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(X(0), Y(2)); c.lineTo(X(0), Y(-.3)); c.moveTo(x0, Y(0)); c.lineTo(x1, Y(0)); c.stroke();
   const cl = a => 2*JK.gk(a*Math.PI/180)/JK.c;
   c.beginPath(); for (let a=-4;a<=14;a+=.5){ a > -4 ? c.lineTo(X(a), Y(cl(a))) : c.moveTo(X(a), Y(cl(a))); } c.strokeStyle = p.tau; c.lineWidth = 2.2; c.stroke();
   c.setLineDash([4,4]); c.beginPath(); c.moveTo(X(-4), Y(2*Math.PI*-4*Math.PI/180)); c.lineTo(X(14), Y(2*Math.PI*14*Math.PI/180)); c.strokeStyle = p.mut; c.lineWidth = 1.2; c.stroke(); c.setLineDash([]);
   c.fillStyle = p.tau; c.beginPath(); c.arc(X(HS.K), Y(cl(HS.K)), 5, 0, 7); c.fill();
   subl(c, 'C', 'l', x0+4, 14, p.tau); label(c, '┄ thin flat plate 2πα', x1, 108, p.mut, F10, 'right'); label(c, 'α', x1+8, Y(0)+4, p.mut, MATH);
   const a = HS.K*Math.PI/180, G = JK.gk(a);
   root.querySelector('.ecalc').textContent = `R = ${JK.R.toFixed(4)}, β = ${(JK.B*180/Math.PI).toFixed(2)}°, α = ${HS.K}°: Γ = 4π × ${JK.R.toFixed(3)} × sin(${(HS.K+JK.B*180/Math.PI).toFixed(2)}°) = ${G.toFixed(3)} · chord c = ${JK.c.toFixed(3)} → Cl = 2Γ/c = ${cl(HS.K).toFixed(3)} (flat plate 2πα = ${(2*Math.PI*a).toFixed(3)})`; }}
};
HOW.G.bind = bindEx('G','r'); HOW.A.bind = bindEx('A','j'); HOW.L.bind = bindEx('L','n'); HOW.V.bind = bindEx('V','i'); HOW.B.bind = bindEx('B','th'); HOW.K.bind = bindEx('K','a');

// ---------- A: superposition in a slice through the axis ----------
const CA = hidpi($('supviz')), SX = 62, SOX = 200, SOY = 165;
let mode = 0, Qs = 3, supPaths = null, body = null, probe = [1.4, 1.0];
const D2 = 0.8;
// velocity (u_x, u_ϖ) in the meridional plane, U∞ = 1 along x
function supVel(x, w){ let ux = 1, uw = 0; const src = (xs, q) => { const dx = x-xs, R2 = dx*dx+w*w, R3 = R2*Math.sqrt(R2), s = q*FP/R3; ux += s*dx; uw += s*w; };
  if (mode === 0) src(0, Qs); else if (mode === 1) { src(-D2, Qs); src(D2, -Qs); }
  else { const a3 = Qs/(2*Math.PI), R2 = x*x+w*w, R = Math.sqrt(R2), R5 = R2*R2*R; ux += a3/2*(1/(R2*R) - 3*x*x/R5); uw += a3/2*(-3*x*w/R5); }
  return [ux, uw]; }
function supPhi(x, y, z){ const w2 = y*y+z*z; let f = x;
  if (mode === 0) f -= Qs*FP/Math.sqrt(x*x+w2); else if (mode === 1) f += -Qs*FP/Math.sqrt((x+D2)**2+w2) + Qs*FP/Math.sqrt((x-D2)**2+w2);
  else f += Qs/(2*Math.PI)/2*x/(x*x+w2)**1.5; return f; }
function supPsi(x, w){ let s = .5*w*w; const R = (xs) => Math.sqrt((x-xs)**2+w*w);
  if (mode === 0) return s - Qs*FP*x/R(0) - Qs*FP; if (mode === 1) return s - Qs*FP*((x+D2)/R(-D2) - (x-D2)/R(D2));
  return s*(1 - Qs/(2*Math.PI)/R(0)**3); }
function supBuild(){
  // body outline: dividing stream surface ψ = 0, found per x by bisection on ϖ
  body = []; for (let x=-3.3;x<=4.3;x+=0.03){ if (supPsi(x, 1e-3) >= 0) { body.push(null); continue; } let lo = 1e-3, hi = 3; for (let k=0;k<40;k++){ const m = (lo+hi)/2; supPsi(x, m) < 0 ? lo = m : hi = m; } body.push([x, lo]); }
  const inside = (x, w) => supPsi(x, Math.abs(w)) < 0;
  const trace = (x, w, dir, perp, maxs) => { const pts = [[x,w]]; for (let s=0;s<maxs;s++){
      const f = (a,b) => { const [u,v] = supVel(a,b), L = Math.hypot(u,v) || 1; return perp ? [-v/L, u/L] : [u/L, v/L]; };
      const h = .035*dir, k1 = f(x,w), k2 = f(x+h/2*k1[0], w+h/2*k1[1]), k3 = f(x+h/2*k2[0], w+h/2*k2[1]), k4 = f(x+h*k3[0], w+h*k3[1]);
      x += h/6*(k1[0]+2*k2[0]+2*k3[0]+k4[0]); w += h/6*(k1[1]+2*k2[1]+2*k3[1]+k4[1]);
      if (x < -3.3 || x > 4.3 || w > 2.4 || w < 0) break; if (perp && inside(x, w)) break; pts.push([x,w]); } return pts; };
  const stream = [0.18,0.36,0.56,0.78,1.0,1.25,1.5,1.8,2.1].map(w => trace(-3.3, w, 1, false, 500));
  const pot = []; for (let x=-3;x<=4.01;x+=0.5){ let w = 0; if (inside(x, 0.002)) { const bi = body[Math.round((x+3.3)/0.03)]; if (!bi) continue; w = bi[1]+0.01; } pot.push(trace(x, w, 1, true, 120)); }
  supPaths = {stream, pot};
}
const parts = [...Array(110)].map(() => [-3.3 + Math.random()*7.6, (Math.random() < .5 ? -1 : 1)*(0.04 + Math.random()*2.1), Math.random()*20]);
function supStep(dt){ parts.forEach(q => { const s = Math.sign(q[1]) || 1, [u,v] = supVel(q[0], Math.abs(q[1])); q[0] += u*dt*.8; q[1] += s*v*dt*.8; q[2] += dt;
  if (q[0] > 4.3 || Math.abs(q[1]) > 2.5 || q[2] > 30 || supPsi(q[0], Math.abs(q[1])) < 0) { q[0] = -3.3 - Math.random()*.6; q[1] = s*(0.04+Math.random()*2.1); q[2] = 0; } }); }
const SP = (x, w) => [SOX + x*SX, SOY - w*SX];
let supLast = null, supVA = {th: -0.5, ph: 0.35, s: 17, ox: 382, oy: 64};
function drawSup(now){
  const dt = supLast === null ? 0 : Math.min(60, now-supLast)/1000; supLast = now; if (!reduce) { supStep(dt); supVA.th += dt*.5; }
  const c = CA, W = c.W, H = c.H, p = P(); c.clearRect(0,0,W,H);
  c.save(); c.beginPath(); c.rect(0, 26, W, 278); c.clip();
  // axis of symmetry
  c.setLineDash([2,4]); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(0, SOY); c.lineTo(W, SOY); c.stroke(); c.setLineDash([]);
  // equipotentials φ = const (perpendicular to the streamlines, and to the body)
  const phOn = isAct('phi','grad');
  c.strokeStyle = p.f; c.lineWidth = phOn ? 2 : 1.1; c.globalAlpha = phOn ? .95 : .4; c.setLineDash(phOn ? [] : [4,4]);
  supPaths.pot.forEach(l => [1,-1].forEach(s => { c.beginPath(); l.forEach(([x,w],k) => { const [X,Y] = SP(x, s*w); k ? c.lineTo(X,Y) : c.moveTo(X,Y); }); c.stroke(); }));
  c.setLineDash([]); c.globalAlpha = 1;
  // streamlines
  c.strokeStyle = p.mut; c.lineWidth = 1; c.globalAlpha = .55;
  supPaths.stream.forEach(l => [1,-1].forEach(s => { c.beginPath(); l.forEach(([x,w],k) => { const [X,Y] = SP(x, s*w); k ? c.lineTo(X,Y) : c.moveTo(X,Y); }); c.stroke(); })); c.globalAlpha = 1;
  // the body: dividing stream surface, cut through its axis
  const segs = []; let seg = []; body.forEach(b => { if (b) seg.push(b); else if (seg.length) { segs.push(seg); seg = []; } }); if (seg.length) segs.push(seg);
  segs.forEach(sg => { c.beginPath(); sg.forEach(([x,w],k) => { const [X,Y] = SP(x,w); k ? c.lineTo(X,Y) : c.moveTo(X,Y); }); for (let k=sg.length-1;k>=0;k--){ const [X,Y] = SP(sg[k][0], -sg[k][1]); c.lineTo(X,Y); } c.closePath();
    c.fillStyle = p.panel; c.fill(); c.strokeStyle = isAct('S') ? p.ink : p.mut; c.lineWidth = isAct('S') ? 2.6 : 1.6; c.stroke();
    if (isAct('n')) for (let k=3;k<sg.length-3;k+=8){ const [x,w] = sg[k], [x2,w2] = sg[k+1], tx = x2-x, tw = w2-w, L = Math.hypot(tx,tw); [1,-1].forEach(s => { const [X,Y] = SP(x, s*w); arrow(c, X, Y, X - tw/L*16, Y - s*tx/L*16, p.cs, 1.6); }); } });
  // particles
  c.fillStyle = p.u; parts.forEach(([x,w]) => { const [X,Y] = SP(x,w); c.globalAlpha = isAct('u') ? 1 : .8; c.beginPath(); c.arc(X, Y, isAct('u') ? 2.4 : 1.8, 0, 7); c.fill(); }); c.globalAlpha = 1;
  if (isAct('u','grad')) for (let x=-2.8;x<4;x+=0.8) for (let w=-1.8;w<=1.9;w+=0.6){ if (supPsi(x, Math.abs(w)) < 0) continue; const [u,v] = supVel(x, Math.abs(w)), [X,Y] = SP(x,w); arrow(c, X, Y, X+u*18, Y-Math.sign(w||1)*v*18, p.u, 1.6); }
  // sources and sinks
  const srcs = mode === 0 ? [[0, 1]] : mode === 1 ? [[-D2, 1], [D2, -1]] : [[0, 0]];
  srcs.forEach(([x,s]) => { const [X,Y] = SP(x,0), on = isAct('sig','Q');
    if (isAct('G')) [0.3,0.6,0.9].forEach(r => { c.setLineDash([3,3]); c.strokeStyle = p.tau; c.lineWidth = 1.2; c.beginPath(); c.arc(X, Y, r*SX, 0, 7); c.stroke(); c.setLineDash([]); });
    c.fillStyle = s > 0 ? p.eq : s < 0 ? p.c : p.tau; c.beginPath(); c.arc(X, Y, on ? 7 : 5, 0, 7); c.fill();
    label(c, s > 0 ? 'source' : s < 0 ? 'sink' : 'doublet', X, Y+(s < 0 ? 20 : -10), c.fillStyle, F10, 'center'); });
  if (isAct('G')) { const [X,Y] = SP(srcs[0][0], 0); label(c, 'G ∝ −1/r', X+0.95*SX, Y-0.6*SX, p.tau, B11); }
  // freestream
  for (let w=-1.8;w<=1.9;w+=0.6){ const [X,Y] = SP(-3.25, w); arrow(c, X, Y, X+26, Y, isAct('U') ? p.ink : p.c, isAct('U') ? 2.6 : 1.6); }
  // probe: φ, u and the Laplacian by finite differences, all at a real 3D point
  const [px, pw] = probe, [PX, PY] = SP(px, pw), inB = supPsi(px, Math.abs(pw)) < 0;
  c.strokeStyle = isAct('x','lap') ? p.ink : p.mut; c.lineWidth = isAct('x','lap') ? 2 : 1.2; c.beginPath(); c.arc(PX, PY, 6, 0, 7); c.moveTo(PX-10, PY); c.lineTo(PX+10, PY); c.moveTo(PX, PY-10); c.lineTo(PX, PY+10); c.stroke();
  if (!inB) { const [u,v] = supVel(px, Math.abs(pw)); arrow(c, PX, PY, PX+u*30, PY-Math.sign(pw||1)*v*30, p.u, 2.4); }
  c.restore();
  // 3D inset: the body of revolution
  { const V = supVA; c.fillStyle = p.bg; c.globalAlpha = .85; rr(c, 330, 30, 124, 72, 8); c.fill(); c.globalAlpha = 1;
    c.strokeStyle = isAct('S') ? p.ink : p.mut; c.lineWidth = 1;
    for (let k=0;k<body.length;k+=12){ const b = body[k]; if (!b || b[0] > 3.6) continue; c.beginPath(); for (let a=0;a<=24;a++){ const t = a/24*2*Math.PI, Q = proj(V, b[0]*.9, b[1]*Math.cos(t)*.9, b[1]*Math.sin(t)*.9); a ? c.lineTo(Q[0],Q[1]) : c.moveTo(Q[0],Q[1]); } c.stroke(); }
    const bb = body.filter(b => b && b[0] <= 3.6); [0,1,2,3].forEach(q => { const t = q*Math.PI/2; c.beginPath(); bb.forEach((b,k) => { const Q = proj(V, b[0]*.9, b[1]*Math.cos(t)*.9, b[1]*Math.sin(t)*.9); k ? c.lineTo(Q[0],Q[1]) : c.moveTo(Q[0],Q[1]); }); c.stroke(); });
    const a0 = proj(V, -3.2, 1.6, 0), a1 = proj(V, -2.2, 1.6, 0); arrow(c, a0[0], a0[1], a1[0], a1[1], p.c, 1.4);
    label(c, 'in 3D', 336, 98, p.mut, F10); }
  label(c, ['source + uniform flow = Rankine half-body', 'source + sink + uniform flow = Rankine ovoid', 'doublet + uniform flow = sphere'][mode], 10, 18, p.ink, SANS);
  // readouts
  let x = 10; const y = H-50;
  if (mode === 0) x = pill(c, x, y, `far width R = √(Q/πU∞) = ${Math.sqrt(Qs/Math.PI).toFixed(2)}`, p.eq);
  if (mode === 0) pill(c, x, y, `nose at x = −√(Q/4πU∞) = ${fx(-Math.sqrt(Qs*FP),2)}`, p.mut);
  if (mode === 1) pill(c, x, y, `ovoid: source and sink at x = ∓${D2}, Q = ${Qs.toFixed(1)}`, p.eq);
  if (mode === 2) pill(c, x, y, `sphere radius a = (μ/2πU∞)^⅓ = ${Math.cbrt(Qs/(2*Math.PI)).toFixed(3)}`, p.tau);
  const h = 1e-3, py = pw*Math.cos(.7), pz = pw*Math.sin(.7), f0 = supPhi(px, py, pz);
  const lap = (supPhi(px+h,py,pz)+supPhi(px-h,py,pz)+supPhi(px,py+h,pz)+supPhi(px,py-h,pz)+supPhi(px,py,pz+h)+supPhi(px,py,pz-h)-6*f0)/(h*h);
  const lp = inB ? 'probe is inside the body: not part of the flow' : `probe (${px.toFixed(2)}, ${py.toFixed(2)}, ${pz.toFixed(2)}): φ = ${fx(f0,3)} · ∂α∂αφ = ${lap.toExponential(0)} ≈ 0`;
  label(c, lp, 10, H-14, isAct('lap','x','phi') ? p.ink : p.mut, isAct('lap') ? B11 : F11);
}
$('supviz').addEventListener('click', e => { const r = $('supviz').getBoundingClientRect(), sx = (e.clientX-r.left)/r.width*CA.W, sy = (e.clientY-r.top)/r.height*CA.H; if (sy > 300) return; probe = [(sx-SOX)/SX, (SOY-sy)/SX]; if (reduce) drawSup(0); });
const qIn = $('q');
function supUpdate(){ Qs = +qIn.value; $('qv').textContent = Qs.toFixed(1); $('qs').textContent = mode === 2 ? 'μ' : 'Q'; supBuild(); if (reduce) drawSup(0); }
qIn.oninput = supUpdate;
$('modes').onclick = e => { const b = e.target.closest('[data-mode]'); if (!b) return; mode = +b.dataset.mode; $('modes').querySelectorAll('[data-mode]').forEach(x => x.classList.toggle('pri', x === b)); supUpdate(); };
supUpdate();

// ---------- B: the panelled sphere, its dense matrix, and the solve ----------
const CBc = hidpi($('matviz')), VB = {th: -0.5, ph: 0.35, s: 88, ox: 118, oy: 124}; orbit($('matviz'), VB, () => { if (reduce) drawB(0); });
let bs = null, bi = 0, bHold = false, bT = 0, bLast = null;
const heat = document.createElement('canvas');
function bBuild(n){ const S = system(n, 1), N = S.N, g = gmres(S.A, N, S.b, 1e-12), sMax = Math.max(...g.x.map(Math.abs));
  let offMax = 0; for (let i=0;i<N;i++) for (let j=0;j<N;j++) if (i !== j) offMax = Math.max(offMax, S.A[i*N+j]);
  heat.width = N; heat.height = N; const hc = heat.getContext('2d'), img = hc.createImageData(N, N), p = P(), bg = hex(p.bg), tcl = hex(p.tau);
  for (let i=0;i<N;i++) for (let j=0;j<N;j++){ const v = S.A[i*N+j], t = i === j ? 1 : clamp((Math.log10(Math.max(v/offMax, 1e-9)) + 2.5)/2.5, 0, 1)*.8, o = (i*N+j)*4, col = mixa(bg, tcl, t); img.data[o] = col[0]; img.data[o+1] = col[1]; img.data[o+2] = col[2]; img.data[o+3] = 255; }
  hc.putImageData(img, 0, 0);
  bs = {...S, sig: g.x, hist: g.hist, it: g.it, sMax, offMax}; bi = Math.min(bi, N-1); $('bi').max = N-1; $('bnv').textContent = `N = ${N}`; bT = 0; }
$('bn').oninput = () => { bBuild(+$('bn').value); if (reduce) drawB(0); };
$('bi').oninput = () => { bi = +$('bi').value; bHold = true; $('biv').textContent = `${bi}`; if (reduce) drawB(0); };
bBuild(4);
function drawB(now){
  const dt = bLast === null ? 0 : Math.min(100, now-bLast); bLast = now; bT += dt/1000;
  if (!reduce && !VB.drag) VB.th += dt*0.00012;
  const S = bs, N = S.N, M = S.M, c = CBc, W = c.W, H = c.H, p = P();
  if (!bHold && !reduce && Math.floor(bT/1.6) !== Math.floor((bT-dt/1000)/1.6)) { bi = (bi + Math.max(1, Math.round(N/9))) % N; $('bi').value = bi; }
  let jm = -1, jv = 0; for (let j=0;j<N;j++) if (j !== bi && S.A[bi*N+j] > jv) { jv = S.A[bi*N+j]; jm = j; }
  c.clearRect(0,0,W,H);
  // sphere: coloured by σ (or b), panel i and j outlined, influence lines into panel i
  const colOf = j => isAct('b') ? sgRGB(p, S.b[j], 1) : sgRGB(p, S.sig[j], S.sMax);
  drawBody(c, VB, M, colOf, N <= 150 ? (isAct('dS') ? p.w : p.rule) : null);
  const outline = (j, col, lw) => { if (!facing(VB, M.Nn[j*3], M.Nn[j*3+1], M.Nn[j*3+2])) return; c.beginPath(); for (let m=0;m<4;m++){ const o = j*12+m*3, Q = proj(VB, M.V[o]*1.003, M.V[o+1]*1.003, M.V[o+2]*1.003); m ? c.lineTo(Q[0],Q[1]) : c.moveTo(Q[0],Q[1]); } c.closePath(); c.strokeStyle = col; c.lineWidth = lw; c.stroke(); };
  const ci = proj(VB, M.C[bi*3], M.C[bi*3+1], M.C[bi*3+2]);
  for (let j=0;j<N;j++){ if (j === bi) continue; const v = S.A[bi*N+j]/S.offMax; if (v < .02) continue; const cj = proj(VB, M.C[j*3], M.C[j*3+1], M.C[j*3+2]);
    c.globalAlpha = Math.min(1, Math.pow(v, .8))*(isAct('Am') ? 1 : .55)*(facing(VB, M.Nn[j*3], M.Nn[j*3+1], M.Nn[j*3+2]) ? 1 : .2); c.strokeStyle = p.tau; c.lineWidth = isAct('Am') ? 1.6 : 1; c.beginPath(); c.moveTo(cj[0], cj[1]); c.lineTo(ci[0], ci[1]); c.stroke(); }
  c.globalAlpha = 1;
  if (isAct('xc')) for (let j=0;j<N;j++) if (facing(VB, M.Nn[j*3], M.Nn[j*3+1], M.Nn[j*3+2])) { const q = proj(VB, M.C[j*3], M.C[j*3+1], M.C[j*3+2]); c.fillStyle = p.w; c.fillRect(q[0]-1.5, q[1]-1.5, 3, 3); }
  if (isAct('n')) for (let j=0;j<N;j+=Math.max(1, N/60|0)) if (facing(VB, M.Nn[j*3], M.Nn[j*3+1], M.Nn[j*3+2])) { const q = proj(VB, M.C[j*3], M.C[j*3+1], M.C[j*3+2]), e = proj(VB, M.C[j*3]+.3*M.Nn[j*3], M.C[j*3+1]+.3*M.Nn[j*3+1], M.C[j*3+2]+.3*M.Nn[j*3+2]); arrow(c, q[0], q[1], e[0], e[1], p.cs, 1.4); }
  outline(jm, p.eq, isAct('j') ? 3.4 : 2.2); outline(bi, p.f, isAct('i') ? 3.4 : 2.4);
  if (isAct('r') && jm >= 0) { const cj = proj(VB, M.C[jm*3], M.C[jm*3+1], M.C[jm*3+2]); c.strokeStyle = p.w; c.lineWidth = 2.4; c.beginPath(); c.moveTo(cj[0], cj[1]); c.lineTo(ci[0], ci[1]); c.stroke(); }
  label(c, isAct('b') ? 'colour: bᵢ (the leak)' : 'colour: σⱼ (solved)', 12, 18, isAct('b') ? p.c : p.eq, F10);
  triad(c, VB, 26, 220, p);
  // the matrix
  const mx = 262, my = 28, ms = 180;
  label(c, `Aᵢⱼ  ${N} × ${N}`, mx, 18, isAct('Am','N') ? p.tau : p.ink, B11);
  c.imageSmoothingEnabled = false; c.drawImage(heat, mx, my, ms, ms); c.imageSmoothingEnabled = true;
  c.strokeStyle = isAct('Am') ? p.tau : p.rule; c.lineWidth = isAct('Am') ? 2 : 1; c.strokeRect(mx, my, ms, ms);
  const rowY = my + (bi+.5)/N*ms; c.strokeStyle = p.f; c.lineWidth = isAct('i') ? 2.4 : 1.4; c.strokeRect(mx-2, rowY-Math.max(1.5, ms/N/2)-1, ms+4, Math.max(3, ms/N)+2);
  if (jm >= 0) { const colX = mx + (jm+.5)/N*ms; c.strokeStyle = p.eq; c.lineWidth = isAct('j') ? 2.4 : 1.2; c.strokeRect(colX-Math.max(1.5, ms/N/2)-1, my-2, Math.max(3, ms/N)+2, ms+4); }
  if (isAct('delta')) { c.strokeStyle = p.w; c.lineWidth = 2; c.setLineDash([3,3]); c.beginPath(); c.moveTo(mx, my); c.lineTo(mx+ms, my+ms); c.stroke(); c.setLineDash([]); }
  label(c, `row i = ${bi}: A(i,i) = 0.5`, mx, my+ms+16, p.mut, F10);
  label(c, `strongest: A(i,${jm}) = ${jv.toFixed(4)}`, mx, my+ms+30, p.eq, F10);
  // GMRES residual vs iteration, revealed one iteration at a time
  const gx0 = 50, gx1 = 440, gy0 = 262, gy1 = 372, kmax = Math.max(8, S.hist.length-1), X = k => gx0 + k/kmax*(gx1-gx0), Y = r => gy0 + (-Math.log10(Math.max(r, 1e-14)))/14*(gy1-gy0);
  const shown = reduce ? S.hist.length : Math.min(S.hist.length, 1 + Math.floor((bT % 6)/0.45));
  label(c, 'solve: GMRES residual |b − Aσ⁽ᵏ⁾| / |b|', gx0, gy0-12, isAct('res','Ainv') ? p.rho : p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(gx0, gy0); c.lineTo(gx0, gy1); c.lineTo(gx1, gy1); c.stroke();
  [0,-6,-12].forEach(e => label(c, e ? `1e${e}` : '1', gx0-4, Y(10**e)+4, p.mut, F10, 'right'));
  for (let k=0;k<=kmax;k++) label(c, String(k), X(k), gy1+13, isAct('k') ? p.rho : p.mut, F10, 'center');
  c.beginPath(); for (let k=0;k<shown;k++) k ? c.lineTo(X(k), Y(S.hist[k])) : c.moveTo(X(k), Y(S.hist[k])); c.strokeStyle = p.rho; c.lineWidth = isAct('res','Ainv','k') ? 3 : 2; c.stroke();
  for (let k=0;k<shown;k++){ c.fillStyle = p.rho; c.beginPath(); c.arc(X(k), Y(S.hist[k]), 3, 0, 7); c.fill(); }
  label(c, 'k', gx1+8, gy1+4, p.rho, MATH);
  let x = 10; const yb = H-12;
  x = pill(c, x, yb, `${(N*N).toLocaleString('en')} entries`, p.tau);
  x = pill(c, x, yb, `LU ⅔N³ = ${(2/3*N**3/1e6).toFixed(2)} M ops`, p.w);
  pill(c, x, yb, `GMRES ${S.it} it × 2N² = ${(S.it*2*N*N/1e6).toFixed(2)} M`, p.rho);
}

// ---------- C: a wing section, its circulation and the Kutta condition ----------
const JK = (() => { const a = 1, mu = [-0.09, 0.07], R = Math.hypot(a-mu[0], mu[1]), B = Math.atan2(mu[1], a-mu[0]);
  const gk = al => 4*Math.PI*R*Math.sin(al+B);
  let xmin = 9; for (let k=0;k<720;k++){ const t = k/720*2*Math.PI, zr = mu[0]+R*Math.cos(t), zi = mu[1]+R*Math.sin(t), d = zr*zr+zi*zi; xmin = Math.min(xmin, zr + zr/d); }
  return {a, mu, R, B, gk, c: 2*a - xmin, xle: xmin}; })();
// complex helpers
const cmul = (a,b) => [a[0]*b[0]-a[1]*b[1], a[0]*b[1]+a[1]*b[0]], cdiv = (a,b) => { const d = b[0]*b[0]+b[1]*b[1]; return [(a[0]*b[0]+a[1]*b[1])/d, (a[1]*b[0]-a[0]*b[1])/d]; };
const jz = z => { const d = z[0]*z[0]+z[1]*z[1]; return [z[0] + z[0]/d, z[1] - z[1]/d]; };   // Joukowski map z = ζ + 1/ζ
function dF(z, al, G){ // dF/dζ and dz/dζ
  const s = [z[0]-JK.mu[0], z[1]-JK.mu[1]], e = [Math.cos(al), -Math.sin(al)], ei = [Math.cos(al), Math.sin(al)], s2 = cmul(s,s);
  const t = cdiv(cmul([JK.R*JK.R, 0], ei), s2), w = [e[0]-t[0], e[1]-t[1]], g = cdiv([0, G/(2*Math.PI)], s);
  const z2 = cmul(z,z), jp = cdiv([1,0], z2); return [[w[0]+g[0], w[1]+g[1]], [1-jp[0], -jp[1]]]; }
let kAl = 6*Math.PI/180, kFr = 0, kGhost = [], kData = null, kStart = null;
const kPts = [...Array(150)].map(() => [0,0,99]);
function kBuild(){
  const al = kAl, G = kFr*JK.gk(al), R = JK.R, mu = JK.mu, NR = 46, NT = 180, r1 = 6*R;
  // ψ on a polar grid around the circle, mapped to the wing plane; marching squares draws the streamlines
  const grid = [], zp = [];
  for (let k=0;k<NR;k++){ const r = R*Math.exp(k/(NR-1)*Math.log(r1/R)), row = [], zr = [];
    for (let m=0;m<NT;m++){ const t = m/NT*2*Math.PI; row.push((r - R*R/r)*Math.sin(t-al) + G/(2*Math.PI)*Math.log(r/R)); zr.push(jz([mu[0]+r*Math.cos(t), mu[1]+r*Math.sin(t)])); }
    grid.push(row); zp.push(zr); }
  const segs = [];
  for (let L=-2.4;L<=2.41;L+=0.2){ if (Math.abs(L) < 1e-9) continue;
    for (let k=0;k<NR-1;k++) for (let m=0;m<NT;m++){ const m2 = (m+1)%NT, v = [grid[k][m], grid[k][m2], grid[k+1][m2], grid[k+1][m]], P4 = [zp[k][m], zp[k][m2], zp[k+1][m2], zp[k+1][m]], cr = [];
      for (let e=0;e<4;e++){ const a = v[e]-L, b = v[(e+1)%4]-L; if ((a < 0) !== (b < 0)) { const t = a/(a-b), A = P4[e], B2 = P4[(e+1)%4]; cr.push([A[0]+(B2[0]-A[0])*t, A[1]+(B2[1]-A[1])*t]); } }
      if (cr.length >= 2) segs.push([cr[0], cr[1]]); if (cr.length === 4) segs.push([cr[2], cr[3]]); } }
  // surface: speed and Cp, upper and lower, from the trailing edge round the nose
  const surf = []; let ile = 0, xm = 9;
  for (let s=1;s<400;s++){ const t = -JK.B + s/400*2*Math.PI, z = [mu[0]+R*Math.cos(t), mu[1]+R*Math.sin(t)], q = Math.abs(2*Math.sin(t-al) + G/(2*Math.PI*R)) / Math.hypot(...dF(z, al, G)[1]), Z = jz(z);
    surf.push([(Z[0]-JK.xle)/JK.c, Z[1], 1-q*q]); if (Z[0] < xm) { xm = Z[0]; ile = s-1; } }
  const up = surf.slice(0, ile+1), lo = surf.slice(ile);
  // stagnation points on the circle, mapped
  const g = G/(4*Math.PI*R), stg = Math.abs(g) <= 1 ? [al - Math.asin(g), Math.PI + al + Math.asin(g)].map(t => jz([mu[0]+R*Math.cos(t), mu[1]+R*Math.sin(t)])) : [];
  // forces from the Blasius integral on a big circle, where the flow is smooth: X − iY = (iρ/2)∮(dF/dz)² dz
  let I0 = [0,0]; const Mb = 256, rb = 3*R;
  for (let k=0;k<Mb;k++){ const t = (k+.5)/Mb*2*Math.PI, z = [mu[0]+rb*Math.cos(t), mu[1]+rb*Math.sin(t)], [w, jp] = dF(z, al, G), w2 = cmul(w,w), dz = [-rb*Math.sin(t)*2*Math.PI/Mb, rb*Math.cos(t)*2*Math.PI/Mb], f = cmul(cdiv(w2, jp), dz); I0 = [I0[0]+f[0], I0[1]+f[1]]; }
  const XY = cmul([0, .5], I0), Fx = XY[0], Fy = -XY[1], Dr = Fx*Math.cos(al) + Fy*Math.sin(al), Lf = -Fx*Math.sin(al) + Fy*Math.cos(al);
  kData = {segs, up, lo, stg, G, Dr, Lf, al}; }
const kOut = () => { $('kav').textContent = (kAl*180/Math.PI).toFixed(1)+'°'; $('kgv').textContent = `${kFr.toFixed(2)} × Kutta`; };
const kSnap = () => { if (kData) kGhost = [{up: kData.up, lo: kData.lo}, ...kGhost].slice(0,3); };
['ka','kg'].forEach(id => { const el = $(id); el.addEventListener('pointerdown', kSnap); el.addEventListener('keydown', kSnap);
  el.oninput = () => { kAl = +$('ka').value*Math.PI/180; kFr = +$('kg').value; kOut(); kBuild(); if (reduce) drawK(0); }; });
$('kk').onclick = () => { kSnap(); kFr = 1; $('kg').value = 1; kOut(); kBuild(); K.pin('K'); if (reduce) drawK(0); };
kOut(); kBuild();
const CK = hidpi($('kviz')), KS = 72, KOX = 248, KOY = 130;
const KP = z => [KOX + z[0]*KS, KOY - z[1]*KS];
function kSpawn(q){ const y = (Math.random()*2-1)*1.7, x = -3.4, zz = [x, y], d = Math.sqrt; // inverse map: ζ = (z ± √(z² − 4))/2, the root outside the circle
  const w = cmul(zz, zz), sq = (() => { const re = w[0]-4, im = w[1], m = Math.hypot(re, im); return [d((m+re)/2), Math.sign(im||1)*d((m-re)/2)]; })();
  const r1 = [(zz[0]+sq[0])/2, (zz[1]+sq[1])/2], r2 = [(zz[0]-sq[0])/2, (zz[1]-sq[1])/2], out = Math.hypot(r1[0]-JK.mu[0], r1[1]-JK.mu[1]) > Math.hypot(r2[0]-JK.mu[0], r2[1]-JK.mu[1]) ? r1 : r2;
  q[0] = out[0]; q[1] = out[1]; q[2] = 0; }
kPts.forEach(q => { kSpawn(q); const n = Math.floor(Math.random()*260); for (let k=0;k<n;k++) kAdv(q, 1/30); });
function kAdv(q, dt){ // dζ/dt = (dz/dt)/(dz/dζ), with dz/dt = conj(dF/dz) the physical velocity
  const [w, jp] = dF([q[0], q[1]], kData.al, kData.G), fz = cdiv(w, jp), vel = [fz[0], -fz[1]], dzt = cdiv(vel, jp); let sx = dzt[0]*dt*.7, sy = dzt[1]*dt*.7; const L = Math.hypot(sx, sy); if (L > .04) { sx *= .04/L; sy *= .04/L; }
  q[0] += sx; q[1] += sy; q[2] += dt; const rr2 = Math.hypot(q[0]-JK.mu[0], q[1]-JK.mu[1]); if (rr2 < JK.R) { const f = JK.R*1.001/rr2; q[0] = JK.mu[0]+(q[0]-JK.mu[0])*f; q[1] = JK.mu[1]+(q[1]-JK.mu[1])*f; }
  const Z = jz([q[0], q[1]]); if (Z[0] > 3.3 || Math.abs(Z[1]) > 2 || q[2] > 25) kSpawn(q); }
let kLast = null;
function drawK(now){
  const dt = kLast === null ? 0 : Math.min(60, now-kLast)/1000; kLast = now; if (!reduce) kPts.forEach(q => kAdv(q, dt));
  const c = CK, W = c.W, H = c.H, p = P(), d = kData; c.clearRect(0,0,W,H);
  c.save(); c.beginPath(); c.rect(0, 0, W, 248); c.clip();
  c.strokeStyle = p.u; c.globalAlpha = isAct('u','V') ? .8 : .32; c.lineWidth = 1; c.beginPath(); d.segs.forEach(([a,b]) => { const A = KP(a), B2 = KP(b); c.moveTo(A[0], A[1]); c.lineTo(B2[0], B2[1]); }); c.stroke(); c.globalAlpha = 1;
  c.fillStyle = p.u; kPts.forEach(q => { const Z = KP(jz([q[0], q[1]])); c.beginPath(); c.arc(Z[0], Z[1], 1.8, 0, 7); c.fill(); });
  // the section, coloured by Cp
  const all = d.up.concat(d.lo.slice(1));
  for (let k=0;k<all.length-1;k++){ const a = all[k], b = all[k+1]; c.strokeStyle = rgb(cpRGB(p, clamp(a[2], -1.25, 1))); c.lineWidth = isAct('Cp','P','p') ? 6 : 4.5; c.beginPath(); const A = KP([a[0]*JK.c+JK.xle, a[1]]), B2 = KP([b[0]*JK.c+JK.xle, b[1]]); c.moveTo(A[0], A[1]); c.lineTo(B2[0], B2[1]); c.stroke(); }
  c.beginPath(); all.forEach((a,k) => { const A = KP([a[0]*JK.c+JK.xle, a[1]]); k ? c.lineTo(A[0], A[1]) : c.moveTo(A[0], A[1]); }); c.closePath(); c.fillStyle = p.panel; c.fill();
  // trailing edge and stagnation points
  const te = KP([2, 0]), kut = Math.abs(kFr-1) < .01;
  c.strokeStyle = isAct('K') ? p.tau : p.ink; c.lineWidth = 2; c.beginPath(); c.arc(te[0], te[1], 7, 0, 7); c.stroke();
  d.stg.forEach((z,k) => { const Z = KP(z); c.fillStyle = k === 0 ? (kut ? p.ok : p.nu) : p.ink; c.beginPath(); c.arc(Z[0], Z[1], 4.5, 0, 7); c.fill(); });
  // circulation
  if (isAct('Gam','K') || d.G > 0) { c.strokeStyle = p.tau; c.globalAlpha = isAct('Gam','K') ? 1 : .5; c.lineWidth = 1.6; const o = KP([0, .05]); c.beginPath(); c.ellipse(o[0], o[1], 2.55*KS, .62*KS, 0, -2.6, -0.5); c.stroke();
    const e = [o[0]+2.55*KS*Math.cos(-.5), o[1]+.62*KS*Math.sin(-.5)]; arrow(c, e[0]-6, e[1]-5, e[0]+1, e[1]+3, p.tau, 1.6); label(c, `Γ = ${d.G.toFixed(2)}`, o[0]-30, o[1]-.62*KS-8, p.tau, B11); c.globalAlpha = 1; }
  // freestream
  for (let y=-1.2;y<=1.21;y+=.8){ const A = KP([-3.35, y]); arrow(c, A[0], A[1], A[0]+28*Math.cos(d.al), A[1]-28*Math.sin(d.al), isAct('U') ? p.ink : p.c, isAct('U') ? 2.4 : 1.5); }
  c.restore();
  // 3D inset: where the section sits on the wing, and the wake sheet that carries Γ downstream
  { const V = {th: -0.9, ph: 0.55, s: 22, ox: 400, oy: 34}, wing = [[-.5,0,-1.4],[.5,0,-1.4],[.5,0,1.4],[-.5,0,1.4]].map(v => proj(V, ...v));
    c.fillStyle = p.bg; c.globalAlpha = .85; rr(c, 340, 4, 136, 66, 8); c.fill(); c.globalAlpha = 1;
    c.fillStyle = p.panel; c.strokeStyle = p.mut; c.lineWidth = 1; c.beginPath(); wing.forEach((q,k) => k ? c.lineTo(q[0],q[1]) : c.moveTo(q[0],q[1])); c.closePath(); c.fill(); c.stroke();
    c.setLineDash([3,3]); c.strokeStyle = isAct('Gam','K') ? p.tau : p.rule; for (let z=-1.4;z<=1.41;z+=.7){ const a = proj(V, .5, 0, z), b = proj(V, 2.6, -.15, z); c.beginPath(); c.moveTo(a[0], a[1]); c.lineTo(b[0], b[1]); c.stroke(); } c.setLineDash([]);
    const s0 = proj(V, -.6, 0, .4), s1 = proj(V, .6, 0, .4); c.strokeStyle = p.acc; c.lineWidth = 2.4; c.beginPath(); c.moveTo(s0[0], s0[1]); c.lineTo(s1[0], s1[1]); c.stroke();
    label(c, 'section · wake', 346, 64, p.mut, F10); }
  // Cp(x/c), with earlier settings as ghosts
  const px0 = 46, px1 = 466, py0 = 262, py1 = 370, X = v => px0 + v*(px1-px0), Y = v => py0 + (3.2 - clamp(-v, -1.2, 3.2))/4.4*(py1-py0);
  label(c, '−Cₚ along the chord', px0, py0-4, isAct('Cp','P') ? p.nu : p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(px0, py0+6); c.lineTo(px0, py1); c.moveTo(px0, Y(0)); c.lineTo(px1, Y(0)); c.stroke();
  [-1,0,1,2,3].forEach(v => label(c, String(v).replace('-','−'), px0-4, Y(-v)+4, p.mut, F10, 'right'));
  label(c, 'x/c →', (px0+px1)/2, py1+14, p.mut, F10, 'center'); label(c, '0', px0, py1+14, p.mut, F10, 'center'); label(c, '1', px1, py1+14, p.mut, F10, 'center');
  const line = (arr, col, lw, dash, al) => { c.beginPath(); arr.forEach(([x,,cp],k) => k ? c.lineTo(X(x), Y(cp)) : c.moveTo(X(x), Y(cp))); c.strokeStyle = col; c.lineWidth = lw; c.globalAlpha = al; c.setLineDash(dash ? [5,4] : []); c.stroke(); c.setLineDash([]); c.globalAlpha = 1; };
  kGhost.forEach((g,k) => { line(g.up, p.tau, 1.2, false, .5-.13*k); line(g.lo, p.tau, 1.2, true, .5-.13*k); });
  line(d.up, p.nu, isAct('Cp') ? 3 : 2.2, false, 1); line(d.lo, p.nu, isAct('Cp') ? 3 : 2.2, true, 1);
  // readouts
  let x = 8; const yb = H-12, Cl = 2*d.Lf/JK.c;
  x = pill(c, x, yb, `Cl = ${fx(Cl,3)}`, p.cs);
  x = pill(c, x, yb, `drag (Blasius) = ${Math.abs(d.Dr) < 5e-4 ? '0.000' : fx(d.Dr,3)}`, isAct('D') ? p.ink : p.nu);
  pill(c, x, yb, kut ? '✓ leaves the edge smoothly' : '✕ wraps round the edge, |u| → ∞', kut ? p.ok : p.nu);
}

// ---------- BUILD: the real 3D panel method ----------
const SC = hidpi($('sim')), VS = {th: -0.6, ph: 0.35, s: 105, ox: 150, oy: 160}; orbit($('sim'), VS, () => { if (reduce) drawSim(); });
let job = null, running = false, bBody = 'sphere', bSolver = 'lu', bN = 8, errPts = {sphere: [], spheroid: []}, meshPrev = null;
function newJob(){ job = makeJob(bN, bBody, bSolver); VS.s = bBody === 'spheroid' ? 66 : 105; }
function setBtn(on, off){ $(on).classList.add('pri'); $(off).classList.remove('pri'); }
$('n').oninput = () => { bN = +$('n').value; $('nv').textContent = bN; $('bigN').textContent = 6*bN*bN; if (running) newJob(); else { meshPrev = prep(mesh(bN, bBody === 'spheroid' ? 2 : 1)); drawSim(); } };
$('bs').onclick = () => { bBody = 'sphere'; setBtn('bs','be'); running ? newJob() : (meshPrev = prep(mesh(bN, 1)), VS.s = 105, drawSim()); };
$('be').onclick = () => { bBody = 'spheroid'; setBtn('be','bs'); running ? newJob() : (meshPrev = prep(mesh(bN, 2)), VS.s = 66, drawSim()); };
$('slu').onclick = () => { bSolver = 'lu'; setBtn('slu','sgm'); if (running) newJob(); };
$('sgm').onclick = () => { bSolver = 'gmres'; setBtn('sgm','slu'); if (running) newJob(); };
const ms = t => t < 1000 ? `${t.toFixed(0)} ms` : `${(t/1000).toFixed(2)} s`;
let lastLogged = null;
function drawSim(){
  const c = SC, W = c.W, H = c.H, p = P(), J = job, M = J ? J.M : meshPrev;
  c.clearRect(0,0,W,H);
  const grey = hex(p.panel), accS = hex(p.accSoft);
  const colOf = j => !J ? grey : J.phase === 'done' ? cpRGB(p, J.cp[j]) : J.phase === 'velocity' && j < J.row ? cpRGB(p, J.cp[j]) : J.done[j] ? accS : grey;
  drawBody(c, VS, M, colOf, M.N <= 400 ? p.rule : null);
  triad(c, VS, 30, 130, p);
  arrow(c, 14, 70, 54, 70, p.c, 2); label(c, 'U∞', 20, 60, p.c, MATH);
  label(c, `${bBody === 'sphere' ? 'sphere' : 'prolate spheroid 2:1'} · N = ${M.N} panels`, 150, 18, p.ink, SANS, 'center');
  // progress through the phases
  const phases = [['assemble', 'A: assemble'], ['solve', bSolver === 'lu' ? 'A⁻¹: LU' : 'A⁻¹: GMRES'], ['velocity', 'V + P']];
  phases.forEach(([k, n], q) => { const y = 300 + q*16, x0 = 112, w = 140, idx = J ? ['assemble','solve','velocity','done'].indexOf(J.phase) : -1;
    const f = !J ? 0 : idx > q ? 1 : idx === q ? J.frac() : 0;
    label(c, n, x0-6, y+4, idx === q ? p.ink : p.mut, F10, 'right');
    c.fillStyle = p.rule; rr(c, x0, y-4, w, 8, 4); c.fill(); c.fillStyle = idx > q ? p.ok : p.acc; rr(c, x0, y-4, w*f, 8, 4); c.fill();
    if (J && (idx > q || J.phase === 'done')) label(c, ms(J.t[k]), x0+w+6, y+4, p.mut, F10); });
  if (!J) label(c, running ? '' : 'Put the steps in order to run the solver', 150, H-4, p.mut, F10, 'center');
  // Cp against θ: every panel vs the exact answer
  const gx0 = 360, gx1 = 700, gy0 = 30, gy1 = 190, kf = J ? J.kf : (bBody === 'spheroid' ? ellK(2,1,1) : 1.5), X = t => gx0 + t/Math.PI*(gx1-gx0), lo = 1 - kf*kf - .15, Y = v => gy0 + (1.1 - v)/(1.1 - lo)*(gy1-gy0);
  label(c, 'Cₚ against θ (angle of the surface normal from the flow)', gx0, 16, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(gx0, gy0); c.lineTo(gx0, gy1); c.lineTo(gx1, gy1); c.moveTo(gx0, Y(0)); c.lineTo(gx1, Y(0)); c.stroke();
  [1,0,-1].filter(v => v >= lo).forEach(v => label(c, String(v).replace('-','−'), gx0-4, Y(v)+4, p.mut, F10, 'right')); [0,45,90,135,180].forEach(d => label(c, d+'°', X(d*Math.PI/180), gy1+13, p.mut, F10, 'center'));
  if (J && (J.phase === 'velocity' || J.phase === 'done')) { const n = J.phase === 'done' ? J.N : J.row; for (let i=0;i<n;i++){ c.fillStyle = rgb(cpRGB(p, J.cp[i])); c.strokeStyle = p.nu; c.lineWidth = .8; c.beginPath(); c.arc(X(J.th[i]), Y(J.cp[i]), 2.6, 0, 7); c.fill(); c.stroke(); } }
  c.beginPath(); for (let k=0;k<=100;k++){ const t = k/100*Math.PI, v = 1 - kf*kf*Math.sin(t)**2; k ? c.lineTo(X(t), Y(v)) : c.moveTo(X(t), Y(v)); } c.strokeStyle = p.ink; c.lineWidth = 1.6; c.setLineDash([5,4]); c.stroke(); c.setLineDash([]);
  label(c, bBody === 'sphere' ? '┄ exact 1 − (9/4) sin²θ' : `┄ exact 1 − ${(kf*kf).toFixed(3)} sin²θ (Lamb)`, gx0+8, gy1-22, p.ink, F10);
  label(c, '● your panels', gx0+8, gy1-8, p.nu, F10);
  // error against N, log-log, with the measured slope
  const ex0 = 420, ex1 = 700, ey0 = 232, ey1 = 326, Xn = N => ex0 + (Math.log10(N)-1.6)/(3.1-1.6)*(ex1-ex0), Ye = e => ey0 + (-1 - Math.log10(e))/1.6*(ey1-ey0);
  label(c, 'rms Cₚ error vs N', ex0, ey0-8, p.ink, SANS);
  c.strokeStyle = p.rule; c.beginPath(); c.moveTo(ex0, ey0); c.lineTo(ex0, ey1); c.lineTo(ex1, ey1); c.stroke();
  [[0.1,'0.1'],[0.01,'0.01']].forEach(([v,s]) => label(c, s, ex0-4, Ye(v)+4, p.mut, F10, 'right')); [54,216,864].forEach(N => label(c, String(N), Xn(N), ey1+13, p.mut, F10, 'center'));
  const pts = errPts[bBody].slice().sort((a,b) => a[0]-b[0]);
  if (pts.length) { c.beginPath(); pts.forEach(([N,e],k) => k ? c.lineTo(Xn(N), Ye(e)) : c.moveTo(Xn(N), Ye(e))); c.strokeStyle = p.nu; c.lineWidth = 1.6; c.stroke();
    pts.forEach(([N,e]) => { c.fillStyle = J && J.phase === 'done' && N === J.N ? p.ink : p.nu; c.beginPath(); c.arc(Xn(N), Ye(e), 3.5, 0, 7); c.fill(); }); }
  if (pts.length >= 2) { const a = pts[0], b = pts[pts.length-1], sl = Math.log(b[1]/a[1])/Math.log(b[0]/a[0]); label(c, `slope ${sl.toFixed(2)} (error ∝ N^${sl.toFixed(2)})`, ex1, ey0+4, p.nu, F10, 'right'); }
  else label(c, 'run several N to see the trend', ex1, ey0+4, p.mut, F10, 'right');
  if (J && J.phase === 'done') label(c, `error vs exact: rms ${J.rms.toFixed(4)} · max ${J.emax.toFixed(4)}`, 150, 34, p.nu, F10, 'center');
}
function simNote(){ const J = job; if (!J) return; const tot = J.t.assemble+J.t.solve+J.t.velocity;
  $('bnote').textContent = J.phase === 'done' ? `N = ${J.N}: assemble ${ms(J.t.assemble)}, solve ${ms(J.t.solve)}${J.solver === 'gmres' ? ` (${J.it} GMRES iterations)` : ` (⅔N³ = ${(2/3*J.N**3/1e6).toFixed(J.N < 300 ? 2 : 0)} M operations)`}, velocity ${ms(J.t.velocity)}; total ${ms(tot)} spread over frames of ≤ ${J.maxCall.toFixed(1)} ms. Residual ${J.resid.toExponential(1)}; Cp error rms ${J.rms.toFixed(4)}, max ${J.emax.toFixed(4)}. Drag the body to rotate it.`
    : `Working: ${J.phase}… (${(J.frac()*100).toFixed(0)}%), in slices of about 8 ms per frame so the page stays smooth.`; }

// ---------- PARALLEL: who does what, and how it scales ----------
const PV = hidpi($('pviz')), PS = hidpi($('scale'));
let pm = -1, pT = 0, pLast = null;
const RATE = (() => { const n = 160, A = new Float64Array(n*n), b = new Float64Array(n); for (let i=0;i<n*n;i++) A[i] = Math.random() + (i % (n+1) === 0 ? n : 0);
  const t0 = tnow(); for (let k=0;k<n;k++) luCol(A, n, b, k); const t = Math.max(0.3, tnow()-t0); return 2/3*n**3/(t/1000); })();
const COST = [N => ({t: (2/3*N**3 + 20*N*N)/RATE, m: 8*N*N}), N => ({t: (20*N*N + 20*2*N*N)/RATE, m: 8*N*N}), N => ({t: 20*2e4*N/RATE, m: 1e3*N})];
const MNAME = ['Dense LU', 'GMRES, dense matrix', 'GMRES + FMM'];
const tfmt = s => s < 1e-3 ? `${(s*1e6).toFixed(0)} µs` : s < 1 ? `${(s*1e3).toFixed(0)} ms` : s < 120 ? `${s.toFixed(1)} s` : s < 7200 ? `${(s/60).toFixed(0)} min` : s < 172800 ? `${(s/3600).toFixed(1)} h` : s < 3.15e7*2 ? `${(s/86400).toFixed(0)} days` : `${(s/3.15e7).toFixed(0)} years`;
const bfmt = b => b < 1e6 ? `${(b/1e3).toFixed(0)} kB` : b < 1e9 ? `${(b/1e6).toFixed(0)} MB` : b < 1e12 ? `${(b/1e9).toFixed(1)} GB` : `${(b/1e12).toFixed(1)} TB`;
function pN(){ return Math.round(10**+$('pn').value); }
function pUpdate(){ const N = pN(); $('pnv').textContent = N.toLocaleString('en'); const fb = $('pfb');
  if (pm < 0) { fb.className = 'fb'; fb.textContent = 'Pick a method.'; }
  else { const {t, m} = COST[pm](N), fits = m <= 64e9;
    if (!fits) { fb.className = 'fb bad'; fb.textContent = `✕ ${MNAME[pm]} at N = ${N.toLocaleString('en')}: the matrix alone needs ${bfmt(m)}, more than the 64 GB you have${pm === 0 ? `, and ⅔N³ would take ${tfmt(t)}` : ''}.`; }
    else if (N >= 1e5 && pm === 2) { fb.className = 'fb good'; fb.textContent = `✓ GMRES + FMM at N = ${N.toLocaleString('en')}: about ${bfmt(m)} and ${tfmt(t)} on one core. The matrix is never stored; far panels act through multipole expansions. This is how large panel and boundary-element codes run.`; K.done('parallel'); }
    else { fb.className = 'fb'; fb.textContent = `${MNAME[pm]} at N = ${N.toLocaleString('en')}: ${tfmt(t)}, ${bfmt(m)}. ${N < 1e5 ? 'Now push N to the aircraft size, 100 000.' : ''}`; } }
  drawScale(); drawPar(0); }
[['mlu',0],['mgm',1],['mfm',2]].forEach(([id,k]) => $(id).onclick = () => { pm = k; ['mlu','mgm','mfm'].forEach((x,q) => $(x).classList.toggle('pri', q === k)); pT = 0; pUpdate(); });
$('pn').oninput = pUpdate;
function drawScale(){
  const c = PS, W = c.W, H = c.H, p = P(), x0 = 64, x1 = 600, y0 = 20, y1 = 200, X = l => x0 + (l-2)/5*(x1-x0), Y = s => y0 + (9 - Math.log10(Math.max(s, 1e-6)))/15*(y1-y0), N = pN(), cols = [p.w, p.rho, p.ok];
  c.clearRect(0,0,W,H);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x0, y1); c.lineTo(x1, y1); c.stroke();
  [[1e-3,'1 ms'],[1,'1 s'],[60,'1 min'],[86400,'1 day'],[3.15e7,'1 year']].forEach(([s,n]) => { c.setLineDash([2,4]); c.strokeStyle = p.rule; c.beginPath(); c.moveTo(x0, Y(s)); c.lineTo(x1, Y(s)); c.stroke(); c.setLineDash([]); label(c, n, x0-6, Y(s)+4, p.mut, F10, 'right'); });
  for (let l=2;l<=7;l++) label(c, `10${['²','³','⁴','⁵','⁶','⁷'][l-2]}`, X(l), y1+14, p.mut, F10, 'center');
  label(c, 'panels N →', (x0+x1)/2, y1+28, p.mut, F10, 'center'); label(c, 'time for one solve, one core', x0+6, y0-6, p.ink, SANS);
  c.fillStyle = p.nu; c.globalAlpha = .08; c.fillRect(X(Math.log10(Math.sqrt(64e9/8))), y0, x1-X(Math.log10(Math.sqrt(64e9/8))), y1-y0); c.globalAlpha = 1;
  label(c, 'dense matrix > 64 GB', X(Math.log10(Math.sqrt(64e9/8)))+4, y1-6, p.nu, F10);
  COST.forEach((f,k) => { c.beginPath(); for (let l=2;l<=7.001;l+=.05){ const s = f(10**l).t; l > 2 ? c.lineTo(X(l), Y(s)) : c.moveTo(X(l), Y(s)); } c.strokeStyle = cols[k]; c.lineWidth = pm === k ? 3.2 : 1.6; c.globalAlpha = pm < 0 || pm === k ? 1 : .45; c.stroke(); c.globalAlpha = 1;
    label(c, MNAME[k] + ['  ∝ N³','  ∝ N²','  ∝ N'][k], x0+10, y0+16+k*15, cols[k], B11); });
  c.strokeStyle = p.ink; c.lineWidth = 1.2; c.beginPath(); c.moveTo(X(Math.log10(N)), y0); c.lineTo(X(Math.log10(N)), y1); c.stroke();
  if (pm >= 0) { const s = COST[pm](N).t; c.fillStyle = cols[pm]; c.beginPath(); c.arc(X(Math.log10(N)), Y(s), 6, 0, 7); c.fill(); }
  // memory bars
  label(c, 'memory at this N', x0, 248, p.ink, SANS);
  COST.forEach((f,k) => { const m = f(N).m, w = clamp((Math.log10(m)-5)/(13-5), 0, 1)*(x1-x0-200), y = 256 + k*12; c.fillStyle = m > 64e9 ? p.nu : cols[k]; c.globalAlpha = pm < 0 || pm === k ? 1 : .45; rr(c, x0+130, y, Math.max(2, w), 7, 3); c.fill(); c.globalAlpha = 1;
    label(c, MNAME[k], x0+124, y+7, p.mut, F10, 'right'); label(c, bfmt(m), x0+136+w, y+7, p.mut, F10); });
  label(c, `measured here: ${(RATE/1e9).toFixed(2)} G operations/s`, x1, y0-6, p.mut, F10, 'right');
}
function drawPar(now){
  const dt = pLast === null ? 0 : Math.min(100, now-pLast); pLast = now; pT += dt/1000;
  const c = PV, W = c.W, H = c.H, p = P(), cores = [p.f, p.eq, p.c, p.tau]; c.clearRect(0,0,W,H);
  const m = pm < 0 ? 0 : pm, x0 = 30, y0 = 34, s = 150;
  label(c, ['Assembly + dense LU', 'Assembly + dense GMRES', 'GMRES + FMM octree'][m], 12, 20, p.ink, SANS);
  if (m < 2) { // the matrix, rows split over 4 cores
    for (let q=0;q<4;q++){ c.fillStyle = cores[q]; c.globalAlpha = .22; c.fillRect(x0, y0+q*s/4, s, s/4); c.globalAlpha = 1; }
    c.strokeStyle = p.mut; c.lineWidth = 1; c.strokeRect(x0, y0, s, s);
    if (m === 0) { const k = reduce ? .4 : (pT/6) % 1, kk = k*s; c.fillStyle = p.bg; c.globalAlpha = .75; c.fillRect(x0, y0, s, kk); c.fillRect(x0, y0, kk, s); c.globalAlpha = 1;
      c.strokeStyle = p.ink; c.lineWidth = 2; c.strokeRect(x0+kk, y0+kk, s-kk, s-kk); c.fillStyle = p.ink; c.fillRect(x0+kk, y0+kk, s-kk, 3);
      for (let q=0;q<4;q++) arrow(c, x0+s+8, y0+kk+2, x0+s+40, y0+q*s/4+s/8, p.nu, 1.4, true);
      label(c, 'pivot row k →', x0+s+44, y0+kk+4, p.nu, F10); label(c, 'broadcast to all 4 cores, N times', 12, H-26, p.mut, F10); label(c, 'remaining work shrinks like (N−k)²', 12, H-12, p.mut, F10); }
    else { const k = reduce ? 0 : Math.floor(pT*3) % 4; for (let q=0;q<4;q++) label(c, `core ${q}`, x0+s+10, y0+q*s/4+s/8+4, cores[q], F10);
      c.fillStyle = p.rho; for (let i=0;i<12;i++) c.fillRect(x0+s+56, y0+i*s/12+2, 8, s/12-4);
      arrow(c, x0+s+60, y0+s+12, x0+s/2, y0+s+12, p.rho, 1.4); label(c, 'σ⁽ᵏ⁾ sent to every core', 12, H-26, p.mut, F10); label(c, `then a global sum for each dot product (${['·','··','···','····'][k]})`, 12, H-12, p.mut, F10); } }
  else { // octree (drawn as a quadtree slice): near boxes direct, far boxes as one expansion each
    const cx = 110, cy = 120, R = 74, tgt = [cx+R*Math.cos(.6), cy-R*Math.sin(.6)];
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.arc(cx, cy, R, 0, 7); c.stroke();
    const box = (x, y, w, d) => { const inner = !(x+w < cx-R || x > cx+R || y+w < cy-R || y > cy+R), near = Math.abs(x+w/2-tgt[0]) < w*1.5 && Math.abs(y+w/2-tgt[1]) < w*1.5;
      if (!inner) return; if (d < 3 && near) { [[0,0],[1,0],[0,1],[1,1]].forEach(([a,b]) => box(x+a*w/2, y+b*w/2, w/2, d+1)); return; }
      c.strokeStyle = near ? p.eq : p.ok; c.lineWidth = 1; c.strokeRect(x, y, w, w);
      if (!near) { c.fillStyle = p.ok; c.beginPath(); c.arc(x+w/2, y+w/2, 3, 0, 7); c.fill(); c.globalAlpha = .35; c.strokeStyle = p.ok; c.beginPath(); c.moveTo(x+w/2, y+w/2); c.lineTo(tgt[0], tgt[1]); c.stroke(); c.globalAlpha = 1; } };
    box(cx-R-2, cy-R-2, 2*R+4, 0);
    c.fillStyle = p.f; c.beginPath(); c.arc(tgt[0], tgt[1], 5, 0, 7); c.fill();
    label(c, '● target panel', 200, 60, p.f, F10); label(c, '▢ near: direct sum', 200, 76, p.eq, F10); label(c, '● far box: one', 200, 92, p.ok, F10); label(c, '  multipole each', 200, 106, p.ok, F10);
    label(c, 'boxes are split between cores;', 12, H-26, p.mut, F10); label(c, 'only neighbours and the tree talk', 12, H-12, p.mut, F10); }
}
pUpdate();

this.ops = HOW;
function drawLearn(now){ const all = reduce;
  if (all || openB === '0') drawOps(now); if (all || openB === 'A') drawSup(now); if (all || openB === 'B') drawB(now); if (all || openB === 'C') drawK(now); }
drawLearn(0); drawOps(0); drawSup(0); drawB(0); drawK(0);
meshPrev = prep(mesh(bN, 1)); drawSim();
return {
  frame(now, stp){
    if (stp === 0) drawLearn(now);
    if (stp === 1) { if (running && job && job.phase !== 'done') { job.run(7.5); simNote(); if (job.phase === 'done' && lastLogged !== job) { lastLogged = job; const L = errPts[job.body]; const k = L.findIndex(q => q[0] === job.N); if (k >= 0) L[k] = [job.N, job.rms]; else L.push([job.N, job.rms]); simNote(); } }
      if (!reduce && !VS.drag) VS.th += 0.003; drawSim(); }
    if (stp === 2) drawPar(now);
  },
  onBlock(k){ openB = k; },
  onStep(stp){ if (stp === 2) { drawScale(); drawPar(0); } if (stp === 1) drawSim(); },
  buildReset(){ running = false; job = null; meshPrev = prep(mesh(bN, bBody === 'spheroid' ? 2 : 1)); $('bnote').textContent = 'Drag the body to rotate it.'; drawSim(); },
  buildStart(){ running = true; newJob(); if (reduce) { while (job.phase !== 'done') job.run(9); errPts[job.body].push([job.N, job.rms]); simNote(); drawSim(); } }
};
}

CFD.register(SPEC);
})();
