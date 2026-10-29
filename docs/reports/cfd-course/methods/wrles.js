// Wall-resolved LES: the energy cascade and the filter, Smagorinsky and the dynamic procedure, and why resolving the wall is expensive. See ../README.md for the spec.
(() => {
// ---- the Build solver: pseudo-spectral LES in a periodic box [0, 2π)³, sharp spectral filter at k_c = N/3 ----
const now = () => (typeof performance !== 'undefined' ? performance : Date).now();
function mkFFT3(N){ const lg = Math.log2(N)|0, rev = new Int32Array(N), wr = new Float64Array(N/2), wi = new Float64Array(N/2), NN = N*N, T = NN*N;
  for (let i=0;i<N;i++){ let r = 0; for (let b=0;b<lg;b++) r |= ((i>>b)&1) << (lg-1-b); rev[i] = r; }
  for (let i=0;i<N/2;i++){ wr[i] = Math.cos(2*Math.PI*i/N); wi[i] = -Math.sin(2*Math.PI*i/N); }
  function passX(re, im, sg){ for (let o=0;o<T;o+=N){
    for (let i=0;i<N;i++){ const j = rev[i]; if (j > i){ const a = o+i, b = o+j; let t = re[a]; re[a] = re[b]; re[b] = t; t = im[a]; im[a] = im[b]; im[b] = t; } }
    for (let h=1, st=N>>1; h<N; h<<=1, st>>=1) for (let k=0;k<h;k++){ const cr = wr[k*st], ci = sg*wi[k*st];
      for (let P=o+k; P<o+N; P+=2*h){ const Q = P+h, xr = re[Q]*cr-im[Q]*ci, xi = re[Q]*ci+im[Q]*cr; re[Q] = re[P]-xr; im[Q] = im[P]-xi; re[P] += xr; im[P] += xi; } } } }
  // along y or z: butterflies on whole contiguous rows of length s (cache friendly)
  function pass(re, im, s, sg){ const blk = N*s;
    for (let o=0;o<T;o+=blk){
      for (let i=0;i<N;i++){ const j = rev[i]; if (j > i){ const a = o+i*s, b = o+j*s; for (let v=0;v<s;v++){ let t = re[a+v]; re[a+v] = re[b+v]; re[b+v] = t; t = im[a+v]; im[a+v] = im[b+v]; im[b+v] = t; } } }
      for (let h=1, st=N>>1; h<N; h<<=1, st>>=1) for (let k=0;k<h;k++){ const cr = wr[k*st], ci = sg*wi[k*st];
        for (let a=k;a<N;a+=2*h){ const p = o+a*s, q = p+h*s; for (let v=0;v<s;v++){ const P = p+v, Q = q+v, xr = re[Q]*cr-im[Q]*ci, xi = re[Q]*ci+im[Q]*cr; re[Q] = re[P]-xr; im[Q] = im[P]-xi; re[P] += xr; im[P] += xi; } } } } }
  return (re, im, inv) => { const sg = inv ? -1 : 1; passX(re, im, sg); pass(re, im, N, sg); pass(re, im, NN, sg); };
}
const IJ = [[0,0],[1,1],[2,2],[0,1],[0,2],[1,2]];
function mkLES(N, nu){
  const T = N*N*N, fft = mkFFT3(N), kc = Math.floor(N/3), Dl = Math.PI/kc, F = Float64Array, A = () => new F(T);
  const KX = A(), KY = A(), KZ = A(), K2 = A(), neg = new Int32Array(T), shell = new Int16Array(T), KK = [KX, KY, KZ];
  for (let z=0;z<N;z++) for (let y=0;y<N;y++) for (let x=0;x<N;x++){ const k = (z*N+y)*N+x, kx = x<N/2?x:x-N, ky = y<N/2?y:y-N, kz = z<N/2?z:z-N;
    KX[k] = kx; KY[k] = ky; KZ[k] = kz; K2[k] = kx*kx+ky*ky+kz*kz; neg[k] = (((N-z)%N)*N+((N-y)%N))*N+((N-x)%N); shell[k] = Math.round(Math.sqrt(K2[k])); }
  const act = (() => { const l = []; for (let k=0;k<T;k++) if (K2[k] <= kc*kc && K2[k] > 0) l.push(k); return Int32Array.from(l); })();
  const V3 = () => [A(), A(), A()], V6 = () => [A(), A(), A(), A(), A(), A()];
  const S = { N, T, kc, Dl, nu, act, K2, model: 2, Cs: 0.17, Cs2: 0, Cs2raw: 0, alpha: 2, t: 0, dt: 0.1, dtMax: 0.15, step: 0, cfl: 0.75,
    Ur: V3(), Ui: V3(), U0r: V3(), U0i: V3(), Rr: V3(), Ri: V3(), Xr: V3(), Xi: V3(),
    u: V3(), w: V3(), Sf: V6(), G: [...V6(), ...V6()], H: V3(), Hs: V6(), nt: A(),
    wmag: new Float32Array(T), eSgs: 0, eNu: 0, K: 0, dKdt: 0, Ek: new F(N), samp: [], LM: 0, MM: 0, umax: 1 };
  const zr = A(), zi = A(), ar = A(), ai = A(), br = A(), bi = A(), t0r = A(), t0i = A(), t1r = A(), t1i = A();
  // two real fields in one complex FFT: spectra a + i b → physical (re = a, im = b)
  function inv2(Ar, Ai, Br, Bi, oa, ob){ zr.fill(0); zi.fill(0);
    for (let q=0;q<act.length;q++){ const k = act[q]; zr[k] = Ar[k]-(Bi ? Bi[k] : 0); zi[k] = Ai[k]+(Br ? Br[k] : 0); }
    fft(zr, zi, true); oa.set(zr); if (ob) ob.set(zi); }
  // physical a + i b → the two spectra, unpacked by Hermitian symmetry (resolved modes only)
  function fwd2(a, b){ zr.set(a); if (b) zi.set(b); else zi.fill(0); fft(zr, zi, false); const s = 0.5/T;
    for (let q=0;q<act.length;q++){ const k = act[q], m = neg[k], Zr = zr[k], Zi = zi[k], Wr = zr[m], Wi = zi[m];
      ar[k] = (Zr+Wr)*s; ai[k] = (Zi-Wi)*s; br[k] = (Zi+Wi)*s; bi[k] = (Wr-Zr)*s; } }
  // filter two physical fields with a sharp cutoff |k| ≤ k_m (a real, symmetric mask commutes with the pairing)
  function filt2(a, b, km2){ zr.set(a); zi.set(b); fft(zr, zi, false);
    for (let k=0;k<T;k++){ if (K2[k] > km2){ zr[k] = 0; zi[k] = 0; } else { zr[k] /= T; zi[k] /= T; } }
    fft(zr, zi, true); a.set(zr); b.set(zi); }
  // strain rate in Fourier space: Ŝ_ij = i (k_j û_i + k_i û_j) / 2
  function strainSpec(c, Vr, Vi, or, oi, km2){ const [i,j] = IJ[c], ki = KK[i], kj = KK[j]; or.fill(0); oi.fill(0);
    for (let q=0;q<act.length;q++){ const k = act[q]; if (K2[k] > km2) continue; const a = kj[k]*Vr[i][k]+ki[k]*Vr[j][k], b = kj[k]*Vi[i][k]+ki[k]*Vi[j][k]; or[k] = -b*.5; oi[k] = a*.5; } }
  const smag = (Sf, k) => Math.sqrt(2*(Sf[0][k]*Sf[0][k]+Sf[1][k]*Sf[1][k]+Sf[2][k]*Sf[2][k])+4*(Sf[3][k]*Sf[3][k]+Sf[4][k]*Sf[4][k]+Sf[5][k]*Sf[5][k]));
  function* strains(Vr, Vi, km2, out){ for (let c=0;c<6;c+=2){ strainSpec(c, Vr, Vi, t0r, t0i, km2); strainSpec(c+1, Vr, Vi, t1r, t1i, km2); inv2(t0r, t0i, t1r, t1i, out[c], out[c+1]); yield; } }
  // R = P[ ū × ω̄ − ∂_j τ_ij ] − ν k² ū   (rotational form; the projection P removes every gradient, pressure included)
  function* rhs(Vr, Vi, first){
    const [u,v,w] = S.u, [ox,oy,oz] = S.w, Rr = S.Rr, Ri = S.Ri, kc2 = kc*kc;
    inv2(Vr[0], Vi[0], Vr[1], Vi[1], u, v); yield;
    t0r.fill(0); t0i.fill(0); t1r.fill(0); t1i.fill(0); ar.fill(0); ai.fill(0);
    for (let q=0;q<act.length;q++){ const k = act[q];   // ω̂ = i 𝐤 × û
      t0r[k] = -(KY[k]*Vi[2][k]-KZ[k]*Vi[1][k]); t0i[k] = KY[k]*Vr[2][k]-KZ[k]*Vr[1][k];
      t1r[k] = -(KZ[k]*Vi[0][k]-KX[k]*Vi[2][k]); t1i[k] = KZ[k]*Vr[0][k]-KX[k]*Vr[2][k];
      ar[k] = -(KX[k]*Vi[1][k]-KY[k]*Vi[0][k]); ai[k] = KX[k]*Vr[1][k]-KY[k]*Vr[0][k]; }
    inv2(Vr[2], Vi[2], t0r, t0i, w, ox); yield; inv2(t1r, t1i, ar, ai, oy, oz); yield;
    if (first){ let um = 0; for (let k=0;k<T;k++){ S.wmag[k] = Math.sqrt(ox[k]*ox[k]+oy[k]*oy[k]+oz[k]*oz[k]); const q = u[k]*u[k]+v[k]*v[k]+w[k]*w[k]; if (q > um) um = q; } S.umax = Math.sqrt(um); }
    const n0 = S.G[0], n1 = S.G[1], n2 = S.G[2];
    for (let k=0;k<T;k++){ n0[k] = v[k]*oz[k]-w[k]*oy[k]; n1[k] = w[k]*ox[k]-u[k]*oz[k]; n2[k] = u[k]*oy[k]-v[k]*ox[k]; }
    for (let c=0;c<3;c++){ Rr[c].fill(0); Ri[c].fill(0); }
    fwd2(n0, n1); for (let q=0;q<act.length;q++){ const k = act[q]; Rr[0][k] = ar[k]; Ri[0][k] = ai[k]; Rr[1][k] = br[k]; Ri[1][k] = bi[k]; } yield;
    // −∂_j τ_ij in Fourier space: −i k_j τ̂_ij (τ symmetric, so off-diagonal entries feed both rows)
    const addTau = (c, Xr, Xi) => { const [i,j] = IJ[c], kj = KK[j], ki = KK[i], Ra = Rr[i], Ia = Ri[i], Rb = Rr[j], Ib = Ri[j];
      for (let q=0;q<act.length;q++){ const k = act[q]; Ra[k] += kj[k]*Xi[k]; Ia[k] -= kj[k]*Xr[k]; if (i !== j){ Rb[k] += ki[k]*Xi[k]; Ib[k] -= ki[k]*Xr[k]; } } };
    if (S.model > 0){ const C2 = S.model === 1 ? S.Cs*S.Cs : S.Cs2, Sf = S.Sf, G = S.G, cd = C2*Dl*Dl, nt = S.nt;
      yield* strains(Vr, Vi, kc2, Sf);
      let eS = 0;
      for (let k=0;k<T;k++){ const sm = smag(Sf, k), n = cd*sm; nt[k] = n; eS += n*sm*sm; for (let c=0;c<6;c++) G[3+c][k] = -2*n*Sf[c][k]; }
      if (first) S.eSgs = eS/T;
      fwd2(n2, G[3]); for (let q=0;q<act.length;q++){ const k = act[q]; Rr[2][k] += ar[k]; Ri[2][k] += ai[k]; } addTau(0, br, bi); yield;
      for (let c=1;c<6;c+=2){ fwd2(G[3+c], c+1 < 6 ? G[4+c] : null); addTau(c, ar, ai); if (c+1 < 6) addTau(c+1, br, bi); yield; }
    } else { if (first){ S.eSgs = 0; S.nt.fill(0); } fwd2(n2, null); for (let q=0;q<act.length;q++){ const k = act[q]; Rr[2][k] += ar[k]; Ri[2][k] += ai[k]; } yield; }
    for (let q=0;q<act.length;q++){ const k = act[q], k2 = K2[k], kx = KX[k], ky = KY[k], kz = KZ[k];
      for (let c=0;c<3;c++){ Rr[c][k] -= nu*k2*Vr[c][k]; Ri[c][k] -= nu*k2*Vi[c][k]; }
      const dr = (kx*Rr[0][k]+ky*Rr[1][k]+kz*Rr[2][k])/k2, di = (kx*Ri[0][k]+ky*Ri[1][k]+kz*Ri[2][k])/k2;
      Rr[0][k] -= kx*dr; Rr[1][k] -= ky*dr; Rr[2][k] -= kz*dr; Ri[0][k] -= kx*di; Ri[1][k] -= ky*di; Ri[2][k] -= kz*di; }
  }
  // dynamic procedure: Germano identity with a sharp test filter at k_c/α, Lilly's least squares, averaged over the whole box
  function* dyn(){
    const Ur = S.Ur, Ui = S.Ui, kc2 = kc*kc, kt = kc/S.alpha, kt2 = kt*kt, Sf = S.Sf, G = S.G, [u,v,w] = S.u, al2 = S.alpha*S.alpha, U = [u,v,w];
    inv2(Ur[0], Ui[0], Ur[1], Ui[1], u, v); inv2(Ur[2], Ui[2], null, null, w, null); yield;
    yield* strains(Ur, Ui, kc2, Sf);
    const [g0,g1,g2,g3,g4,g5,g6,g7,g8,g9,g10,g11] = G, [s0,s1,s2,s3,s4,s5] = Sf;
    for (let k=0;k<T;k++){ const sm = smag(Sf, k), a = u[k], b = v[k], c = w[k];
      g0[k] = a*a; g1[k] = b*b; g2[k] = c*c; g3[k] = a*b; g4[k] = a*c; g5[k] = b*c;
      g6[k] = sm*s0[k]; g7[k] = sm*s1[k]; g8[k] = sm*s2[k]; g9[k] = sm*s3[k]; g10[k] = sm*s4[k]; g11[k] = sm*s5[k]; }
    yield;
    for (let c=0;c<12;c+=2){ filt2(G[c], G[c+1], kt2); yield; }
    for (let c=0;c<3;c++){ S.Xr[c].set(Ur[c]); S.Xi[c].set(Ui[c]); for (let q=0;q<act.length;q++){ const k = act[q]; if (K2[k] > kt2){ S.Xr[c][k] = 0; S.Xi[c][k] = 0; } } }
    inv2(S.Xr[0], S.Xi[0], S.Xr[1], S.Xi[1], S.H[0], S.H[1]); inv2(S.Xr[2], S.Xi[2], null, null, S.H[2], null); yield;
    yield* strains(S.Xr, S.Xi, kt2, S.Hs);
    let LM = 0, MM = 0; const [h0,h1,h2] = S.H, Hs = S.Hs, [q0,q1,q2,q3,q4,q5] = Hs, D2 = 2*Dl*Dl, samp = [];
    for (let k=0;k<T;k++){ const sh = smag(Hs, k), a = h0[k], b = h1[k], c = h2[k], f = al2*sh;
      let L0 = g0[k]-a*a, L1 = g1[k]-b*b, L2 = g2[k]-c*c; const L3 = g3[k]-a*b, L4 = g4[k]-a*c, L5 = g5[k]-b*c, tr = (L0+L1+L2)/3; L0 -= tr; L1 -= tr; L2 -= tr;
      const M0 = D2*(g6[k]-f*q0[k]), M1 = D2*(g7[k]-f*q1[k]), M2 = D2*(g8[k]-f*q2[k]), M3 = D2*(g9[k]-f*q3[k]), M4 = D2*(g10[k]-f*q4[k]), M5 = D2*(g11[k]-f*q5[k]);
      const lm = L0*M0+L1*M1+L2*M2+2*(L3*M3+L4*M4+L5*M5), mm = M0*M0+M1*M1+M2*M2+2*(M3*M3+M4*M4+M5*M5); LM += lm; MM += mm;
      if (k % 89 === 0) samp.push([M3, L3, M0, L0, lm, mm]); }
    S.LM = LM/T; S.MM = MM/T; S.Cs2raw = MM > 0 ? LM/MM : 0; S.Cs2 = Math.max(0, S.Cs2raw); S.samp = samp; S.dynT = S.t;
  }
  function diag(){ let K = 0, E = 0; S.Ek.fill(0);
    for (let q=0;q<act.length;q++){ const k = act[q]; let e = 0; for (let c=0;c<3;c++) e += S.Ur[c][k]*S.Ur[c][k]+S.Ui[c][k]*S.Ui[c][k]; K += e; E += K2[k]*e; S.Ek[shell[k]] += .5*e; }
    S.K = .5*K; S.eNu = nu*E; }
  function* stepGen(){
    if (S.model === 2 && (S.step % 2 === 0 || S.dynT === undefined)) yield* dyn();
    const dt = S.dt = Math.min(S.dtMax, S.cfl*(2*Math.PI/N)/Math.max(.3, S.umax)), Ur = S.Ur, Ui = S.Ui, U0r = S.U0r, U0i = S.U0i, Rr = S.Rr, Ri = S.Ri;
    for (let c=0;c<3;c++){ U0r[c].set(Ur[c]); U0i[c].set(Ui[c]); }
    // strong-stability-preserving Runge–Kutta 3 (Shu–Osher)
    yield* rhs(Ur, Ui, true);
    for (let c=0;c<3;c++) for (let q=0;q<act.length;q++){ const k = act[q]; Ur[c][k] += dt*Rr[c][k]; Ui[c][k] += dt*Ri[c][k]; }
    yield* rhs(Ur, Ui, false);
    for (let c=0;c<3;c++) for (let q=0;q<act.length;q++){ const k = act[q]; Ur[c][k] = .75*U0r[c][k]+.25*(Ur[c][k]+dt*Rr[c][k]); Ui[c][k] = .75*U0i[c][k]+.25*(Ui[c][k]+dt*Ri[c][k]); }
    yield* rhs(Ur, Ui, false);
    for (let c=0;c<3;c++) for (let q=0;q<act.length;q++){ const k = act[q]; Ur[c][k] = U0r[c][k]/3+2/3*(Ur[c][k]+dt*Rr[c][k]); Ui[c][k] = U0i[c][k]/3+2/3*(Ui[c][k]+dt*Ri[c][k]); }
    const K0 = S.K; S.t += dt; S.step++; diag(); S.dKdt = (K0-S.K)/dt;
  }
  let gen = null, chunkMax = 0;
  // run chunks of work until the budget (ms) is used up; returns the number of finished time steps
  S.advance = (budget, one) => { const t0 = now(); let n = 0; do { const c0 = now(); if (!gen) gen = stepGen(); if (gen.next().done){ gen = null; n++; if (one) break; } chunkMax = Math.max(chunkMax, now()-c0); } while (now()-t0 < budget); return n; };
  S.chunkMax = () => chunkMax;
  S.toSpec = fields => { for (let q=0;q<3;q++){ zr.set(fields[q]); zi.fill(0); fft(zr, zi, false); S.Ur[q].fill(0); S.Ui[q].fill(0); for (let i=0;i<act.length;i++){ const k = act[i]; S.Ur[q][k] = zr[k]/T; S.Ui[q][k] = zi[k]/T; } } };
  S.initTGV = () => { gen = null; S.t = 0; S.step = 0; const [a,b,c] = S.u;
    for (let z=0;z<N;z++) for (let y=0;y<N;y++) for (let x=0;x<N;x++){ const k = (z*N+y)*N+x, X = 2*Math.PI*x/N, Y = 2*Math.PI*y/N, Z = 2*Math.PI*z/N;
      a[k] = Math.sin(X)*Math.cos(Y)*Math.cos(Z); b[k] = -Math.cos(X)*Math.sin(Y)*Math.cos(Z); c[k] = 0; }
    S.toSpec(S.u); S.umax = 1; S.Cs2 = 0; S.Cs2raw = 0; S.eSgs = 0; S.samp = []; diag(); S.dKdt = S.eNu; };
  // random, divergence-free field with E(k) ∝ k⁴ exp(−2 (k/k_p)²), scaled to energy K0: Gaussian, so it has no cascade yet
  S.initRandom = (seed, kp, K0) => { gen = null; S.t = 0; S.step = 0; let s = seed; const rnd = () => (s = (s*16807) % 2147483647) / 2147483647;
    for (let q=0;q<3;q++) for (let k=0;k<T;k++) S.u[q][k] = Math.sqrt(-2*Math.log(rnd()+1e-12))*Math.cos(2*Math.PI*rnd());
    S.toSpec(S.u);
    for (let i=0;i<act.length;i++){ const k = act[i], kk = Math.sqrt(K2[k]), e = kk*Math.exp(-((kk/kp)**2)), k2 = K2[k];
      for (let c=0;c<3;c++){ S.Ur[c][k] *= e; S.Ui[c][k] *= e; }
      const dr = (KX[k]*S.Ur[0][k]+KY[k]*S.Ur[1][k]+KZ[k]*S.Ur[2][k])/k2, di = (KX[k]*S.Ui[0][k]+KY[k]*S.Ui[1][k]+KZ[k]*S.Ui[2][k])/k2;
      for (let c=0;c<3;c++){ S.Ur[c][k] -= KK[c][k]*dr; S.Ui[c][k] -= KK[c][k]*di; } }
    diag(); const f = Math.sqrt(K0/S.K); for (let c=0;c<3;c++) for (let i=0;i<act.length;i++){ S.Ur[c][act[i]] *= f; S.Ui[c][act[i]] *= f; }
    diag(); S.umax = 2; S.Cs2 = 0; S.Cs2raw = 0; S.eSgs = 0; S.samp = []; S.dKdt = S.eNu; };
  // physical velocity and strain of the current state, for pictures between steps
  S.phys = () => { inv2(S.Ur[0], S.Ui[0], S.Ur[1], S.Ui[1], S.u[0], S.u[1]); inv2(S.Ur[2], S.Ui[2], null, null, S.u[2], null); const g = strains(S.Ur, S.Ui, kc*kc, S.Sf); while (!g.next().done); };
  S.dynNow = () => { const g = dyn(); while (!g.next().done); };
  S.smag = smag;
  return S;
}

// ---- MathML helpers: every symbol carries data-t so it lights up with its term ----
const mi = (s, k) => k ? `<mi data-t="${k}">${s}</mi>` : `<mi>${s}</mi>`;
const R_ = (k, x) => `<mrow data-t="${k}">${x}</mrow>`;
const BAR = x => `<mover accent="true">${x}<mo>‾</mo></mover>`, HAT = x => `<mover accent="true">${x}<mo>^</mo></mover>`;
const WBAR = x => `<mover><mrow>${x}</mrow><mo stretchy="true">‾</mo></mover>`, WHAT = x => `<mover><mrow>${x}</mrow><mo stretchy="true">^</mo></mover>`;
const iI = mi('i','i'), jJ = mi('j','j'), tT = mi('t','t'), ij = `<mrow>${iI}${jJ}</mrow>`;
const ub = (s = iI) => `<msub data-t="ub">${BAR('<mi>u</mi>')}${s}</msub>`;
const ubt = (s, sup) => `<msubsup data-t="ub">${BAR('<mi>u</mi>')}${s}${sup}</msubsup>`;
const uu = (s = iI) => `<msub data-t="u"><mi>u</mi>${s}</msub>`, up = (s = iI) => `<msubsup data-t="up"><mi>u</mi>${s}<mo>′</mo></msubsup>`;
const uh = (s = iI) => `<msub data-t="uh">${HAT(BAR('<mi>u</mi>'))}${s}</msub>`;
const Sb = (s = ij) => `<msub data-t="Sij">${BAR('<mi>S</mi>')}${s}</msub>`, Shat = (s = ij) => `<msub data-t="Sh">${HAT(BAR('<mi>S</mi>'))}${s}</msub>`;
const SM = R_('Smag', `<mo>|</mo>${BAR('<mi>S</mi>')}<mo>|</mo>`), SHM = R_('Sh', `<mo>|</mo>${HAT(BAR('<mi>S</mi>'))}<mo>|</mo>`);
const TAU = (s = ij) => `<msub data-t="tau"><mi>τ</mi>${s}</msub>`, TT = (s = ij) => `<msub data-t="Tt"><mi>T</mi>${s}</msub>`;
const LL = `<msub data-t="L"><mi>L</mi>${ij}</msub>`, MM = `<msub data-t="M"><mi>M</mi>${ij}</msub>`;
const NUS = `<msub data-t="nut"><mi>ν</mi><mtext>sgs</mtext></msub>`, CS = `<msub data-t="Cs"><mi>C</mi><mi>s</mi></msub>`, CS2 = `<msubsup data-t="Cs"><mi>C</mi><mi>s</mi><mn>2</mn></msubsup>`;
const DEL = mi('Δ','D'), DH = R_('Dh', HAT('<mi>Δ</mi>')), KC = `<msub data-t="kc"><mi>k</mi><mi>c</mi></msub>`, KK = mi('k','k');
const d_ = s => `<msub data-t="grad"><mo>∂</mo>${s}</msub>`, dtt = `<msub data-t="grad"><mo>∂</mo><mi data-t="t">t</mi></msub>`;
const NU = mi('ν','nu'), PB = R_('p', BAR('<mi>p</mi>')), DELTA = `<msub data-t="delta"><mi>δ</mi>${ij}</msub>`, EPS = mi('ε','eps');
const AVG = x => `<mo data-t="avg">⟨</mo>${x}<mo data-t="avg">⟩</mo>`;
const OPL = (x, k, lbl) => `<munder><munder><mrow>${x}</mrow><mo stretchy="true">⏟</mo></munder><mtext data-t="${k}" class="opl">${lbl}</mtext></munder>`;
const N_ = mi('N','N'), R3N = `<msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo>${N_}<mo>×</mo>${N_}<mo>×</mo>${N_}</mrow></msup>`;
const R3Np = `<msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo><mi>N</mi><mo>×</mo><mi>N</mi><mo>×</mo><mi>N</mi></mrow></msup>`, R6Np = `<msup><mi>ℝ</mi><mrow><mn>6</mn><mo>×</mo><mi>N</mi><mo>×</mo><mi>N</mi><mo>×</mo><mi>N</mi></mrow></msup>`;
const xyz = `<mrow>${mi('x','ix')}${mi('y','iy')}${mi('z','iz')}</mrow>`;
const PLUS = s => `<msup><mrow>${s}</mrow><mo>+</mo></msup>`;
const sp = s => `<mspace width="${s}"/>`;
const frac = (a, b) => `<mfrac>${a}${b}</mfrac>`;
const ROW = (t, sym, rg, txt) => `<div class="ir" data-t="${t}"><span class="is"><math>${sym}</math></span><span class="rg"><math>${rg}</math></span><span class="im">${txt}</span></div>`;
const deep = (n, steps) => `<details class="deep"><summary>Going a bit deeper <span class="note">· ${n} steps</span></summary>${steps.map(([k, m, p]) => `<div class="dstep"><span class="k">${k}</span><div class="dm"><math display="block">${m}</math></div><p>${p}</p></div>`).join('')}</details>`;

// ---- block 0: the objects ----
const B0 = `<div class="eqhero">
  <math display="block"><msubsup data-t="ub">${BAR('<mi>u</mi>')}<mrow>${iI}${mi('x','ix')}${mi('y','iy')}${mi('z','iz')}</mrow>${tT}</msubsup><mo>∈</mo>${R3N}${sp('2em')}${ub()}<mo>=</mo>${mi('G','G')}<mo>⋆</mo>${uu()}<mo>,</mo>${sp('.6em')}${uu()}<mo>=</mo>${ub()}<mo>+</mo>${up()}</math>
  <math display="block" class="sm">${CS2}<mo>=</mo>${OPL(`${mi('𝒟','Dy')}<mo>(</mo>${ubt(iI, tT)}<mo>)</mo>`, 'Dy', '𝒟: dynamic')}${sp('1.4em')}${TAU()}<mo>=</mo>${OPL(`${mi('𝒯','Mo')}<mo>(</mo>${ubt(iI, tT)}<mo>,</mo>${CS2}<mo>)</mo>`, 'Mo', '𝒯: SGS model')}${sp('1.4em')}${ubt(iI, `<mrow>${tT}<mo>+</mo>${R_('dt', '<mi>Δ</mi><mi>t</mi>')}</mrow>`)}<mo>=</mo>${OPL(`${mi('𝒫','P')}<mo>(</mo>${ubt(iI, tT)}<mo>,</mo>${TAU()}<mo>)</mo>`, 'P', '𝒫: step + project')}</math>
</div>
<div class="idx"><span class="eyebrow">Every index</span>
  ${ROW('i', '<mi>i</mi>', '<mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi>', 'Velocity component: ū<sub>i</sub> is ū<sub>x</sub>, ū<sub>y</sub> or ū<sub>z</sub>. A free index: the equation holds for each of the three.')}
  ${ROW('j', '<mi>j</mi>', '<mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi>', 'Summed axis. Repeated in one term → add over x, y, z (Einstein): ∂<sub>j</sub>(ū<sub>i</sub>ū<sub>j</sub>) = ∂<sub>x</sub>(ū<sub>i</sub>ū<sub>x</sub>) + ∂<sub>y</sub>(ū<sub>i</sub>ū<sub>y</sub>) + ∂<sub>z</sub>(ū<sub>i</sub>ū<sub>z</sub>).')}
  ${ROW('ix', '<mi>x</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>N</mi><mo>−</mo><mn>1</mn>', 'Grid point along x (the box is periodic: N wraps to 0).')}
  ${ROW('iy', '<mi>y</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>N</mi><mo>−</mo><mn>1</mn>', 'Grid point along y (at a wall: the wall-normal direction, y⁺ in wall units).')}
  ${ROW('iz', '<mi>z</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>N</mi><mo>−</mo><mn>1</mn>', 'Grid point along z (spanwise at a wall).')}
  ${ROW('k', '<mi>𝐤</mi><mo>,</mo><mi>k</mi>', '<msub><mi>k</mi><mi>j</mi></msub><mo>∈</mo><mo>{</mo><mo>−</mo><mfrac><mi>N</mi><mn>2</mn></mfrac><mo>,</mo><mo>…</mo><mo>,</mo><mfrac><mi>N</mi><mn>2</mn></mfrac><mo>−</mo><mn>1</mn><mo>}</mo>', 'Wavevector of one Fourier mode (how many waves fit in the box along x, y, z); k = |𝐤| is its size. Small k = big eddy.')}
  ${ROW('t', '<mi>t</mi>', '<mn>0</mn><mo>,</mo><mi>Δ</mi><mi>t</mi><mo>,</mo><mn>2</mn><mi>Δ</mi><mi>t</mi><mo>,</mo><mo>…</mo>', 'Time level. As a superscript (ūᵗ) it labels the time; it is not a power.')}
</div>
<div class="dims">
  <div class="dim"><b>Fix i, x, y, z</b><math>${ub(`<mrow>${iI}${xyz}</mrow>`)}<mo>∈</mo><mi>ℝ</mi></math><span>one number: one velocity component at one grid point</span></div>
  <div class="dim"><b>Fix x, y, z</b><math>${ub()}<mo>∈</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>,</mo>${sp('.4em')}${Sb()}<mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo><mn>3</mn></mrow></msup></math><span>one point: a velocity vector, and a symmetric strain matrix (6 numbers)</span></div>
  <div class="dim"><b>Nothing fixed (the state)</b><math>${ub(`<mrow>${iI}${xyz}</mrow>`)}<mo>∈</mo>${R3N}</math><span>a 4-index array; 32³ box in Build → 98 304 numbers</span></div>
  <div class="dim"><b>The stress field</b><math>${TAU(`<mrow>${iI}${jJ}${xyz}</mrow>`)}<mo>∈</mo>${R6Np}</math><span>symmetric in i, j: 6 numbers per point</span></div>
</div>
<span class="eyebrow">What the operators do, along one line of the box</span>
<figure class="viz"><div class="scrollx"><canvas id="wrles-opviz" data-w="880" data-h="350" aria-label="Animated walkthrough on 64 numbers along one line: filter G, test filter, dynamic coefficient, SGS stress, then step and projection"></canvas></div>
  <div class="opctl"><button class="b" id="wrles-opplay">Pause</button><div id="wrles-opsteps" class="btns"></div></div>
  <p class="opcap" id="wrles-opcap"></p></figure>
<aside class="insp" data-terms="G,Gh,Dy,Mo,P,ub,u,up,N"></aside>
${deep(3, [
 ['G', `${ub()}<mo>(</mo><mi data-t="x">𝐱</mi><mo>)</mo><mo>=</mo><mo>∫</mo>${mi('G','G')}<mo>(</mo><mi data-t="x">𝐱</mi><mo>−</mo><msup><mi data-t="x">𝐱</mi><mo>′</mo></msup><mo>)</mo>${uu()}<mo>(</mo><msup><mi data-t="x">𝐱</mi><mo>′</mo></msup><mo>)</mo><msup><mi>d</mi><mn>3</mn></msup><msup><mi data-t="x">𝐱</mi><mo>′</mo></msup>${sp('1em')}<mo>⇔</mo>${sp('1em')}<msub data-t="ub">${BAR('<mi>u</mi>')}<mrow>${iI}<mo>,</mo><mi data-t="k">𝐤</mi></mrow></msub><mo>=</mo><msub data-t="G"><mi>G</mi><mi data-t="k">𝐤</mi></msub><msub data-t="u"><mi>u</mi><mrow>${iI}<mo>,</mo><mi data-t="k">𝐤</mi></mrow></msub>`, 'The filter is a weighted local average (a convolution). In Fourier space a convolution is a plain multiplication, one weight G<sub>𝐤</sub> per mode. The sharp spectral filter uses G<sub>𝐤</sub> = 1 for |𝐤| ≤ k<sub>c</sub> and 0 above: in a spectral code, filtering is just dropping modes.'],
 ['𝒫', `<msub data-t="ub">${BAR('<mi>u</mi>')}<mrow>${iI}<mo>,</mo><mi data-t="k">𝐤</mi></mrow></msub><mo>←</mo><mo>(</mo>${DELTA}<mo>−</mo>${frac(`<msub><mi data-t="k">k</mi>${iI}</msub><msub><mi data-t="k">k</mi>${jJ}</msub>`, `<msup><mi data-t="k">k</mi><mn>2</mn></msup>`)}<mo>)</mo><msub data-t="ub">${BAR('<mi>u</mi>')}<mrow>${jJ}<mo>,</mo><mi data-t="k">𝐤</mi></mrow></msub>`, 'The projection: remove the part of each mode that points along 𝐤. What is removed is exactly the pressure gradient, so ∂<sub>i</sub>ū<sub>i</sub> = 0 holds after every step and no pressure equation is needed in a periodic box.'],
 ['N', `<mtext>work per step</mtext><mo>∝</mo><msup>${N_}<mn>3</mn></msup><mi>log</mi><mo>⁡</mo>${N_}`, 'Each step costs a few dozen 3D FFTs. With N³ unknowns and a time step that shrinks like 1/N, a whole run costs about N⁴: doubling the resolution costs 16× more.']])}`;

// ---- block A: the energy cascade, and what the filter cuts ----
const BA = `<div class="eqhero">
  <math display="block">${R_('E', `<mi>E</mi><mo>(</mo>${KK}<mo>)</mo>`)}<mo>=</mo>${OPL(`<msub data-t="CK"><mi>C</mi><mi>K</mi></msub><msup>${EPS}<mrow><mn>2</mn><mo>/</mo><mn>3</mn></mrow></msup><msup>${KK}<mrow><mo>−</mo><mn>5</mn><mo>/</mo><mn>3</mn></mrow></msup>`, 'E', 'inertial range: 1/L ≪ k ≪ 1/η')}</math>
  <math display="block" class="sm">${ub()}<mo>(</mo><mi data-t="x">𝐱</mi><mo>)</mo><mo>=</mo>${OPL(`<mo>∫</mo>${mi('G','G')}<mo>(</mo><mi data-t="x">𝐱</mi><mo>−</mo><msup><mi data-t="x">𝐱</mi><mo>′</mo></msup><mo>)</mo>${uu()}<mo>(</mo><msup><mi data-t="x">𝐱</mi><mo>′</mo></msup><mo>)</mo><msup><mi>d</mi><mn>3</mn></msup><msup><mi data-t="x">𝐱</mi><mo>′</mo></msup>`, 'G', 'G: keeps eddies larger than Δ')}${sp('1.4em')}${KC}<mo>=</mo>${frac('<mi>π</mi>', DEL)}${sp('1.4em')}${uu()}<mo>=</mo>${ub()}<mo>+</mo>${up()}</math>
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="wrles-specviz" data-w="480" data-h="452" aria-label="A slice of a synthetic turbulent velocity field, its filtered and subgrid parts, and the energy spectrum with the filter cut"></canvas>
    <div class="lg"><span style="color:var(--c-f)"><i class="ln"></i>E(k)</span><span style="color:var(--c-nu)"><i class="ln dash"></i>dissipation 2νk²E</span><span style="color:var(--c-cs)"><i class="ln"></i>cut k<sub>c</sub> = π/Δ</span></div>
    <div class="ctl"><label for="wrles-kc" class="sym" style="color:var(--c-cs)">k<sub>c</sub></label><input type="range" id="wrles-kc" min="0.3" max="3" step="0.01" value="1.78" style="accent-color:var(--c-cs)"><output id="wrles-kcv">60</output></div>
    <div class="note" id="wrles-kccap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="E,k,CK,eps,eta,G,kc,D,ub,up,u,x"></aside>
</div>
${deep(3, [
 ['1', `${R_('E', `<mi>E</mi><mo>(</mo>${KK}<mo>)</mo>`)}<mo>=</mo><mi>f</mi><mo>(</mo>${EPS}<mo>,</mo>${KK}<mo>)</mo>${sp('.8em')}<mo>⇒</mo>${sp('.8em')}<mfrac><msup><mi>m</mi><mn>3</mn></msup><msup><mi>s</mi><mn>2</mn></msup></mfrac><mo>=</mo><msup><mrow><mo>(</mo><mfrac><msup><mi>m</mi><mn>2</mn></msup><msup><mi>s</mi><mn>3</mn></msup></mfrac><mo>)</mo></mrow><mi>a</mi></msup><msup><mi>m</mi><mrow><mo>−</mo><mi>b</mi></mrow></msup>${sp('.6em')}<mo>⇒</mo>${sp('.6em')}<mi>a</mi><mo>=</mo><mfrac><mn>2</mn><mn>3</mn></mfrac><mo>,</mo><mi>b</mi><mo>=</mo><mfrac><mn>5</mn><mn>3</mn></mfrac>`, 'Kolmogorov (1941): far from the big eddies (size L) and the smallest ones (η), an eddy only knows how fast energy passes through it, ε. Matching units fixes the −5/3 law; experiments give C<sub>K</sub> ≈ 1.5.'],
 ['2', `<mi>D</mi><mo>(</mo>${KK}<mo>)</mo><mo>=</mo><mn>2</mn>${NU}<msup>${KK}<mn>2</mn></msup>${R_('E', `<mi>E</mi><mo>(</mo>${KK}<mo>)</mo>`)}<mo>,</mo>${sp('1em')}<msubsup><mo>∫</mo><mn>0</mn><mi>∞</mi></msubsup><mi>D</mi><mo>(</mo>${KK}<mo>)</mo><mi>d</mi>${KK}<mo>=</mo>${EPS}`, 'Energy sits at small k, but viscosity removes it at large k, near the Kolmogorov scale η. A cut in the inertial range keeps most of the energy and almost none of the dissipation: the model must remove energy at k<sub>c</sub> at the rate ε the cascade delivers.'],
 ['3', `<mfrac><mi>L</mi><mi data-t="eta">η</mi></mfrac><mo>∼</mo><msup><mi>Re</mi><mrow><mn>3</mn><mo>/</mo><mn>4</mn></mrow></msup>${sp('.8em')}<mo>⇒</mo>${sp('.8em')}<msub><mi>N</mi><mtext>DNS</mtext></msub><mo>∼</mo><msup><mi>Re</mi><mrow><mn>9</mn><mo>/</mo><mn>4</mn></mrow></msup>`, 'Resolving down to η (DNS) needs ~Re<sup>3/4</sup> points per direction. LES cuts in the inertial range instead (Pope: resolve at least 80% of the energy), so away from walls its cost hardly grows with Re. Near a wall the energetic eddies themselves shrink: block C.']])}`;

// ---- block B: filtered Navier–Stokes and the Smagorinsky model ----
const BBk = `<div class="eqhero">
  <math display="block">${dtt}${ub()}<mo>+</mo>${d_(jJ)}<mo>(</mo>${ub()}${ub(jJ)}<mo>)</mo><mo>=</mo>${OPL(`<mo>−</mo>${d_(iI)}${PB}`, 'P', '𝒫: projection')}<mo>+</mo>${NU}${d_(jJ)}${d_(jJ)}${ub()}${OPL(`<mo>−</mo>${d_(jJ)}${TAU()}`, 'Mo', '𝒯: SGS stress')}<mo>,</mo>${sp('.8em')}${d_(iI)}${ub()}<mo>=</mo><mn>0</mn></math>
  <math display="block" class="sm">${TAU()}<mo>=</mo>${R_('tau', WBAR(`${uu()}${uu(jJ)}`))}<mo>−</mo>${ub()}${ub(jJ)}${sp('1.2em')}${TAU()}<mo>≈</mo><mo>−</mo><mn>2</mn>${OPL(`${NUS}`, 'Mo', '𝒯')}${Sb()}<mo>,</mo>${sp('.6em')}${NUS}<mo>=</mo><msup><mrow><mo>(</mo>${CS}${DEL}<mo>)</mo></mrow><mn>2</mn></msup>${SM}</math>
  <math display="block" class="sm">${Sb()}<mo>=</mo><mfrac><mn>1</mn><mn>2</mn></mfrac><mo>(</mo>${d_(jJ)}${ub()}<mo>+</mo>${d_(iI)}${ub(jJ)}<mo>)</mo><mo>,</mo>${sp('1em')}${SM}<mo>=</mo><msqrt><mn>2</mn>${Sb()}${Sb()}</msqrt>${sp('1em')}${R_('Pi', '<mi>Π</mi>')}<mo>=</mo><mo>−</mo>${TAU()}${Sb()}<mo>=</mo>${NUS}<msup>${SM}<mn>2</mn></msup></math>
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="wrles-smviz" data-w="480" data-h="440" aria-label="A slice of a live 3D turbulent field coloured by the Smagorinsky eddy viscosity, with the strain and stress axes at a moving probe; drag the right picture to rotate"></canvas>
    <div class="lg"><span style="color:var(--c-tau)">■ ν<sub>sgs</sub></span><span style="color:var(--c-c)"><i class="ln"></i>S̄ stretching / squeezing axes</span><span style="color:var(--c-eq)"><i class="ln"></i>τ (opposes S̄)</span><span class="note">drag the 3D glyph</span></div>
    <div class="ctl"><label for="wrles-cs" class="sym" style="color:var(--c-tau)">C<sub>s</sub></label><input type="range" id="wrles-cs" min="0" max="0.3" step="0.005" value="0.17"><output id="wrles-csv">0.170</output></div>
    <div class="note" id="wrles-smcap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="Mo,P,ub,p,nu,tau,nut,Sij,Smag,Cs,D,Pi,grad,i,j,delta"></aside>
</div>
${deep(3, [
 ['1', `${R_('G', WBAR(`${dtt}${uu()}<mo>+</mo>${d_(jJ)}<mo>(</mo>${uu()}${uu(jJ)}<mo>)</mo>`))}<mo>=</mo>${dtt}${ub()}<mo>+</mo>${d_(jJ)}${R_('tau', WBAR(`${uu()}${uu(jJ)}`))}`, 'Filter the Navier–Stokes equations. A uniform filter commutes with derivatives, so every linear term just gets a bar. Only the product does not: the filter of uᵢuⱼ is not ūᵢūⱼ. The difference is τ<sub>ij</sub>, and it needs the unresolved u′: it must be modelled.'],
 ['2', `${R_('Pi', '<mi>Π</mi>')}<mo>=</mo><mo>−</mo>${TAU()}${Sb()}<mo>=</mo><mn>2</mn>${NUS}${Sb()}${Sb()}<mo>=</mo>${NUS}<msup>${SM}<mn>2</mn></msup><mo>≥</mo><mn>0</mn>`, 'Multiply the filtered equation by ūᵢ: τ<sub>ij</sub> takes Π out of the resolved kinetic energy. An eddy viscosity makes Π ≥ 0 everywhere: energy only ever goes down the cascade (no backscatter).'],
 ['3', `${CS}<mo>=</mo>${frac('<mn>1</mn>', '<mi>π</mi>')}<msup><mrow><mo>(</mo>${frac('<mn>2</mn>', `<mn>3</mn><msub data-t="CK"><mi>C</mi><mi>K</mi></msub>`)}<mo>)</mo></mrow><mrow><mn>3</mn><mo>/</mo><mn>4</mn></mrow></msup><mo>≈</mo><mn>0.17</mn>`, 'Lilly (1967): put the cut in the −5/3 range and ask that ⟨Π⟩ equal ε. With C<sub>K</sub> = 1.5 this gives C<sub>s</sub> ≈ 0.17. In channel flow the best value is nearer 0.1, and at a wall it must fall to 0: one constant cannot fit every flow (block C).']])}`;

// ---- block C: the dynamic procedure, and the wall ----
const BC = `<div class="eqhero">
  <math display="block">${LL}<mo>=</mo>${TT()}<mo>−</mo>${R_('tau', WHAT(TAU()))}<mo>=</mo>${OPL(`${R_('Gh', WHAT(`${ub()}${ub(jJ)}`))}<mo>−</mo>${uh()}${uh(jJ)}`, 'Gh', 'Ĝ: test filter at Δ̂ = 2Δ')}</math>
  <math display="block" class="sm">${MM}<mo>=</mo><mn>2</mn><msup>${DEL}<mn>2</mn></msup><mo>(</mo>${R_('Gh', WHAT(`${SM}${Sb()}`))}<mo>−</mo><msup>${mi('α','alpha')}<mn>2</mn></msup>${SHM}${Shat()}<mo>)</mo>${sp('1.2em')}${CS2}<mo>=</mo>${OPL(frac(AVG(`${LL}${MM}`), AVG(`${MM}${MM}`)), 'Dy', '𝒟: least squares (Lilly)')}</math>
  <math display="block" class="sm">${R_('dxp', `${PLUS('<mi>Δ</mi><mi>x</mi>')}<mo>≈</mo><mn>50</mn><mo>,</mo>${sp('.4em')}${PLUS('<mi>Δ</mi><mi>z</mi>')}<mo>≈</mo><mn>15</mn>`)}<mo>,</mo>${sp('.4em')}${R_('yp', `<msubsup><mi>y</mi><mn>1</mn><mo>+</mo></msubsup><mo>≲</mo><mn>1</mn>`)}${sp('1.2em')}${R_('Nwr', '<msub><mi>N</mi><mtext>wr</mtext></msub>')}<mo>∼</mo><msup>${R_('Rex', '<msub><mi>Re</mi><msub><mi>L</mi><mi>x</mi></msub></msub>')}<mrow><mn>13</mn><mo>/</mo><mn>7</mn></mrow></msup></math>
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="wrles-dynviz" data-w="480" data-h="300" aria-label="Live 3D turbulence: Germano's L against Lilly's M at sample points, the least-squares slope C_s squared, and its history as the cascade builds up"></canvas>
    <div class="ctl"><label for="wrles-al" class="sym" style="color:var(--c-cs)">α</label><input type="range" id="wrles-al" min="1.5" max="3" step="0.25" value="2" style="accent-color:var(--c-cs)"><output id="wrles-alv">2.00</output><button class="b" id="wrles-respin">Restart box</button></div>
    <div class="note" id="wrles-dyncap">&nbsp;</div>
    <canvas id="wrles-wallviz" data-w="480" data-h="250" aria-label="A patch of wall seen from above: near-wall streaks and the wall-resolved grid, which gets finer as the Reynolds number grows; grid count against Reynolds number"></canvas>
    <div class="ctl"><label for="wrles-re" class="sym" style="color:var(--c-w)">Re</label><input type="range" id="wrles-re" min="5.5" max="9" step="0.05" value="6.5" style="accent-color:var(--c-w)"><output id="wrles-rev">3×10⁶</output></div>
    <div class="note" id="wrles-wallcap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="Dy,Gh,L,Tt,M,Cs,uh,Dh,alpha,avg,yp,dxp,ut,Rex,Nwr"></aside>
</div>
${deep(3, [
 ['1', `${TAU()}<mo>≈</mo><mo>−</mo><mn>2</mn>${CS2}<msup>${DEL}<mn>2</mn></msup>${SM}${Sb()}<mo>,</mo>${sp('.5em')}${TT()}<mo>≈</mo><mo>−</mo><mn>2</mn>${CS2}<msup>${DH}<mn>2</mn></msup>${SHM}${Shat()}${sp('.8em')}<mo>⇒</mo>${sp('.8em')}${LL}<mo>≈</mo>${CS2}${MM}`, 'Germano et al. (1991): use the same model at the grid level Δ and the test level Δ̂. L<sub>ij</sub> is computable from ū alone, so it tells the model what C<sub>s</sub> must be. Five independent equations, one unknown: Lilly (1992) takes the least-squares fit, then averages over directions in which the flow is statistically the same (the whole box here; wall-parallel planes in a channel), because the local value swings wildly and can turn negative.'],
 ['2', `<mo>−</mo><mover accent="true"><mrow><msup><mi>u</mi><mo>′</mo></msup><msup><mi>v</mi><mo>′</mo></msup></mrow><mo>‾</mo></mover><mo>∝</mo><msup>${R_('yp', '<mi>y</mi>')}<mn>3</mn></msup>${sp('1em')}${NUS}<mo>∝</mo><msup>${R_('yp', '<mi>y</mi>')}<mn>3</mn></msup>${sp('1em')}<mtext>vs</mtext>${sp('1em')}${NUS}<mo>=</mo><msup><mrow><mo>(</mo>${CS}${DEL}<mo>(</mo><mn>1</mn><mo>−</mo><msup><mi>e</mi><mrow><mo>−</mo>${R_('yp', PLUS('<mi>y</mi>'))}<mo>/</mo><mn>26</mn></mrow></msup><mo>)</mo><mo>)</mo></mrow><mn>2</mn></msup>${SM}`, 'At a no-slip wall the fluctuations vanish (u′ ∝ y, v′ ∝ y²), so the stress must fall like y³. Constant Smagorinsky stays finite there and needs an ad hoc Van Driest damping factor (A⁺ = 26). The dynamic model gets L<sub>ij</sub> → 0 by itself: no damping function, and it also switches off in laminar flow.'],
 ['3', `${R_('ut', '<msub><mi>u</mi><mi>τ</mi></msub>')}<mo>=</mo><msqrt><mfrac><msub><mi>τ</mi><mi>w</mi></msub><mi>ρ</mi></mfrac></msqrt><mo>,</mo>${sp('.6em')}${R_('yp', PLUS('<mi>y</mi>'))}<mo>=</mo><mfrac><mrow><mi>y</mi>${R_('ut', '<msub><mi>u</mi><mi>τ</mi></msub>')}</mrow>${NU}</mfrac>${sp('1em')}${R_('Nwr', '<msub><mi>N</mi><mtext>wr</mtext></msub>')}<mo>≈</mo><mn>0.021</mn><mfrac><msub><mi>L</mi><mi>z</mi></msub><msub><mi>L</mi><mi>x</mi></msub></mfrac><mfrac><msub><mi>n</mi><mi>y</mi></msub><mrow>${PLUS('<mi>Δ</mi><mi>x</mi>')}${PLUS('<mi>Δ</mi><mi>z</mi>')}</mrow></mfrac><msup>${R_('Rex', '<msub><mi>Re</mi><msub><mi>L</mi><mi>x</mi></msub></msub>')}<mrow><mn>13</mn><mo>/</mo><mn>7</mn></mrow></msup>`, 'Near the wall the energetic eddies (streaks ~100 ν/u<sub>τ</sub> apart) are measured in wall units ν/u<sub>τ</sub>, which shrink as Re grows. So the grid must be fixed in wall units, and the number of cells on the wall grows almost like Re². Choi & Moin (2012) sum this over a turbulent boundary layer: Re<sup>13/7</sup> for wall-resolved LES, against Re<sup>1</sup> with a wall model and Re<sup>37/14</sup> for DNS.']])}`;

// ---- terms: every symbol, its plain definition, and where it lives ----
const Rp = '<msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', Rnn = '<msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>';
const fieldMap = (a, b, note) => `<mo>:</mo>${a}<mo>→</mo>${b}${note ? `<mo>,</mo><mspace width=".5em"/><mtext>${note}</mtext>` : ''}`;
const TERMS = {
 ub: { sym: BAR('<mi>u</mi>') + '', name: 'Filtered velocity', def: 'The velocity with eddies smaller than Δ removed: what the LES grid stores and solves for. ū<sub>i</sub> is its component i.', space: `<msub><mover accent="true"><mi>u</mi><mo>‾</mo></mover><mrow><mi>i</mi><mi>x</mi><mi>y</mi><mi>z</mi></mrow></msub><mo>∈</mo>${R3Np}`, col: '--c-f' },
 u: { sym: '<msub><mi>u</mi><mi>i</mi></msub>', name: 'True velocity', def: 'The full turbulent velocity, with every eddy down to the Kolmogorov scale η. LES never stores it.', space: '<msub><mi>u</mi><mi>i</mi></msub><mo>:</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>×</mo><mi>ℝ</mi><mo>→</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mspace width=".5em"/><mtext>(a field on space and time)</mtext>', col: '--c-u' },
 up: { sym: '<msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup>', name: 'Subgrid velocity', def: 'What the filter removed: u′ = u − ū. The eddies smaller than Δ. Their effect on ū is the SGS stress τ<sub>ij</sub>.', space: '<msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup><mo>=</mo><msub><mi>u</mi><mi>i</mi></msub><mo>−</mo><msub><mover accent="true"><mi>u</mi><mo>‾</mo></mover><mi>i</mi></msub><mspace width=".5em"/><mtext>(not stored)</mtext>', col: '--c-nu' },
 uh: { sym: `<msub>${HAT(BAR('<mi>u</mi>'))}<mi>i</mi></msub>`, name: 'Test-filtered velocity', def: 'ū filtered once more, at the test width Δ̂ = 2Δ. Computable from the grid: it keeps only the larger half of the resolved eddies.', space: `<msub>${HAT(BAR('<mi>u</mi>'))}<mi>i</mi></msub><mo>∈</mo>${R3Np}`, col: '--c-cs' },
 i: { sym: '<mi>i</mi>', name: 'Component index', def: 'Which velocity component: x, y or z. A free index: the equation holds for each value.', space: '<mi>i</mi><mo>∈</mo><mo>{</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>}</mo>', col: '--ink' },
 j: { sym: '<mi>j</mi>', name: 'Summed axis index', def: 'Appears twice in a term, so it is summed over x, y and z (Einstein convention).', space: '<mi>j</mi><mo>∈</mo><mo>{</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>}</mo>', col: '--ink' },
 ix: { sym: '<mi>x</mi>', name: 'Grid point along x', def: 'Which column of the grid, 0 … N−1 (periodic in the Build box).', space: '<mi>x</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>N</mi><mo>−</mo><mn>1</mn><mo>}</mo>', col: '--ink' },
 iy: { sym: '<mi>y</mi>', name: 'Grid point along y', def: 'Which row, 0 … N−1. Next to a wall this is the wall-normal direction.', space: '<mi>y</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>N</mi><mo>−</mo><mn>1</mn><mo>}</mo>', col: '--ink' },
 iz: { sym: '<mi>z</mi>', name: 'Grid point along z', def: 'Which layer, 0 … N−1 (spanwise next to a wall).', space: '<mi>z</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>N</mi><mo>−</mo><mn>1</mn><mo>}</mo>', col: '--ink' },
 k: { sym: '<mi>k</mi>', name: 'Wavenumber', def: 'Size of a Fourier mode: k = |𝐤|, about 2π / (eddy size). Big eddies have small k.', space: '<mi>𝐤</mi><mo>∈</mo><msup><mi>ℤ</mi><mn>3</mn></msup><mo>,</mo><mspace width=".5em"/><mi>k</mi><mo>=</mo><mo>|</mo><mi>𝐤</mi><mo>|</mo><mo>∈</mo>' + Rnn, col: '--ink' },
 t: { sym: '<mi>t</mi>', name: 'Time level', def: 'Which step: 0, Δt, 2Δt, … As a superscript (ūᵗ) it labels the time, it is not a power.', space: '<mi>t</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mi>Δ</mi><mi>t</mi><mo>,</mo><mn>2</mn><mi>Δ</mi><mi>t</mi><mo>,</mo><mo>…</mo><mo>}</mo>', col: '--c-w' },
 dt: { sym: '<mi>Δ</mi><mi>t</mi>', name: 'Time step', def: 'How far one update moves in time. Explicit stepping needs |ū|Δt below about one cell (the CFL limit).', space: '<mi>Δ</mi><mi>t</mi><mo>∈</mo>' + Rp, col: '--c-w' },
 x: { sym: '<mi>𝐱</mi>', name: 'Position', def: 'A point in the 3D box, 𝐱 = (x, y, z).', space: '<mi>𝐱</mi><mo>∈</mo><msup><mi>ℝ</mi><mn>3</mn></msup>', col: '--ink' },
 N: { sym: '<mi>N</mi>', name: 'Points per direction', def: 'The grid has N × N × N points (32³ in Build). A wall-resolved wing needs ~10⁹–10¹¹ in total.', space: '<mi>N</mi><mo>∈</mo><mi>ℕ</mi>', col: '--ink' },
 G: { sym: '<mi>G</mi>', name: 'Filter', def: 'A local weighted average over a width Δ: keeps eddies larger than Δ, removes smaller ones. Like blurring a photo before shrinking it.', space: `<mi>G</mi>${fieldMap('<mtext>field</mtext>', R3Np, 'linear')}`, col: '--c-cs', op: 'G' },
 Gh: { sym: HAT('<mi>G</mi>'), name: 'Test filter', def: 'The same kind of filter at twice the width, Δ̂ = 2Δ, applied to resolved fields. It lets the model see the cascade between Δ̂ and Δ.', space: `${HAT('<mi>G</mi>')}${fieldMap(R3Np, R3Np, 'linear')}`, col: '--c-cs', op: 'G' },
 Dy: { sym: '<mi>𝒟</mi>', name: 'Dynamic procedure', def: 'Measures C<sub>s</sub>² from the resolved field: test-filter, compute L<sub>ij</sub> and M<sub>ij</sub>, fit L ≈ C<sub>s</sub>²M by least squares over the box. Like calibrating a scale with known weights.', space: `<mi>𝒟</mi>${fieldMap(R3Np, Rnn, 'nonlinear, one number')}`, col: '--c-rho', op: 'Dy' },
 Mo: { sym: '<mi>𝒯</mi>', name: 'SGS stress model', def: 'Turns the resolved strain into the stress of the missing eddies: τ = −2(C<sub>s</sub>Δ)²|S̄|S̄. Works like extra, local viscosity.', space: `<mi>𝒯</mi>${fieldMap(`${R3Np}<mo>×</mo><mi>ℝ</mi>`, R6Np, 'nonlinear, pointwise')}`, col: '--c-tau', op: 'Mo' },
 P: { sym: '<mi>𝒫</mi>', name: 'Step and projection', def: 'Adds Δt × (advection + viscosity − ∂<sub>j</sub>τ<sub>ij</sub>), then removes whatever would compress the fluid. The removed part is the pressure gradient.', space: `<mi>𝒫</mi>${fieldMap(`${R3Np}<mo>×</mo>${R6Np}`, R3Np, 'one Runge–Kutta step')}`, col: '--c-u', op: 'P' },
 E: { sym: '<mi>E</mi><mo>(</mo><mi>k</mi><mo>)</mo>', name: 'Energy spectrum', def: 'How the kinetic energy is shared among eddy sizes: ∫E(k)dk = ½⟨u<sub>i</sub>u<sub>i</sub>⟩.', space: '<mi>E</mi><mo>:</mo>' + Rnn + '<mo>→</mo>' + Rnn, col: '--c-f' },
 CK: { sym: '<msub><mi>C</mi><mi>K</mi></msub>', name: 'Kolmogorov constant', def: 'The number in front of the −5/3 law. Measured ≈ 1.5 (Pope 2000).', space: '<msub><mi>C</mi><mi>K</mi></msub><mo>≈</mo><mn>1.5</mn><mo>∈</mo>' + Rp, col: '--c-w' },
 eps: { sym: '<mi>ε</mi>', name: 'Dissipation rate', def: 'Energy per unit mass and time passed down the cascade and finally turned into heat (m²/s³).', space: '<mi>ε</mi><mo>∈</mo>' + Rp, col: '--c-nu' },
 eta: { sym: '<mi>η</mi>', name: 'Kolmogorov scale', def: 'Size of the smallest eddies, η = (ν³/ε)<sup>1/4</sup>, where viscosity wins. DNS must resolve it, LES does not.', space: '<mi>η</mi><mo>∈</mo>' + Rp, col: '--c-w' },
 kc: { sym: '<msub><mi>k</mi><mi>c</mi></msub>', name: 'Cutoff wavenumber', def: 'The largest wavenumber kept: k<sub>c</sub> = π/Δ. Everything above it is subgrid.', space: '<msub><mi>k</mi><mi>c</mi></msub><mo>=</mo><mfrac><mi>π</mi><mi>Δ</mi></mfrac><mo>∈</mo>' + Rp, col: '--c-cs' },
 D: { sym: '<mi>Δ</mi>', name: 'Filter width', def: 'The size of the smallest resolved eddy, tied to the grid spacing (here Δ = π/k<sub>c</sub> = 1.5 cells).', space: '<mi>Δ</mi><mo>∈</mo>' + Rp, col: '--c-cs' },
 Dh: { sym: HAT('<mi>Δ</mi>'), name: 'Test filter width', def: 'Width of the test filter, usually Δ̂ = 2Δ.', space: `${HAT('<mi>Δ</mi>')}<mo>=</mo><mi>α</mi><mi>Δ</mi><mo>∈</mo>${Rp}`, col: '--c-cs' },
 alpha: { sym: '<mi>α</mi>', name: 'Filter ratio', def: 'Test width over grid width, Δ̂/Δ. Germano et al. used 2; results depend only weakly on it.', space: '<mi>α</mi><mo>=</mo><mfrac><mover accent="true"><mi>Δ</mi><mo>^</mo></mover><mi>Δ</mi></mfrac><mo>∈</mo><mo>(</mo><mn>1</mn><mo>,</mo><mi>∞</mi><mo>)</mo>', col: '--c-cs' },
 Sij: { sym: `<msub>${BAR('<mi>S</mi>')}<mrow><mi>i</mi><mi>j</mi></mrow></msub>`, name: 'Resolved strain rate', def: 'How fast the resolved flow stretches or squeezes a fluid blob, ½(∂<sub>j</sub>ū<sub>i</sub> + ∂<sub>i</sub>ū<sub>j</sub>). Rotation does not count.', space: `<msub>${BAR('<mi>S</mi>')}<mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo><mn>3</mn></mrow></msup><mspace width=".4em"/><mtext>symmetric, trace 0 (per point)</mtext>`, col: '--c-c' },
 Smag: { sym: `<mo>|</mo>${BAR('<mi>S</mi>')}<mo>|</mo>`, name: 'Strain magnitude', def: 'One number for how hard the flow is being strained: √(2S̄<sub>ij</sub>S̄<sub>ij</sub>), in 1/s.', space: `<mo>|</mo>${BAR('<mi>S</mi>')}<mo>|</mo><mo>∈</mo>${Rnn}<mspace width=".4em"/><mtext>(per point)</mtext>`, col: '--c-c' },
 Sh: { sym: `<msub>${HAT(BAR('<mi>S</mi>'))}<mrow><mi>i</mi><mi>j</mi></mrow></msub>`, name: 'Test-level strain rate', def: 'The strain rate of the test-filtered velocity ū̂, and |Ŝ| its magnitude.', space: `<msub>${HAT(BAR('<mi>S</mi>'))}<mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo><mn>3</mn></mrow></msup>`, col: '--c-cs' },
 tau: { sym: '<msub><mi>τ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Subgrid-scale stress', def: 'The momentum the missing eddies carry: the filter of uᵢuⱼ minus ūᵢūⱼ. Unknown on the grid, so it is modelled.', space: `<msub><mi>τ</mi><mrow><mi>i</mi><mi>j</mi><mi>x</mi><mi>y</mi><mi>z</mi></mrow></msub><mo>∈</mo>${R6Np}`, col: '--c-eq', op: 'Mo' },
 Tt: { sym: '<msub><mi>T</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Test-level stress', def: 'The subgrid stress you would have with the coarser filter Ĝ∘G: the eddies smaller than Δ̂.', space: `<msub><mi>T</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo>${R6Np}`, col: '--c-eq' },
 L: { sym: '<msub><mi>L</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Resolved (Leonard) stress', def: 'The stress carried by eddies between Δ and Δ̂. Computable from ū alone: Germano\'s identity says it is T − τ̂.', space: `<msub><mi>L</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo>${R6Np}`, col: '--c-eq', op: 'Dy' },
 M: { sym: '<msub><mi>M</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Model difference', def: 'What the Smagorinsky model predicts for L if C<sub>s</sub> = 1. Then L ≈ C<sub>s</sub>²M fixes C<sub>s</sub>.', space: `<msub><mi>M</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo>${R6Np}`, col: '--c-rho', op: 'Dy' },
 avg: { sym: '<mo>⟨</mo><mo>·</mo><mo>⟩</mo>', name: 'Average', def: 'Mean over directions where the flow is statistically the same: the whole box here, wall-parallel planes in a channel.', space: `<mo>⟨</mo><mo>·</mo><mo>⟩</mo>${fieldMap('<msup><mi>ℝ</mi><mrow><mi>N</mi><mo>×</mo><mi>N</mi><mo>×</mo><mi>N</mi></mrow></msup>', '<mi>ℝ</mi>', 'linear')}`, col: '--ink' },
 nut: { sym: '<msub><mi>ν</mi><mtext>sgs</mtext></msub>', name: 'Eddy viscosity', def: 'Extra viscosity standing in for the missing eddies, (C<sub>s</sub>Δ)²|S̄|: large where the flow is strongly strained, zero in uniform flow.', space: `<msub><mi>ν</mi><mtext>sgs</mtext></msub><mo>∈</mo>${Rnn}<mspace width=".4em"/><mtext>(a field)</mtext>`, col: '--c-tau', op: 'Mo' },
 Cs: { sym: '<msub><mi>C</mi><mi>s</mi></msub>', name: 'Smagorinsky coefficient', def: 'Sets the model\'s strength. Lilly: ≈ 0.17 in isotropic turbulence; ≈ 0.1 in channels; 0 at a wall and in laminar flow.', space: '<msub><mi>C</mi><mi>s</mi></msub><mo>∈</mo>' + Rnn, col: '--c-tau' },
 nu: { sym: '<mi>ν</mi>', name: 'Kinematic viscosity', def: 'The fluid\'s own viscosity (m²/s). In the Build box ν = 1/1600, i.e. Re = 1600.', space: '<mi>ν</mi><mo>∈</mo>' + Rp, col: '--c-w' },
 p: { sym: BAR('<mi>p</mi>'), name: 'Filtered pressure', def: 'Pressure divided by density, filtered. It is whatever keeps ∂<sub>i</sub>ū<sub>i</sub> = 0; the projection supplies it.', space: `${BAR('<mi>p</mi>')}<mo>∈</mo><msup><mi>ℝ</mi><mrow><mi>N</mi><mo>×</mo><mi>N</mi><mo>×</mo><mi>N</mi></mrow></msup>`, col: '--c-rho' },
 Pi: { sym: '<mi>Π</mi>', name: 'SGS dissipation', def: 'Energy per second the model takes from the resolved eddies and hands to the missing ones. With an eddy viscosity it is never negative.', space: `<mi>Π</mi><mo>=</mo><mo>−</mo><msub><mi>τ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><msub>${BAR('<mi>S</mi>')}<mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo>${Rnn}`, col: '--c-nu' },
 grad: { sym: '<msub><mo>∂</mo><mi>j</mi></msub>', name: 'Partial derivative', def: 'Rate of change along axis j; ∂ₜ in time. In Fourier space ∂<sub>j</sub> is multiplication by i k<sub>j</sub>.', space: '<msub><mo>∂</mo><mi>j</mi></msub><mo>:</mo><mtext>field → field (linear)</mtext>', col: '--ink' },
 delta: { sym: '<msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Kronecker delta', def: '1 if i = j, else 0: the 3 × 3 identity matrix in index form.', space: '<msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo><mn>3</mn></mrow></msup>', col: '--c-w' },
 yp: { sym: '<msup><mi>y</mi><mo>+</mo></msup>', name: 'Wall distance in wall units', def: 'y u<sub>τ</sub>/ν. The viscous sublayer is y⁺ ≲ 5; the first cell must sit at y⁺ ≲ 1.', space: '<msup><mi>y</mi><mo>+</mo></msup><mo>∈</mo>' + Rnn, col: '--c-cs' },
 dxp: { sym: '<msup><mrow><mi>Δ</mi><mi>x</mi></mrow><mo>+</mo></msup><mo>,</mo><msup><mrow><mi>Δ</mi><mi>z</mi></mrow><mo>+</mo></msup>', name: 'Wall-resolved spacing', def: 'Cell size along and across the flow in wall units. ≈ 50 and ≈ 15 resolve the near-wall streaks (≈ 100 wall units apart).', space: '<msup><mrow><mi>Δ</mi><mi>x</mi></mrow><mo>+</mo></msup><mo>,</mo><msup><mrow><mi>Δ</mi><mi>z</mi></mrow><mo>+</mo></msup><mo>∈</mo>' + Rp, col: '--c-cs' },
 ut: { sym: '<msub><mi>u</mi><mi>τ</mi></msub>', name: 'Friction velocity', def: '√(wall shear stress / density). It sets the wall unit ν/u<sub>τ</sub>, which shrinks as Re grows.', space: '<msub><mi>u</mi><mi>τ</mi></msub><mo>∈</mo>' + Rp, col: '--c-u' },
 Rex: { sym: '<msub><mi>Re</mi><msub><mi>L</mi><mi>x</mi></msub></msub>', name: 'Reynolds number of the plate', def: 'U L<sub>x</sub>/ν for a surface of length L<sub>x</sub>. A car ~10⁶–10⁷, an airliner wing ~10⁷–10⁸.', space: '<msub><mi>Re</mi><msub><mi>L</mi><mi>x</mi></msub></msub><mo>∈</mo>' + Rp, col: '--c-w' },
 Nwr: { sym: '<msub><mi>N</mi><mtext>wr</mtext></msub>', name: 'Wall-resolved grid count', def: 'Grid points a wall-resolved LES of a boundary layer needs (Choi & Moin 2012). Grows like Re<sup>13/7</sup>.', space: '<msub><mi>N</mi><mtext>wr</mtext></msub><mo>∈</mo><mi>ℕ</mi>', col: '--ink' },
};

const CHECKS = {
 '0': [
  ['At one grid point, what is ūᵢ (with i free)?', ['One number', 'A vector in ℝ³', 'A 3 × 3 matrix'], 1, 'Fixing x, y, z leaves i free: three numbers ūx, ūy, ūz, a vector in ℝ³.'],
  ['Which operator turns the whole velocity field into a single number?', ['The filter G', 'The dynamic procedure 𝒟', 'The projection 𝒫'], 1, '𝒟 fits one coefficient C_s² to the whole box (a least-squares average), so its output lives in ℝ.'],
  ['The Build box is 32³ points. How many numbers is its state?', ['32 768', '98 304', '196 608'], 1, '3 velocity components × 32³ points = 98 304. The stress τ_ij is recomputed each step, not stored.'],
  ['What does the projection 𝒫 remove from each step?', ['The subgrid stress', 'The part of the velocity that would compress the fluid: the pressure gradient', 'The smallest resolved eddies'], 1, 'Incompressible flow needs ∂_iū_i = 0; removing the part of each mode along 𝐤 enforces it, and that removed part is −∂_ip̄.'],
  ['What would happen if you skipped the model 𝒯 on a coarse grid?', ['Energy cascading to k_c has nowhere to go and piles up at the smallest resolved scales', 'The flow becomes laminar', 'The pressure becomes negative'], 0, 'The grid cannot hold the eddies that would dissipate it; without a drain the energy bunches up at k_c (you will see it in Build).']],
 A: [
  ['In the inertial range, how does E(k) fall off?', ['k⁻¹', 'k⁻⁵ᐟ³', 'k⁻³'], 1, 'Kolmogorov 1941: E = C_K ε^(2/3) k^(−5/3), with C_K ≈ 1.5.'],
  ['The filter width is Δ. Which wavenumbers survive a sharp filter?', ['k ≤ π/Δ', 'k ≥ π/Δ', 'All, with smaller weight'], 0, 'k_c = π/Δ: a wave of length 2Δ is the shortest the filter keeps.'],
  ['You put the cut in the middle of the inertial range. Roughly what is resolved?', ['Most of the energy, little of the dissipation', 'Most of the dissipation, little of the energy', 'Both, about equally'], 0, 'Energy sits in the big eddies, dissipation in the smallest. That is why the model must supply the dissipation.'],
  ['What happens to the spectrum picture if you double Δ?', ['k_c halves: the cut moves to larger eddies and more energy becomes subgrid', 'k_c doubles', 'Nothing: Δ is only a label'], 0, 'k_c = π/Δ. A coarser grid cuts off more of the cascade, and the model has to do more.'],
  ['Why can LES cost almost nothing more at higher Re away from walls?', ['The big, energy-carrying eddies do not shrink with Re; only η does, and LES does not resolve η', 'Viscosity is ignored', 'The time step grows with Re'], 0, 'The cut stays in the inertial range at a fixed fraction of the big eddies. DNS, which must reach η, grows like Re^(9/4).']],
 B: [
  ['Why does filtering Navier–Stokes leave an unknown term?', ['Derivatives do not commute with the filter', 'The filter of a product is not the product of the filters', 'Pressure disappears'], 1, 'The filter of u_iu_j ≠ ū_iū_j; the difference τ_ij needs u′.'],
  ['A region of the flow rotates as a solid body. What is ν_sgs there?', ['Large', 'Zero', 'Negative'], 1, 'Solid rotation has no strain: S̄_ij = 0, so |S̄| = 0 and ν_sgs = 0.'],
  ['With an eddy-viscosity model, Π = ν_sgs|S̄|² is…', ['always ≥ 0: energy only goes to smaller scales', 'sometimes negative', 'always zero on average'], 0, 'ν_sgs ≥ 0 and |S̄|² ≥ 0. Real turbulence also has some backscatter, which this model cannot represent.'],
  ['You double C_s. What happens to ν_sgs?', ['Doubles', 'Four times larger', 'Halves'], 1, 'ν_sgs = (C_sΔ)²|S̄|: quadratic in C_s.'],
  ['Where does C_s ≈ 0.17 come from?', ['A fit to wind-tunnel data of wings', 'Matching the model dissipation to ε for a −5/3 spectrum (Lilly)', 'Stability of the time step'], 1, 'Lilly (1967): with C_K ≈ 1.5, ⟨Π⟩ = ε gives C_s = (2/(3C_K))^(3/4)/π ≈ 0.17.']],
 C: [
  ['What does the Germano identity relate?', ['The stresses at the two filter levels: L = T − τ̂', 'The pressure to the velocity', 'The grid to the time step'], 0, 'L_ij, computable from ū, equals the difference of the test-level and (test-filtered) grid-level stresses.'],
  ['The box starts as a random field with no cascade. What does the dynamic C_s² do?', ['Starts near 0 and climbs as the nonlinear cascade builds up', 'Starts at 0.17² and stays', 'Becomes negative and stays'], 0, 'L_ij measures energy actually flowing between Δ̂ and Δ. With no cascade there is no flow, so the model switches itself off (watch the history plot).'],
  ['Why average L_ijM_ij over the box instead of using each point?', ['Pointwise values swing widely and go negative, which makes the simulation unstable', 'To save memory', 'Because M is zero at most points'], 0, 'Germano\'s local values give negative viscosity in places; Lilly\'s least squares plus averaging over homogeneous directions keeps it stable.'],
  ['Why is wall-resolved LES expensive at high Re?', ['The near-wall eddies have a fixed size in wall units, and wall units shrink as Re grows', 'The model needs more test filters', 'The time step grows'], 0, 'Streaks are ≈ 100 ν/u_τ apart. Higher Re → smaller ν/u_τ → more cells on every square metre of wall; Choi & Moin: N ~ Re^(13/7).'],
  ['Multiply Re by 10. Roughly how many more grid points does wall-resolved LES need?', ['≈ 10×', '≈ 72×', '≈ 437×'], 1, '10^(13/7) ≈ 72. A wall model needs ≈ 10×, DNS ≈ 10^(37/14) ≈ 437×.']]
};

const QUIZ = [
 ['What exactly does an LES grid resolve?', ['Every eddy down to η', 'The eddies larger than the filter width Δ; smaller ones are modelled', 'Only the time-averaged flow'], 1, 'LES solves for ū; the subgrid eddies enter only through τ_ij. RANS averages all eddies, DNS resolves all.'],
 ['Your LES spectrum turns up at the highest wavenumbers instead of falling. The most likely cause?', ['Too much model dissipation', 'Too little: energy reaches k_c faster than the model removes it', 'The time step is too small'], 1, 'Pile-up at k_c is the signature of too little SGS dissipation (or none).'],
 ['Constant Smagorinsky on the Taylor–Green vortex: what goes wrong early, while the flow is still laminar?', ['Nothing, it switches off', 'It still dissipates, because |S̄| is large even in smooth flow', 'It adds energy'], 1, 'ν_sgs depends only on |S̄|, not on whether there is a cascade. The dynamic model measures the cascade and stays near 0 (compare them in Build).'],
 ['What does the dynamic procedure need that constant Smagorinsky does not?', ['A second, coarser test filter applied to the resolved field', 'Wind-tunnel data', 'A wall model'], 0, 'L_ij and M_ij come from test-filtering ū at Δ̂ = 2Δ; C_s² then follows from least squares.'],
 ['Why does a wall-resolved grid need a first cell at y⁺ ≲ 1?', ['To resolve the viscous sublayer, where the velocity gradient sets the wall shear stress', 'For the CFL condition', 'Because the filter needs it'], 0, 'Skin friction is ν ∂u/∂y at the wall; with no wall model the sublayer (y⁺ ≲ 5) must be resolved.'],
 ['A pseudo-spectral LES runs on 100 000 cores. What limits its scaling?', ['The pointwise SGS model', 'The all-to-all transposes of the 3D FFTs', 'Reading the input'], 1, 'Every 3D FFT reshuffles the whole field among ranks; the model and products are local.'],
 ['Which statement about LES costs is right?', ['Away from walls cost barely grows with Re; near walls it grows like Re^(13/7)', 'LES always costs Re^(9/4) like DNS', 'LES cost does not depend on Re at all'], 0, 'The outer flow is cheap; the near-wall eddies shrink with Re. That is the motivation for wall-modelled LES.']
];

const BUILD = {
 intro: 'Put the steps of one LES update in order. When it is right, your 3D solver runs below: the Taylor–Green vortex at Re = 1600 on 32³ points (pseudo-spectral, sharp filter at k<sub>c</sub> = 10). Switch the model and watch the spectrum tail and the dissipation.',
 html: `<div class="scrollx"><canvas class="sim" id="wrles-sim" data-w="760" data-h="400" aria-label="Your 3D LES: vortical structures of the Taylor–Green vortex, live energy spectrum against k to the minus five thirds, and dissipation against time; drag the cube to rotate"></canvas></div>
  <div class="row"><span class="note">Model:</span><div class="btns" id="wrles-models"><button class="b" data-m="0">No model</button><button class="b" data-m="1">Smagorinsky</button><button class="b pri" data-m="2">Dynamic</button></div><button class="b" id="wrles-restart">Restart</button><button class="b" id="wrles-pause">Pause</button><button class="b" id="wrles-plus">+1 time unit</button></div>
  <div class="row"><label for="wrles-bcs">C<sub>s</sub> = <span id="wrles-bcsv">0.17</span></label><input type="range" id="wrles-bcs" min="0.05" max="0.3" step="0.01" value="0.17"><span class="note" id="wrles-bnote"></span></div>
  <div class="note" id="wrles-bstat">&nbsp;</div>`,
 steps: ['Strain rate S̄ᵢⱼ and |S̄| from ū', 'Test-filter at 2Δ, fit C_s² from Lᵢⱼ and Mᵢⱼ', 'SGS stress τᵢⱼ = −2(C_sΔ)²|S̄|S̄ᵢⱼ', 'Advection, viscosity and −∂ⱼτᵢⱼ', 'Project out the pressure gradient', 'Advance in time, keep only |k| ≤ k_c'],
 hint: 'The model needs the strain first; C_s² must be known before τ; the projection acts on the full right-hand side, before the state is updated.',
 success: 'Your LES is running. Drag the cube; dots are points of strong vorticity. Compare models: the reference DNS dissipation peaks at ≈ 0.0127 near t ≈ 9.'
};

const PARALLEL = `<div class="par">
  <div class="stack">
    <p><strong>Local work:</strong> the SGS model, the products ūᵢūⱼ and the Runge–Kutta update touch one grid point at a time. In a finite-difference code the filter and the test filter are small stencils (e.g. ¼, ½, ¼): only a one-cell halo is exchanged.</p>
    <p><strong>Global work:</strong> a spectral code computes every derivative, filter and projection with 3D FFTs. A 1D FFT needs a whole line of the box, so each 3D FFT reshuffles the field among ranks (an all-to-all transpose). This step dominates at scale.</p>
    <p><strong>One small global sum:</strong> the dynamic procedure averages ⟨LM⟩ and ⟨MM⟩ over the box (or over wall-parallel planes): two numbers per step, one allreduce.</p>
  </div>
  <canvas id="wrles-decomp" data-w="340" data-h="250" style="width:100%;max-width:340px;border-radius:8px;background:var(--bg)" aria-label="The box split into slabs or pencils, one per rank, with the transpose that the FFT needs"></canvas>
</div>
<h3 style="font-size:16px">Slabs or pencils?</h3>
<p>A wall-resolved LES of an airliner wing (Re ≈ 10⁸) needs 10¹⁰–10¹¹ points. Treat it as a periodic box of N = 4096 points per side (6.9 × 10¹⁰ points, about 200 bytes each) and get it onto <strong>at least 65 536 ranks</strong> with at most 4 GB per rank. Pick a decomposition, then set N and the ranks.</p>
<div class="btns"><button class="b" id="wrles-slab">Slabs (1D split)</button><button class="b" id="wrles-pencil">Pencils (2D split)</button></div>
<div class="ctl"><label for="wrles-np">ranks</label><input type="range" id="wrles-np" min="6" max="20" step="1" value="10"><output id="wrles-npv">1024</output></div>
<div class="ctl"><label for="wrles-nn">N</label><input type="range" id="wrles-nn" min="9" max="13" step="1" value="12"><output id="wrles-nnv">4096</output></div>
<div class="fb" id="wrles-decfb"></div>
<details><summary>Further optimizations</summary><p>Overlap the transposes with computation (one velocity component in flight while the next is transformed). Use real-to-complex FFTs to halve the data. Pack two real fields into one complex transform, as the Build solver does. On GPUs, cuFFT plus NVLink/InfiniBand all-to-alls; finite-difference LES codes on unstructured wall grids replace the FFT with a pressure Poisson solve (multigrid), whose coarse levels are the global bottleneck instead.</p></details>`;

const SOURCES = [
 ['Pope, S. B., Turbulent Flows, Cambridge University Press, 2000 (ch. 6 spectra, ch. 13 LES)', 'https://doi.org/10.1017/CBO9780511840531'],
 ['Germano, Piomelli, Moin & Cabot, A dynamic subgrid-scale eddy viscosity model, Phys. Fluids A 3, 1760 (1991)', 'https://doi.org/10.1063/1.857955'],
 ['Lilly, D. K., A proposed modification of the Germano subgrid-scale closure method, Phys. Fluids A 4, 633 (1992)', 'https://doi.org/10.1063/1.858280'],
 ['Smagorinsky, J., General circulation experiments with the primitive equations, Mon. Weather Rev. 91, 99 (1963)', 'https://doi.org/10.1175/1520-0493(1963)091%3C0099:GCEWTP%3E2.3.CO;2'],
 ['Choi, H. & Moin, P., Grid-point requirements for large eddy simulation: Chapman\'s estimates revisited, Phys. Fluids 24, 011702 (2012)', 'https://doi.org/10.1063/1.3676783'],
 ['Yang, X. I. A. & Griffin, K. P., Grid-point and time-step requirements for DNS and LES, Phys. Fluids 33, 015108 (2021)', 'https://arxiv.org/abs/2010.15307'],
 ['Brachet et al., Small-scale structure of the Taylor–Green vortex, J. Fluid Mech. 130, 411 (1983)', 'https://doi.org/10.1017/S0022112083001159'],
 ['DeBonis, J., Solutions of the Taylor–Green vortex problem using high-resolution explicit finite difference methods, AIAA 2013-0382 (Re = 1600 reference)', 'https://doi.org/10.2514/6.2013-382'],
 ['Kolmogorov, A. N., The local structure of turbulence in incompressible viscous fluid for very large Reynolds numbers (1941)', 'https://doi.org/10.1098/rspa.1991.0075'],
 ['Pekurovsky, D., P3DFFT: a framework for parallel computations of Fourier transforms in three dimensions, SIAM J. Sci. Comput. 34 (2012)', 'https://doi.org/10.1137/11082748X'],
];
// term definitions are shown as plain text: turn <sub>/<sup> into Unicode scripts
const SUBM = {0:'₀',1:'₁',2:'₂',3:'₃',4:'₄',5:'₅',6:'₆',7:'₇',8:'₈',9:'₉',a:'ₐ',e:'ₑ',h:'ₕ',i:'ᵢ',j:'ⱼ',k:'ₖ',l:'ₗ',m:'ₘ',n:'ₙ',o:'ₒ',p:'ₚ',r:'ᵣ',s:'ₛ',t:'ₜ',u:'ᵤ',v:'ᵥ',x:'ₓ','τ':'ᵧ'.replace('ᵧ','τ')};
const SUPM = {0:'⁰',1:'¹',2:'²',3:'³',4:'⁴',5:'⁵',6:'⁶',7:'⁷',8:'⁸',9:'⁹','/':'ᐟ','-':'⁻','−':'⁻'};
const plain = s => s.replace(/<sub>(.*?)<\/sub>/g, (_, x) => [...x].every(c => SUBM[c] && c !== 'τ') ? [...x].map(c => SUBM[c]).join('') : '_' + x)
  .replace(/<sup>(.*?)<\/sup>/g, (_, x) => [...x].every(c => SUPM[c]) ? [...x].map(c => SUPM[c]).join('') : '^' + x);
Object.values(TERMS).forEach(t => { t.def = plain(t.def); });

// ---- small FFT for 1D lines and 2D pictures ----
function mkFFT1(n){ const lg = Math.log2(n)|0, rev = new Int32Array(n), cr = new Float64Array(n/2), ci = new Float64Array(n/2);
  for (let i=0;i<n;i++){ let r = 0; for (let b=0;b<lg;b++) r |= ((i>>b)&1) << (lg-1-b); rev[i] = r; }
  for (let i=0;i<n/2;i++){ cr[i] = Math.cos(2*Math.PI*i/n); ci[i] = -Math.sin(2*Math.PI*i/n); }
  return (re, im, inv) => { for (let i=0;i<n;i++){ const j = rev[i]; if (j > i){ let t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; } }
    const sg = inv ? -1 : 1;
    for (let s=2;s<=n;s<<=1){ const h = s>>1, st = n/s; for (let a=0;a<n;a+=s) for (let k=0;k<h;k++){ const wr = cr[k*st], wi = sg*ci[k*st], i = a+k, j = i+h, xr = re[j]*wr-im[j]*wi, xi = re[j]*wi+im[j]*wr; re[j] = re[i]-xr; im[j] = im[i]-xi; re[i] += xr; im[i] += xi; } } }; }
function mkFFT2(n){ const f = mkFFT1(n), tr = new Float64Array(n), ti = new Float64Array(n);
  return (re, im, inv) => { for (let y=0;y<n;y++) f(re.subarray(y*n, y*n+n), im.subarray(y*n, y*n+n), inv);
    for (let x=0;x<n;x++){ for (let y=0;y<n;y++){ tr[y] = re[y*n+x]; ti[y] = im[y*n+x]; } f(tr, ti, inv); for (let y=0;y<n;y++){ re[y*n+x] = tr[y]; im[y*n+x] = ti[y]; } } }; }

// ---- the walkthrough's line: 64 samples of u_x along x, with a steep front (so energy really cascades) ----
const N1 = 64, KC1 = 8, KT1 = 4, D1 = Math.PI/KC1, f1 = mkFFT1(N1);
const spec1 = u => { const r = Float64Array.from(u), i = new Float64Array(N1); f1(r, i, false); for (let k=0;k<N1;k++){ r[k] /= N1; i[k] /= N1; } return [r, i]; };
const kk1 = k => k <= N1/2 ? k : k-N1;
const back1 = (r, i) => { const a = Float64Array.from(r), b = Float64Array.from(i); f1(a, b, true); return a; };
const filt1 = (u, kc) => { const [r, i] = spec1(u); for (let k=0;k<N1;k++) if (Math.abs(kk1(k)) > kc){ r[k] = 0; i[k] = 0; } return back1(r, i); };
const ddx1 = u => { const [r, i] = spec1(u), a = new Float64Array(N1), b = new Float64Array(N1); for (let k=0;k<N1;k++){ const q = Math.abs(kk1(k)) === N1/2 ? 0 : kk1(k); a[k] = -q*i[k]; b[k] = q*r[k]; } return back1(a, b); };
const U1 = Float64Array.from({length: N1}, (_, n) => { const x = 2*Math.PI*n/N1; let v = 0; for (let k=1;k<=24;k++) v -= Math.sin(k*x)/k*(1+0.3*Math.cos(3*k)); return 0.6*v; });
const UB1 = filt1(U1, KC1), UH1 = filt1(UB1, KT1), SB1 = ddx1(UB1), SH1 = ddx1(UH1);
const L1 = filt1(UB1.map(v => v*v), KT1).map((v,n) => v-UH1[n]*UH1[n]);
const M1 = filt1(SB1.map(v => Math.abs(v)*v), KT1).map((v,n) => 2*D1*D1*(v-4*Math.abs(SH1[n])*SH1[n]));
const C21 = (() => { let a = 0, b = 0; for (let n=0;n<N1;n++){ a += L1[n]*M1[n]; b += M1[n]*M1[n]; } return a/b; })();
const T1 = SB1.map(s => -2*C21*D1*D1*Math.abs(s)*s);
const AMP1 = (() => { const [r, i] = spec1(U1); return Array.from({length: 25}, (_, k) => 2*(r[k]*r[k]+i[k]*i[k])); })();
// projection example on one Fourier mode
const KP = [1,2,2], UP = [0.6,0.3,-0.4], KU = KP[0]*UP[0]+KP[1]*UP[1]+KP[2]*UP[2], KP2 = 9, PU = UP.map((v,a) => v-KU/KP2*KP[a]);

// ---- block A's model spectrum (Pope 2000, eq. 6.246) in box units: L = 0.71, η = 1/600, ε = 1 ----
const LA = 0.71, ETA = 1/600, NUA = Math.pow(ETA, 4/3);
const EA = k => 1.5*Math.pow(k, -5/3)*Math.pow(k*LA/Math.sqrt((k*LA)**2+6.78), 11/3)*Math.exp(-5.2*(Math.pow((k*ETA)**4+0.4**4, .25)-0.4));
const KG = Array.from({length: 600}, (_, q) => Math.pow(10, -2+q*6/599));
const integ = (g) => { let s = 0; for (let q=1;q<KG.length;q++){ const a = KG[q-1], b = KG[q]; s += .5*(g(a)+g(b))*(b-a); } return s; };
const ETOT = integ(EA), DTOT = integ(k => 2*NUA*k*k*EA(k));
const GF = { sharp: (k, kc) => k <= kc ? 1 : 0, box: (k, kc) => { const x = k*Math.PI/kc/2; return x < 1e-9 ? 1 : Math.sin(x)/x; }, gauss: (k, kc) => Math.exp(-((k*Math.PI/kc)**2)/24), test: (k, kc) => k <= kc/2 ? 1 : 0 };
const kept = (g, kc) => [integ(k => g(k, kc)**2*EA(k))/ETOT, integ(k => g(k, kc)**2*2*NUA*k*k*EA(k))/DTOT];

// symmetric 3 × 3 eigen-decomposition (Jacobi rotations)
function eig3(a){ const A = a.map(r => r.slice()), V = [[1,0,0],[0,1,0],[0,0,1]];
  for (let sw=0;sw<10;sw++) for (const [p,q] of [[0,1],[0,2],[1,2]]){ if (Math.abs(A[p][q]) < 1e-14) continue;
    const th = .5*Math.atan2(2*A[p][q], A[q][q]-A[p][p]), c = Math.cos(th), s = Math.sin(th);
    for (let k=0;k<3;k++){ const x = A[k][p], y = A[k][q]; A[k][p] = c*x-s*y; A[k][q] = s*x+c*y; }
    for (let k=0;k<3;k++){ const x = A[p][k], y = A[q][k]; A[p][k] = c*x-s*y; A[q][k] = s*x+c*y; }
    for (let k=0;k<3;k++){ const x = V[k][p], y = V[k][q]; V[k][p] = c*x-s*y; V[k][q] = s*x+c*y; } }
  return { l: [A[0][0], A[1][1], A[2][2]], v: [0,1,2].map(j => [V[0][j], V[1][j], V[2][j]]) }; }
const SUP = {'0':'⁰','1':'¹','2':'²','3':'³','4':'⁴','5':'⁵','6':'⁶','7':'⁷','8':'⁸','9':'⁹','-':'⁻'};
const sci = v => { if (!isFinite(v) || v === 0) return '0'; const e = Math.floor(Math.log10(Math.abs(v)) + 1e-9), m = v/10**e; return `${m.toFixed(1)}×10${String(e).split('').map(c => SUP[c]).join('')}`; };
const fx = (v, d=3) => (Math.abs(v) < .5*10**-d ? 0 : v).toFixed(d);
// Choi & Moin (2012) prefactor with Yang & Griffin's (2021) assumptions L_z/L_x = 1/4, n_y/(Δx⁺Δz⁺) = 1/200
const NWR = re => 0.021*0.25/200*Math.pow(re, 13/7);
const UTAU = re => Math.sqrt(0.0576*Math.pow(re, -0.2)/2);   // turbulent flat plate, C_f = 0.0576 Re_x^(−1/5)

CFD.register({
 id: 'wrles', name: 'Wall-resolved LES', sub: 'filtered, wall resolved',
 lede: 'Filter the flow at a width Δ: solve for the <strong>large eddies</strong>, model the small ones with an eddy viscosity whose strength is <strong>measured dynamically</strong>, and resolve the wall all the way down.',
 blocks: [
  { key: '0', title: 'The objects', note: 'what goes in, what comes out', html: B0 },
  { key: 'A', title: 'The cascade and the filter', note: 'what the filter cuts', html: BA },
  { key: 'B', title: 'Filtered equations and Smagorinsky', note: 'the missing eddies as viscosity', html: BBk },
  { key: 'C', title: 'The dynamic procedure and the wall', note: 'measuring C_s, and why walls cost', html: BC }],
 checks: CHECKS, quiz: QUIZ, build: BUILD, parallel: { html: PARALLEL },
 unlock: 'The Wall-resolved LES row of the comparison is now visible: resolves the energetic eddies everywhere including the near-wall streaks, needs a subgrid model (dynamic Smagorinsky switches itself off in laminar flow and at the wall), and costs ~Re<sup>13/7</sup> grid points. Complete the other methods to open the full page.',
 sources: SOURCES, terms: TERMS,
 bench(){
  const S = mkLES(32, 1/1600), out = {}; S.cfl = .75; S.dtMax = .15;
  for (const [m, name] of [[0,'none'],[1,'smagorinsky'],[2,'dynamic']]){ S.model = m; S.Cs = .17; S.initTGV();
    let n = 0; while (n < 2) n += S.advance(0);
    const ch = [], t0 = now(); let st = 0; while (st < 6){ const c0 = now(); st += S.advance(0); ch.push(now()-c0); }
    ch.sort((a,b) => a-b); out[name] = { msPerStep: +((now()-t0)/6).toFixed(1), framesPerStepAt9ms: +((now()-t0)/6/9).toFixed(1), chunkMedianMs: +ch[ch.length>>1].toFixed(2), chunkMaxMs: +ch[ch.length-1].toFixed(1) }; }
  // accuracy checks: laminar start of the Taylor–Green vortex, ε(0) = 3ν/4 exactly; and the energy budget −dK/dt = ε_ν + ε_sgs
  S.model = 0; S.initTGV(); const e0 = S.eNu;
  S.model = 1; S.initTGV(); let n = 0; while (n < 3) n += S.advance(0); const bud = Math.abs(S.dKdt-(S.eNu+S.eSgs))/S.dKdt;
  out.epsilon0 = { solver: +e0.toExponential(4), exact: +(0.75/1600).toExponential(4) };
  out.energyBudgetError = +bud.toExponential(2);
  out.note = 'Taylor–Green Re = 1600, 32³, SSP-RK3, Δt ≤ 0.15. Offline: same solver at 64³, no model: peak −dK/dt 0.0121 at t = 9.3 (DNS ≈ 0.0127 at t ≈ 9).';
  return out;
 },
 mount(root, K){
const { $, reduce, MONO, MATH, P, hex, hidpi, arrow, rr, pill, label, ease, lerp, clamp, proj, box, orbit, isAct } = K;
const triad = K.triad, F10 = '10px "IBM Plex Mono", monospace', F11 = '11px "IBM Plex Mono", monospace', B11 = '600 11px "IBM Plex Mono", monospace', SANS = '600 12px "IBM Plex Sans", sans-serif';
let openB = '0';
const line = (c, pts, col, lw, dash) => { c.strokeStyle = col; c.lineWidth = lw; c.setLineDash(dash ? [5,4] : []); c.beginPath(); pts.forEach(([x,y],i) => i ? c.lineTo(x,y) : c.moveTo(x,y)); c.stroke(); c.setLineDash([]); };

// ===== 0: the walkthrough on 64 numbers =====
const CO = hidpi($('opviz'));
const OPS = [
 ['u', 'Start: the true velocity uₓ along one line of the box, 64 samples. It has eddies of every size, down to tiny wiggles, and one steep front where energy is being passed to small scales. Like a photo at full resolution.'],
 ['G', `G keeps only the waves with k ≤ k_c = 8 (Δ = π/8): that is ū, all the grid stores. The rest, u′ = u − ū, is subgrid (red). Like blurring a photo before shrinking it. Here ū keeps ${''}`],
 ['Ĝ', 'Ĝ blurs ū once more at twice the width (k ≤ 4): ū̂. Comparing the two blurs shows what the eddies between Δ and 2Δ are doing, using only numbers the grid has.'],
 ['𝒟', `𝒟 computes, at every point, L (stress the in-between eddies really carry) and M (what the model predicts with C_s = 1), then the single C_s² that fits all 64 points best: ΣLM / ΣMM = ${C21.toFixed(3)}. Like calibrating a scale with known weights. (On a 1D line the number differs from 3D, where it comes out ≈ 0.025.)`],
 ['𝒯', 'The model 𝒯 turns the strain into the subgrid stress, τ = −2(C_sΔ)²|S̄|S̄. It is large only where ū changes fast (the front) and zero where ū is flat: friction that drains energy exactly where the grid cannot hold it.'],
 ['𝒫', '𝒫 adds Δt × (advection + viscosity − ∂ⱼτᵢⱼ), then removes the part of every Fourier mode that points along 𝐤 (one mode shown, real numbers). That part would compress the fluid; removing it is the pressure.']];
(() => { let a = 0, b = 0; for (let n=0;n<N1;n++){ a += UB1[n]*UB1[n]; b += U1[n]*U1[n]; } OPS[1][1] += `${Math.round(a/b*100)}% of the energy on this line.`; })();
let opStage = 0, opT = 0, opPlay = !reduce, opLast = null;
const opBtns = $('opsteps');
opBtns.innerHTML = OPS.map(([n],k) => `<button class="b opb" data-k="${k}">${k+1} · ${n}</button>`).join('');
opBtns.onclick = e => { const b = e.target.closest('.opb'); if (!b) return; opStage = +b.dataset.k; opT = 0; opCap(); K.pin([null,'G','Gh','Dy','Mo','P'][opStage]); if (reduce) drawOps(0); };
$('opplay').onclick = e => { opPlay = !opPlay; e.target.textContent = opPlay ? 'Pause' : 'Play'; };
function opCap(){ $('opcap').textContent = OPS[opStage][1]; opBtns.querySelectorAll('.opb').forEach((b,k) => b.classList.toggle('pri', k === opStage)); }
opCap();
const U1max = Math.max(...U1.map(Math.abs));
function drawOps(tm){
  const dt = opLast === null ? 0 : Math.min(100, tm-opLast); opLast = tm;
  opT = Math.min(opPlay ? 99 : 4, opT + dt/1000); if (opPlay && opT > 4.2){ opT = 0; opStage = (opStage+1) % OPS.length; opCap(); }
  const c = CO, W = c.W, H = c.H, p = P(), e = reduce ? 1 : ease(opT/1.8), st = opStage;
  c.clearRect(0,0,W,H);
  const X = n => 44 + n*(516/(N1-1)), Y = v => 104 - v*58/U1max;
  label(c, 'uₓ along one line of the box (64 points)', 44, 18, p.mut, F11);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(40, Y(0)); c.lineTo(564, Y(0)); c.stroke();
  const curve = (arr, col, lw, frac, alpha) => { const m = Math.max(1, Math.round(frac*(N1-1))); c.globalAlpha = alpha; line(c, Array.from({length: m+1}, (_, n) => [X(n), Y(arr[n])]), col, lw); c.globalAlpha = 1; };
  const hl = (k, ...o) => isAct(k, ...o) ? 1.6 : 1;
  curve(U1, p.u, 1.6*hl('u'), 1, st === 0 || isAct('u') ? 1 : .35);
  if (st >= 1){ curve(UB1, p.f, 2.6*hl('ub','G'), st === 1 ? e : 1, 1);
    if (st === 1 || isAct('up')) for (let n=0;n<N1;n++){ c.strokeStyle = p.nu; c.globalAlpha = .7; c.lineWidth = 2; c.beginPath(); c.moveTo(X(n), Y(UB1[n])); c.lineTo(X(n), Y(U1[n])); c.stroke(); c.globalAlpha = 1; } }
  if (st >= 2) curve(UH1, p.cs, 2.2*hl('uh','Gh'), st === 2 ? e : 1, 1);
  // spectrum of the line: which waves each filter keeps
  { const x0 = 604, bw = 9.5, base = 168;
    label(c, '|u_k|² per wave k (log)', x0, 18, p.mut, F11);
    for (let k=1;k<=24;k++){ const h = clamp((Math.log10(AMP1[k])+4.2)/4*120, 2, 130), x = x0+(k-1)*(bw+1.4);
      const col = st >= 2 && k <= KT1 ? p.cs : st >= 1 && k <= KC1 ? p.f : st >= 1 ? p.nu : p.u;
      c.fillStyle = col; c.globalAlpha = st >= 1 && k > KC1 ? .35 : 1; rr(c, x, base-h, bw, h, 2); c.fill(); c.globalAlpha = 1; }
    const cut = (k, col, txt, on) => { const x = x0+k*(bw+1.4)-.7; c.strokeStyle = col; c.lineWidth = on ? 2.4 : 1.4; c.setLineDash([4,3]); c.beginPath(); c.moveTo(x, 30); c.lineTo(x, base+4); c.stroke(); c.setLineDash([]); label(c, txt, x+3, 40, col, F10); };
    if (st >= 1) cut(KC1, p.cs, 'k_c = 8', isAct('G','kc'));
    if (st >= 2) cut(KT1, p.cs, '4', isAct('Gh'));
    label(c, 'k → 24', x0+23*(bw+1.4), base+16, p.mut, F10, 'right'); }
  // the numbers, at 8 of the 64 points
  const y0 = 212, cols = [0,8,16,24,32,40,48,56];
  const row = (name, arr, col, y, scale, d) => { label(c, name, 40, y+4, col, B11, 'right');
    cols.forEach((n,j) => { const x = 60+j*62, v = arr[n], h = clamp(Math.abs(v)*scale, 0, 14);
      c.fillStyle = col; c.globalAlpha = .25; c.fillRect(x, v >= 0 ? y+8-h : y+8, 50, h); c.globalAlpha = 1;
      label(c, fx(v, d === undefined ? 2 : d), x+25, y+4, p.ink, F11, 'center'); }); };
  label(c, 'at points n = 0, 8, 16, … 56:', 44, y0-14, p.mut, F10);
  if (st === 0) row('u', U1, p.u, y0, 10);
  if (st === 1){ row('ū', UB1, p.f, y0, 10); row('u′', U1.map((v,n) => v-UB1[n]), p.nu, y0+40, 20); }
  if (st === 2){ row('ū', UB1, p.f, y0, 10); row('ū̂', UH1, p.cs, y0+40, 10); }
  if (st === 3){ row('L', L1, p.eq, y0, 40, 3); row('M', M1, p.rho, y0+40, 10, 3);
    let a = 0, b = 0; for (let n=0;n<N1;n++){ a += L1[n]*M1[n]; b += M1[n]*M1[n]; }
    label(c, `C_s² = ΣLM / ΣMM = ${fx(a,3)} / ${fx(b,3)} = ${C21.toFixed(3)}`, 60, y0+94, p.rho, B11);
    // scatter L against M, with the fitted line
    const x0 = 610, w = 240, yc = 270, sx = w/2/Math.max(...M1.map(Math.abs)), sy = 60/Math.max(...L1.map(Math.abs));
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, yc); c.lineTo(x0+w, yc); c.moveTo(x0+w/2, yc-64); c.lineTo(x0+w/2, yc+64); c.stroke();
    for (let n=0;n<N1;n++){ const t = clamp((opT - n*0.02)/1, 0, 1); if (!t && !reduce) continue; c.fillStyle = p.eq; c.globalAlpha = .8; c.beginPath(); c.arc(x0+w/2+M1[n]*sx, yc-L1[n]*sy, 2.6, 0, 7); c.fill(); c.globalAlpha = 1; }
    const mx = w/2/sx; line(c, [[x0, yc+mx*C21*sy], [x0+w, yc-mx*C21*sy]], p.rho, isAct('Dy','Cs') ? 3 : 2);
    label(c, 'L', x0+w/2+5, yc-58, p.eq, MATH); label(c, 'M', x0+w-4, yc+16, p.rho, MATH, 'right'); label(c, 'slope = C_s²', x0+w, yc-70, p.rho, F10, 'right'); }
  if (st === 4){ row('S̄', SB1, p.c, y0, 4); row('τ', T1, p.eq, y0+40, 400, 4);
    label(c, `τ = −2 × ${C21.toFixed(3)} × (π/8)² × |S̄| S̄  ·  largest at the steep front`, 60, y0+94, p.tau, B11);
    // highlight the front in the plot
    let nm = 0; T1.forEach((v,n) => { if (Math.abs(v) > Math.abs(T1[nm])) nm = n; });
    c.fillStyle = p.tau; c.globalAlpha = .12*e; c.fillRect(X(nm)-26, 28, 52, 150); c.globalAlpha = 1; label(c, 'τ largest here', X(nm), 186, p.tau, F10, 'center'); }
  if (st === 5){ label(c, `one mode: 𝐤 = (${KP})   ū_𝐤 = (${UP})`, 60, y0+4, p.ink, F11);
    label(c, `𝐤·ū/k² = ${fx(KU,2)}/${KP2} = ${fx(KU/KP2,4)}  →  removed: (${KP.map(k => fx(k*KU/KP2,3)).join(', ')})`, 60, y0+26, p.rho, F11);
    label(c, `𝒫ū = (${PU.map(v => fx(v,3)).join(', ')})   check 𝐤·𝒫ū = ${fx(KP[0]*PU[0]+KP[1]*PU[1]+KP[2]*PU[2],6)}`, 60, y0+48, p.u, B11);
    label(c, 'removed part = pressure gradient: no Poisson solve in a periodic box', 60, y0+72, p.mut, F10);
    const V = {th: -0.6, ph: 0.35, s: 46, ox: 730, oy: 280}, o = proj(V,0,0,0), kn = Math.sqrt(KP2), Q = v => proj(V, v[0], v[1], v[2]);
    const kk = Q(KP.map(v => v/kn*1.3)), uu = Q(UP.map(v => v*1.6)), pu = Q(PU.map(v => v*1.6*lerp(1, 1, e)));
    arrow(c, o[0], o[1], kk[0], kk[1], p.ink, 2); label(c, '𝐤', kk[0]+6, kk[1], p.ink, MATH);
    arrow(c, o[0], o[1], uu[0], uu[1], p.f, 2, true); label(c, 'ū', uu[0]+6, uu[1]+4, p.f, MATH);
    const pe = Q(UP.map((v,a) => 1.6*(v - e*KU/KP2*KP[a]))); arrow(c, o[0], o[1], pe[0], pe[1], p.u, 3); label(c, '𝒫ū', pe[0]+6, pe[1]+12, p.u, MATH);
    triad(c, V, 840, 330, p); }
  // operator chain along the bottom
  const names = ['u', 'G', 'Ĝ', '𝒟', '𝒯', '𝒫'], keys = [null, 'G', 'Gh', 'Dy', 'Mo', 'P'];
  names.forEach((nm, k) => { const x = 610 + k*42, y = 196, on = k === st || (keys[k] && isAct(keys[k]));
    if (st === 3 || st === 5) return; label(c, nm, x, y, on ? p.ink : p.mut, on ? '600 15px "STIX Two Math", serif' : MATH, 'center'); if (k < 5) label(c, '→', x+21, y, p.rule, F11, 'center'); });
}

// ===== A: the cascade and the filter =====
const CA = hidpi($('specviz')), NP = 128, f2 = mkFFT2(NP), PH = new Float64Array(NP*NP), AM = new Float64Array(NP*NP), KAP = new Float64Array(NP*NP);
(() => { let s = 99; const rnd = () => (s = (s*16807) % 2147483647) / 2147483647;
  for (let y=0;y<NP;y++) for (let x=0;x<NP;x++){ const kx = x < NP/2 ? x : x-NP, ky = y < NP/2 ? y : y-NP, k = Math.hypot(kx, ky), j = y*NP+x; KAP[j] = k; PH[j] = 2*Math.PI*rnd(); AM[j] = k >= 1 && k < NP/2 ? Math.sqrt(EA(k)/(2*Math.PI*k)) : 0; } })();
const FR = new Float64Array(NP*NP), FI = new Float64Array(NP*NP), GR = new Float64Array(NP*NP), GI = new Float64Array(NP*NP);
const imgs = [0,1,2].map(() => { const cv = document.createElement('canvas'); cv.width = NP; cv.height = NP; return { cv, ctx: cv.getContext('2d'), im: new ImageData(NP, NP) }; });
let aKc = 60, aGhost = [], aStart = 60, aClock = 0, aLast = null, aRms = 0, aFr = 0;
const kcIn = $('kc');
kcIn.oninput = () => { aKc = Math.pow(10, +kcIn.value); $('kcv').textContent = aKc < 100 ? aKc.toFixed(aKc < 10 ? 1 : 0) : Math.round(aKc); fieldA(); if (reduce) drawA(0); };
kcIn.addEventListener('pointerdown', () => aStart = aKc);
kcIn.addEventListener('change', () => { if (Math.abs(aStart-aKc) > .01) aGhost = [aStart, ...aGhost.filter(g => g !== aStart)].slice(0,3); aStart = aKc; });
function fieldA(){
  for (let j=0;j<NP*NP;j++){ const ph = PH[j] + 0.35*Math.pow(KAP[j], 2/3)*aClock, a = AM[j]; FR[j] = a*Math.cos(ph); FI[j] = a*Math.sin(ph); const keep = KAP[j] <= aKc ? 1 : 0; GR[j] = FR[j]*keep; GI[j] = FI[j]*keep; }
  f2(FR, FI, true); f2(GR, GI, true);
  if (!aRms){ let s = 0; for (let j=0;j<NP*NP;j++) s += FR[j]*FR[j]; aRms = Math.sqrt(s/(NP*NP)); }
  const p = P(), A = hex(p.acc), B = hex(p.warm), bg = hex(p.bg);
  [FR, GR, null].forEach((fld, q) => { const d = imgs[q].im.data;
    for (let j=0;j<NP*NP;j++){ const v = fld ? fld[j] : FR[j]-GR[j], s = Math.tanh(v/(1.6*aRms)), col = s > 0 ? A : B, t = Math.abs(s)**.85, o = j*4;
      d[o] = bg[0]+(col[0]-bg[0])*t; d[o+1] = bg[1]+(col[1]-bg[1])*t; d[o+2] = bg[2]+(col[2]-bg[2])*t; d[o+3] = 255; }
    imgs[q].ctx.putImageData(imgs[q].im, 0, 0); });
}
function drawA(tm){
  const dt = aLast === null ? 0 : Math.min(100, tm-aLast); aLast = tm;
  if (!reduce){ aClock += dt/1000; if ((aFr++ & 1) === 0) fieldA(); } else if (!aRms) fieldA();
  const c = CA, W = c.W, H = c.H, p = P(); c.clearRect(0,0,W,H);
  [['u: true field', 'u', p.u], ['ū = G ⋆ u', 'ub', p.f], ['u′ = u − ū', 'up', p.nu]].forEach(([t, k, col], q) => { const x = 14+q*154, on = isAct(k) || (q === 1 && isAct('G'));
    c.imageSmoothingEnabled = true; c.drawImage(imgs[q].cv, x, 28, 140, 140);
    c.strokeStyle = on ? col : p.rule; c.lineWidth = on ? 3 : 1; rr(c, x, 28, 140, 140, 6); c.stroke(); label(c, t, x+70, 20, on ? col : p.mut, on ? B11 : F11, 'center'); });
  label(c, 'synthetic random-phase field with the E(k) below; small eddies turn faster', W/2, 184, p.mut, F10, 'center');
  // spectrum
  const x0 = 54, x1 = 466, yT = 204, yB = 392, Emax = EA(2.85/LA);
  const X = k => x0 + Math.log10(k)/3*(x1-x0), Y = e => yB - (Math.log10(e/Emax)+6)/6.4*(yB-yT);
  c.fillStyle = p.f; c.globalAlpha = isAct('ub') ? .2 : .08; c.fillRect(X(1), yT, X(Math.min(1000, aKc))-X(1), yB-yT);
  c.fillStyle = p.nu; c.globalAlpha = isAct('up') ? .2 : .07; c.fillRect(X(Math.min(1000, aKc)), yT, X(1000)-X(Math.min(1000, aKc)), yB-yT); c.globalAlpha = 1;
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, yT); c.lineTo(x0, yB); c.lineTo(x1, yB); c.stroke();
  [1,10,100,1000].forEach(k => label(c, String(k), X(k), yB+14, isAct('k') ? p.ink : p.mut, F10, 'center'));
  label(c, 'k', x1+8, yB+4, isAct('k') ? p.ink : p.mut, MATH); label(c, 'E (log)', x0-4, yT-4, p.f, F10, 'right');
  const pts = []; for (let q=0;q<=160;q++){ const k = Math.pow(10, q*3/160), e = EA(k); if (e > Emax*1e-6) pts.push([X(k), Y(e)]); }
  line(c, pts, p.f, isAct('E') ? 4 : 2.6);
  const Dm = Math.max(...KG.map(k => 2*NUA*k*k*EA(k))), dp = []; let kpk = 1, dpk = 0;
  for (let q=0;q<=160;q++){ const k = Math.pow(10, q*3/160), d = 2*NUA*k*k*EA(k); if (d > dpk){ dpk = d; kpk = k; } if (d/Dm*Emax > Emax*1e-6) dp.push([X(k), Y(d/Dm*Emax)]); }
  line(c, dp, p.nu, isAct('eps') ? 3.4 : 1.8, true);
  label(c, 'dissipation (shape)', X(kpk)-6, Y(Emax)+14, p.nu, F10, 'right');
  const ck = isAct('CK'); line(c, [[X(8), Y(1.5*Math.pow(8,-5/3))+(ck?0:-14)], [X(200), Y(1.5*Math.pow(200,-5/3))+(ck?0:-14)]], p.w, ck ? 2.6 : 1.4, true);
  label(c, 'C_K ε^2/3 k^−5/3', X(30), Y(1.5*Math.pow(30,-5/3))+4, ck ? p.ink : p.w, F10, 'center');
  c.strokeStyle = p.w; c.lineWidth = isAct('eta') ? 2.6 : 1.2; c.beginPath(); c.moveTo(X(1/ETA), yB); c.lineTo(X(1/ETA), yB-26); c.stroke(); label(c, '1/η', X(1/ETA), yB-30, isAct('eta') ? p.ink : p.w, F10, 'center');
  c.setLineDash([2,3]); c.strokeStyle = p.mut; c.lineWidth = 1; c.beginPath(); c.moveTo(X(64), yT+20); c.lineTo(X(64), yB); c.stroke(); c.setLineDash([]); label(c, 'picture limit', X(64)+3, yB-6, p.mut, F10);
  aGhost.forEach((g,j) => { c.globalAlpha = .45-.12*j; c.strokeStyle = p.cs; c.lineWidth = 1.2; c.setLineDash([3,3]); c.beginPath(); c.moveTo(X(g), yT); c.lineTo(X(g), yB); c.stroke(); c.setLineDash([]); c.globalAlpha = 1; });
  const cOn = isAct('kc','G','D'); c.strokeStyle = p.cs; c.lineWidth = cOn ? 4 : 2.6; c.beginPath(); c.moveTo(X(aKc), yT-4); c.lineTo(X(aKc), yB); c.stroke();
  label(c, `k_c = π/Δ`, clamp(X(aKc), x0+30, x1-30), yT-8, p.cs, B11, 'center');
  const [fe, fd] = kept(GF.sharp, aKc);
  let px = 12; const py = H-14;
  px = pill(c, px, py, `Δ = ${(Math.PI/aKc).toFixed(3)}`, p.cs); px = pill(c, px, py, `energy kept ${(fe*100).toFixed(fe > .999 ? 2 : 1)}%`, p.f); pill(c, px, py, `dissipation kept ${(fd*100).toFixed(1)}%`, p.nu);
  $('kccap').textContent = fe < .8 ? `Too coarse: the cut is in the energy-containing range, ${(100-fe*100).toFixed(0)}% of the energy is subgrid (Pope: resolve ≥ 80%). The model would be doing the physics.`
    : fd < .5 ? `LES: the cut sits in the inertial range. ${(fe*100).toFixed(1)}% of the energy is resolved but only ${(fd*100).toFixed(0)}% of the dissipation, so the model must drain the rest (≈ ε) at k_c.`
    : `Near DNS: the cut reaches the dissipation range (k_c η = ${(aKc*ETA).toFixed(2)}); the grid resolves most of the dissipation itself, and the model matters little.`;
}

// ===== B and C share one live 32³ box: a random field (no cascade yet) evolving with the dynamic model =====
let LS = null, lsHist = [], lsNeedPhys = false, lsDynT = -1;
const SL = { u: [0,1,2].map(() => new Float64Array(1024)), S: [0,1,2,3,4,5].map(() => new Float64Array(1024)), s3: 0, s99: 1, t: 0 };
function ensureLS(){ if (LS) return; LS = mkLES(32, 1/2000); LS.model = 2; LS.cfl = .6; LS.dtMax = .06; LS.initRandom(12345, 3, .5); lsHist = []; lsDynT = -1; lsNeedPhys = true;
  if (reduce){ while (LS.t < 2.5) LS.advance(1e9, true); lsHist.push([LS.t, LS.Cs2raw]); LS.phys(); copySlice(); lsNeedPhys = false; } }
function copySlice(){ const N = 32, z0 = 16, T = N*N*N; let s3 = 0; const mags = new Float64Array(T);
  for (let k=0;k<T;k++){ const m = LS.smag(LS.Sf, k); mags[k] = m; s3 += m*m*m; }
  for (let y=0;y<N;y++) for (let x=0;x<N;x++){ const k = (z0*N+y)*N+x, j = y*N+x; for (let a=0;a<3;a++) SL.u[a][j] = LS.u[a][k]; for (let c=0;c<6;c++) SL.S[c][j] = LS.Sf[c][k]; }
  const sorted = Array.from(mags.filter((_, i) => i % 7 === 0)).sort((a,b) => a-b); SL.s99 = sorted[(sorted.length*.99)|0]; SL.s3 = s3/T; SL.t = LS.t; SL.eNu = LS.eNu; SL.eS = LS.eSgs; }
function learnStep(){ if (!LS) return;
  if (lsNeedPhys){ LS.phys(); copySlice(); lsNeedPhys = false; return; }
  if (LS.t >= 6) return;
  if (LS.advance(7, true)){ lsNeedPhys = true; if (LS.dynT !== lsDynT){ lsDynT = LS.dynT; lsHist.push([LS.t, LS.Cs2raw]); } } }
const Smat = j => { const S = SL.S; return [[S[0][j], S[3][j], S[4][j]], [S[3][j], S[1][j], S[5][j]], [S[4][j], S[5][j], S[2][j]]]; };

// ----- B: eddy viscosity on a slice, and the strain/stress axes at a moving probe -----
const CBv = hidpi($('smviz')), VBg = { th: -0.5, ph: 0.35, s: 78, ox: 368, oy: 150 }, offB = document.createElement('canvas'); offB.width = 32; offB.height = 32;
const imB = new ImageData(32, 32); orbit($('smviz'), VBg);
let bCsL = .17, bCsStart = .17, bGhost = [], bClock = 0, bLast = null;
const csIn = $('cs');
csIn.oninput = () => { bCsL = +csIn.value; $('csv').textContent = bCsL.toFixed(3); if (reduce) drawB(0); };
csIn.addEventListener('pointerdown', () => bCsStart = bCsL);
csIn.addEventListener('change', () => { if (bCsStart !== bCsL) bGhost = [bCsStart, ...bGhost.filter(g => g !== bCsStart)].slice(0,2); bCsStart = bCsL; });
const DL = Math.PI/10;
function drawB(tm){
  const dt = bLast === null ? 0 : Math.min(100, tm-bLast); bLast = tm; if (!reduce) bClock += dt/1000;
  if (!VBg.drag && !reduce) VBg.th += dt*0.0001;
  const c = CBv, W = c.W, H = c.H, p = P(); c.clearRect(0,0,W,H);
  if (!LS){ label(c, 'starting the live box…', W/2, H/2, p.mut, F11, 'center'); return; }
  const cd = (bCsL*DL)**2, nRef = (.17*DL)**2*SL.s99, showS = isAct('Smag'), tc = hex(showS ? p.c : p.tau), bg = hex(p.bg), d = imB.data;
  for (let y=0;y<32;y++) for (let x=0;x<32;x++){ const j = y*32+x, m = LS.smag(SL.S, j), v = showS ? m/SL.s99 : cd*m/nRef, t = Math.min(1, v)**.75, o = ((31-y)*32+x)*4;
    for (let q=0;q<3;q++) d[o+q] = bg[q]+(tc[q]-bg[q])*t; d[o+3] = 255; }
  offB.getContext('2d').putImageData(imB, 0, 0);
  const sx = 12, sy = 30, sw = 240; c.imageSmoothingEnabled = true; c.drawImage(offB, sx, sy, sw, sw);
  c.strokeStyle = isAct('nut') ? p.tau : p.rule; c.lineWidth = isAct('nut') ? 3 : 1; rr(c, sx, sy, sw, sw, 6); c.stroke();
  label(c, `${showS ? '|S̄|' : 'ν_sgs'} on slice z = N/2 · t = ${SL.t.toFixed(2)}`, sx, 20, p.ink, F11);
  // resolved velocity in the slice
  const g = sw/32, vOn = isAct('ub'); c.globalAlpha = vOn ? 1 : .55;
  for (let y=1;y<32;y+=3) for (let x=1;x<32;x+=3){ const j = y*32+x, X = sx+(x+.5)*g, Y = sy+(31-y+.5)*g; arrow(c, X, Y, X+SL.u[0][j]*14, Y-SL.u[1][j]*14, p.f, vOn ? 1.6 : 1.1); }
  c.globalAlpha = 1;
  // probe
  const px = 16+11*Math.sin(.21*bClock), py = 16+11*Math.sin(.33*bClock+1), jp = (Math.round(py)%32)*32+(Math.round(px)%32);
  const PX = sx+(px+.5)*g, PY = sy+(31-py+.5)*g; c.strokeStyle = p.ink; c.lineWidth = 2; c.beginPath(); c.arc(PX, PY, 7, 0, 7); c.stroke(); c.beginPath(); c.moveTo(PX+7, PY); c.lineTo(290, 150); c.stroke();
  // 3D glyph at the probe: principal axes of S̄ (stretch out, squeeze in) and of τ (opposite)
  const Sm = Smat(jp), { l, v } = eig3(Sm), lm = Math.max(...l.map(Math.abs)) || 1, sOn = isAct('Sij'), tOn = isAct('tau');
  box(c, VBg, .9, .9, .9, p.rule, 1);
  const Q = (a, s) => proj(VBg, a[0]*s, a[1]*s, a[2]*s), o = Q([0,0,0], 0);
  // the blob a sphere of fluid becomes under this strain
  [[0,1],[0,2],[1,2]].forEach(([a,b]) => { c.beginPath(); for (let q=0;q<=40;q++){ const th = q/40*2*Math.PI, ca = Math.cos(th), sa = Math.sin(th), r = [0,1,2].map(i => .5*(ca*v[a][i]*(1+.45*l[a]/lm) + sa*v[b][i]*(1+.45*l[b]/lm))), P3 = proj(VBg, ...r); q ? c.lineTo(P3[0], P3[1]) : c.moveTo(P3[0], P3[1]); } c.strokeStyle = p.c; c.globalAlpha = .35; c.lineWidth = 1.2; c.stroke(); c.globalAlpha = 1; });
  for (let a=0;a<3;a++){ const s = l[a]/lm, len = .35+.5*Math.abs(s);
    for (const sg of [1,-1]){ const e = v[a].map(x => x*sg), A1 = Q(e, s > 0 ? .12 : len), A2 = Q(e, s > 0 ? len : .12);
      arrow(c, A1[0], A1[1], A2[0], A2[1], p.c, sOn ? 3.4 : 2.2);
      const T1 = Q(e, s > 0 ? len*.75 : .2), T2 = Q(e, s > 0 ? .2 : len*.75); c.globalAlpha = .9; arrow(c, T1[0]+5, T1[1]+5, T2[0]+5, T2[1]+5, p.eq, tOn ? 3 : 1.6, true); c.globalAlpha = 1; }
    const E = Q(v[a], .95); label(c, `${l[a] >= 0 ? '+' : '−'}${Math.abs(l[a]).toFixed(1)}`, E[0], E[1], p.c, F10, 'center'); }
  triad(c, VBg, 452, 34, p);
  const sm = LS.smag(SL.S, jp), nu = cd*sm;
  label(c, `probe: |S̄| = ${sm.toFixed(2)}, ν_sgs = ${sci(nu)}`, 272, 268, p.ink, F11);
  label(c, `Π = ν_sgs|S̄|² = ${sci(nu*sm*sm)}`, 272, 284, isAct('Pi') ? p.nu : p.mut, F11);
  // budget: what this C_s would drain vs what the dynamic model chose vs resolved viscous dissipation
  const PiC = cd*SL.s3, bars = [[`Π with C_s = ${bCsL.toFixed(3)}`, PiC, p.tau, 'Cs'], [`Π dynamic (C_s = ${Math.sqrt(Math.max(0, LS.Cs2)).toFixed(3)})`, SL.eS || 0, p.rho, 'Dy'], ['ε_ν resolved viscous', SL.eNu || 0, p.w, 'nu']];
  const bmax = Math.max(...bars.map(b => b[1]), (.3*DL)**2*SL.s3*.6, 1e-9)*1.05, bx = 170, bw = W-bx-20;
  label(c, 'energy drained per unit time, box average', 12, 302, p.mut, F10);
  bars.forEach(([n, val, col, k], q) => { const y = 314+q*30, on = isAct(k) || (q === 0 && isAct('Pi','nut','Mo'));
    label(c, n, bx-8, y+13, on ? col : p.mut, on ? B11 : F11, 'right'); c.fillStyle = col; c.globalAlpha = on ? 1 : .8; rr(c, bx, y, Math.max(2, val/bmax*bw), 18, 4); c.fill(); c.globalAlpha = 1;
    label(c, sci(val), bx+Math.max(2, val/bmax*bw)+6, y+13, p.ink, F10);
    if (q === 0) bGhost.forEach((gc, j) => { const xg = bx+(gc*DL)**2*SL.s3/bmax*bw; c.globalAlpha = .5-.2*j; c.fillStyle = p.tau; c.fillRect(xg-1, y-3, 2, 24); c.globalAlpha = 1; }); });
  const reg = bCsL < .02 ? 'no model: nothing removes energy at k_c, it piles up' : bCsL < .13 ? 'around 0.1: typical for channel flow (Deardorff 1970)' : bCsL < .21 ? 'around 0.17: Lilly\'s value for isotropic turbulence' : 'over-damped: behaves like a much more viscous fluid';
  label(c, reg, 12, H-8, p.tau, F11);
  $('smcap').textContent = `Your C_s drains ${(PiC/Math.max(1e-12, SL.eS)).toFixed(2)}× what the dynamic model measured for this field. ν_sgs ∝ C_s²: doubling C_s quadruples it.`;
}

// ----- C: Germano's L against M, and the history of C_s as the cascade builds -----
const CCv = hidpi($('dynviz')), alIn = $('al');
alIn.oninput = () => { if (LS) LS.alpha = +alIn.value; $('alv').textContent = (+alIn.value).toFixed(2); if (LS){ lsHist.push([LS.t, NaN]); if (reduce){ LS.dynNow(); lsHist.push([LS.t, LS.Cs2raw]); drawC(); } } };
$('respin').onclick = () => { if (!LS) return; LS.alpha = +alIn.value; LS.initRandom(12345 + ((Math.random()*1e6)|0), 3, .5); lsHist = []; lsDynT = -1; lsNeedPhys = true; if (reduce){ LS = null; ensureLS(); drawLearn(0); } };
function drawC(){
  const c = CCv, W = c.W, H = c.H, p = P(); c.clearRect(0,0,W,H);
  if (!LS){ label(c, 'starting the live box…', W/2, H/2, p.mut, F11, 'center'); return; }
  const sm = LS.samp || [], x0 = 26, x1 = 226, yc = 132, hh = 96;
  label(c, 'L against M at sample points', x0, 18, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, yc); c.lineTo(x1, yc); c.moveTo((x0+x1)/2, yc-hh); c.lineTo((x0+x1)/2, yc+hh); c.stroke();
  if (sm.length){ const ms = sm.flatMap(s => [Math.abs(s[0]), Math.abs(s[2])]).sort((a,b) => a-b), ls = sm.flatMap(s => [Math.abs(s[1]), Math.abs(s[3])]).sort((a,b) => a-b);
    const mx = ms[(ms.length*.96)|0] || 1, lx = ls[(ls.length*.96)|0] || 1, X = m => (x0+x1)/2 + m/mx*(x1-x0)/2, Y = v => yc - v/lx*hh, on = isAct('L','M');
    c.fillStyle = p.eq; c.globalAlpha = on ? .8 : .45; sm.forEach(s => { for (const [m, v] of [[s[0], s[1]], [s[2], s[3]]]) { const xx = X(m), yy = Y(v); if (xx > x0 && xx < x1 && yy > yc-hh && yy < yc+hh) c.fillRect(xx-1.5, yy-1.5, 3, 3); } }); c.globalAlpha = 1;
    const lineC = (s, col, lw, dash) => { const m = mx; c.save(); c.beginPath(); c.rect(x0, yc-hh, x1-x0, 2*hh); c.clip(); line(c, [[X(-m), Y(-m*s)], [X(m), Y(m*s)]], col, lw, dash); c.restore(); };
    lineC(.17*.17, p.w, 1.4, true); lineC(LS.Cs2, p.rho, isAct('Dy','Cs','avg') ? 3.4 : 2.4);
    const neg = sm.filter(s => s[4] < 0).length/sm.length;
    label(c, 'M', x1, yc+14, p.rho, MATH, 'right'); label(c, 'L', (x0+x1)/2+6, yc-hh+10, p.eq, MATH);
    label(c, `slope C_s² = ${LS.Cs2.toFixed(4)}`, x0, yc+hh+18, p.rho, B11); label(c, `┄ Lilly 0.17² = 0.029`, x0, yc+hh+32, p.w, F10);
    label(c, `${(neg*100).toFixed(0)}% of points locally negative`, x0, yc+hh+46, isAct('avg') ? p.ink : p.mut, F10);
  } else label(c, 'waiting for the first dynamic step…', x0, yc, p.mut, F10);
  // history
  const hx0 = 280, hx1 = 466, hy0 = 40, hy1 = 236, Xt = t => hx0+(hx1-hx0)*t/6, Yc = v => hy1-(hy1-hy0)*v/.25;
  label(c, 'C_s over time', hx0, 18, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(hx0, hy0); c.lineTo(hx0, hy1); c.lineTo(hx1, hy1); c.stroke();
  [0,.1,.2].forEach(v => label(c, String(v), hx0-4, Yc(v)+4, p.mut, F10, 'right')); [0,2,4,6].forEach(t => label(c, String(t), Xt(t), hy1+13, p.mut, F10, 'center'));
  label(c, 't', hx1+8, hy1+4, p.mut, MATH);
  line(c, [[hx0, Yc(.17)], [hx1, Yc(.17)]], p.w, 1.2, true); label(c, 'Lilly 0.17', hx1, Yc(.17)-5, p.w, F10, 'right');
  const pts = []; lsHist.forEach(([t, v]) => { if (isNaN(v)){ c.strokeStyle = p.cs; c.lineWidth = 1; c.beginPath(); c.moveTo(Xt(t), hy0); c.lineTo(Xt(t), hy1); c.stroke(); label(c, 'α', Xt(t)+3, hy0+10, p.cs, F10); return; } pts.push([Xt(t), Yc(Math.sqrt(Math.max(0, v)))]); });
  if (pts.length) line(c, pts, p.tau, isAct('Cs') ? 3.4 : 2.4); pts.forEach(([x, y]) => { c.fillStyle = p.tau; c.beginPath(); c.arc(x, y, 2, 0, 7); c.fill(); });
  label(c, `t = ${LS.t.toFixed(2)}${LS.t >= 6 ? ' (held)' : ''}`, hx1, hy0-8, p.mut, F10, 'right');
  const cs = Math.sqrt(Math.max(0, LS.Cs2));
  $('dyncap').textContent = `Test filter α = Δ̂/Δ = ${(+alIn.value).toFixed(2)} · C_s = ${cs.toFixed(3)}. ${LS.t < .6 ? 'The random start has no cascade yet, so L and M are uncorrelated and C_s ≈ 0.' : 'The cascade has built up: L lines up with M and C_s settles near Lilly\'s value, with no constant typed in.'}`;
}

// ----- C, the wall: streaks fixed in wall units, so the grid must shrink as Re grows -----
const CWv = hidpi($('wallviz')), reIn = $('re'); let wRe = Math.pow(10, 6.5);
reIn.oninput = () => { wRe = Math.pow(10, +reIn.value); $('rev').textContent = sci(wRe).replace('1.0×', ''); if (reduce) drawWall(); };
$('rev').textContent = sci(wRe);
function drawWall(){
  const c = CWv, W = c.W, H = c.H, p = P(); c.clearRect(0,0,W,H);
  const ut = UTAU(wRe), Lp = wRe*ut/200, x0 = 14, y0 = 26, S = 200, sc = S/Lp;   // patch = L_x/200 square, in wall units
  label(c, 'wall patch L/200 × L/200, from above', x0, 16, p.ink, F11);
  c.save(); rr(c, x0, y0, S, S, 6); c.clip(); c.fillStyle = p.bg; c.fillRect(x0, y0, S, S);
  // low-speed streaks ≈ 100 wall units apart, ≈ 1000 long
  const nS = Lp/100; c.strokeStyle = p.u; c.globalAlpha = nS > 60 ? .25 : .55; c.lineWidth = Math.max(.6, Math.min(5, 30*sc));
  if (nS <= 400) for (let s=0;s<=nS;s++){ const z = (s+.3)*100; c.beginPath(); for (let q=0;q<=40;q++){ const x = q/40*Lp; const zz = z + 18*Math.sin(2*Math.PI*x/1000 + s*1.7); q ? c.lineTo(x0+x*sc, y0+zz*sc) : c.moveTo(x0+x*sc, y0+zz*sc); } c.stroke(); }
  else { c.fillStyle = p.u; c.globalAlpha = .18; c.fillRect(x0, y0, S, S); }
  c.globalAlpha = 1;
  const gx = 50*sc, gz = 15*sc, gOn = isAct('dxp','yp');
  c.strokeStyle = p.cs; c.lineWidth = gOn ? 1.2 : .8;
  if (gz >= 2.5){ c.globalAlpha = .8; c.beginPath(); for (let x=0;x<=S;x+=gx){ c.moveTo(x0+x, y0); c.lineTo(x0+x, y0+S); } for (let z=0;z<=S;z+=gz){ c.moveTo(x0, y0+z); c.lineTo(x0+S, y0+z); } c.stroke(); c.globalAlpha = 1; }
  else { c.fillStyle = p.cs; c.globalAlpha = .35; c.fillRect(x0, y0, S, S); c.globalAlpha = 1; label(c, 'grid too fine to draw', x0+S/2, y0+S/2, p.ink, B11, 'center'); }
  c.restore(); c.strokeStyle = p.rule; c.lineWidth = 1; rr(c, x0, y0, S, S, 6); c.stroke();
  const nx = Lp/50, nz = Lp/15;
  label(c, `${Math.max(1, Math.round(nx)).toLocaleString('en-US')} × ${Math.max(1, Math.round(nz)).toLocaleString('en-US')} cells on this patch`, x0, y0+S+16, gOn ? p.cs : p.ink, F11);
  // wall-unit ruler
  const r100 = 100*sc; if (r100 > 4){ c.strokeStyle = p.ut || p.u; c.lineWidth = 2; c.beginPath(); c.moveTo(x0+6, y0+S-8); c.lineTo(x0+6+Math.min(r100, S-12), y0+S-8); c.stroke(); label(c, '100 ν/u_τ', x0+8, y0+S-12, isAct('ut') ? p.ink : p.u, F10); }
  // grid count against Re
  const px0 = 270, px1 = 466, py0 = 30, py1 = 200, X = r => px0+(Math.log10(r)-5.5)/3.5*(px1-px0), Y = n => py1-(Math.log10(n)-4)/10*(py1-py0), on = isAct('Nwr','Rex');
  label(c, 'grid points, wall-resolved LES', px0, 16, p.ink, F11);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(px0, py0); c.lineTo(px0, py1); c.lineTo(px1, py1); c.stroke();
  [6,7,8,9].forEach(e => label(c, `10${SUP[e]}`, X(10**e), py1+13, p.mut, F10, 'center')); [6,9,12].forEach(e => label(c, `10${String(e).split('').map(d => SUP[d]).join('')}`, px0-4, Y(10**e)+4, p.mut, F10, 'right'));
  line(c, [[X(10**5.5), Y(NWR(10**5.5))], [X(1e9), Y(NWR(1e9))]], p.ink, on ? 3 : 2);
  c.fillStyle = p.cs; c.beginPath(); c.arc(X(wRe), Y(NWR(wRe)), 6, 0, 7); c.fill();
  label(c, 'slope 13/7', X(10**7.6), Y(NWR(10**7.6))+16, p.mut, F10);
  label(c, 'Re_Lx', px1, py1+26, on ? p.ink : p.mut, F10, 'right');
  label(c, `N_wr ≈ ${sci(NWR(wRe))}`, X(wRe) < 380 ? X(wRe)+10 : X(wRe)-10, Y(NWR(wRe))-8, p.cs, B11, X(wRe) < 380 ? 'left' : 'right');
  label(c, 'Re ×10 → points: WM ×10, WR ×72, DNS ×437', px1, H-10, p.mut, F10, 'right');
  $('wallcap').textContent = `Re = ${sci(wRe)}: u_τ/U = ${ut.toFixed(4)}, so one wall unit ν/u_τ is L/${Math.round(wRe*ut).toLocaleString('en-US')}. First cell at y⁺ = 1, Δx⁺ = 50, Δz⁺ = 15 → about ${sci(NWR(wRe))} points for the whole surface (Choi & Moin 2012 scaling).`;
}

// ===== how-it-works panels: one per operator, worked on real numbers =====
const mt = s => `<div class="hm"><math display="block">${s}</math></div>`, tc = (col, x) => `<mrow style="color:var(${col})">${x}</mrow>`, sw = col => `<i class="tb" style="background:var(${col})"></i>`;
const btns = (key, list, cur) => `<div class="eex"><span>Example</span>${list.map((n,i) => `<button class="b${i === cur ? ' pri' : ''}" data-x="${i}">${n}</button>`).join('')}</div>`;
const HS = { G: 0, Mo: 0, Dy: 1, P: 2 };
const bindX = (key) => function(root){ root.querySelectorAll('[data-x]').forEach(b => b.onclick = () => { HS[key] = +b.dataset.x; root.querySelectorAll('[data-x]').forEach(x => x.classList.toggle('pri', x === b)); this.draw(root); }); };
const ub_k = '<msub><mover accent="true"><mi>u</mi><mo>‾</mo></mover><mrow><mi>i</mi><mo>,</mo><mi>𝐤</mi></mrow></msub>';
const GRADS = [['shear', [[0,2,0],[0,0,0],[0,0,0]]], ['stretch', [[1,0,0],[0,-.5,0],[0,0,-.5]]], ['rotation', [[0,-1,0],[1,0,0],[0,0,0]]], ['live probe', null]];
const HOW = {
 G: { html: () => `<span class="eyebrow">How G works</span><p>A filter is a local weighted average. In Fourier space it multiplies each mode by a weight G<sub>𝐤</sub> between 0 and 1:</p>
   ${mt(`${ub_k}<mo>=</mo><msub><mi>G</mi><mi>𝐤</mi></msub><msub><mi>u</mi><mrow><mi>i</mi><mo>,</mo><mi>𝐤</mi></mrow></msub><mo>,</mo><mspace width="1em"/><msub><mi>G</mi><mi>𝐤</mi></msub><mo>=</mo>${tc('--c-cs','<mi>H</mi><mo>(</mo><msub><mi>k</mi><mi>c</mi></msub><mo>−</mo><mi>k</mi><mo>)</mo>')}<mo>,</mo><mspace width=".5em"/>${tc('--c-f','<mfrac><mrow><mi>sin</mi><mo>(</mo><mi>k</mi><mi>Δ</mi><mo>/</mo><mn>2</mn><mo>)</mo></mrow><mrow><mi>k</mi><mi>Δ</mi><mo>/</mo><mn>2</mn></mrow></mfrac>')}<mo>,</mo><mspace width=".5em"/>${tc('--c-eq','<msup><mi>e</mi><mrow><mo>−</mo><msup><mi>k</mi><mn>2</mn></msup><msup><mi>Δ</mi><mn>2</mn></msup><mo>/</mo><mn>24</mn></mrow></msup>')}`)}
   <div class="eterms"><span>${sw('--c-cs')}sharp</span><span>Keeps k ≤ k<sub>c</sub> = π/Δ exactly, drops the rest. Free in a spectral code (Build uses it); the test filter is the same at k<sub>c</sub>/2.</span>
   <span>${sw('--c-f')}box</span><span>Average over a cell of width Δ: what a finite-volume grid does implicitly. Part of every small eddy leaks through.</span>
   <span>${sw('--c-eq')}Gaussian</span><span>Smooth in both x and k; often used for analysis of DNS data.</span></div>
   ${btns('G', ['sharp', 'box', 'Gaussian', 'test 2Δ'], HS.G)}<canvas class="hc" data-w="420" data-h="120"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), names = ['sharp','box','gauss','test'], cols = [p.cs, p.f, p.eq, p.cs], sel = HS.G, X = r => 34+r/3*370, Y = g => 100-g*80;
   c.clearRect(0,0,c.W,c.H); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(34, 20); c.lineTo(34, 100); c.lineTo(410, 100); c.stroke();
   [0,1,2,3].forEach(r => label(c, r ? r+'k_c' : '0', X(r), 114, p.mut, F10, 'center')); label(c, '1', 28, 24, p.mut, F10, 'right');
   names.forEach((n, q) => { const pts = []; for (let s=0;s<=150;s++){ const r = s/50; pts.push([X(r), Y(Math.max(0, GF[n](r*20, 20)))]); } c.globalAlpha = q === sel ? 1 : .3; line(c, pts, cols[q], q === sel ? 3 : 1.4, q === 3); c.globalAlpha = 1; });
   const g = GF[names[sel]], [fe, fd] = kept(g, aKc);
   root.querySelector('.ecalc').textContent = `${['Sharp','Box','Gaussian','Test (sharp at k_c/2)'][sel]}: G at k_c/2 = ${g(aKc/2, aKc).toFixed(3)}, at k_c = ${g(aKc, aKc).toFixed(3)}, at 2k_c = ${g(2*aKc, aKc).toFixed(3)}. With block A's cut (k_c = ${aKc.toFixed(0)}) it keeps ${(fe*100).toFixed(1)}% of the energy and ${(fd*100).toFixed(1)}% of the dissipation.`; },
  bind: null },
 Mo: { html: () => `<span class="eyebrow">How 𝒯 works</span><p>From the velocity gradient, take its symmetric part (the strain), then make a viscous stress with an eddy viscosity:</p>
   ${mt(`<msub><mi>τ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>=</mo><mo>−</mo><mn>2</mn>${tc('--c-tau','<msup><mrow><mo>(</mo><msub><mi>C</mi><mi>s</mi></msub><mi>Δ</mi><mo>)</mo></mrow><mn>2</mn></msup>')}${tc('--c-u','<mo>|</mo><mover accent="true"><mi>S</mi><mo>‾</mo></mover><mo>|</mo>')}${tc('--c-c','<msub><mover accent="true"><mi>S</mi><mo>‾</mo></mover><mrow><mi>i</mi><mi>j</mi></mrow></msub>')}`)}
   <div class="eterms"><span>${sw('--c-tau')}(C<sub>s</sub>Δ)²</span><span>A mixing length squared: the size of the largest missing eddy, scaled by C<sub>s</sub>.</span>
   <span>${sw('--c-u')}|S̄|</span><span>How hard the flow strains here: turns the length² into a viscosity ν<sub>sgs</sub>.</span>
   <span>${sw('--c-c')}S̄<sub>ij</sub></span><span>The direction: the stress opposes the strain, exactly like the fluid's own viscous stress −2νS.</span></div>
   ${btns('Mo', GRADS.map(g => g[0]), HS.Mo)}<canvas class="hc" data-w="420" data-h="112"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(); let A = GRADS[HS.Mo][1];
   if (!A){ if (LS && SL.t > 0){ const j = 16*32+16; A = Smat(j); } else A = GRADS[0][1]; }
   const S = [0,1,2].map(i => [0,1,2].map(j => .5*(A[i][j]+A[j][i]))), sm = Math.sqrt(2*S.flat().reduce((s,v) => s+v*v, 0)), Cs = bCsL, nu = (Cs*DL)**2*sm, Tm = S.map(r => r.map(v => -2*nu*v));
   c.clearRect(0,0,c.W,c.H);
   const mat = (M, x0, title, col, d) => { label(c, title, x0+60, 14, col, B11, 'center'); const mx = Math.max(1e-9, ...M.flat().map(Math.abs));
     M.forEach((r,i) => r.forEach((v,j) => { const x = x0+j*40, y = 22+i*28; c.fillStyle = col; c.globalAlpha = .12+.5*Math.abs(v)/mx; rr(c, x, y, 38, 26, 4); c.fill(); c.globalAlpha = 1; label(c, Math.abs(v) < 1e-12 ? '0' : d ? sci(v) : v.toFixed(2), x+19, y+17, p.ink, F10, 'center'); })); };
   mat(A, 4, '∂ⱼūᵢ', p.f); mat(S, 144, 'S̄ᵢⱼ', p.c); mat(Tm, 284, 'τᵢⱼ', p.eq, true);
   root.querySelector('.ecalc').textContent = `|S̄| = √(2 S̄ᵢⱼS̄ᵢⱼ) = ${sm.toFixed(3)} · ν_sgs = (${Cs.toFixed(3)} × ${DL.toFixed(3)})² × ${sm.toFixed(3)} = ${sci(nu)} · Π = ν_sgs|S̄|² = ${sci(nu*sm*sm)}${sm < 1e-9 ? ' · pure rotation has no strain, so the model does nothing' : ''} (C_s from block B's slider, Δ = π/10).`; },
  bind: null },
 Dy: { html: () => `<span class="eyebrow">How 𝒟 works</span><p>At every point the resolved field gives a measured L<sub>ij</sub> and a predicted M<sub>ij</sub> (per unit C<sub>s</sub>²). One number has to fit them all:</p>
   ${mt(`<msubsup><mi>C</mi><mi>s</mi><mn>2</mn></msubsup><mo>=</mo><mfrac><mrow><munder><mo>∑</mo><mtext>points</mtext></munder>${tc('--c-eq','<msub><mi>L</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>')}${tc('--c-rho','<msub><mi>M</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>')}</mrow><mrow><munder><mo>∑</mo><mtext>points</mtext></munder>${tc('--c-rho','<msub><mi>M</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><msub><mi>M</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>')}</mrow></mfrac>`)}
   <div class="eterms"><span>${sw('--c-eq')}L</span><span>Measured: the stress the eddies between Δ and Δ̂ really carry, from ū alone.</span>
   <span>${sw('--c-rho')}M</span><span>Predicted: what Smagorinsky at both levels says L should be, per unit C<sub>s</sub>².</span>
   <span>${sw('--c-w')}Σ / Σ</span><span>Least squares: the C<sub>s</sub>² that makes C<sub>s</sub>²M closest to L everywhere at once. Few points → noisy, even negative.</span></div>
   ${btns('Dy', ['1 point', '8 points', 'all 64 (line)', 'live 3D box'], HS.Dy)}<canvas class="hc" data-w="420" data-h="120"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), sel = HS.Dy; c.clearRect(0,0,c.W,c.H);
   let pts, a = 0, b = 0, txt;
   if (sel < 3){ const idx = sel === 0 ? [40] : sel === 1 ? [0,8,16,24,32,40,48,56] : [...Array(N1).keys()]; pts = idx.map(n => [M1[n], L1[n]]); idx.forEach(n => { a += L1[n]*M1[n]; b += M1[n]*M1[n]; });
     txt = `${idx.length} point${idx.length > 1 ? 's' : ''} on block 0's line: ΣLM = ${fx(a,4)}, ΣMM = ${fx(b,4)} → C_s² = ${(a/b).toFixed(3)}${a < 0 ? ' (negative: anti-diffusion, why one point is never used)' : ''}`; }
   else if (LS && LS.samp.length){ pts = LS.samp.map(s => [s[0], s[1]]); a = LS.LM; b = LS.MM; txt = `live 3D box, all 32³ points and all six ij: ⟨LM⟩ = ${sci(a)}, ⟨MM⟩ = ${sci(b)} → C_s² = ${(a/b).toFixed(4)}, C_s = ${Math.sqrt(Math.max(0, a/b)).toFixed(3)} (dots: xy component)`; }
   else { pts = []; txt = 'Open block B or C to start the live 3D box, then come back.'; }
   const mx = Math.max(1e-12, ...pts.map(q => Math.abs(q[0]))), lx = Math.max(1e-12, ...pts.map(q => Math.abs(q[1]))), X = m => 210+m/mx*190, Y = v => 60-v/lx*48;
   c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(20, 60); c.lineTo(400, 60); c.moveTo(210, 8); c.lineTo(210, 112); c.stroke();
   c.fillStyle = p.eq; pts.forEach(([m, v]) => { c.beginPath(); c.arc(X(m), Y(v), pts.length < 10 ? 4 : 2.2, 0, 7); c.fill(); });
   if (b > 0) line(c, [[X(-mx), Y(-mx*a/b)], [X(mx), Y(mx*a/b)]], p.rho, 2.4);
   label(c, 'M', 400, 74, p.rho, MATH, 'right'); label(c, 'L', 216, 18, p.eq, MATH);
   root.querySelector('.ecalc').textContent = txt; },
  bind: null },
 P: { html: () => `<span class="eyebrow">How 𝒫 works</span><p>One Runge–Kutta stage adds Δt × the right-hand side, then every Fourier mode loses its component along 𝐤:</p>
   ${mt(`${ub_k}<mo>←</mo>${tc('--c-u','<mo>(</mo><msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>−</mo><mfrac><mrow><msub><mi>k</mi><mi>i</mi></msub><msub><mi>k</mi><mi>j</mi></msub></mrow><msup><mi>k</mi><mn>2</mn></msup></mfrac><mo>)</mo>')}<mo>(</mo>${tc('--c-f','<msub><mover accent="true"><mi>u</mi><mo>‾</mo></mover><mrow><mi>j</mi><mo>,</mo><mi>𝐤</mi></mrow></msub>')}<mo>+</mo>${tc('--c-w','<mi>Δ</mi><mi>t</mi>')}<msub><mi>R</mi><mrow><mi>j</mi><mo>,</mo><mi>𝐤</mi></mrow></msub><mo>)</mo>`)}
   <div class="eterms"><span>${sw('--c-f')}ū + ΔtR</span><span>Advection, viscosity and −∂ⱼτᵢⱼ push the velocity; three such stages make one SSP-RK3 step.</span>
   <span>${sw('--c-u')}δ − kk/k²</span><span>Projection: removes the part along 𝐤, which is the only part that would compress the fluid. That removed part is the pressure gradient.</span>
   <span>${sw('--c-w')}Δt</span><span>Explicit: Δt ≤ 0.75 Δx / |ū|<sub>max</sub> (CFL), capped at 0.15 in Build.</span></div>
   ${btns('P', ['𝐤 = (1,0,0)', '(1,1,0)', '(1,2,2)', '(0,3,4)'], HS.P)}<canvas class="hc" data-w="300" data-h="180"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), k = [[1,0,0],[1,1,0],[1,2,2],[0,3,4]][HS.P], k2 = k[0]**2+k[1]**2+k[2]**2, ku = k[0]*UP[0]+k[1]*UP[1]+k[2]*UP[2], pu = UP.map((v,a) => v-ku/k2*k[a]);
   const V = {th: -0.6, ph: 0.38, s: 70, ox: 140, oy: 96}, o = proj(V,0,0,0), Q = v => proj(V, v[0], v[1], v[2]), kn = Math.sqrt(k2);
   c.clearRect(0,0,c.W,c.H);
   const K1 = Q(k.map(v => v/kn*1.1)); arrow(c, o[0], o[1], K1[0], K1[1], p.ink, 2); label(c, '𝐤', K1[0]+6, K1[1], p.ink, MATH);
   const U = Q(UP.map(v => v*1.4)); arrow(c, o[0], o[1], U[0], U[1], p.f, 2, true); label(c, 'ū', U[0]+6, U[1]+4, p.f, MATH);
   const Pq = Q(pu.map(v => v*1.4)); arrow(c, o[0], o[1], Pq[0], Pq[1], p.u, 3); label(c, '𝒫ū', Pq[0]+6, Pq[1]+12, p.u, MATH);
   c.setLineDash([3,3]); c.strokeStyle = p.rho; c.lineWidth = 1.4; c.beginPath(); c.moveTo(Pq[0], Pq[1]); c.lineTo(U[0], U[1]); c.stroke(); c.setLineDash([]);
   triad(c, V, 262, 150, p);
   root.querySelector('.ecalc').textContent = `ū_𝐤 = (${UP}) · 𝐤·ū = ${fx(ku,2)}, k² = ${k2} → remove ${fx(ku/k2,4)} × 𝐤 = (${k.map(v => fx(v*ku/k2,3)).join(', ')}) → 𝒫ū = (${pu.map(v => fx(v,3)).join(', ')}), and 𝐤·𝒫ū = ${fx(k[0]*pu[0]+k[1]*pu[1]+k[2]*pu[2],6)}.`; },
  bind: null }
};
Object.keys(HOW).forEach(k => HOW[k].bind = bindX(k));
this.ops = HOW;

// ===== Build: the 3D LES of the Taylor–Green vortex =====
const SC = hidpi($('sim')), VS = {th: -0.65, ph: 0.4, s: 105, ox: 182, oy: 205}; orbit($('sim'), VS);
let BS = null, running = false, paused = false, bModel = 2, bCs = .17, runHist = [], ghosts = [], specSnap = null, pts = new Int32Array(0), bSteps = 0, bRate = 0, bLastT = 0, solverMs = 0;
const LBL = () => ['no model', `Smagorinsky ${bCs.toFixed(2)}`, 'dynamic'][bModel];
function pickPts(){ const w = BS.wmag, T = w.length; let mx = 0; for (let k=0;k<T;k++) if (w[k] > mx) mx = w[k]; if (!mx) return;
  const hist = new Int32Array(100); for (let k=0;k<T;k++) hist[Math.min(99, (w[k]/mx*100)|0)]++;
  let acc = 0, b = 99; while (b > 0 && acc + hist[b] < T*.04){ acc += hist[b]; b--; }
  const thr = (b+1)/100*mx, l = []; for (let k=0;k<T;k++) if (w[k] >= thr) l.push(k); pts = Int32Array.from(l); }
function bInit(saveGhost){
  if (saveGhost && BS && BS.t > 1) ghosts = [{ label: BS.lbl, hist: runHist, spec: specSnap || Array.from(BS.Ek) }, ...ghosts].slice(0,3);
  if (!BS){ BS = mkLES(32, 1/1600); BS.cfl = .75; BS.dtMax = .15; }
  BS.model = bModel; BS.Cs = bCs; BS.lbl = LBL(); BS.initTGV(); runHist = [[0, BS.dKdt, 0]]; specSnap = null; pts = new Int32Array(0); bSteps = 0;
  K.qa('#wrles-models .b').forEach(b => b.classList.toggle('pri', +b.dataset.m === bModel)); bNote(); }
function bNote(){ $('bnote').textContent = bModel === 1 ? 'C_s is used as typed (releasing the slider restarts the run)' : bModel === 2 ? 'dynamic: C_s is measured each step; moving the slider switches to Smagorinsky' : 'no model: nothing drains energy at k_c'; }
K.qa('#wrles-models .b').forEach(b => b.onclick = () => { bModel = +b.dataset.m; bInit(true); if (reduce) drawBuild(); });
const bcsIn = $('bcs');
bcsIn.oninput = () => { bCs = +bcsIn.value; $('bcsv').textContent = bCs.toFixed(2); if (BS && BS.model === 1) $('bnote').textContent = `release to restart · at this C_s the model would now drain ${sci(BS.eSgs*(bCs/BS.Cs)**2)} instead of ${sci(BS.eSgs)}`; };
bcsIn.onchange = () => { bModel = 1; bInit(true); if (reduce) drawBuild(); };
$('restart').onclick = () => { bInit(true); if (reduce) drawBuild(); };
$('pause').onclick = e => { paused = !paused; e.target.textContent = paused ? 'Play' : 'Pause'; };
$('plus').onclick = () => { if (!BS || !running) return; const t1 = BS.t+1; while (BS.t < t1 && BS.t < 14){ if (BS.advance(1e9, true)) afterStep(); } drawBuild(); };
function afterStep(){ runHist.push([BS.t, BS.dKdt, BS.eSgs]); bSteps++; pickPts(); if (!specSnap && BS.t >= 9) specSnap = Array.from(BS.Ek); }
function drawBuild(){
  const c = SC, W = c.W, H = c.H, p = P(); c.clearRect(0,0,W,H); if (!BS) return;
  // 3D: points of strong vorticity, coloured by depth
  box(c, VS, 1, 1, 1, p.mut, 1); const N = 32, sc = 2/N;
  const items = []; for (let q=0;q<pts.length;q++){ const k = pts[q], x = k%N, y = ((k/N)|0)%N, z = (k/N/N)|0, P3 = proj(VS, -1+(x+.5)*sc, -1+(z+.5)*sc, -1+(y+.5)*sc); items.push(P3); }
  items.sort((a,b) => a[2]-b[2]); c.fillStyle = p.f; items.forEach(([X, Y, d]) => { c.globalAlpha = .25+.6*clamp((d+1.6)/3.2, 0, 1); c.fillRect(X-1.3, Y-1.3, 2.6, 2.6); }); c.globalAlpha = 1;
  triad(c, VS, 30, 370, p);
  label(c, 'strongest 4% of |ω̄| (drag to rotate)', 14, 18, p.mut, F11); label(c, `${N}³ points, periodic 2π box`, 14, 34, p.mut, F10);
  // spectrum
  const sx0 = 410, sx1 = 740, sy0 = 24, sy1 = 176, Xk = k => sx0+Math.log10(k)/Math.log10(12)*(sx1-sx0), Ye = e => sy1-(Math.log10(Math.max(e, 1e-12))+6.5)/6*(sy1-sy0);
  label(c, 'energy spectrum E(k)', sx0, 14, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(sx0, sy0); c.lineTo(sx0, sy1); c.lineTo(sx1, sy1); c.stroke();
  [1,2,5,10].forEach(k => label(c, String(k), Xk(k), sy1+13, p.mut, F10, 'center')); label(c, 'k', sx1+6, sy1+4, p.mut, MATH);
  c.strokeStyle = p.cs; c.lineWidth = 1.6; c.beginPath(); c.moveTo(Xk(BS.kc), sy0); c.lineTo(Xk(BS.kc), sy1); c.stroke(); label(c, 'k_c', Xk(BS.kc)+3, sy0+10, p.cs, F10);
  const specLine = (E, col, lw, a) => { const q = []; for (let k=1;k<=BS.kc;k++) if (E[k] > 3e-7) q.push([Xk(k), Ye(E[k])]); c.globalAlpha = a; line(c, q, col, lw); c.globalAlpha = 1; };
  ghosts.forEach((g,j) => { specLine(g.spec, p.tau, 1.3, .55-.15*j); const e = g.spec[BS.kc]; if (e > 0) label(c, g.label, Xk(BS.kc)-4, Ye(e)-4-10*j, p.tau, F10, 'right'); });
  specLine(BS.Ek, p.f, 2.6, 1);
  const e3 = BS.Ek[3]; if (e3 > 0) line(c, [[Xk(2), Ye(e3*Math.pow(2/3,-5/3))], [Xk(10), Ye(e3*Math.pow(10/3,-5/3))]], p.w, 1.3, true); label(c, 'k^−5/3', Xk(6), Ye(e3*Math.pow(2,-5/3))-6, p.w, F10);
  const pile = BS.Ek[BS.kc-1]/Math.max(1e-12, BS.Ek[BS.kc-4]); if (pile > 1 && BS.t > 3) label(c, 'pile-up at k_c', Xk(BS.kc)-6, Ye(BS.Ek[BS.kc-1])-14, p.nu, B11, 'right');
  // dissipation history
  const dx0 = 410, dx1 = 740, dy0 = 228, dy1 = 370, Xt = t => dx0+(dx1-dx0)*t/14, Yd = v => dy1-(dy1-dy0)*v/.02;
  label(c, 'dissipation −dK/dt (shaded: share taken by the model)', dx0, 216, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(dx0, dy0); c.lineTo(dx0, dy1); c.lineTo(dx1, dy1); c.stroke();
  [0,.01,.02].forEach(v => label(c, String(v), dx0-4, Yd(v)+4, p.mut, F10, 'right')); [0,4,8,12].forEach(t => label(c, String(t), Xt(t), dy1+13, p.mut, F10, 'center')); label(c, 't', dx1+6, dy1+4, p.mut, MATH);
  ghosts.forEach((g,j) => { c.globalAlpha = .5-.13*j; line(c, g.hist.map(([t, d]) => [Xt(t), Yd(d)]), p.tau, 1.3); c.globalAlpha = 1; const l = g.hist[g.hist.length-1]; label(c, g.label, Xt(l[0])+3, Yd(l[1])-3, p.tau, F10); });
  if (runHist.length > 1){ c.beginPath(); runHist.forEach(([t, , e], i) => i ? c.lineTo(Xt(t), Yd(e)) : c.moveTo(Xt(t), Yd(e))); c.lineTo(Xt(runHist[runHist.length-1][0]), dy1); c.lineTo(Xt(0), dy1); c.closePath(); c.fillStyle = p.tau; c.globalAlpha = .2; c.fill(); c.globalAlpha = 1;
    line(c, runHist.map(([t, d]) => [Xt(t), Yd(d)]), p.u, 2.6); }
  c.fillStyle = p.eq; c.beginPath(); c.arc(Xt(9), Yd(.0127), 5, 0, 7); c.fill(); label(c, 'DNS peak ≈ 0.0127', Xt(9)+8, Yd(.0127)-6, p.eq, F10);
  let mx = 0, tp = 0; runHist.forEach(([t, d]) => { if (d > mx){ mx = d; tp = t; } });
  const sg = BS.dKdt > 0 ? BS.eSgs/BS.dKdt : 0, cs = BS.model === 2 ? Math.sqrt(BS.Cs2) : BS.model === 1 ? BS.Cs : 0;
  $('bstat').textContent = `${BS.lbl} · t = ${BS.t.toFixed(2)} · K = ${BS.K.toFixed(4)} · −dK/dt = ${BS.dKdt.toFixed(5)} (model ${(sg*100).toFixed(0)}%) · C_s = ${cs.toFixed(3)} · peak so far ${mx.toFixed(4)} at t = ${tp.toFixed(1)} · ${bRate.toFixed(1)} steps/s, solver ${solverMs.toFixed(1)} ms/frame, largest chunk ${BS.chunkMax().toFixed(1)} ms${BS.t >= 14 ? ' · finished: Restart or switch model' : ''}`;
}

// ===== Parallelize: slabs or pencils =====
const DC = hidpi($('decomp')); let dec = 'slab', decT = 0, decLast = null;
const npIn = $('np'), nnIn = $('nn');
function face(c, V, b, n, col, alpha){ const [x0,x1,y0,y1,z0,z1] = b, cx = (x0+x1)/2, cy = (y0+y1)/2, cz = (z0+z1)/2, o = proj(V,0,0,0)[2], nd = proj(V, ...n)[2]-o; if (nd <= 0) return;
  const ax = n[0] ? 0 : n[1] ? 1 : 2, s = n[ax] > 0 ? 1 : 0, lo = [x0,y0,z0], hi = [x1,y1,z1], fixed = s ? hi[ax] : lo[ax], others = [0,1,2].filter(a => a !== ax);
  const corner = (u, v) => { const q = [0,0,0]; q[ax] = fixed; q[others[0]] = u ? hi[others[0]] : lo[others[0]]; q[others[1]] = v ? hi[others[1]] : lo[others[1]]; return proj(V, ...q); };
  const P4 = [corner(0,0), corner(1,0), corner(1,1), corner(0,1)]; c.beginPath(); P4.forEach(([x,y],i) => i ? c.lineTo(x,y) : c.moveTo(x,y)); c.closePath(); c.globalAlpha = alpha; c.fillStyle = col; c.fill(); c.globalAlpha = 1; c.stroke(); }
function drawDecomp(tm){
  const dt = decLast === null ? 0 : Math.min(100, tm-decLast); decLast = tm; if (!reduce) decT += dt/1000;
  const c = DC, p = P(), V = {th: -0.6, ph: 0.42, s: 62, ox: 170, oy: 120}; c.clearRect(0,0,c.W,c.H);
  const phase = Math.floor(decT/2.6) % 2, n = 4, pieces = [];
  for (let a=0;a<n;a++) for (let b=0;b<(dec === 'slab' ? 1 : n);b++){ const s = i => [-1+2*i/n, -1+2*(i+1)/n];
    let bx; if (dec === 'slab') bx = phase ? [-1,1, ...s(a), -1,1] : [-1,1, -1,1, ...s(a)];
    else bx = phase ? [...s(a), -1,1, ...s(b)] : [-1,1, ...s(a), ...s(b)];
    pieces.push({ bx, me: a === 1 && b === (dec === 'slab' ? 0 : 2), d: proj(V, (bx[0]+bx[1])/2, (bx[2]+bx[3])/2, (bx[4]+bx[5])/2)[2] }); }
  pieces.sort((x,y) => x.d-y.d).forEach(({bx, me}) => { c.strokeStyle = me ? p.acc : p.rule; c.lineWidth = me ? 1.6 : 1; [[1,0,0],[-1,0,0],[0,1,0],[0,-1,0],[0,0,1],[0,0,-1]].forEach(nn => face(c, V, bx, nn, me ? p.acc : p.panel, me ? .55 : .9)); });
  const ax = dec === 'slab' ? (phase ? 'x and z' : 'x and y') : (phase ? 'y' : 'x');
  label(c, `${dec === 'slab' ? '4 slabs' : '16 pencils'}: each rank holds whole lines along ${ax}`, 10, c.H-26, p.ink, F10);
  label(c, `every ${2.6}s an all-to-all transpose swaps the layout`, 10, c.H-12, p.mut, F10);
}
function decUpdate(){ const Pn = 2**+npIn.value, N = 2**+nnIn.value, pts3 = N**3, mem = pts3*200/Pn/2**30, maxP = dec === 'slab' ? N : N*N, legal = Pn <= maxP, fits = mem <= 4;
  $('npv').textContent = Pn.toLocaleString('en-US'); $('nnv').textContent = N;
  K.qa('#wrles-slab, #wrles-pencil').forEach(b => b.classList.toggle('pri', b.id === 'wrles-' + dec));
  const re = Math.pow(pts3/NWR(1), 7/13), msg = dec === 'slab' ? Pn-1 : 2*(Math.round(Math.sqrt(Pn))-1), fb = $('decfb');
  const head = `${N}³ = ${sci(pts3)} points (a wall-resolved surface near Re ≈ ${sci(re)}), ${Pn.toLocaleString('en-US')} ranks, ${dec}s: ${mem < 1 ? (mem*1024).toFixed(0) + ' MB' : mem.toFixed(1) + ' GB'} per rank, each transpose talks to ${msg.toLocaleString('en-US')} other ranks.`;
  if (!legal){ fb.className = 'fb bad'; fb.textContent = `${head} Not possible: ${dec}s allow at most ${maxP.toLocaleString('en-US')} ranks (${dec === 'slab' ? 'one plane each, P ≤ N' : 'one line each, P ≤ N²'}).`; return; }
  if (!fits){ fb.className = 'fb bad'; fb.textContent = `${head} Too much memory: add ranks.`; return; }
  if (dec === 'pencil' && Pn >= 65536 && N >= 4096){ fb.className = 'fb good'; fb.textContent = `✓ ${head} Pencils scale to N² ranks; slabs would have stopped at ${N.toLocaleString('en-US')}. This is how P3DFFT and 2DECOMP run spectral turbulence codes on 10⁵–10⁶ cores.`; K.done('parallel'); return; }
  fb.className = 'fb'; fb.textContent = `${head} Fits, but the goal is N = 4096 on at least 65 536 ranks.`; }
$('slab').onclick = () => { dec = 'slab'; decUpdate(); if (reduce) drawDecomp(0); }; $('pencil').onclick = () => { dec = 'pencil'; decUpdate(); if (reduce) drawDecomp(0); };
npIn.oninput = decUpdate; nnIn.oninput = decUpdate; decUpdate();

function drawLearn(tm){
  if (openB === '0') drawOps(tm);
  if (openB === 'A') drawA(tm);
  if (openB === 'B' || openB === 'C'){ if (!reduce) learnStep(); if (openB === 'B') drawB(tm); else { drawC(); drawWall(); } }
}
drawOps(0);
return {
  frame(tm, stp){
    if (stp === 0) drawLearn(tm);
    if (stp === 1 && BS){ if (running && !paused && BS.t < 14 && !reduce){ const t0 = now(); let n = 0; while (now()-t0 < 7.5){ const d = BS.advance(7.5-(now()-t0), true); if (d){ n++; afterStep(); } else break; } solverMs = now()-t0;
        const tw = performance.now(); if (tw-bLastT > 1000){ bRate = bSteps/((tw-bLastT)/1000); bSteps = 0; bLastT = tw; } }
      drawBuild(); }
    if (stp === 2) drawDecomp(tm);
  },
  onStep(stp){ if (stp === 2){ drawDecomp(0); decUpdate(); } if (stp === 1 && BS) drawBuild(); },
  onBlock(key){ openB = key; if (key === 'B' || key === 'C') ensureLS(); if (key === 'A' && !aRms) fieldA(); if (reduce) drawLearn(0); },
  buildReset(){ running = false; bInit(false); drawBuild(); },
  buildStart(){ running = true; bLastT = performance.now(); bSteps = 0; if (reduce){ while (BS.t < 3) if (BS.advance(1e9, true)) afterStep(); drawBuild(); } },
};
 }
});
})();
