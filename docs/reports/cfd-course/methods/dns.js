// Direct numerical simulation (pseudo-spectral, Fourier): nothing modelled. See ../README.md for the spec; lbm.js is the reference module.
// The Build solver is a real 3D pseudo-spectral Navier–Stokes solver: 32³ Fourier modes, 2/3 dealiasing, projection,
// rotational nonlinear term, Williamson low-storage RK3 with an exact viscous integrating factor. It runs the Taylor–Green vortex.

// ---------- a compact radix-2 complex FFT, batched along one axis of a 3D array ----------
function dnsPlan(n){ const lg = Math.log2(n)|0, rev = new Uint16Array(n), cs = new Float64Array(n/2), sn = new Float64Array(n/2), K = Math.floor(n/3);
  for (let i=0;i<n;i++){ let r=0; for (let b=0;b<lg;b++) r |= ((i>>b)&1) << (lg-1-b); rev[i]=r; }
  for (let i=0;i<n/2;i++){ cs[i]=Math.cos(2*Math.PI*i/n); sn[i]=Math.sin(2*Math.PI*i/n); }
  const kept = [0, K+1, n-K, n], zk = []; for (let z=0;z<n;z++) if (z <= K || z >= n-K) zk.push(z*n*n);
  return {n, rev, cs, sn, K, all: [0, n], kept, sq: [0, n*n], zAll: [...Array(n)].map((_,z) => z*n*n), zKept: zk}; }
// transform every line along one axis: sl = stride along the line, sb = stride between lines done together, seg = ranges of lines, outer = plane offsets
function dnsFFTb(P, re, im, sgn, sl, sb, seg, outer){ const {n, rev, cs, sn} = P, ns = seg.length;
  for (let oi=0; oi<outer.length; oi++){ const o = outer[oi];
    for (let j=0;j<n;j++){ const r = rev[j]; if (r <= j) continue; const oa = o+j*sl, ob = o+r*sl;
      for (let g=0; g<ns; g+=2) for (let i=seg[g]; i<seg[g+1]; i++){ const a = oa+i*sb, b = ob+i*sb; let t = re[a]; re[a] = re[b]; re[b] = t; t = im[a]; im[a] = im[b]; im[b] = t; } }
    for (let h=1, tw=n>>1; h<n; h<<=1, tw>>=1) for (let s=0;s<n;s+=2*h) for (let k=0;k<h;k++){
      const c = cs[k*tw], si = sgn*sn[k*tw], oa = o+(s+k)*sl, ob = oa+h*sl;
      for (let g=0; g<ns; g+=2) for (let i=seg[g]; i<seg[g+1]; i++){ const a = oa+i*sb, b = ob+i*sb, br = re[b], bi = im[b], xr = br*c - bi*si, xi = br*si + bi*c;
        re[b] = re[a]-xr; im[b] = im[a]-xi; re[a] += xr; im[a] += xi; } } } }
// 3D FFT (sg = -1 forward, +1 inverse, unscaled). trunc skips lines that are all zero (inverse) or not needed (forward) after the 2/3 rule
function dnsFFT3(P, re, im, sg, trunc){ const n = P.n, zs = trunc ? P.zKept : P.zAll;
  if (sg > 0) { dnsFFTb(P, re, im, sg, 1, n, trunc ? P.kept : P.all, zs); dnsFFTb(P, re, im, sg, n, 1, P.all, zs); dnsFFTb(P, re, im, sg, n*n, 1, P.sq, [0]); }
  else { dnsFFTb(P, re, im, sg, n*n, 1, P.sq, [0]); dnsFFTb(P, re, im, sg, n, 1, P.all, zs); dnsFFTb(P, re, im, sg, 1, n, trunc ? P.kept : P.all, zs); } }
const dnsTG = (x, y, z) => [Math.sin(x)*Math.cos(y)*Math.cos(z), -Math.cos(x)*Math.sin(y)*Math.cos(z), 0];

// ---------- the solver: incompressible Navier–Stokes in a 2π-periodic box, pseudo-spectral ----------
function dnsMake(n){
  const {abs, exp, sqrt, pow, min, max} = Math; // local copies: hot loops avoid global lookups
  const M = n*n*n, P = dnsPlan(n), K = P.K, F = m => new Float64Array(m || M), wrap = i => i > n/2 ? i-n : i;
  // only the kept modes |k_x|, |k_y|, |k_z| <= N/3 are stored: compact index j -> grid index KEEP[j]
  const keep = []; for (let z=0;z<n;z++) for (let y=0;y<n;y++) for (let x=0;x<n;x++) if (abs(wrap(x))<=K && abs(wrap(y))<=K && abs(wrap(z))<=K) keep.push((z*n+y)*n+x);
  const nk = keep.length, KEEP = Int32Array.from(keep), NEG = new Int32Array(nk), KX = F(nk), KY = F(nk), KZ = F(nk), K2 = F(nk), SH = new Uint8Array(nk);
  for (let j=0;j<nk;j++){ const q = KEEP[j], x = q%n, y = ((q/n)|0)%n, z = (q/(n*n))|0;
    KX[j] = wrap(x); KY[j] = wrap(y); KZ[j] = wrap(z); K2[j] = KX[j]**2+KY[j]**2+KZ[j]**2; SH[j] = Math.round(sqrt(K2[j]));
    NEG[j] = (((n-z)%n)*n + (n-y)%n)*n + (n-x)%n; }
  const C3 = () => [F(nk),F(nk),F(nk)];
  const S = { n, M, K, nk, nu: 0.01, t: 0, dt: 0.1, steps: 0, stage: 0, cfl: 0.9, umax: 1, hist: [],
    vr: C3(), vi: C3(), qr: C3(), qi: C3(), nr: C3(), ni: C3(), ar: [F(),F(),F()], ai: [F(),F(),F()], W: [F(),F(),F()],
    em: C3(), ep: C3(), spec: F(Math.ceil(sqrt(3)*K)+2) };
  const A = [0, -5/9, -153/128], B = [1/3, 15/16, 8/15], C = [0, 1/3, 3/4]; // Williamson (1980) low-storage RK3
  // integrating factors for this step: em[s] = e^{-nu k^2 c_s dt}; em[0] = e^{-nu k^2 dt} closes the step; ep = 1/em
  function factors(){ const g0 = S.nu*S.dt; for (let j=0;j<nk;j++){ const g = g0*K2[j];
    S.em[0][j] = exp(-g); S.em[1][j] = exp(-g*C[1]); S.em[2][j] = exp(-g*C[2]); S.ep[1][j] = 1/S.em[1][j]; S.ep[2][j] = 1/S.em[2][j]; } }
  // FFT output a0 = X + iY, a1 = Z  ->  spectral X, Y, Z on the kept modes, projected with P_ij, times sc (and the factor ep)
  function unpack(sc, ep){ const [a0r, a1r] = S.ar, [a0i, a1i] = S.ai, [xr,yr,zr] = S.nr, [xi,yi,zi] = S.ni;
    for (let j=0;j<nk;j++){ const q = KEEP[j], g = NEG[j], s = ep ? sc*ep[j] : sc, Ar = a0r[q], Ai = a0i[q], Br = a0r[g], Bi = a0i[g];
      const nxr = .5*(Ar+Br), nxi = .5*(Ai-Bi), nyr = .5*(Ai+Bi), nyi = -.5*(Ar-Br), nzr = .5*(a1r[q]+a1r[g]), nzi = .5*(a1i[q]-a1i[g]);
      const kx = KX[j], ky = KY[j], kz = KZ[j], k2 = K2[j] || 1, pr = (kx*nxr+ky*nyr+kz*nzr)/k2, pi = (kx*nxi+ky*nyi+kz*nzi)/k2;
      xr[j] = (nxr-kx*pr)*s; xi[j] = (nxi-kx*pi)*s; yr[j] = (nyr-ky*pr)*s; yi[j] = (nyi-ky*pi)*s; zr[j] = (nzr-kz*pr)*s; zi[j] = (nzi-kz*pi)*s; } }
  S.init = function(nu, field){ S.nu = nu; S.t = 0; S.steps = 0; S.stage = 0; S.sub = 0; const [a0r, a1r] = S.ar, [a0i, a1i] = S.ai, h = 2*Math.PI/n;
    for (let z=0;z<n;z++) for (let y=0;y<n;y++) for (let x=0;x<n;x++){ const q = (z*n+y)*n+x, u = (field || dnsTG)(x*h, y*h, z*h); a0r[q] = u[0]; a0i[q] = u[1]; a1r[q] = u[2]; a1i[q] = 0; }
    dnsFFT3(P, a0r, a0i, -1, true); dnsFFT3(P, a1r, a1i, -1, true); unpack(1/M, null);
    for (let c=0;c<3;c++){ S.vr[c].set(S.nr[c]); S.vi[c].set(S.ni[c]); S.qr[c].fill(0); S.qi[c].fill(0); }
    S.diag(); S.hist = [[0, S.E, S.eps, S.eta]]; S.vortField(); };
  // one RK stage = 8 sub-tasks of about 1 ms each (pack, 3 inverse FFTs, product, 2 forward FFTs, unpack + update),
  // so a caller with a frame budget can stop between any two of them
  function pack(s){ const [ur,vr,wr] = S.vr, [ui,vi,wi] = S.vi, [a0r,a1r,a2r] = S.ar, [a0i,a1i,a2i] = S.ai, em = s ? S.em[s] : null;
    for (let c=0;c<3;c++){ S.ar[c].fill(0); S.ai[c].fill(0); }
    for (let j=0;j<nk;j++){ const q = KEEP[j], e = em ? em[j] : 1, kx = KX[j], ky = KY[j], kz = KZ[j];
      const Ur = ur[j]*e, Ui = ui[j]*e, Vr = vr[j]*e, Vi = vi[j]*e, Wr = wr[j]*e, Wi = wi[j]*e;
      const oxr = -(ky*Wi-kz*Vi), oxi = ky*Wr-kz*Vr, oyr = -(kz*Ui-kx*Wi), oyi = kz*Ur-kx*Wr, ozr = -(kx*Vi-ky*Ui), ozi = kx*Vr-ky*Ur; // w = i k x û
      a0r[q] = Ur-Vi; a0i[q] = Ui+Vr; a1r[q] = Wr-oxi; a1i[q] = Wi+oxr; a2r[q] = oyr-ozi; a2i[q] = oyi+ozr; } } // two real fields per complex FFT
  function product(s){ const [a0r,a1r,a2r] = S.ar, [a0i,a1i,a2i] = S.ai; let um = 0; const [W0, W1, W2] = S.W, first = s === 0;
    for (let q=0;q<M;q++){ const ux = a0r[q], uy = a0i[q], uz = a1r[q], wx = a1i[q], wy = a2r[q], wz = a2i[q];
      if (first) { W0[q] = wx; W1[q] = wy; W2[q] = wz; const m = abs(ux)+abs(uy)+abs(uz); if (m > um) um = m; }
      a0r[q] = uy*wz-uz*wy; a0i[q] = uz*wx-ux*wz; a1r[q] = ux*wy-uy*wx; a1i[q] = 0; }   // u × w on the grid
    if (first) S.umax = um; }
  function update(s){ unpack(1/M, s ? S.ep[s] : null);
    if (s === 0) { S.dt = min(0.1, S.cfl*sqrt(3)/(K*max(S.umax, 1e-6))); factors(); }
    const dt = S.dt, a = A[s], b = B[s];
    for (let c=0;c<3;c++){ const qr = S.qr[c], qi = S.qi[c], vr = S.vr[c], vi = S.vi[c], nr = S.nr[c], ni = S.ni[c];
      for (let j=0;j<nk;j++){ qr[j] = a*qr[j]+dt*nr[j]; qi[j] = a*qi[j]+dt*ni[j]; vr[j] += b*qr[j]; vi[j] += b*qi[j]; } }
    S.stage = (s+1)%3;
    if (S.stage === 0) { const e = S.em[0]; for (let c=0;c<3;c++){ const vr = S.vr[c], vi = S.vi[c]; for (let j=0;j<nk;j++){ vr[j] *= e[j]; vi[j] *= e[j]; } }
      S.t += dt; S.steps++; S.diag(); S.hist.push([S.t, S.E, S.eps, S.eta]); } }
  const TASKS = [s => pack(s), () => dnsFFT3(P, S.ar[0], S.ai[0], 1, true), () => dnsFFT3(P, S.ar[1], S.ai[1], 1, true), () => dnsFFT3(P, S.ar[2], S.ai[2], 1, true),
    s => product(s), () => dnsFFT3(P, S.ar[0], S.ai[0], -1, true), () => dnsFFT3(P, S.ar[1], S.ai[1], -1, true), s => update(s)];
  S.sub = 0; S.nsub = TASKS.length;
  S.work = function(){ TASKS[S.sub](S.stage); S.sub = (S.sub+1) % TASKS.length; };       // one sub-task
  S.stageStep = function(){ do S.work(); while (S.sub !== 0); };                            // one whole RK stage
  // vorticity on the grid for drawing at t = 0 (later the stage-0 product step refreshes it)
  S.vortField = function(){ pack(0); for (let c=0;c<3;c++) dnsFFT3(P, S.ar[c], S.ai[c], 1, true); product(0); };
  // E = ½<u_i u_i>, enstrophy Z = ½<w_i w_i> = Σ k²·½|û|², eps = 2 nu Z, shell spectrum E(k), Kolmogorov eta
  S.diag = function(){ let E = 0, Z = 0; const sp = S.spec, [ur,vr,wr] = S.vr, [ui,vi,wi] = S.vi; sp.fill(0);
    for (let j=0;j<nk;j++){ const e = .5*(ur[j]*ur[j]+ui[j]*ui[j]+vr[j]*vr[j]+vi[j]*vi[j]+wr[j]*wr[j]+wi[j]*wi[j]); E += e; Z += K2[j]*e; sp[SH[j]] += e; }
    S.E = E; S.Z = Z; S.eps = 2*S.nu*Z; S.eta = pow(S.nu**3/max(S.eps, 1e-12), .25); };
  return S;
}
// −dE/dt by central differences of the energy history, next to 2νΩ at the same time
function dnsDEdt(H, m){ if (m < 1 || m >= H.length-1) return null; return -(H[m+1][1]-H[m-1][1])/(H[m+1][0]-H[m-1][0]); }
// finer-grid reference ε(t) for the same Taylor–Green runs, computed offline with this very solver (64³ for Re ≤ 200, 128³ above), every 0.25 time units
const DNS_REF = {
 50: [64, [0.015,0.01465,0.01447,0.01442,0.01449,0.01465,0.01486,0.0151,0.01532,0.01551,0.01563,0.01567,0.01561,0.01546,0.01522,0.01489,0.0145,0.01404,0.01354,0.013,0.01243,0.01185,0.01125,0.01066,0.01007,0.009492,0.008929,0.008385,0.007863,0.007363,0.006889,0.00644,0.006016,0.005618,0.005244,0.004894,0.004567,0.004263,0.003979,0.003714,0.003469,0.00324,0.003028,0.002831,0.002648,0.002478,0.002321,0.002174,0.002038]],
 100: [64, [0.0075,0.007436,0.007463,0.007574,0.007769,0.008044,0.008392,0.008804,0.009266,0.00976,0.01026,0.01076,0.01122,0.01164,0.01201,0.01232,0.01258,0.01277,0.0129,0.01296,0.01297,0.0129,0.01277,0.01257,0.0123,0.01197,0.01158,0.01116,0.0107,0.01021,0.009712,0.009209,0.008708,0.008215,0.007736,0.007274,0.006831,0.006411,0.006012,0.005637,0.005285,0.004956,0.004648,0.004361,0.004094,0.003846,0.003615,0.0034,0.0032]],
 200: [64, [0.00375,0.003747,0.00379,0.003882,0.004024,0.004219,0.004469,0.004775,0.005138,0.00555,0.006006,0.006497,0.007013,0.007547,0.008098,0.008664,0.009247,0.009844,0.01045,0.01106,0.01163,0.01213,0.01251,0.01273,0.01279,0.01271,0.01251,0.01223,0.0119,0.01152,0.0111,0.01065,0.01019,0.009725,0.009263,0.008818,0.008402,0.008019,0.007671,0.007349,0.007042,0.00674,0.006439,0.006135,0.00583,0.005526,0.005227,0.004935,0.004653]],
 400: [128, [0.001875,0.00188,0.00191,0.001965,0.002048,0.002161,0.002308,0.002491,0.002713,0.002975,0.003278,0.003621,0.004003,0.004426,0.004898,0.005433,0.006046,0.006747,0.007531,0.008362,0.009158,0.009821,0.0103,0.0106,0.01078,0.0109,0.01095,0.01095,0.01092,0.01085,0.01077,0.0107,0.01068,0.01077,0.01091,0.01098,0.01087,0.0106,0.01024,0.009827,0.009355,0.008861,0.008427,0.008059,0.007716,0.00737,0.007002,0.006601,0.006165]],
 800: [128, [0.0009375,0.0009419,0.0009586,0.0009886,0.001033,0.001094,0.001173,0.001272,0.001395,0.001543,0.001718,0.001923,0.00216,0.002432,0.002754,0.003145,0.003636,0.004243,0.004954,0.005707,0.0064,0.006946,0.007345,0.007677,0.008008,0.008348,0.008679,0.009014,0.009315,0.009538,0.009869,0.01045,0.01109,0.01155,0.01181,0.0119,0.0119,0.01159,0.01103,0.01051,0.01014,0.009849,0.009612,0.009346,0.008984,0.008506,0.007947,0.007413,0.007005]] };
const DNS_RES = [50, 100, 200, 400, 800, 1600];

// ---------- small DFT helpers for the worked examples ----------
function dnsDFT(u){ const N = u.length, re = new Float64Array(N), im = new Float64Array(N);
  for (let k=0;k<N;k++){ let a=0, b=0; for (let n=0;n<N;n++){ const th = -2*Math.PI*k*n/N; a += u[n]*Math.cos(th); b += u[n]*Math.sin(th); } re[k] = a/N; im[k] = b/N; } return [re, im]; }
function dnsIDFT(re, im){ const N = re.length, u = new Float64Array(N);
  for (let n=0;n<N;n++){ let a=0; for (let k=0;k<N;k++){ const th = 2*Math.PI*k*n/N; a += re[k]*Math.cos(th) - im[k]*Math.sin(th); } u[n] = a; } return u; }
const dnsKw = (k, N) => k <= N/2 ? k : k-N;
// Pope (2000) model spectrum, with U = L = ε = 1 so ν = 1/Re and η = Re^{-3/4}
function dnsPope(k, Re){ const eta = Math.pow(Re, -0.75), kL = k, ke = k*eta;
  const fL = Math.pow(kL/Math.sqrt(kL*kL+6.78), 5/3+2), fe = Math.exp(-5.2*(Math.pow(Math.pow(ke,4)+Math.pow(0.4,4), .25)-0.4)); return 1.5*Math.pow(k, -5/3)*fL*fe; }

// ---------- MathML shorthands ----------
const dT = t => t ? ` data-t="${t}"` : '';
const mi = (x, t) => `<mi${dT(t)}>${x}</mi>`, mo = x => `<mo>${x}</mo>`, mn = x => `<mn>${x}</mn>`, mrow = (x, t) => `<mrow${dT(t)}>${x}</mrow>`;
const msub = (b, s, t) => `<msub${dT(t)}>${b}${s}</msub>`, msup = (b, s, t) => `<msup${dT(t)}>${b}${s}</msup>`, frac = (a, b, t) => `<mfrac${dT(t)}>${mrow(a)}${mrow(b)}</mfrac>`;
const hat = b => `<mover accent="true">${b}<mo>^</mo></mover>`;
const ub = (inner, op, lbl) => `<munder><munder><mrow>${inner}</mrow><mo stretchy="true">⏟</mo></munder><mtext data-t="${op}" class="opl">${lbl}</mtext></munder>`;
const Ix = l => mi(l, 'alpha'), Ij = (...l) => mrow(l.map(Ix).join(''));
const U = l => msub(mi('u'), Ix(l), 'u'), UH = l => msub(hat(mi('u')), Ix(l), 'uh'), KJ = l => msub(mi('k'), Ix(l), 'kj'), OM = l => msub(mi('ω'), Ix(l), 'om');
const NH = l => msub(hat(mi('N')), Ix(l), 'Nl'), PIJ = (a, b) => msub(mi('P'), Ij(a, b), 'P'), DEL = (a, b) => msub(mi('δ'), Ij(a, b), 'delta'), DJ = l => msub(mo('∂'), Ix(l), 'grad');
const BK = mi('𝐤', 'k'), BX = mi('𝐱', 'x'), K2 = msup(mi('k'), mn(2), 'k2'), NU = mi('ν', 'nu'), TT = mi('t', 't'), DTT = mrow(mi('Δ')+mi('t'), 'dt'), DTd = msub(mo('∂'), mi('t', 't'), 'grad');
const FF = mi('𝓕', 'F'), FI = msup(mi('𝓕'), mrow(mo('−')+mn(1)), 'F'), PP = mi('p', 'p'), EPS = mi('ε', 'eps'), ETA = mi('η', 'eta'), NN = mi('N', 'N'), RE = mi('Re', 'Re');
const KMAX = msub(mi('k'), mtx('max'), 'kmax'), VV = mi('V', 'V'), DD = mrow(mi('i')+KJ('j'), 'D');
function mtx(s){ return `<mtext>${s}</mtext>`; }
const EXPV = msup(mi('e'), mrow(mo('−')+NU+K2+DTT), 'V');
const KUHAT = (i, t) => mrow(msub(hat(mi('u')), Ix(i))+mo('(')+BK+mo(',')+(t || TT)+mo(')'), 'uh');
const SPC = (inner) => msup(mi('ℂ'), mrow(mn(3)+mo('×')+inner+mo('×')+inner+mo('×')+inner));
const IDX = (sym, rng, txt, t) => `<div class="ir" data-t="${t}"><span class="is"><math>${sym}</math></span><span class="rg"><math>${rng}</math></span><span class="im">${txt}</span></div>`;
const DSTEP = (k, m, p) => `<div class="dstep"><span class="k">${k}</span><div class="dm"><math display="block">${m}</math></div><p>${p}</p></div>`;
const DEEP = (steps) => `<details class="deep"><summary>Going a bit deeper <span class="note">· ${steps.length} steps</span></summary>${steps.join('')}</details>`;

CFD.register({
 id: 'dns', name: 'DNS', sub: 'nothing modelled',
 lede: 'Solve the full Navier–Stokes equations on a grid fine enough for the <strong>smallest eddy</strong>. Here: in Fourier space, where derivatives are exact and pressure is one multiplication.',
 uncoloured: ['adv', 'press', 'visc', 'grp'],
 blocks: [
 { key: '0', title: 'The objects', note: 'what goes in, what comes out',
   html: `<div class="eqhero"><math display="block">${KUHAT('i')}<mo>∈</mo>${msup(mi('ℂ'), mrow(mn(3)+mo('×')+NN+mo('×')+NN+mo('×')+NN))}<mo>,</mo><mspace width="1em"/>${KJ('j')}${UH('j')}<mo>=</mo><mn>0</mn></math>
     <math display="block">${msup(hat(mi('u')), mrow(TT+mo('+')+DTT), 'uh')}<mo>=</mo>${VV}<mo>(</mo>${msup(hat(mi('u')), TT, 'uh')}<mo>+</mo>${DTT}${mi('P', 'P')}${mi('N', 'Nl')}<mo>(</mo>${msup(hat(mi('u')), TT, 'uh')}<mo>)</mo><mo>)</mo></math>
     <math display="block" class="sm">${mi('N', 'Nl')}<mo>(</mo>${hat(mi('u'))}<mo>)</mo><mo>=</mo>${FF}<mo>[</mo>${FI}<mo>(</mo>${hat(mi('u'))}<mo>)</mo><mo>×</mo>${FI}<mo>(</mo>${mrow(mi('i')+BK, 'D')}<mo>×</mo>${hat(mi('u'))}<mo>)</mo><mo>]</mo></math></div>`
   + `<p class="note">The state is a set of 3D waves, one complex amplitude per axis i and wavevector 𝐤. One step takes them in (with ν and Δt) and gives them back at t + Δt. Shown here as one Euler stage; the Build solver uses three Runge–Kutta stages.</p>
   <div class="idx"><span class="eyebrow">Every index</span>
     ${IDX(mrow(mi('i')+mo(',')+mi('j')+mo(',')+mi('l')+mo(',')+mi('m')), mrow(mi('x')+mo(',')+mi('y')+mo(',')+mi('z')), 'Axis of a vector: û<sub>i</sub>, k<sub>j</sub>, ω<sub>l</sub>. Twice in one term → summed: k<sub>j</sub>û<sub>j</sub> = k<sub>x</sub>û<sub>x</sub> + k<sub>y</sub>û<sub>y</sub> + k<sub>z</sub>û<sub>z</sub>.', 'alpha')}
     ${IDX(mi('𝐤'), mrow(msub(mi('k'), mi('j'))+mo('∈')+mo('{')+mo('−')+mfrac0('N','2')+mo('+')+mn(1)+mo(',')+mo('…')+mo(',')+mfrac0('N','2')+mo('}')), 'Wavevector: which 3D wave. Integer in each direction, because the box is 2π wide. Kept: |k<sub>j</sub>| ≤ N/3.', 'k')}
     ${IDX(mi('x'), mrow(mfrac0('2π','N')+mi('n')+mo(',')+mspace()+mi('n')+mo('=')+mn(0)+mo('…')+mi('N')+mo('−')+mn(1)), 'Grid point along x (the physical side, where products are taken).', 'ix')}
     ${IDX(mi('y'), mrow(mfrac0('2π','N')+mi('n')), 'Grid point along y.', 'iy')}
     ${IDX(mi('z'), mrow(mfrac0('2π','N')+mi('n')), 'Grid point along z.', 'iz')}
     ${IDX(mi('t'), mrow(mn(0)+mo(',')+mi('Δ')+mi('t')+mo(',')+mn(2)+mi('Δ')+mi('t')+mo(',')+mo('…')), 'Time level. As a superscript (ûᵗ) it labels the time, not a power.', 't')}
     ${IDX(mi('s'), mrow(mn(1)+mo(',')+mn(2)+mo(',')+mn(3)), 'Runge–Kutta stage inside one step (the Build solver evaluates the nonlinear term three times per step).', 'rk')}
   </div>
   <div class="dims">
     <div class="dim"><b>Fix i and 𝐤</b><math>${msub(hat(mi('u')), Ix('i'), 'uh')}<mo>(</mo>${BK}<mo>)</mo><mo>∈</mo><mi>ℂ</mi></math><span>one complex number: the size and phase of one wave in one direction</span></div>
     <div class="dim"><b>Fix 𝐤</b><math>${msub(hat(mi('u')), Ix('i'), 'uh')}<mo>(</mo>${BK}<mo>)</mo><mo>∈</mo>${msup(mi('ℂ'), mn(3))}</math><span>a 3-vector, but ⟂ 𝐤 (k<sub>j</sub>û<sub>j</sub> = 0): only 2 free numbers</span></div>
     <div class="dim"><b>Nothing fixed (the state)</b><math>${msub(hat(mi('u')), Ix('i'), 'uh')}<mo>∈</mo>${msup(mi('ℂ'), mrow(mn(3)+mo('×')+NN+mo('×')+NN+mo('×')+NN))}</math><span>32³ grid → 98 304 complex numbers; the 2/3 rule keeps 21³ = 9 261 waves per component</span></div>
     <div class="dim"><b>On the grid</b><math>${msub(mi('u'), Ix('i'), 'u')}<mo>(</mo>${BX}<mo>)</mo><mo>∈</mo>${msup(mi('ℝ'), mrow(mn(3)+mo('×')+NN+mo('×')+NN+mo('×')+NN))}</math><span>the same velocity as real numbers at N³ points: 𝓕⁻¹ of the state</span></div>
   </div>
   <span class="eyebrow">What the operators do, on real numbers</span>
   <figure class="viz"><div class="scrollx"><canvas id="dns-opviz" data-w="880" data-h="350" aria-label="Animated walkthrough on one grid line: the FFT, the spectral derivative, the dealiased product, the projection and the viscous factor"></canvas></div>
     <div class="opctl"><button class="b" id="dns-opplay">Pause</button><div id="dns-opsteps" class="btns"></div></div>
     <p class="opcap" id="dns-opcap"></p></figure>
   <aside class="insp" data-terms="F,D,Nl,P,V,uh,u,k,N"></aside>
   ${DEEP([
     DSTEP('𝓕', `${msub(hat(mi('u')), Ix('i'), 'uh')}<mo>(</mo>${BK}<mo>)</mo><mo>=</mo>${frac(mn(1), msup(NN, mn(3)))}<munder><mo>∑</mo>${BX}</munder>${msub(mi('u'), Ix('i'), 'u')}<mo>(</mo>${BX}<mo>)</mo>${msup(mi('e'), mrow(mo('−')+mi('i')+KJ('j')+msub(mi('x'), Ix('j'))))}`, 'The state and the grid values hold the same information: 𝓕 is an invertible linear map ℂ^(N³) → ℂ^(N³) for each component. The FFT computes it in N³·log₂N³ operations instead of N⁶.'),
     DSTEP('D', `${msub(hat(mrow(mo('(')+DJ('j')+msub(mi('u'), Ix('i'))+mo(')'))), mrow(''))}<mo>=</mo>${DD}${msub(hat(mi('u')), Ix('i'), 'uh')}`, 'Every derivative becomes a multiplication, wave by wave. No stencil, no neighbours: for the waves on the grid it is exact.'),
     DSTEP('V', `${msub(hat(mi('u')), Ix('i'), 'uh')}<mo>(</mo>${TT}<mo>+</mo>${DTT}<mo>)</mo><mo>=</mo>${EXPV}${msub(hat(mi('u')), Ix('i'), 'uh')}<mo>(</mo>${TT}<mo>)</mo><mspace width="1em"/><mtext>if only viscosity acted</mtext>`, 'Viscosity alone damps each wave on its own, at rate νk². The factor V is that exact solution; the solver applies it, so viscosity never limits the time step.')
   ])}` },
 { key: 'A', title: 'Navier–Stokes, nothing modelled', note: 'the equations a DNS solves',
   html: `<div class="eqhero"><math display="block">${mrow(DTd+U('i'), 'dudt')}<mo>+</mo>${ub(mrow(U('j')+DJ('j')+U('i'), 'adv'), 'Nl', 'N: carried by the flow')}<mo>=</mo>${ub(mrow(mo('−')+DJ('i')+PP, 'press'), 'P', 'P: keeps ∂ᵢuᵢ = 0')}<mo>+</mo>${ub(mrow(NU+DJ('j')+DJ('j')+U('i'), 'visc'), 'V', 'V: viscous smoothing')}</math>
     <math display="block" class="sm">${DJ('i')}${U('i')}<mo>=</mo><mn>0</mn><mspace width="2em"/>${msub(mi('u'), mi('x', 'ix'), 'u')}<mo>=</mo><mi>sin</mi><mi>x</mi><mi>cos</mi><mi>y</mi><mi>cos</mi><mi>z</mi><mo>,</mo><mspace width=".6em"/>${msub(mi('u'), mi('y', 'iy'), 'u')}<mo>=</mo><mo>−</mo><mi>cos</mi><mi>x</mi><mi>sin</mi><mi>y</mi><mi>cos</mi><mi>z</mi><mo>,</mo><mspace width=".6em"/>${msub(mi('u'), mi('z', 'iz'), 'u')}<mo>=</mo><mn>0</mn></math></div>
   <p class="note">Density is 1 and units are the vortex's: speed 1, length 1, so ν = 1/Re. The second line is the Taylor–Green vortex the Build step starts from.</p>
   <div class="bb"><figure class="viz">
       <canvas id="dns-nsviz" data-w="460" data-h="450" aria-label="The Taylor–Green vortex in its 2π box: velocity arrows, tracer particles, and the four terms of Navier–Stokes at a moving probe; drag to rotate"></canvas>
       <div class="lg"><span style="color:var(--c-u)"><i class="ln"></i>uᵢ</span><span style="color:var(--c-eq)"><i class="ln"></i>−advection</span><span style="color:var(--c-tau)"><i class="ln"></i>−∂ᵢp</span><span style="color:var(--c-nu)"><i class="ln"></i>viscous</span><span style="color:var(--c-f)"><i class="ln dash"></i>∂ₜuᵢ (sum)</span><span class="note">drag to rotate</span></div>
       <div class="ctl"><label for="dns-are" class="sym" style="color:var(--ink)">Re</label><input type="range" id="dns-are" min="1" max="3.2" step="0.01" value="2"><output id="dns-arev">100</output></div>
     </figure>
     <aside class="insp" data-terms="dudt,adv,press,visc,u,p,nu,grad,alpha,x,t,Re,Nl,P,V"></aside></div>
   ${DEEP([
     DSTEP('1', `${DJ('i')}${DJ('i')}${PP}<mo>=</mo><mo>−</mo>${DJ('i')}${DJ('j')}<mo>(</mo>${U('i')}${U('j')}<mo>)</mo>`, 'Take ∂ᵢ of the equation and use ∂ᵢuᵢ = 0: pressure obeys a Poisson equation. It is not a state variable with its own law; it is whatever keeps the flow incompressible, everywhere at once.'),
     DSTEP('2', `${U('j')}${DJ('j')}${U('i')}<mo>=</mo><mo>−</mo>${msub(mi('ϵ'), Ij('i','j','l'), 'lc')}${U('j')}${OM('l')}<mo>+</mo>${DJ('i')}<mo>(</mo>${frac(mn(1), mn(2))}${U('j')}${U('j')}<mo>)</mo>`, 'The rotational form: advection = −(𝐮 × 𝛚) plus a gradient. The gradient merges with the pressure, so the solver only needs u × ω, which conserves energy exactly even on a grid.'),
     DSTEP('3', `${frac(mi('d')+mi('E', 'KE'), mi('d')+TT)}<mo>=</mo><mo>−</mo>${NU}<mo>⟨</mo>${DJ('j')}${U('i')}${DJ('j')}${U('i')}<mo>⟩</mo><mo>=</mo><mo>−</mo>${EPS}`, 'Multiply by uᵢ and average over the periodic box: advection and pressure only move energy around. All loss is viscous, at the rate ε. Nothing is modelled, so this holds term by term.')
   ])}` },
 { key: 'B', title: 'Fourier space', note: 'derivatives, pressure and products',
   html: `<div class="eqhero"><math display="block">${DTd}${msub(hat(mi('u')), Ix('i'), 'uh')}<mo>=</mo>${ub(mrow(PIJ('i','j')+NH('j')), 'P', 'P: only the part ⟂ 𝐤')}<mo>−</mo>${ub(mrow(NU+K2+msub(hat(mi('u')), Ix('i'), 'uh')), 'V', 'V: exact factor e^(−νk²Δt)')}</math>
     <math display="block" class="sm">${PIJ('i','j')}<mo>=</mo>${DEL('i','j')}<mo>−</mo>${frac(KJ('i')+KJ('j'), K2)}<mspace width="1.5em"/>${ub(mrow(NH('j')+mo('=')+FF+mo('[')+msub(mi('ϵ'), Ij('j','l','m'), 'lc')+U('l')+OM('m')+mo(']')), 'Nl', 'N: product on the grid, then cut |kⱼ| > N/3')}<mspace width="1.5em"/>${ub(mrow(DJ('j')+mo('→')+DD), 'D', 'D: derivative = multiply')}</math></div>
   <div class="bb"><figure class="viz">
       <canvas id="dns-kviz" data-w="460" data-h="430" aria-label="One Fourier wave in the 3D box, its wavevector k, and the projection of the nonlinear term onto the plane perpendicular to k; drag to rotate"></canvas>
       <div class="ctl3"><label for="dns-kx" class="sym" style="color:var(--c-c)">k<sub>x</sub></label><input type="range" id="dns-kx" min="-3" max="3" step="1" value="1"><output id="dns-kxv">1</output><label for="dns-ky" class="sym" style="color:var(--c-c)">k<sub>y</sub></label><input type="range" id="dns-ky" min="-3" max="3" step="1" value="2"><output id="dns-kyv">2</output><label for="dns-kz" class="sym" style="color:var(--c-c)">k<sub>z</sub></label><input type="range" id="dns-kz" min="-3" max="3" step="1" value="0"><output id="dns-kzv">0</output><span class="note" style="grid-column:1/-1">drag the picture to rotate · the stripes are the wave cos(k<sub>j</sub>x<sub>j</sub>) on the walls of the box</span></div>
     </figure>
     <aside class="insp" data-terms="P,Nl,D,V,F,uh,k,kj,k2,delta,lc,om,nu,alpha"></aside></div>
   ${DEEP([
     DSTEP('1', `${DJ('j')}${msup(mi('e'), mrow(mi('i')+KJ('l')+msub(mi('x'), Ix('l'))))}<mo>=</mo>${DD}${msup(mi('e'), mrow(mi('i')+KJ('l')+msub(mi('x'), Ix('l'))))}`, 'Why derivatives become multiplications: each Fourier wave is an eigenfunction of ∂ⱼ. Error only comes from waves the grid cannot hold, so accuracy improves faster than any power of N (spectral accuracy).'),
     DSTEP('2', `${hat(PP)}<mo>=</mo><mo>−</mo><mi>i</mi>${frac(KJ('j')+NH('j'), K2)}<mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${NH('i')}<mo>−</mo><mi>i</mi>${KJ('i')}${hat(PP)}<mo>=</mo>${PIJ('i','j')}${NH('j')}`, 'Pressure in Fourier space: k<sub>j</sub>û<sub>j</sub> = 0 must stay true, so the pressure wave is fixed by k<sub>j</sub>N̂<sub>j</sub>, one division per wave. Subtracting its gradient is the projection P. (With the rotational form this p also contains ½u<sub>j</sub>u<sub>j</sub>.)'),
     DSTEP('3', `${PIJ('i','j')}${PIJ('j','l')}<mo>=</mo>${PIJ('i','l')}<mo>,</mo><mspace width="1em"/>${PIJ('i','j')}${KJ('j')}<mo>=</mo><mn>0</mn><mo>,</mo><mspace width="1em"/>${PIJ('i','j')}${UH('j')}<mo>=</mo>${UH('i')}`, 'P is a projector: applying it twice changes nothing, it kills anything along 𝐤, and it leaves a divergence-free field alone. Viscosity (−νk²ûᵢ) is already ⟂ 𝐤, so it needs no projection.')
   ])}` },
 { key: 'C', title: 'Resolution and cost', note: 'why DNS is the most expensive method',
   html: `<div class="eqhero"><math display="block">${ETA}<mo>=</mo>${msup(mrow(mo('(')+frac(msup(NU, mn(3)), EPS)+mo(')')), frac(mn(1), mn(4)))}<mspace width="1.5em"/>${ub(mrow(KMAX+ETA, 'grp'), 'kmax', 'resolution: ≳ 1 to 1.5')}<mo>,</mo><mspace width="1em"/>${KMAX}<mo>=</mo>${frac(NN, mn(3))}</math>
     <math display="block" class="sm">${ub(mrow(msup(NN, mn(3))+mo('∼')+msup(RE, frac(mn(9), mn(4)))), 'N', 'grid points')}<mspace width="1.2em"/>${ub(mrow(frac(mi('T'), DTT)+mo('∼')+msup(RE, frac(mn(3), mn(4)))), 'dt', 'time steps')}<mspace width="1.2em"/>${ub(mrow(mtx('work')+mo('∼')+msup(RE, mn(3))), 'Re', 'total cost')}</math></div>
   <div class="bb"><figure class="viz"><div class="scrollx">
       <canvas id="dns-resviz" data-w="560" data-h="330" aria-label="Model energy and dissipation spectra with the grid cutoff k_max; dots ride the energy cascade toward small scales and pile up at the cutoff when the grid is too coarse"></canvas></div>
       <div class="ctl"><label for="dns-cre" class="sym" style="color:var(--ink)">Re</label><input type="range" id="dns-cre" min="2" max="6" step="0.05" value="3.5"><output id="dns-crev">3 162</output></div>
       <div class="ctl"><label for="dns-cn" class="sym" style="color:var(--ink)">N</label><input type="range" id="dns-cn" min="5" max="14" step="1" value="9"><output id="dns-cnv">512</output></div>
       <div class="note" id="dns-ccap">&nbsp;</div>
     </figure>
     <aside class="insp" data-terms="eta,eps,nu,kmax,N,Re,Ek,L,k2,dt"></aside></div>
   ${DEEP([
     DSTEP('1', `${ETA}<mo>=</mo>${msup(mrow(mo('(')+frac(msup(NU, mn(3)), EPS)+mo(')')), frac(mn(1), mn(4)))}<mo>,</mo><mspace width="1em"/>${msub(mi('τ'), mi('η'))}<mo>=</mo>${msup(mrow(mo('(')+frac(NU, EPS)+mo(')')), frac(mn(1), mn(2)))}`, 'Kolmogorov (1941): at the smallest scales only ν and ε matter, and these are the only length and time built from them. There the eddy Reynolds number is 1: viscosity wins.'),
     DSTEP('2', `${EPS}<mo>∼</mo>${frac(msup(mi('U'), mn(3)), mi('L', 'L'))}<mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${frac(mi('L', 'L'), ETA)}<mo>∼</mo>${msup(RE, frac(mn(3), mn(4)))}<mo>,</mo><mspace width="1em"/>${RE}<mo>=</mo>${frac(mi('U')+mi('L', 'L'), NU)}`, 'Big eddies lose energy in about one turnover, independent of ν. So the range of scales grows as Re³ᐟ⁴ in each direction: N³ ∼ Re⁹ᐟ⁴ points.'),
     DSTEP('3', `${DTT}<mo>∼</mo>${frac(mi('Δ')+mi('x'), mi('U'))}<mo>∼</mo>${frac(ETA, mi('U'))}<mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${frac(mi('T'), DTT)}<mo>∼</mo>${frac(mi('L', 'L'), ETA)}<mo>∼</mo>${msup(RE, frac(mn(3), mn(4)))}`, 'The time step must stop the fastest flow from skipping a cell (CFL), and a run lasts a few large-eddy turnovers. Points × steps: Re⁹ᐟ⁴ × Re³ᐟ⁴ = Re³. Doubling Re costs 8×.')
   ])}` }
 ],
 checks: {
  '0': [
   ['Fix 𝐤 but not i. What is ûᵢ(𝐤)?', ['A single real number', 'A vector in ℂ³, perpendicular to 𝐤', 'A 32³ array'], 1, 'One complex amplitude per axis, three in all; k_j û_j = 0 makes it perpendicular to 𝐤, so only two of them are free.'],
   ['Which operator mixes every grid point with every other one?', ['The FFT 𝓕', 'The derivative D = i kⱼ', 'The viscous factor V'], 0, 'Each Fourier coefficient is a sum over all N³ points. D and V act on each wave separately, and the product acts on each grid point separately.'],
   ['Why is the product u × ω taken on the grid and not in Fourier space?', ['It is more accurate on the grid', 'In Fourier space a product is a convolution: every wave pairs with every other, ∼N⁶ work. On the grid it is N³ multiplications plus FFTs', 'Fourier space has no vectors'], 1, 'That is the “pseudo” in pseudo-spectral: products where they are cheap, derivatives where they are exact.'],
   ['What does the 2/3 rule remove?', ['Waves with |kⱼ| > N/3, where the folded-back (aliased) parts of products land', 'The pressure', 'The mean flow'], 0, 'Products of kept waves reach at most 2N/3; anything above N/2 folds back, but only onto |k| > N/3, which is then zeroed.'],
   ['You double N in each direction. How much bigger is the state?', ['2×', '8×', '4×'], 1, 'N³ waves per component: 2³ = 8× the numbers (and with half the time step, about 16× the work).']
  ],
  A: [
   ['Which term makes Navier–Stokes nonlinear?', ['−∂ᵢp', 'uⱼ∂ⱼuᵢ (advection)', 'ν∂ⱼ∂ⱼuᵢ'], 1, 'Velocity carries itself: the product of u with its own gradient. It moves energy between scales and creates the small eddies.'],
   ['What decides the pressure in incompressible flow?', ['An equation of state p = ρRT', 'Whatever keeps ∂ᵢuᵢ = 0, everywhere at once (a Poisson equation)', 'The boundary conditions only'], 1, 'Pressure has no law of its own here; it is the constraint force that keeps the flow divergence-free.'],
   ['What does a DNS model?', ['The eddies smaller than the grid', 'Nothing: every eddy down to the dissipation scale is computed', 'The pressure'], 1, 'No turbulence model at all. The only errors are numerical ones, so the grid has to be fine enough.'],
   ['Taylor–Green at Re = 100 vs Re = 1000: what happens to the viscous term at the start?', ['It is 10× smaller relative to advection', 'It is the same', 'It is 10× larger'], 0, 'ν = 1/Re here. With weaker viscosity, smaller eddies survive, so the grid must be finer.'],
   ['If ∂ᵢuᵢ = 0 holds at t = 0, why does it need pressure to stay true?', ['Advection alone would create divergence; −∂ᵢp removes exactly that part', 'It does not: incompressibility holds by itself', 'Viscosity would break it'], 0, 'u·∇u is not divergence-free in general; the pressure gradient cancels its compressive part (block B shows this as the projection P).']
  ],
  B: [
   ['In Fourier space, ∂ⱼ becomes…', ['Multiplication by i kⱼ', 'A finite difference', 'Division by kⱼ'], 0, 'e^(ik·x) is an eigenfunction of ∂ⱼ with eigenvalue i kⱼ: a quarter-turn of phase and a stretch by kⱼ.'],
   ['Apply Pᵢⱼ to a vector parallel to 𝐤. What comes out?', ['The same vector', 'Zero', 'A vector twice as long'], 1, 'P removes the component along 𝐤 completely: that is the part pressure cancels.'],
   ['Why does the solver need no pressure Poisson solve?', ['Pressure is ignored', 'In Fourier space the Poisson equation is one division per wave, folded into Pᵢⱼ', 'It uses an iterative solver hidden in the FFT'], 1, '−k²p̂ = … is solved by dividing by k²: the projection does it for free.'],
   ['You switch the 2/3 rule off at high Re. What can happen?', ['Nothing changes', 'Aliased product terms put energy into the wrong waves, which can pile up and blow the run up', 'The run gets more accurate'], 1, 'Without dealiasing, fake modes feed energy into the smallest scales; with little viscosity to absorb it the simulation can become unstable.'],
   ['Why treat −νk²ûᵢ with the exact factor e^(−νk²Δt)?', ['It is cheaper than nothing', 'The highest k decay very fast; an explicit step would need a tiny Δt to stay stable', 'It adds a turbulence model'], 1, 'The linear viscous part is solved exactly, so only advection (CFL) limits Δt.']
  ],
  C: [
   ['Halve ν at the same ε. What happens to η?', ['Halves', 'Shrinks to 2^(−3/4) ≈ 0.59×', 'Stays the same'], 1, 'η = (ν³/ε)^{1/4}: (½)^{3/4} ≈ 0.59.'],
   ['k_max η drops to 0.3. What do you see in the spectrum?', ['Energy piles up near k_max instead of falling off', 'The spectrum gets steeper', 'Nothing'], 0, 'The cascade brings energy to scales the grid cannot hold and viscosity is too weak there; it accumulates at the cutoff. It is no longer a DNS.'],
   ['Why does total cost grow like Re³?', ['N³ ∼ Re⁹ᐟ⁴ points times Re³ᐟ⁴ time steps', 'The FFT is N²', 'Pressure solves get harder'], 0, 'Finer grid in all three directions, and a smaller time step to match.'],
   ['Taylor–Green at Re = 1600 (peak ε near t ≈ 9). Is 32³ enough?', ['Yes', 'No: k_max η is about 0.14; published references use 256³ to 512³', 'Only if Δt is tiny'], 1, 'At 32³ the run is badly under-resolved: the Build step lets you see the pile-up and the wrong dissipation peak.'],
   ['In the spectral solver, −dE/dt and 2νΩ agree even when under-resolved. Why?', ['The dealiased nonlinear term conserves energy exactly, so all loss is the resolved viscous loss: the check shows the numerics add no dissipation, not that the eddies are resolved', 'Because the run is always resolved', 'Because ν is large'], 0, 'That is why resolution is judged by k_max η, the spectrum tail, and a finer-grid reference.']
  ]
 },
 quiz: [
  ['What makes a simulation a DNS?', ['It uses a spectral method', 'Every scale of motion down to the Kolmogorov scale is computed; no turbulence model', 'It runs on a GPU'], 1, 'DNS is defined by resolution, not by the numerical method; spectral codes are just the most accurate way to get there in a box.'],
  ['Why do periodic-box DNS codes use Fourier pseudo-spectral methods?', ['Derivatives are exact for every resolved wave and pressure is one division per wave', 'They need no grid', 'They work for any geometry'], 0, 'Spectral accuracy plus a trivial Poisson solve; the price is periodic (or very simple) geometry.'],
  ['Re doubles. Roughly how much more work?', ['2×', '4×', '8×'], 2, 'Work ∼ Re³.'],
  ['What dominates a large parallel spectral DNS?', ['The pointwise products', 'The all-to-all transposes inside the 3D FFTs', 'Writing output'], 1, 'Every 3D FFT reshuffles the whole array across the machine; communication, not arithmetic, sets the speed at scale.'],
  ['Slab vs pencil decomposition on an N³ grid: how many ranks can each use?', ['Slab ≤ N, pencil ≤ N²', 'Both ≤ N', 'Slab ≤ N², pencil ≤ N³'], 0, 'A slab needs at least one plane per rank; a pencil needs at least one line.'],
  ['An under-resolved spectral run: which symptom gives it away?', ['−dE/dt ≠ 2νΩ', 'k_max η well below 1 and energy piling up at the cutoff', 'Negative energy'], 1, 'Energy conservation of the dealiased scheme hides the problem in the budget; the spectrum shows it.'],
  ['Why can DNS not simulate a whole airliner wing in flight?', ['Wings are not periodic, and at Re ∼ 10⁷ the cost ∼ Re³ is far beyond any computer', 'Air is compressible', 'It would be less accurate than RANS'], 0, 'DNS is a research tool for moderate Re: the ground truth that the modelled methods are checked against.']
 ],
 build: {
  intro: 'Put the steps of one Runge–Kutta stage in order. When it is right, your 3D pseudo-spectral DNS runs below: the Taylor–Green vortex on 32³ points.',
  html: `<div class="scrollx"><canvas class="sim" id="dns-sim" data-w="760" data-h="400" aria-label="Your 3D DNS: vorticity in the box, the dissipation rate two ways against a finer-grid reference, and the energy spectrum"></canvas></div>
   <div class="row"><label for="dns-re">Re = <span id="dns-rev">100</span></label><input type="range" id="dns-re" min="0" max="5" step="1" value="1"><button class="b" id="dns-run">Pause</button><button class="b" id="dns-restart">Restart</button></div>
   <div class="note" id="dns-simcap">&nbsp;</div>
   <details><summary>What the curves prove, and what they do not</summary><p>−dE/dt (dots, from the energy history) and 2νΩ (line, from the enstrophy) agree to about 0.1 % at every Re: the dealiased spectral scheme adds no numerical dissipation, so all energy loss is the resolved viscous loss. That checks the numerics, not the resolution. Resolution shows in k<sub>max</sub>η and in the spectrum tail, and in the dashed finer-grid reference (computed offline with this same code at 64³ or 128³): at Re ≥ 400 the 32³ run leaves it. The Re = 1600 case is the standard benchmark (peak ε ≈ 0.0127 near t ≈ 9 with 512³ spectral references); 32³ cannot get it.</p></details>`,
  steps: ['Vorticity in Fourier space: ω̂ = i𝐤 × û', 'Inverse FFT: û, ω̂ → u, ω on the grid', 'Multiply on the grid: u × ω', 'FFT back, zero |kⱼ| > N/3 (2/3 rule)', 'Project with Pᵢⱼ (pressure part removed)', 'RK update with viscous factor e^(−νk²Δt)'],
  hint: 'Derivatives are taken in Fourier space, products on the grid; the projection acts on the transformed, dealiased product; viscosity comes last with the update.',
  success: 'Your 3D DNS is running: 32³ Fourier modes, 5 FFTs per stage, 3 stages per step. Watch the vortex sheets roll up, ε rise to its peak, and the spectrum fill toward k_max. Slide Re up until k_max η falls below 1.'
 },
 parallel: {
  html: `<div class="par"><div class="stack">
     <p><strong>FFTs dominate.</strong> Each stage does five 3D FFTs (15 per step). A 3D FFT is 1D FFTs along x, then y, then z, and each pass needs whole lines in one memory.</p>
     <p><strong>Slab:</strong> each rank holds N/P planes. x and y are local; z needs one global <em>transpose</em> (all-to-all). At most N ranks: one plane each.</p>
     <p><strong>Pencil:</strong> each rank holds a column N × N/P₁ × N/P₂. Two transposes, each inside a row or column group of ranks. Up to N² ranks.</p>
     <p>Every transpose moves the whole array across the network, so at scale DNS is <strong>communication-bound</strong>.</p></div>
   <canvas id="dns-decomp" data-w="320" data-h="250" style="width:100%;max-width:320px;border-radius:8px;background:var(--bg)" aria-label="The N³ grid cut into slabs or pencils, one colour per rank, with the transpose that swaps their orientation"></canvas></div>
   <h3 style="font-size:16px">Fit a grid onto a machine</h3>
   <p>Pick a grid and a number of ranks. Find a setup where slabs run out but pencils still work.</p>
   <div class="btns"><button class="b pri" id="dns-slab">Slab</button><button class="b" id="dns-pencil">Pencil</button></div>
   <div class="ctl"><label for="dns-pn" class="sym" style="color:var(--ink)">N</label><input type="range" id="dns-pn" min="5" max="14" step="1" value="10"><output id="dns-pnv">1024</output></div>
   <div class="ctl"><label for="dns-pp" class="sym" style="color:var(--ink)">P</label><input type="range" id="dns-pp" min="0" max="20" step="1" value="8"><output id="dns-ppv">256</output></div>
   <div class="fb" id="dns-pfb"></div>
   <details><summary>GPUs</summary><p>On GPUs the local 1D FFTs (cuFFT, rocFFT) are so fast that the all-to-all transposes take most of the time; the grid must also fit in GPU memory (3 velocity components plus work arrays, 16 bytes per complex number). Large codes overlap communication with computation, batch several fields per transpose, and keep the pointwise products on the GPU. The largest published runs (8192³ in 2015, 18 432³ in 2020) are limited by the network, not the arithmetic.</p></details>`
 },
 unlock: 'The DNS row of the comparison is now visible: nothing modelled, the ground truth the other methods are measured against, at a cost growing like Re³. Complete the other methods to open the full page.',
 sources: [
  ['Pope, Turbulent Flows (Cambridge, 2000): Kolmogorov scales, model spectrum, DNS resolution k_max η ≥ 1.5 (ch. 6, 9)', 'https://doi.org/10.1017/CBO9780511840531'],
  ['Moin & Mahesh, Direct numerical simulation: a tool in turbulence research, Annu. Rev. Fluid Mech. 30 (1998)', 'https://doi.org/10.1146/annurev.fluid.30.1.539'],
  ['Brachet, Meiron, Orszag, Nickel, Morf & Frisch, Small-scale structure of the Taylor–Green vortex, J. Fluid Mech. 130 (1983)', 'https://doi.org/10.1017/S0022112083001159'],
  ['Canuto, Hussaini, Quarteroni & Zang, Spectral Methods: Fundamentals in Single Domains (Springer, 2006)', 'https://doi.org/10.1007/978-3-540-30726-6'],
  ['Orszag, On the elimination of aliasing in finite-difference schemes by filtering high-wavenumber components (the 2/3 rule), J. Atmos. Sci. 28 (1971)', 'https://doi.org/10.1175/1520-0469(1971)028%3C1074:OTEOAI%3E2.0.CO;2'],
  ['Williamson, Low-storage Runge–Kutta schemes, J. Comput. Phys. 35 (1980)', 'https://doi.org/10.1016/0021-9991(80)90033-9'],
  ['Cooley & Tukey, An algorithm for the machine calculation of complex Fourier series, Math. Comp. 19 (1965)', 'https://doi.org/10.1090/S0025-5718-1965-0178586-1'],
  ['Wang et al., High-order CFD methods: current status and perspective (Taylor–Green Re = 1600 reference), Int. J. Numer. Meth. Fluids 72 (2013)', 'https://doi.org/10.1002/fld.3767'],
  ['Kaneda et al., Energy dissipation rate and energy spectrum in high resolution DNS of turbulence in a periodic box (4096³), Phys. Fluids 15 (2003)', 'https://doi.org/10.1063/1.1539855'],
  ['Yeung, Zhai & Sreenivasan, Extreme events in computational turbulence (8192³), PNAS 112 (2015)', 'https://doi.org/10.1073/pnas.1517368112'],
  ['Yeung & Ravikumar, Advancing understanding of turbulence through extreme-scale computation (18 432³), Phys. Rev. Fluids 5 (2020)', 'https://doi.org/10.1103/PhysRevFluids.5.110517'],
  ['Pekurovsky, P3DFFT: a framework for parallel computations of Fourier transforms in three dimensions (pencil decomposition), SIAM J. Sci. Comput. 34 (2012)', 'https://doi.org/10.1137/11082748X']
 ],
 terms: {
  uh: { sym: hat('<mi>u</mi>').replace('<mover', '<msub><mover').replace('</mover>', '</mover><mi>i</mi></msub>'), name: 'Fourier amplitude', def: 'How much of the wave 𝐤 the velocity component i contains: size and phase in one complex number. These are what the solver stores.', space: '<msub><mover accent="true"><mi>u</mi><mo>^</mo></mover><mi>i</mi></msub><mo>(</mo><mi>𝐤</mi><mo>,</mo><mi>t</mi><mo>)</mo><mo>∈</mo><mi>ℂ</mi><mo>,</mo><mspace width=".5em"/><mtext>state</mtext><mo>∈</mo><msup><mi>ℂ</mi><mrow><mn>3</mn><mo>×</mo><mi>N</mi><mo>×</mo><mi>N</mi><mo>×</mo><mi>N</mi></mrow></msup>', col: '--c-f' },
  u: { sym: '<msub><mi>u</mi><mi>i</mi></msub>', name: 'Velocity', def: 'Component i of the fluid velocity at a point. On the grid it is 𝓕⁻¹ of the Fourier amplitudes.', space: '<msub><mi>u</mi><mi>i</mi></msub><mo>(</mo><mi>𝐱</mi><mo>,</mo><mi>t</mi><mo>)</mo><mo>∈</mo><mi>ℝ</mi><mo>,</mo><mspace width=".5em"/><mtext>on the grid</mtext><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo><mi>N</mi><mo>×</mo><mi>N</mi><mo>×</mo><mi>N</mi></mrow></msup>', col: '--c-u' },
  dudt: { sym: '<msub><mo>∂</mo><mi>t</mi></msub><msub><mi>u</mi><mi>i</mi></msub>', name: 'Rate of change', def: 'How fast the velocity at a fixed point changes: the sum of everything on the right-hand side.', space: '<msub><mo>∂</mo><mi>t</mi></msub><msub><mi>u</mi><mi>i</mi></msub><mo>(</mo><mi>𝐱</mi><mo>,</mo><mi>t</mi><mo>)</mo><mo>∈</mo><mi>ℝ</mi>', col: '--c-f' },
  adv: { sym: '<msub><mi>u</mi><mi>j</mi></msub><msub><mo>∂</mo><mi>j</mi></msub><msub><mi>u</mi><mi>i</mi></msub>', name: 'Advection', def: 'The flow carrying its own velocity along. The only nonlinear term: it creates small eddies from big ones.', space: '<mi>𝐮</mi><mo>↦</mo><msub><mi>u</mi><mi>j</mi></msub><msub><mo>∂</mo><mi>j</mi></msub><msub><mi>u</mi><mi>i</mi></msub><mo>:</mo><mtext>vector field → vector field, quadratic</mtext>', col: '--c-eq', op: 'N' },
  press: { sym: '<mo>−</mo><msub><mo>∂</mo><mi>i</mi></msub><mi>p</mi>', name: 'Pressure force', def: 'Pushes from high to low pressure. Its job here: cancel exactly the part of advection that would compress the fluid.', space: '<mo>−</mo><msub><mo>∂</mo><mi>i</mi></msub><mi>p</mi><mo>∈</mo><mi>ℝ</mi><mtext> at each point (a gradient field)</mtext>', col: '--c-tau', op: 'P' },
  visc: { sym: '<mi>ν</mi><msub><mo>∂</mo><mi>j</mi></msub><msub><mo>∂</mo><mi>j</mi></msub><msub><mi>u</mi><mi>i</mi></msub>', name: 'Viscous term', def: 'Smooths velocity differences, strongest for the smallest eddies. Where kinetic energy turns into heat.', space: '<mi>ν</mi><msub><mo>∂</mo><mi>j</mi></msub><msub><mo>∂</mo><mi>j</mi></msub><mo>:</mo><mtext>vector field → vector field, linear</mtext>', col: '--c-nu', op: 'V' },
  p: { sym: '<mi>p</mi>', name: 'Pressure', def: 'Pressure divided by density. Not given by a law of its own: it is whatever keeps ∂ᵢuᵢ = 0.', space: '<mi>p</mi><mo>(</mo><mi>𝐱</mi><mo>,</mo><mi>t</mi><mo>)</mo><mo>∈</mo><mi>ℝ</mi>', col: '--c-tau', op: 'P' },
  nu: { sym: '<mi>ν</mi>', name: 'Viscosity', def: 'Kinematic viscosity. In the Taylor–Green units ν = 1/Re.', space: '<mi>ν</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--c-nu' },
  alpha: { sym: '<mrow><mi>i</mi><mo>,</mo><mi>j</mi><mo>,</mo><mi>l</mi><mo>,</mo><mi>m</mi></mrow>', name: 'Axis indices', def: 'x, y or z. An index twice in one term means sum over all three (Einstein convention).', space: '<mi>i</mi><mo>,</mo><mi>j</mi><mo>,</mo><mi>l</mi><mo>,</mo><mi>m</mi><mo>∈</mo><mo>{</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>}</mo>', col: '--ink' },
  ix: { sym: '<mi>x</mi>', name: 'Grid coordinate x', def: 'Position along x: N equally spaced points 2πn/N, n = 0 … N−1. The box wraps around.', space: '<mi>x</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mfrac><mrow><mn>2</mn><mi>π</mi></mrow><mi>N</mi></mfrac><mo>,</mo><mo>…</mo><mo>}</mo><mo>⊂</mo><mo>[</mo><mn>0</mn><mo>,</mo><mn>2</mn><mi>π</mi><mo>)</mo>', col: '--ink' },
  iy: { sym: '<mi>y</mi>', name: 'Grid coordinate y', def: 'Position along y (up in the pictures), same spacing 2π/N.', space: '<mi>y</mi><mo>∈</mo><mo>[</mo><mn>0</mn><mo>,</mo><mn>2</mn><mi>π</mi><mo>)</mo>', col: '--ink' },
  iz: { sym: '<mi>z</mi>', name: 'Grid coordinate z', def: 'Position along z (depth in the pictures), same spacing 2π/N.', space: '<mi>z</mi><mo>∈</mo><mo>[</mo><mn>0</mn><mo>,</mo><mn>2</mn><mi>π</mi><mo>)</mo>', col: '--ink' },
  x: { sym: '<mi>𝐱</mi>', name: 'Position', def: 'A point of the periodic box: 𝐱 = (x, y, z).', space: '<mi>𝐱</mi><mo>∈</mo><msup><mrow><mo>[</mo><mn>0</mn><mo>,</mo><mn>2</mn><mi>π</mi><mo>)</mo></mrow><mn>3</mn></msup>', col: '--ink' },
  k: { sym: '<mi>𝐤</mi>', name: 'Wavevector', def: 'Which wave: 𝐤 = (kₓ, k_y, k_z), integers in a 2π box. Its direction is the wave’s direction; its length is how many waves fit in the box.', space: '<mi>𝐤</mi><mo>∈</mo><msup><mi>ℤ</mi><mn>3</mn></msup><mo>,</mo><mspace width=".5em"/><mo>|</mo><msub><mi>k</mi><mi>j</mi></msub><mo>|</mo><mo>≤</mo><mfrac><mi>N</mi><mn>3</mn></mfrac><mtext> kept</mtext>', col: '--c-c' },
  kj: { sym: '<msub><mi>k</mi><mi>j</mi></msub>', name: 'Wavevector component', def: 'Component j of 𝐤: how fast the wave oscillates along axis j.', space: '<msub><mi>k</mi><mi>j</mi></msub><mo>∈</mo><mi>ℤ</mi>', col: '--c-c' },
  k2: { sym: '<msup><mi>k</mi><mn>2</mn></msup>', name: 'Squared wavenumber', def: 'k² = kⱼkⱼ = kₓ² + k_y² + k_z². Large k² = short wave.', space: '<msup><mi>k</mi><mn>2</mn></msup><mo>∈</mo><mi>ℕ</mi>', col: '--c-c' },
  t: { sym: '<mi>t</mi>', name: 'Time', def: 'In vortex units (length / speed). Taylor–Green peaks in dissipation around t ≈ 5–9, later at higher Re.', space: '<mi>t</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>', col: '--c-w' },
  dt: { sym: '<mi>Δ</mi><mi>t</mi>', name: 'Time step', def: 'One update. Set by the CFL limit of advection only (viscosity is exact): about 0.1 at 32³.', space: '<mi>Δ</mi><mi>t</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--c-w' },
  rk: { sym: '<mi>s</mi>', name: 'Runge–Kutta stage', def: 'Each step evaluates the nonlinear term three times (Williamson’s low-storage RK3) and combines them; only two arrays per field are needed.', space: '<mi>s</mi><mo>∈</mo><mo>{</mo><mn>1</mn><mo>,</mo><mn>2</mn><mo>,</mo><mn>3</mn><mo>}</mo>', col: '--c-w' },
  N: { sym: '<mi>N</mi>', name: 'Grid size', def: 'Points per direction; N³ in all. 32 in the Build step, up to 18 432 in the largest runs.', space: '<mi>N</mi><mo>∈</mo><mi>ℕ</mi><mo>,</mo><mspace width=".4em"/><mtext>a power of 2 for the radix-2 FFT</mtext>', col: '--ink' },
  grad: { sym: '<msub><mo>∂</mo><mi>j</mi></msub>', name: 'Partial derivative', def: 'Rate of change along axis j (∂ₜ: in time). In Fourier space it becomes i kⱼ.', space: '<msub><mo>∂</mo><mi>j</mi></msub><mo>:</mo><mtext>field → field, linear</mtext>', col: '--ink', op: 'D' },
  delta: { sym: '<msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Kronecker delta', def: '1 if i = j, else 0: the 3×3 identity matrix.', space: '<msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo><mn>3</mn></mrow></msup>', col: '--c-w' },
  lc: { sym: '<msub><mi>ϵ</mi><mrow><mi>i</mi><mi>j</mi><mi>l</mi></mrow></msub>', name: 'Levi-Civita symbol', def: '+1 for (x,y,z) in cyclic order, −1 for anti-cyclic, 0 if an index repeats. ϵᵢⱼₗ aⱼ bₗ is the cross product.', space: '<msub><mi>ϵ</mi><mrow><mi>i</mi><mi>j</mi><mi>l</mi></mrow></msub><mo>∈</mo><mo>{</mo><mo>−</mo><mn>1</mn><mo>,</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>}</mo><mo>,</mo><mspace width=".4em"/><mtext>a 3×3×3 table</mtext>', col: '--c-w' },
  om: { sym: '<msub><mi>ω</mi><mi>i</mi></msub>', name: 'Vorticity', def: 'Local spin of the fluid, ω = ∇ × u. In Fourier space ω̂ = i𝐤 × û. Thin tubes of it mark the small eddies.', space: '<msub><mi>ω</mi><mi>i</mi></msub><mo>=</mo><msub><mi>ϵ</mi><mrow><mi>i</mi><mi>j</mi><mi>l</mi></mrow></msub><msub><mo>∂</mo><mi>j</mi></msub><msub><mi>u</mi><mi>l</mi></msub><mo>∈</mo><mi>ℝ</mi>', col: '--c-cs' },
  Nl: { sym: '<msub><mover accent="true"><mi>N</mi><mo>^</mo></mover><mi>i</mi></msub>', name: 'Nonlinear term', def: 'Advection in rotational form, u × ω: computed on the grid, transformed back, then the top third of waves is zeroed (2/3 rule).', space: '<mi>N</mi><mo>:</mo><msup><mi>ℂ</mi><mrow><mn>3</mn><mo>×</mo><msup><mi>N</mi><mn>3</mn></msup></mrow></msup><mo>→</mo><msup><mi>ℂ</mi><mrow><mn>3</mn><mo>×</mo><msup><mi>N</mi><mn>3</mn></msup></mrow></msup><mo>,</mo><mspace width=".4em"/><mtext>quadratic</mtext>', col: '--c-eq', op: 'N' },
  kmax: { sym: '<msub><mi>k</mi><mtext>max</mtext></msub>', name: 'Largest kept wavenumber', def: 'After the 2/3 rule, |kⱼ| ≤ N/3: 10 on the 32³ grid. Eddies smaller than about 2π/k_max are not computed.', space: '<msub><mi>k</mi><mtext>max</mtext></msub><mo>=</mo><mo>⌊</mo><mfrac><mi>N</mi><mn>3</mn></mfrac><mo>⌋</mo><mo>∈</mo><mi>ℕ</mi>', col: '--c-eq', op: 'N' },
  P: { sym: '<msub><mi>P</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Projection', def: 'Removes from each wave the part along 𝐤. That part would compress the fluid; it is exactly what the pressure gradient cancels. Like keeping only the shadow of an arrow on a wall.', space: '<msub><mi>P</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>(</mo><mi>𝐤</mi><mo>)</mo><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo><mn>3</mn></mrow></msup><mo>,</mo><mspace width=".4em"/><mtext>one per wave, linear</mtext>', col: '--c-tau', op: 'P' },
  F: { sym: '<mi>𝓕</mi>', name: 'Fast Fourier transform', def: 'Turns N³ grid values into N³ wave amplitudes (and 𝓕⁻¹ back). Like naming the notes in a chord. Cost N³ log₂ N³ instead of N⁶.', space: '<mi>𝓕</mi><mo>:</mo><msup><mi>ℝ</mi><msup><mi>N</mi><mn>3</mn></msup></msup><mo>→</mo><msup><mi>ℂ</mi><msup><mi>N</mi><mn>3</mn></msup></msup><mo>,</mo><mspace width=".4em"/><mtext>linear, invertible</mtext>', col: '--c-rho', op: 'F' },
  D: { sym: '<mi>i</mi><msub><mi>k</mi><mi>j</mi></msub>', name: 'Spectral derivative', def: 'Multiply each wave by i kⱼ: a quarter turn of phase and a stretch by kⱼ. Exact for every wave on the grid.', space: '<mi>D</mi><mo>:</mo><msub><mover accent="true"><mi>u</mi><mo>^</mo></mover><mi>i</mi></msub><mo>↦</mo><mi>i</mi><msub><mi>k</mi><mi>j</mi></msub><msub><mover accent="true"><mi>u</mi><mo>^</mo></mover><mi>i</mi></msub><mo>,</mo><mspace width=".4em"/><mtext>diagonal, wave by wave</mtext>', col: '--c-c', op: 'D' },
  V: { sym: '<msup><mi>e</mi><mrow><mo>−</mo><mi>ν</mi><msup><mi>k</mi><mn>2</mn></msup><mi>Δ</mi><mi>t</mi></mrow></msup>', name: 'Viscous factor', def: 'Damps each wave by its exact viscous decay over one step: short waves fastest. Like a felt damper on a piano string.', space: '<mi>V</mi><mo>:</mo><msub><mover accent="true"><mi>u</mi><mo>^</mo></mover><mi>i</mi></msub><mo>↦</mo><msup><mi>e</mi><mrow><mo>−</mo><mi>ν</mi><msup><mi>k</mi><mn>2</mn></msup><mi>Δ</mi><mi>t</mi></mrow></msup><msub><mover accent="true"><mi>u</mi><mo>^</mo></mover><mi>i</mi></msub><mo>,</mo><mspace width=".4em"/><mtext>diagonal, each factor ∈ (0, 1]</mtext>', col: '--c-nu', op: 'V' },
  eps: { sym: '<mi>ε</mi>', name: 'Dissipation rate', def: 'Kinetic energy turned into heat per unit mass and time: ε = ν⟨∂ⱼuᵢ∂ⱼuᵢ⟩ = 2νΩ in a periodic box.', space: '<mi>ε</mi><mo>(</mo><mi>t</mi><mo>)</mo><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>', col: '--c-nu' },
  eta: { sym: '<mi>η</mi>', name: 'Kolmogorov scale', def: 'Size of the smallest eddies, where viscosity wins. The grid must resolve it: k_max η ≳ 1 (relaxed) to 1.5 (Pope).', space: '<mi>η</mi><mo>=</mo><msup><mrow><mo>(</mo><msup><mi>ν</mi><mn>3</mn></msup><mo>/</mo><mi>ε</mi><mo>)</mo></mrow><mrow><mn>1</mn><mo>/</mo><mn>4</mn></mrow></msup><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--c-cs' },
  Re: { sym: '<mi>Re</mi>', name: 'Reynolds number', def: 'Inertia over viscosity, UL/ν. Sets how wide the range of eddy sizes is, and so the cost.', space: '<mi>Re</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--ink' },
  L: { sym: '<mi>L</mi>', name: 'Large-eddy size', def: 'Size of the energy-carrying eddies (here 1, in a 2π box).', space: '<mi>L</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--ink' },
  Ek: { sym: '<mi>E</mi><mo>(</mo><mi>k</mi><mo>)</mo>', name: 'Energy spectrum', def: 'Kinetic energy per unit wavenumber: E(k) summed over k is the total energy. Turbulence has E ∼ k^(−5/3) between the big eddies and η.', space: '<mi>E</mi><mo>:</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub><mo>→</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>', col: '--c-f' },
  KE: { sym: '<mi>E</mi>', name: 'Kinetic energy', def: 'E = ½⟨uᵢuᵢ⟩, averaged over the box: 1/8 for the Taylor–Green start.', space: '<mi>E</mi><mo>(</mo><mi>t</mi><mo>)</mo><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>', col: '--c-f' },
  grp: { sym: '<msub><mi>k</mi><mtext>max</mtext></msub><mi>η</mi>', name: 'Resolution number', def: 'Largest kept wavenumber times the Kolmogorov scale. Below about 1 the smallest eddies are missing: no longer a DNS.', space: '<msub><mi>k</mi><mtext>max</mtext></msub><mi>η</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--c-cs' }
 },
 bench(){
  // measures the Build solver headless: one RK stage = 8 sub-tasks; the page runs sub-tasks until 9 ms of the frame are used
  const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
  const S = dnsMake(32); S.init(1/100); for (let i=0;i<12;i++) S.stageStep();
  const subs = [], stages = [], t0 = now(), n = 45;
  for (let i=0;i<n;i++){ const a = now(); for (let k=0;k<S.nsub;k++){ const b = now(); S.work(); subs.push(now()-b); } stages.push(now()-a); }
  subs.sort((x, y) => x-y); stages.sort((x, y) => x-y); const q = (v, f) => +v[Math.min(v.length-1, Math.floor(f*v.length))].toFixed(2);
  const ms = (now()-t0)/n; while (S.t < 6) S.stageStep();
  const H = S.hist; let pk = H[0], err = 0; for (let m=1;m<H.length-1;m++){ if (H[m][2] > pk[2]) pk = H[m]; err = Math.max(err, Math.abs(dnsDEdt(H, m)/H[m][2]-1)); }
  const rp = Math.max(...DNS_REF[100][1]);
  return { grid: '32³, 9 261 dealiased modes × 3', msPerStage: +ms.toFixed(2), msPerStep: +(3*ms).toFixed(1), stageMsMedian: q(stages, .5), subTaskMsMedian: q(subs, .5), subTaskMs95: q(subs, .95), subTaskMsMax: q(subs, 1), subTasksPerStage: S.nsub,
    budget: q(subs, .95) < 9 ? 'fits: the frame loop stops between sub-tasks at 9 ms' : 'a single sub-task exceeds 9 ms on this machine',
    Re100PeakEps: +pk[2].toFixed(5), atT: +pk[0].toFixed(2), ref64PeakEps: rp, peakErrPct: +(100*Math.abs(pk[2]/rp-1)).toFixed(2), maxMismatch_dEdt_vs_2nuOmega_pct: +(100*err).toFixed(3) };
 },
 mount(root, K){ return dnsMount.call(this, root, K); }
});
function mfrac0(a, b){ return `<mfrac><mrow>${a.length > 1 && !a.startsWith('<') ? `<mn>2</mn><mi>π</mi>` : `<mi>${a}</mi>`}</mrow><mrow><mi>${b}</mi></mrow></mfrac>`.replace('<mi>2</mi>', '<mn>2</mn>'); }
function mspace(){ return '<mspace width=".4em"/>'; }

// ======================= mount: every canvas, the how-it-works panels, the Build solver, the Parallelize game =======================
function dnsMount(root, K){
const {$, P, hex, hidpi, arrow, rr, pill, label, ease, lerp, clamp, proj, box, orbit, isAct, MONO, MATH, reduce} = K;
const triad = K.triad, TAU = 2*Math.PI, F10 = '10px "IBM Plex Mono", monospace', F11 = '11px "IBM Plex Mono", monospace', B11 = '600 11px "IBM Plex Mono", monospace', B12 = '600 12px "IBM Plex Mono", monospace', SANS = '600 12px "IBM Plex Sans", sans-serif';
const now0 = () => performance.now(), fx = (v, d=2) => (v < 0 && Math.abs(v) >= .5*Math.pow(10, -d) ? '−' : '') + Math.abs(v).toFixed(d), fv = a => '(' + a.map(v => fx(v)).join(', ') + ')';
const sci = v => { if (!isFinite(v) || v === 0) return '0'; const e = Math.floor(Math.log10(Math.abs(v))), m = v/Math.pow(10, e); return e >= -2 && e <= 3 ? v.toPrecision(3) : `${m.toFixed(2)}·10${String(e).split('').map(c => '⁰¹²³⁴⁵⁶⁷⁸⁹'['0123456789'.indexOf(c)] || (c === '-' ? '⁻' : c)).join('')}`; };
const big = v => v >= 1e6 ? sci(v) : Math.round(v).toLocaleString('en-US').replace(/,/g, ' ');
const rgb = (a, b, t) => `rgb(${a.map((x,i) => Math.round(x+(b[i]-x)*t)).join(',')})`;
const dot3 = (a, b) => a[0]*b[0]+a[1]*b[1]+a[2]*b[2], sub3 = (a, b) => [a[0]-b[0], a[1]-b[1], a[2]-b[2]], scl3 = (a, s) => [a[0]*s, a[1]*s, a[2]*s], add3 = (a, b) => [a[0]+b[0], a[1]+b[1], a[2]+b[2]];
const cross3 = (a, b) => [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]], nrm3 = a => { const l = Math.hypot(...a) || 1; return scl3(a, 1/l); };
// a texture n×n from fn(i, j) -> [r,g,b,alpha 0..1]
function tex(n, fn){ const cv = document.createElement('canvas'); cv.width = n; cv.height = n; const c = cv.getContext('2d'), im = c.createImageData(n, n);
  for (let j=0;j<n;j++) for (let i=0;i<n;i++){ const v = fn(i, j), o = (j*n+i)*4; im.data[o] = v[0]; im.data[o+1] = v[1]; im.data[o+2] = v[2]; im.data[o+3] = 255*v[3]; }
  c.putImageData(im, 0, 0); return cv; }
// paint a texture on the face of the box [-1,1]³ normal to axis a (b, c are the other two axes: texture x along b, y along c)
const AX = [[1,2],[0,2],[0,1]];
function face(c, V, img, a, side){ const [b, d] = AX[a], pt = (ub, vd) => { const p = [0,0,0]; p[a] = side; p[b] = ub; p[d] = vd; return proj(V, ...p); };
  const A0 = pt(-1,-1), B0 = pt(1,-1), C0 = pt(-1,1), w = img.width, h = img.height;
  c.save(); c.transform((B0[0]-A0[0])/w, (B0[1]-A0[1])/w, (C0[0]-A0[0])/h, (C0[1]-A0[1])/h, A0[0], A0[1]); c.imageSmoothingEnabled = true; c.drawImage(img, 0, 0); c.restore(); }
// the three faces seen from inside (their outward normal points away from the viewer)
function backFaces(V){ const o = proj(V, 0, 0, 0)[2], out = []; for (let a=0;a<3;a++) for (const s of [-1,1]){ const n = [0,0,0]; n[a] = s; if (proj(V, ...n)[2] - o < 0) out.push([a, s]); } return out; }

// ===================== 0 · operator walkthrough on one grid line =====================
const G = 16, KC = G/3, gx = [...Array(G)].map((_, n) => TAU*n/G), u0 = gx.map(x => Math.sin(x) + .5*Math.sin(5*x));
const [ur0, ui0] = dnsDFT(u0), dre = new Float64Array(G), dim = new Float64Array(G);
for (let k=0;k<G;k++){ const kw = k === G/2 ? 0 : dnsKw(k, G); dre[k] = -kw*ui0[k]; dim[k] = kw*ur0[k]; }
const du = dnsIDFT(dre, dim), prod = u0.map((v, n) => v*du[n]), [pr0, pi0] = dnsDFT(prod);
const fine = 64, fx64 = [...Array(fine)].map((_, n) => TAU*n/fine), [tr0, ti0] = dnsDFT(fx64.map(x => (Math.sin(x)+.5*Math.sin(5*x))*(Math.cos(x)+2.5*Math.cos(5*x))));
const amp = (re, im, k, N) => (k === 0 || k === N/2 ? 1 : 2)*Math.hypot(re[k], im[k]); // amplitude of the real wave k (k and −k together)
const NUV = 0.02, DTV = 1, fV = k => Math.exp(-NUV*k*k*DTV), kP = [1,2,2], NP = [0.6, 0.3, -0.4];
const OPS = [
 ['u', null, 'Start: one row of the 3D grid, 16 points along x. Here u = sin x + ½ sin 5x: two waves on top of each other. The real state has 32 × 32 × 32 points and 3 components.'],
 ['𝓕', 'F', '𝓕 (the FFT) rewrites the 16 values as 16 wave amplitudes, like naming the notes in a chord. Each arrow is one complex number: length = amplitude, angle = phase. Only k = 1 and k = 5 are there (k < 0 mirror k > 0).'],
 ['D', 'D', 'D: a derivative is a multiplication by i k. Each arrow turns a quarter turn (sin → cos) and stretches by k. Back on the grid (green dots) it equals the exact slope cos x + 2.5 cos 5x to 15 digits. No stencil, no neighbours.'],
 ['N', 'Nl', 'N: the product u·∂u is taken point by point on the grid, then transformed. Products create sums and differences of k. k = 10 is too fast for 16 points and folds back onto k = 6, like a wagon wheel spinning backwards on film. The 2/3 rule zeros every wave above N/3 ≈ 5.3, fake or real.'],
 ['P', 'P', 'P: in 3D each wave 𝐤 keeps only the part of the push perpendicular to 𝐤. The part along 𝐤 would squeeze the fluid, and pressure cancels exactly that. Like keeping only the shadow of an arrow on a wall.'],
 ['V', 'V', 'V: viscosity damps every wave by its exact factor e^(−νk²Δt), the short waves fastest, like a felt damper on a piano string. With ν = 0.02, Δt = 1: k = 1 keeps 98 %, k = 5 keeps 61 %.']];
let opStage = 0, opT = 0, opPlay = !reduce, opLast = null;
const CO = hidpi($('opviz')), opBtns = $('opsteps');
opBtns.innerHTML = OPS.map(([n], k) => `<button class="b opb" data-k="${k}">${k+1} · ${n}</button>`).join('');
opBtns.onclick = e => { const b = e.target.closest('.opb'); if (!b) return; opStage = +b.dataset.k; opT = 0; opCap(); K.pin(OPS[opStage][1]); if (reduce) drawOps(0); };
$('opplay').onclick = e => { opPlay = !opPlay; e.target.textContent = opPlay ? 'Pause' : 'Play'; };
function opCap(){ $('opcap').textContent = OPS[opStage][2]; opBtns.querySelectorAll('.opb').forEach((b, k) => b.classList.toggle('pri', k === opStage)); }
opCap();
function drawOps(now){
  const dt = opLast === null ? 0 : Math.min(100, now - opLast); opLast = now;
  opT = Math.min(opPlay ? 99 : 3.8, opT + dt/1000); if (opPlay && opT > 4.4) { opT = 0; opStage = (opStage+1) % OPS.length; opCap(); }
  const c = CO, W = c.W, p = P(), st = opStage, e = reduce ? 1 : ease(opT/2.0);
  c.clearRect(0, 0, W, c.H);
  // left: the grid line (physical space)
  const L0 = 34, L1 = 404, yc = 132, X = x => L0 + (L1-L0)*x/TAU;
  label(c, st === 4 ? 'one 3D wave 𝐤, with numbers' : 'on the grid: 16 points along x', L0, 22, p.ink, SANS);
  if (st !== 4) {
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(L0, yc); c.lineTo(L1, yc); c.stroke();
    for (let n=0;n<=G;n++){ c.beginPath(); c.moveTo(X(TAU*n/G), yc-3); c.lineTo(X(TAU*n/G), yc+3); c.stroke(); }
    label(c, '0', L0, yc+18, p.mut, F10, 'center'); label(c, '2π', L1, yc+18, p.mut, F10, 'center'); label(c, 'x', L1+14, yc+4, p.mut, MATH);
    const curve = (fn, sc, col, lw, dash, upto) => { c.setLineDash(dash ? [5,4] : []); c.strokeStyle = col; c.lineWidth = lw; c.beginPath();
      for (let q=0;q<=200*(upto ?? 1);q++){ const x = TAU*q/200, y = yc - sc*fn(x); q ? c.lineTo(X(x), y) : c.moveTo(X(x), y); } c.stroke(); c.setLineDash([]); };
    const dots = (vals, sc, col, r, upto) => { c.fillStyle = col; vals.forEach((v, n) => { if (n/G > (upto ?? 1)) return; c.beginPath(); c.arc(X(gx[n]), yc - sc*v, r, 0, 7); c.fill(); }); };
    const uf = x => Math.sin(x)+.5*Math.sin(5*x);
    if (st <= 1) { curve(uf, 46, p.u, 1.6); dots(u0, 46, p.u, 3.6); label(c, 'u(x) = sin x + ½ sin 5x', L0, 44, p.u, B11);
      if (st === 0) u0.forEach((v, n) => { if (n % 2 === 0) label(c, fx(v), X(gx[n]), v > 0 ? yc-46*v-8 : yc-46*v+16, p.mut, '9px "IBM Plex Mono", monospace', 'center'); }); }
    if (st === 2) { curve(uf, 46, p.rule, 1.2); curve(x => Math.cos(x)+2.5*Math.cos(5*x), 22, p.c, 1.4, true); dots(du, 22, p.c, 3.8, e);
      label(c, '∂u/∂x: exact (dashed) vs spectral (dots)', L0, 44, p.c, B11);
      let err = 0; du.forEach((v, n) => err = Math.max(err, Math.abs(v - (Math.cos(gx[n])+2.5*Math.cos(5*gx[n]))))); label(c, `largest error ${sci(err)}`, L0, 60, p.mut, F10); }
    if (st === 3) { curve(x => uf(x)*(Math.cos(x)+2.5*Math.cos(5*x)), 15, p.eq, 1.4, false, e); dots(prod, 15, p.eq, 3.6, e);
      label(c, 'u·∂u, multiplied point by point', L0, 44, p.eq, B11); label(c, '16 multiplications, no sums', L0, 60, p.mut, F10); }
    if (st === 5) { curve(uf, 46, p.rule, 1.4, true); curve(x => fV(1)*Math.sin(x) + lerp(.5, .5*fV(5), e)*Math.sin(5*x), 46, p.u, 2);
      label(c, 'before (dashed) and after one viscous factor', L0, 44, p.u, B11); }
  } else {
    const kk = dot3(kP, kP), kn = dot3(kP, NP), par = scl3(kP, kn/kk), pn = sub3(NP, par), rows = [
      ['𝐤 = (1, 2, 2),  k² = 9', p.c], [`N̂ = ${fv(NP)}`, p.eq], [`kⱼN̂ⱼ = ${fx(kn)}`, p.c], [`along 𝐤: 𝐤·${fx(kn)}/9 = ${fv(par)}`, p.tau], [`P N̂ = N̂ − that = ${fv(pn)}`, p.eq], [`check: kⱼ(P N̂)ⱼ = ${fx(dot3(kP, pn), 3)}`, p.ok]];
    rows.forEach(([t, col], i) => { c.globalAlpha = i < 1 + e*6 ? 1 : .15; label(c, t, L0, 60 + i*26, col, B12); }); c.globalAlpha = 1; }
  // right: Fourier amplitudes k = 0 … 10 (Nyquist k = 8 for 16 points)
  const R0 = 470, sp = 35, KX_ = k => R0 + 18 + k*sp, base = 218, ph = 92;
  if (st !== 4) {
    label(c, 'Fourier amplitudes: one arrow and one bar per wave k', R0, 22, p.ink, SANS);
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(R0, base); c.lineTo(KX_(10)+18, base); c.stroke();
    for (let k=0;k<=10;k++) label(c, String(k), KX_(k), base+14, k > 8 ? p.rule : p.mut, F10, 'center');
    c.setLineDash([3,3]); c.strokeStyle = p.mut; c.beginPath(); c.moveTo(KX_(8)+sp/2, 34); c.lineTo(KX_(8)+sp/2, base+4); c.stroke(); c.setLineDash([]);
    label(c, 'N/2', KX_(8)+sp/2, base+28, p.mut, F10, 'center'); label(c, 'off the grid', KX_(9.5), 44, p.rule, F10, 'center');
    const phasor = (k, re, im, s, col, al) => { const x = KX_(k); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.arc(x, ph, 15, 0, 7); c.stroke();
      const r = Math.hypot(re, im)*s; if (r < .5) return; const a = Math.atan2(im, re); c.globalAlpha = al ?? 1; arrow(c, x, ph, x + Math.min(15, r)*Math.cos(a), ph - Math.min(15, r)*Math.sin(a), col, 2); c.globalAlpha = 1; };
    const bar = (k, v, col, al, dash) => { const h = v; c.globalAlpha = al ?? 1; if (dash) { c.setLineDash([3,3]); c.strokeStyle = col; c.lineWidth = 1.4; rr(c, KX_(k)-8, base-h, 16, h, 3); c.stroke(); c.setLineDash([]); } else { c.fillStyle = col; rr(c, KX_(k)-8, base-h, 16, h, 3); c.fill(); } c.globalAlpha = 1; };
    if (st === 0) for (let k=0;k<=8;k++) phasor(k, 0, 0, 0);
    if (st === 1) for (let k=0;k<=8;k++){ phasor(k, ur0[k], ui0[k], 30*e, p.f); bar(k, 64*amp(ur0, ui0, k, G)*e, p.f); if (k === 1 || k === 5) label(c, `${fx(ui0[k], 2)}i`, KX_(k), ph-22, p.f, F10, 'center'); }
    if (st === 2) for (let k=0;k<=8;k++){ const a0 = Math.atan2(ui0[k], ur0[k]) + e*Math.PI/2, m = Math.hypot(ur0[k], ui0[k])*lerp(1, k, e); phasor(k, m*Math.cos(a0), m*Math.sin(a0), 30/lerp(1, 5, e), p.c);
      bar(k, 64*amp(ur0, ui0, k, G)*lerp(1, k, e)/lerp(1, 5, e), p.c); if (k === 1 || k === 5) label(c, `×i·${k}`, KX_(k), ph-22, p.c, F10, 'center'); }
    if (st === 3) { const cut = clamp((opT-1.6)/1.0, 0, 1), kept = k => k <= KC;
      c.fillStyle = p.eq; c.globalAlpha = .07 + .08*cut; c.fillRect(KX_(KC)+4, 30, KX_(10)+18-KX_(KC)-4, base-30); c.globalAlpha = 1;
      c.setLineDash([5,3]); c.strokeStyle = p.eq; c.lineWidth = 1.6; c.beginPath(); c.moveTo(KX_(KC), 30); c.lineTo(KX_(KC), base); c.stroke(); c.setLineDash([]);
      label(c, 'N/3: 2/3 rule', KX_(KC)-4, 56, p.eq, B11, 'right');
      const sc = 34/Math.max(...[...Array(9)].map((_, k) => amp(pr0, pi0, k, G)));
      for (let k=0;k<=8;k++){ const v = amp(pr0, pi0, k, G)*sc*64/34; bar(k, v*(kept(k) ? 1 : 1-cut), p.eq, e); phasor(k, pr0[k]*(kept(k) ? 1 : 1-cut), pi0[k]*(kept(k) ? 1 : 1-cut), 120*e, p.eq); }
      // the true k = 6 part, and the k = 10 part that folds onto it
      bar(6, amp(tr0, ti0, 6, fine)*sc*64/34, p.ink, e*(1-cut)*.9, true); bar(10, amp(tr0, ti0, 10, fine)*sc*64/34, p.warm, e*.9, true);
      label(c, 'true k = 10', KX_(10)+8, base - amp(tr0, ti0, 10, fine)*sc*64/34 - 8, p.warm, F10, 'right');
      if (e > .5) { const y0 = base - amp(tr0, ti0, 10, fine)*sc*64/34 - 22; c.strokeStyle = p.warm; c.lineWidth = 1.6; c.setLineDash([4,3]); c.beginPath(); c.moveTo(KX_(10), y0); c.quadraticCurveTo(KX_(8), y0-34, KX_(6)+6, y0-6); c.stroke(); c.setLineDash([]);
        label(c, 'folds to 16 − 10 = 6 (alias)', KX_(8), y0-38, p.warm, F10, 'center'); } }
    if (st === 5) for (const k of [1, 5]){ const f = lerp(1, fV(k), e); phasor(k, ur0[k]*f, ui0[k]*f, 30, p.u); bar(k, 64*amp(ur0, ui0, k, G)*f, p.u); bar(k, 64*amp(ur0, ui0, k, G), p.u, .5, true);
      label(c, `×${fV(k).toFixed(3)}`, KX_(k), base - 64*amp(ur0, ui0, k, G) - 8, p.nu, B11, 'center'); }
  } else {
    // P: the wave vector, the push, and its shadow on the plane ⟂ 𝐤
    const V = {th:-0.75 + (reduce ? 0 : now*0.00015), ph:0.35, s:80, ox:660, oy:120}, kh = nrm3(kP), par = scl3(kh, dot3(kh, NP)), pn = sub3(NP, par);
    label(c, 'the push N̂ and its part ⟂ 𝐤', R0, 22, p.ink, SANS);
    const e1 = nrm3(cross3(kh, [0,0,1])), e2 = cross3(kh, e1); c.beginPath(); for (let q=0;q<=40;q++){ const a = TAU*q/40, v = add3(scl3(e1, 1.1*Math.cos(a)), scl3(e2, 1.1*Math.sin(a))), s = proj(V, ...v); q ? c.lineTo(s[0], s[1]) : c.moveTo(s[0], s[1]); }
    c.fillStyle = p.tau; c.globalAlpha = .12; c.fill(); c.globalAlpha = .5; c.strokeStyle = p.tau; c.lineWidth = 1; c.stroke(); c.globalAlpha = 1;
    const O = proj(V, 0, 0, 0), A = (v, col, lw, dash, al) => { const s = proj(V, ...v); c.globalAlpha = al ?? 1; arrow(c, O[0], O[1], s[0], s[1], col, lw, dash); c.globalAlpha = 1; return s; };
    const ks = A(scl3(kh, 1.35), p.c, 3); label(c, '𝐤', ks[0]+8, ks[1], p.c, MATH);
    const ns = A(scl3(NP, 1.6), p.eq, 2.6, false, 1-.6*e); label(c, 'N̂', ns[0]+8, ns[1]-4, p.eq, MATH);
    const off = scl3(kh, .9*e), s0 = proj(V, ...off), s1 = proj(V, ...add3(off, scl3(par, 1.6))); c.globalAlpha = 1-e*.8; arrow(c, s0[0], s0[1], s1[0], s1[1], p.tau, 2.4, true); c.globalAlpha = 1;
    label(c, '−∂ᵢp removes this', s1[0]+8, s1[1]+4, p.tau, F10);
    const ps = A(scl3(pn, 1.6), p.eq, 3.4, false, .3+.7*e); label(c, 'P N̂', ps[0]+8, ps[1]+12, p.eq, B11);
    triad(c, V, 820, 196, p); }
  // bottom: where each operator sits in one update
  const boxes = ['u on grid', 'û', 'i k û', 'N̂, cut', 'P N̂', 'û, damped'], ops = ['𝓕', 'D', 'N', 'P', 'V'], by = 268, bw = 104, gp = 37, bx0 = (W - (6*bw + 5*gp))/2;
  boxes.forEach((t, i) => { const x = bx0 + i*(bw+gp), on = i === st; rr(c, x, by, bw, 30, 8); c.fillStyle = on ? p.accSoft : p.panel; c.fill(); c.strokeStyle = on ? p.acc : p.rule; c.lineWidth = on ? 2 : 1; c.stroke();
    label(c, t, x + bw/2, by + 19, on ? p.ink : p.mut, F11, 'center');
    if (i < 5) { const a = x + bw + 3, b = a + gp - 6, onA = i+1 === st; arrow(c, a, by+15, b, by+15, onA ? p.ink : p.rule, onA ? 2.4 : 1.4); label(c, ops[i], (a+b)/2, by - 6, onA ? p.ink : p.mut, MATH, 'center'); } });
  label(c, 'one update, for every wave and every grid point of the 3D box', W/2, by + 58, p.mut, F11, 'center');
}

// ===================== how-it-works panels, one per operator =====================
const mt = s => `<div class="hm"><math display="block">${s}</math></div>`, tc = (col, x) => `<mrow style="color:var(${col})">${x}</mrow>`, sw = col => `<i class="tb" style="background:var(${col})"></i>`;
const HS = {F: 2, D: 5, P: 1, N: 3, V: 1};
const btns = (key, list, cur) => `<div class="eex"><span>Example</span>${list.map((t, i) => `<button class="b${i === cur ? ' pri' : ''}" data-x="${i}">${t}</button>`).join('')}</div>`;
const bindX = (key, op) => function(rt){ rt.querySelectorAll('[data-x]').forEach(b => b.onclick = () => { HS[key] = +b.dataset.x; rt.querySelectorAll('[data-x]').forEach(x => x.classList.toggle('pri', x === b)); op.draw(rt); }); };
const SIG = [['sin x', x => Math.sin(x)], ['cos 2x', x => Math.cos(2*x)], ['sin x + ½ sin 3x', x => Math.sin(x)+.5*Math.sin(3*x)], ['step', x => x < Math.PI ? 1 : -1]];
const DK = [1, 3, 5, 7], PK = [[1,0,0],[1,1,0],[2,-1,2],[0,3,1]], NPAIR = [[2,3],[3,4],[4,5],[5,5]], VRE = [10, 100, 1600], NPv = [0.6, 0.3, -0.4];
const HOW = {
 F: { html: () => `<span class="eyebrow">How 𝓕 works</span>
   ${mt(`<msub><mover accent="true"><mi>u</mi><mo>^</mo></mover><mi>k</mi></msub><mo>=</mo>${tc('--c-w', '<mfrac><mn>1</mn><mi>N</mi></mfrac>')}<munderover><mo>∑</mo><mrow><mi>n</mi><mo>=</mo><mn>0</mn></mrow><mrow><mi>N</mi><mo>−</mo><mn>1</mn></mrow></munderover>${tc('--c-u', '<msub><mi>u</mi><mi>n</mi></msub>')}${tc('--c-c', '<msup><mi>e</mi><mrow><mo>−</mo><mi>i</mi><mi>k</mi><msub><mi>x</mi><mi>n</mi></msub></mrow></msup>')}`)}
   <div class="eterms"><span>${sw('--c-u')}uₙ</span><span>The values at the N grid points.</span>
     <span>${sw('--c-c')}e^(−ikxₙ)</span><span>A test wave: the sum measures how much of wave k is in the data, and its phase.</span>
     <span>${sw('--c-w')}1/N</span><span>Average, so a wave of height 1 gives |ûₖ| = ½ at k and at −k.</span></div>
   <p>In 3D: 1D FFTs along x, then y, then z. The FFT reuses half-sums (butterflies): N log₂N work instead of N².</p>
   ${btns('F', SIG.map(s => s[0]), HS.F)}<canvas class="hc" data-w="420" data-h="120"></canvas><div class="ecalc"></div>`,
  draw(rt){ const c = hidpi(rt.querySelector('canvas')), p = P(), N = 8, f = SIG[HS.F][1], xs = [...Array(N)].map((_, n) => TAU*n/N), u = xs.map(f), [re, im] = dnsDFT(u), yc = 60;
   c.clearRect(0, 0, c.W, c.H); label(c, 'uₙ, N = 8', 8, 14, p.u, F10); label(c, 'ûₖ: real ▮ imag ▮', 228, 14, p.mut, F10);
   c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(8, yc); c.lineTo(200, yc); c.moveTo(222, yc); c.lineTo(414, yc); c.stroke();
   c.strokeStyle = p.u; c.lineWidth = 1.2; c.beginPath(); for (let q=0;q<=100;q++){ const x = TAU*q/100, y = yc-34*f(x); q ? c.lineTo(12+184*q/100, y) : c.moveTo(12, y); } c.globalAlpha = .4; c.stroke(); c.globalAlpha = 1;
   u.forEach((v, n) => { const x = 12+184*n/N; c.strokeStyle = p.u; c.lineWidth = 2; c.beginPath(); c.moveTo(x, yc); c.lineTo(x, yc-34*v); c.stroke(); c.fillStyle = p.u; c.beginPath(); c.arc(x, yc-34*v, 3, 0, 7); c.fill(); });
   for (let j=0;j<N;j++){ const k = j - 3, q = (k+N)%N, x = 236 + j*23; c.fillStyle = p.rho; rr(c, x, Math.min(yc, yc-60*re[q]), 8, Math.abs(60*re[q]), 2); c.fill(); c.fillStyle = p.f; rr(c, x+9, Math.min(yc, yc-60*im[q]), 8, Math.abs(60*im[q]), 2); c.fill();
     label(c, String(k), x+8, c.H-8, p.mut, F10, 'center'); }
   label(c, 'k', 414, c.H-8, p.mut, MATH, 'right');
   const nz = []; for (let k=-3;k<=4;k++){ const q = (k+N)%N; if (Math.hypot(re[q], im[q]) > 1e-9) nz.push(`û${k < 0 ? '₋' : ''}${'₀₁₂₃₄'[Math.abs(k)]} = ${fx(re[q], 3)} ${im[q] < 0 ? '−' : '+'} ${Math.abs(im[q]).toFixed(3)}i`); }
   rt.querySelector('.ecalc').textContent = nz.slice(0, 6).join(' · ') + (nz.length > 6 ? ' · …' : '') + ` · direct sum: ${N*N} multiplications, FFT: ${N/2*Math.log2(N)} butterflies · on 32³: N³log₂N³ ≈ 4.9·10⁵ vs N⁶ ≈ 1.1·10⁹`; } },
 D: { html: () => `<span class="eyebrow">How D works</span>
   ${mt(`<msub><mover accent="true"><mrow><mo>(</mo><msub><mo>∂</mo><mi>x</mi></msub><mi>u</mi><mo>)</mo></mrow><mo>^</mo></mover><mi>k</mi></msub><mo>=</mo>${tc('--c-tau', '<mi>i</mi>')}${tc('--c-c', '<mi>k</mi>')}${tc('--c-f', '<msub><mover accent="true"><mi>u</mi><mo>^</mo></mover><mi>k</mi></msub>')}`)}
   <div class="eterms"><span>${sw('--c-tau')}i</span><span>A quarter turn of phase: the slope of a sine is a cosine.</span>
     <span>${sw('--c-c')}k</span><span>Short waves are steeper: the slope scales with the wavenumber.</span>
     <span>${sw('--c-f')}ûₖ</span><span>The wave’s amplitude. Every wave is handled on its own.</span></div>
   ${btns('D', DK.map(k => `sin ${k}x`), DK.indexOf(HS.D) < 0 ? 2 : DK.indexOf(HS.D))}<canvas class="hc" data-w="420" data-h="120"></canvas><div class="lg"><span style="color:var(--c-c)">● spectral</span><span style="color:var(--warm)">■ central difference</span><span class="note">line: exact</span></div><div class="ecalc"></div>`,
  draw(rt){ const c = hidpi(rt.querySelector('canvas')), p = P(), N = 16, k = HS.D, xs = [...Array(N)].map((_, n) => TAU*n/N), u = xs.map(x => Math.sin(k*x)), [re, im] = dnsDFT(u), dx = TAU/N;
   const r2 = new Float64Array(N), i2 = new Float64Array(N); for (let q=0;q<N;q++){ const kw = q === N/2 ? 0 : dnsKw(q, N); r2[q] = -kw*im[q]; i2[q] = kw*re[q]; }
   const sp = dnsIDFT(r2, i2), fd = u.map((_, n) => (u[(n+1)%N]-u[(n-1+N)%N])/(2*dx)), ex = xs.map(x => k*Math.cos(k*x)), yc = 60, sy = 50/k, X = x => 14 + 392*x/TAU;
   c.clearRect(0, 0, c.W, c.H); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(14, yc); c.lineTo(406, yc); c.stroke();
   c.strokeStyle = p.ink; c.lineWidth = 1.2; c.beginPath(); for (let q=0;q<=300;q++){ const x = TAU*q/300, y = yc - sy*k*Math.cos(k*x); q ? c.lineTo(X(x), y) : c.moveTo(X(x), y); } c.stroke();
   fd.forEach((v, n) => { c.fillStyle = p.warm; c.fillRect(X(xs[n])-3, yc-sy*v-3, 6, 6); });
   sp.forEach((v, n) => { c.fillStyle = p.c; c.beginPath(); c.arc(X(xs[n]), yc-sy*v, 3.4, 0, 7); c.fill(); });
   const eS = Math.max(...sp.map((v, n) => Math.abs(v-ex[n]))), eF = Math.max(...fd.map((v, n) => Math.abs(v-ex[n])));
   rt.querySelector('.ecalc').textContent = `u = sin ${k}x on 16 points: spectral max error ${sci(eS)}; central difference (u₍ₙ₊₁₎ − u₍ₙ₋₁₎)/2Δx max error ${eF.toFixed(3)} = ${(100*eF/k).toFixed(1)} % of the slope (it sees sin(kΔx)/Δx = ${(Math.sin(k*dx)/dx).toFixed(3)} instead of k = ${k}).`; } },
 P: { html: () => `<span class="eyebrow">How P works</span>
   ${mt(`<msub><mi>P</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><msub><mover accent="true"><mi>N</mi><mo>^</mo></mover><mi>j</mi></msub><mo>=</mo>${tc('--c-eq', '<msub><mover accent="true"><mi>N</mi><mo>^</mo></mover><mi>i</mi></msub>')}<mo>−</mo>${tc('--c-tau', '<msub><mi>k</mi><mi>i</mi></msub><mfrac><mrow><msub><mi>k</mi><mi>j</mi></msub><msub><mover accent="true"><mi>N</mi><mo>^</mo></mover><mi>j</mi></msub></mrow><msup><mi>k</mi><mn>2</mn></msup></mfrac>')}`)}
   <div class="eterms"><span>${sw('--c-eq')}N̂ᵢ</span><span>The push from advection on wave 𝐤.</span>
     <span>${sw('--c-tau')}kᵢ(kⱼN̂ⱼ)/k²</span><span>Its part along 𝐤: it would make kⱼûⱼ ≠ 0, i.e. compress the fluid. This is −ikᵢp̂: the pressure gradient.</span></div>
   ${btns('P', PK.map(k => `𝐤 = (${k.join(', ')})`), HS.P)}<canvas class="hc" data-w="300" data-h="190"></canvas><div class="ecalc"></div>`,
  draw(rt){ const c = hidpi(rt.querySelector('canvas')), p = P(), k = PK[HS.P], kk = dot3(k, k), kn = dot3(k, NPv), par = scl3(k, kn/kk), pn = sub3(NPv, par), V = {th:-0.7, ph:0.35, s:70, ox:130, oy:100}, kh = nrm3(k);
   c.clearRect(0, 0, c.W, c.H);
   const e1 = nrm3(cross3(kh, Math.abs(kh[2]) < .9 ? [0,0,1] : [1,0,0])), e2 = cross3(kh, e1); c.beginPath(); for (let q=0;q<=40;q++){ const a = TAU*q/40, s = proj(V, ...add3(scl3(e1, Math.cos(a)), scl3(e2, Math.sin(a)))); q ? c.lineTo(s[0], s[1]) : c.moveTo(s[0], s[1]); }
   c.fillStyle = p.tau; c.globalAlpha = .12; c.fill(); c.globalAlpha = 1;
   const O = proj(V, 0, 0, 0), A = (v, col, lw, dash) => { const s = proj(V, ...v); arrow(c, O[0], O[1], s[0], s[1], col, lw, dash); return s; };
   const ks = A(scl3(kh, 1.2), p.c, 2.6); label(c, '𝐤', ks[0]+6, ks[1], p.c, MATH);
   A(scl3(NPv, 1.5), p.eq, 1.6, true); const s1 = A(scl3(par, 1.5), p.tau, 2.2, true), s2 = A(scl3(pn, 1.5), p.eq, 3);
   label(c, 'P N̂', s2[0]+6, s2[1]+12, p.eq, B11); triad(c, V, 262, 160, p);
   rt.querySelector('.ecalc').textContent = `kⱼN̂ⱼ = ${fx(kn, 3)}, k² = ${kk} → along 𝐤: ${fv(par)} → P N̂ = ${fv(pn)}; check kⱼ(PN̂)ⱼ = ${fx(dot3(k, pn), 4)}; pressure wave p̂ = −i·${fx(kn/kk, 3)}`; } },
 N: { html: () => `<span class="eyebrow">How N works</span>
   ${mt(`<msub><mover accent="true"><mi>N</mi><mo>^</mo></mover><mi>i</mi></msub><mo>=</mo>${tc('--c-rho', '<mi>𝓕</mi>')}<mo>[</mo>${tc('--c-eq', '<msub><mi>ϵ</mi><mrow><mi>i</mi><mi>j</mi><mi>l</mi></mrow></msub><msub><mi>u</mi><mi>j</mi></msub><msub><mi>ω</mi><mi>l</mi></msub>')}<mo>]</mo><mo>,</mo><mspace width="1em"/>${tc('--c-tau', '<mtext>keep </mtext><mo>|</mo><msub><mi>k</mi><mi>j</mi></msub><mo>|</mo><mo>≤</mo><mfrac><mi>N</mi><mn>3</mn></mfrac>')}`)}
   <div class="eterms"><span>${sw('--c-eq')}ϵᵢⱼₗuⱼωₗ</span><span>u × ω, multiplied point by point on the grid: N³ products.</span>
     <span>${sw('--c-rho')}𝓕</span><span>Back to waves. A product of waves k₁ and k₂ has k₁ ± k₂; above N/2 the grid shows it at the wrong k (aliasing).</span>
     <span>${sw('--c-tau')}2/3 rule</span><span>Kept waves have |k| ≤ N/3, so sums reach 2N/3 and fold back only onto |k| > N/3: zeroing those removes every alias.</span></div>
   ${btns('N', NPAIR.map(([a, b]) => `cos ${a}x · cos ${b}x`), HS.N)}<canvas class="hc" data-w="420" data-h="110"></canvas><div class="ecalc"></div>`,
  draw(rt){ const c = hidpi(rt.querySelector('canvas')), p = P(), N = 16, [a, b] = NPAIR[HS.N], s = a+b, d = b-a, al = s > N/2 ? N - s : s, X = k => 20 + k*24, y = 62;
   c.clearRect(0, 0, c.W, c.H);
   c.fillStyle = p.tau; c.globalAlpha = .1; c.fillRect(X(N/3), 18, X(16)-X(N/3), 66); c.globalAlpha = 1;
   c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(X(0), y); c.lineTo(X(16), y); c.stroke();
   for (let k=0;k<=16;k++) label(c, String(k), X(k), y+16, k > 8 ? p.rule : p.mut, F10, 'center');
   c.setLineDash([3,3]); c.strokeStyle = p.mut; c.beginPath(); c.moveTo(X(8), 14); c.lineTo(X(8), y+4); c.stroke(); c.strokeStyle = p.tau; c.beginPath(); c.moveTo(X(N/3), 14); c.lineTo(X(N/3), y+4); c.stroke(); c.setLineDash([]);
   label(c, 'N/2 = 8', X(8)+4, 12, p.mut, F10); label(c, 'N/3', X(N/3)-4, 12, p.tau, F10, 'right'); label(c, 'zeroed', X(12), 34, p.tau, F10, 'center');
   const dotk = (k, col, r) => { c.fillStyle = col; c.beginPath(); c.arc(X(k), y, r, 0, 7); c.fill(); };
   dotk(a, p.c, 5); dotk(b, p.c, 5); dotk(d, p.eq, 4.5); dotk(s, s > 8 ? p.warm : p.eq, 4.5);
   if (s > 8) { c.strokeStyle = p.warm; c.lineWidth = 1.6; c.setLineDash([4,3]); c.beginPath(); c.moveTo(X(s), y-8); c.quadraticCurveTo(X(8), y-50, X(al), y-8); c.stroke(); c.setLineDash([]); dotk(al, p.warm, 4.5); label(c, 'alias', X(al), y+30, p.warm, F10, 'center'); }
   const xs = [...Array(N)].map((_, n) => TAU*n/N); let mx = 0; xs.forEach(x => mx = Math.max(mx, Math.abs(Math.cos(a*x)*Math.cos(b*x) - .5*Math.cos(d*x) - .5*Math.cos(al*x))));
   rt.querySelector('.ecalc').textContent = `cos ${a}x · cos ${b}x = ½cos ${d}x + ½cos ${s}x. ` + (s > 8 ? `On 16 points cos ${s}x is identical to cos ${al}x (max difference ${sci(mx)}): the grid shows a fake k = ${al}. ${al > N/3 ? `${al} > N/3 = 5.33, so the 2/3 rule zeros it.` : `It would survive.`}` : `k = ${s} fits on the grid (no alias); ${s > N/3 ? 'it is above N/3 and zeroed anyway.' : 'it is kept.'}`) + ` In 3D the grid product is 32³ = 32 768 multiplications; done as a Fourier convolution it would be (21³)² ≈ 8.6·10⁷.`; } },
 V: { html: () => `<span class="eyebrow">How V works</span>
   ${mt(`<msub><mover accent="true"><mi>u</mi><mo>^</mo></mover><mi>i</mi></msub><mo>(</mo><mi>t</mi><mo>+</mo><mi>Δ</mi><mi>t</mi><mo>)</mo><mo>=</mo>${tc('--c-nu', '<msup><mi>e</mi><mrow><mo>−</mo><mi>ν</mi><msup><mi>k</mi><mn>2</mn></msup><mi>Δ</mi><mi>t</mi></mrow></msup>')}<msub><mover accent="true"><mi>u</mi><mo>^</mo></mover><mi>i</mi></msub><mo>(</mo><mi>t</mi><mo>)</mo><mspace width="1em"/><mtext>vs</mtext><mspace width="1em"/>${tc('--c-w', '<mo>(</mo><mn>1</mn><mo>−</mo><mi>ν</mi><msup><mi>k</mi><mn>2</mn></msup><mi>Δ</mi><mi>t</mi><mo>)</mo>')}<msub><mover accent="true"><mi>u</mi><mo>^</mo></mover><mi>i</mi></msub>`)}
   <div class="eterms"><span>${sw('--c-nu')}e^(−νk²Δt)</span><span>The exact decay of wave k over one step. Always between 0 and 1: never unstable.</span>
     <span>${sw('--c-w')}1 − νk²Δt</span><span>An explicit (Euler) step: for νk²Δt &gt; 2 it flips sign and grows, so Δt would have to shrink like 1/k².</span></div>
   <p>The solver writes û = e^(−νk²t)·v and steps v: the advection part is Runge–Kutta, viscosity is exact.</p>
   ${btns('V', VRE.map(r => `Re = ${r}`), HS.V)}<canvas class="hc" data-w="420" data-h="120"></canvas><div class="ecalc"></div>`,
  draw(rt){ const c = hidpi(rt.querySelector('canvas')), p = P(), nu = 1/VRE[HS.V], dt = 0.1, km = 10*Math.sqrt(3), X = k => 34 + 370*k/km, Y = v => 50 - 34*v;
   c.clearRect(0, 0, c.W, c.H); c.fillStyle = p.nu; c.globalAlpha = .08; c.fillRect(34, Y(-1), 370, Y(-3)-Y(-1)); c.globalAlpha = 1;
   c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(34, Y(0)); c.lineTo(404, Y(0)); c.moveTo(34, 8); c.lineTo(34, 112); c.stroke();
   label(c, '1', 28, Y(1)+4, p.mut, F10, 'right'); label(c, '0', 28, Y(0)+4, p.mut, F10, 'right'); label(c, '−1', 28, Y(-1)+4, p.mut, F10, 'right'); label(c, 'unstable', 400, Y(-1.6), p.nu, F10, 'right');
   label(c, 'k', 404, Y(0)+14, p.mut, MATH, 'right'); label(c, '|𝐤| max = 17.3', X(km), 116, p.mut, F10, 'right');
   const cv = (fn, col, dash) => { c.setLineDash(dash ? [5,4] : []); c.strokeStyle = col; c.lineWidth = 2; c.beginPath(); for (let q=0;q<=100;q++){ const k = km*q/100, y = Y(clamp(fn(k), -2, 1.2)); q ? c.lineTo(X(k), y) : c.moveTo(X(k), y); } c.stroke(); c.setLineDash([]); };
   cv(k => 1 - nu*k*k*dt, p.w, true); cv(k => Math.exp(-nu*k*k*dt), p.nu);
   const r = k => `k = ${k.toFixed(1)}: exact ${Math.exp(-nu*k*k*dt).toFixed(3)}, Euler ${(1-nu*k*k*dt).toFixed(3)}`;
   rt.querySelector('.ecalc').textContent = `ν = ${nu}, Δt = ${dt}: ${r(10)} · ${r(km)}${1-nu*km*km*dt < -1 ? ' → the explicit step blows up; the exact factor does not.' : ' → both fine here; the exact factor also removes the error.'}`; } }
};
['F','D','P','N','V'].forEach(k => HOW[k].bind = bindX(k, HOW[k]));
HOW.D.bind = function(rt){ rt.querySelectorAll('[data-x]').forEach(b => b.onclick = () => { HS.D = DK[+b.dataset.x]; rt.querySelectorAll('[data-x]').forEach(x => x.classList.toggle('pri', x === b)); HOW.D.draw(rt); }); };

// ===================== A · the Taylor–Green vortex and the four terms =====================
const CA = hidpi($('nsviz')), VA = {th:-0.62, ph:0.36, s:96, ox:210, oy:176}; orbit($('nsviz'), VA);
const tgU = (x, y, z) => dnsTG(x, y, z), tgAdv = (x, y, z) => [.5*Math.sin(2*x)*Math.cos(z)**2, .5*Math.sin(2*y)*Math.cos(z)**2, 0];
const tgGp = (x, y, z) => [-Math.sin(2*x)*(Math.cos(2*z)+2)/8, -Math.sin(2*y)*(Math.cos(2*z)+2)/8, -(Math.cos(2*x)+Math.cos(2*y))*Math.sin(2*z)/8];
const tgP = (x, y, z) => (Math.cos(2*x)+Math.cos(2*y))*(Math.cos(2*z)+2)/16;
// box-averaged |advection| / |viscous| per unit Re, sampled on 16³ points (viscous = 3ν|u| for this field)
const aRMS = (() => { let a = 0, v = 0; for (let i=0;i<16;i++) for (let j=0;j<16;j++) for (let k=0;k<16;k++){ const q = [i, j, k].map(t => TAU*(t+.5)/16); a += dot3(tgAdv(...q), tgAdv(...q)); const u = tgU(...q); v += 9*dot3(u, u); } return Math.sqrt(a/v); })();
let aRe = 100, aClk = 0, aLast = null, aSlide = -1e9, aGhost = [];
const D3 = (x, y, z) => proj(VA, x/Math.PI-1, y/Math.PI-1, z/Math.PI-1);
const parts = [...Array(90)].map((_, i) => ({ q: [TAU*((i*0.618)%1), TAU*((i*0.382+.1)%1), TAU*((i*0.7548)%1)], tr: [], age: (i*37)%300 }));
let pTex = null, pTexKey = '';
function pressureTex(){ const p = P(), key = p.tau + p.c + p.bg; if (key === pTexKey) return pTex; pTexKey = key; const a = hex(p.bg), hi = hex(p.tau), lo = hex(p.c);
  return pTex = tex(32, (i, j) => { const v = tgP(TAU*i/32, 0, TAU*j/32)/0.375; return [...(v > 0 ? hi : lo).map((x, q) => a[q]+(x-a[q])*Math.min(1, Math.abs(v))), .9]; }); }
const aIn = $('are');
aIn.oninput = () => { const old = aRe; aRe = Math.round(Math.pow(10, +aIn.value)); $('arev').textContent = aRe; if (!aGhost.includes(old) && now0() - aSlide > 600) aGhost = [old, ...aGhost].slice(0, 3); aSlide = now0(); if (reduce) drawA(0); };
function drawA(now){
  const dt = aLast === null ? 0 : Math.min(100, now - aLast); aLast = now; const hold = now - aSlide < 2200; if (!hold) aClk += dt;
  if (!VA.drag && !reduce) VA.th += dt*0.00008;
  const c = CA, W = c.W, p = P(), nu = 1/aRe; c.clearRect(0, 0, W, c.H);
  // floor: the pressure field at y = 0
  c.globalAlpha = isAct('p', 'press') ? .9 : .35; face(c, VA, pressureTex(), 1, -1); c.globalAlpha = 1;
  box(c, VA, 1, 1, 1, isAct('x') ? p.ink : p.mut, isAct('x') ? 2 : 1);
  // velocity arrows on a 4 × 4 × 4 lattice
  const aOn = isAct('u'); c.globalAlpha = aOn ? 1 : .28;
  for (let a=0;a<4;a++) for (let b=0;b<4;b++) for (let d=0;d<4;d++){ const x = (a+.5)*Math.PI/2, y = (b+.5)*Math.PI/2, z = (d+.5)*Math.PI/2, u = tgU(x, y, z), A0 = D3(x, y, z), A1 = D3(x+u[0]*1.6, y+u[1]*1.6, z+u[2]*1.6);
    arrow(c, A0[0], A0[1], A1[0], A1[1], p.u, aOn ? 2 : 1.3); }
  c.globalAlpha = 1;
  // tracers swept by the initial field
  const h = reduce ? 0 : dt*0.0016;
  parts.forEach(o => { if (h) { const u1 = tgU(...o.q), m = add3(o.q, scl3(u1, h/2)), u2 = tgU(...m); o.q = o.q.map((v, i) => ((v + h*u2[i]) % TAU + TAU) % TAU); o.tr.push(o.q.slice()); if (o.tr.length > 14) o.tr.shift(); if (++o.age > 500) { o.age = 0; o.tr = []; o.q = [TAU*Math.random(), TAU*Math.random(), TAU*Math.random()]; } }
    c.fillStyle = p.u; c.globalAlpha = .18; o.tr.forEach((q, i) => { if (i % 3) return; const s = D3(...q); c.fillRect(s[0]-1, s[1]-1, 2, 2); }); c.globalAlpha = .7; const s = D3(...o.q); c.beginPath(); c.arc(s[0], s[1], 1.8, 0, 7); c.fill(); c.globalAlpha = 1; });
  // the probe and the four terms there
  const tt = aClk/1000, pr = [Math.PI/2 + 1.1*Math.sin(.31*tt), Math.PI/3 + .9*Math.cos(.23*tt), Math.PI/4 + .7*Math.sin(.17*tt+1)];
  const u = tgU(...pr), adv = tgAdv(...pr), gp = tgGp(...pr), vis = scl3(u, -3*nu), mgp = scl3(gp, -1), sum = add3(add3(scl3(adv, -1), mgp), vis), S = 7;
  const O = D3(...pr), T = (v, col, lw, dash, on) => { const e = D3(...add3(pr, scl3(v, S))); c.globalAlpha = on ? 1 : .8; arrow(c, O[0], O[1], e[0], e[1], col, on ? lw+1.4 : lw, dash); c.globalAlpha = 1; };
  T(scl3(adv, -1), p.eq, 2.2, false, isAct('adv', 'Nl')); T(mgp, p.tau, 2.2, false, isAct('press', 'p', 'P')); T(vis, p.nu, 2.4, false, isAct('visc', 'nu', 'V', 'Re')); T(sum, p.f, 2.2, true, isAct('dudt', 'grad', 't'));
  c.fillStyle = p.ink; c.beginPath(); c.arc(O[0], O[1], isAct('x') ? 5 : 3.5, 0, 7); c.fill();
  label(c, 'probe', O[0]+8, O[1]-8, p.ink, F10);
  label(c, 'Taylor–Green vortex, t = 0', 12, 20, p.mut, MONO); label(c, 'arrows at the probe: −advection, −∂ᵢp, viscous, sum', 12, 36, p.mut, F10);
  triad(c, VA, 30, 300, p);
  // bars: size of each term at the probe
  const bx = 150, bw = 280, by = 334, rows = [['advection |uⱼ∂ⱼuᵢ|', Math.hypot(...adv), p.eq, 'adv'], ['pressure |∂ᵢp|', Math.hypot(...gp), p.tau, 'press'], ['viscous |ν∂ⱼ∂ⱼuᵢ|', Math.hypot(...vis), p.nu, 'visc'], ['change |∂ₜuᵢ|', Math.hypot(...sum), p.f, 'dudt']];
  const sc = bw/0.6;
  rows.forEach(([n, v, col, key], i) => { const y = by + i*22, on = isAct(key) || (key === 'visc' && (hold || isAct('nu', 'Re', 'V')));
    label(c, n, bx-8, y+4, on ? p.ink : p.mut, F10, 'right'); c.fillStyle = col; c.globalAlpha = on ? 1 : .75; rr(c, bx, y-6, Math.max(1.5, Math.min(bw, v*sc)), 12, 3); c.fill(); c.globalAlpha = 1;
    label(c, v.toFixed(3), bx + Math.min(bw, v*sc) + 6, y+4, col, B11);
    if (key === 'visc') aGhost.forEach((g, j) => { const gv = 3/g*Math.hypot(...u)*sc; c.strokeStyle = p.nu; c.globalAlpha = .5-.12*j; c.lineWidth = 1.4; c.beginPath(); c.moveTo(bx+gv, y-9); c.lineTo(bx+gv, y+9); c.stroke(); c.globalAlpha = 1; label(c, 'Re '+g, bx+gv, y+19, p.nu, '9px "IBM Plex Mono", monospace', 'center'); }); });
  label(c, `box average: advection / viscous ≈ ${(aRMS*aRe).toFixed(aRMS*aRe < 10 ? 1 : 0)} (∝ Re)${hold ? '  · held while you slide' : ''}`, 12, c.H-8, isAct('Re') || hold ? p.ink : p.mut, F11);
}

// ===================== B · one Fourier wave and the projection =====================
const CB = hidpi($('kviz')), VB = {th:-0.62, ph:0.38, s:92, ox:200, oy:172}; orbit($('kviz'), VB);
let kv = [1, 2, 0], bClk = 0, bLast = null, bSlide = -1e9, waveTex = null, waveKey = '';
const NB = [0.55, 0.4, -0.5];
['kx', 'ky', 'kz'].forEach((id, j) => { const el = $(id); el.oninput = () => { kv[j] = +el.value; $(id+'v').textContent = el.value; bSlide = now0(); waveKey = ''; if (reduce) drawB(0); }; });
function waves(){ const p = P(), key = kv.join() + p.acc + p.bg; if (key === waveKey) return waveTex; waveKey = key; const a = hex(p.bg), hi = hex(p.acc), lo = hex(p.warm);
  return waveTex = [0, 1, 2].map(ax => tex(40, (i, j) => { const q = [0, 0, 0], [b, d] = AX[ax]; q[b] = TAU*i/40; q[d] = TAU*j/40; const v = Math.cos(dot3(kv, q)); return [...(v > 0 ? hi : lo).map((x, m) => a[m]+(x-a[m])*Math.abs(v)*.85), .95]; })); }
function drawB(now){
  const dt = bLast === null ? 0 : Math.min(100, now - bLast); bLast = now; const hold = now - bSlide < 2200; if (!hold) bClk += dt; if (!VB.drag && !reduce) VB.th += dt*0.00008;
  const c = CB, W = c.W, p = P(), s = reduce || hold ? 4.2 : (bClk/1000) % 5.6, kk = dot3(kv, kv), kn = Math.sqrt(kk);
  c.clearRect(0, 0, W, c.H);
  const wt = waves(); c.globalAlpha = isAct('uh', 'F', 'k', 'kj') ? .75 : .45; backFaces(VB).forEach(([a, sd]) => face(c, VB, wt[a], a, sd)); c.globalAlpha = 1;
  box(c, VB, 1, 1, 1, p.mut, 1);
  const O = proj(VB, 0, 0, 0), A = (v, col, lw, dash, al) => { const e = proj(VB, ...v); c.globalAlpha = al ?? 1; arrow(c, O[0], O[1], e[0], e[1], col, lw, dash); c.globalAlpha = 1; return e; };
  if (kk === 0) { label(c, '𝐤 = 0: the mean flow. P leaves it alone.', W/2, 40, p.ink, B12, 'center'); }
  else {
    const kh = scl3(kv, 1/kn), e1 = nrm3(cross3(kh, Math.abs(kh[2]) < .9 ? [0,0,1] : [1,0,0])), e2 = cross3(kh, e1), pOn = isAct('P', 'delta', 'p');
    c.beginPath(); for (let q=0;q<=48;q++){ const a = TAU*q/48, v = add3(scl3(e1, .85*Math.cos(a)), scl3(e2, .85*Math.sin(a))), e = proj(VB, ...v); q ? c.lineTo(e[0], e[1]) : c.moveTo(e[0], e[1]); }
    c.fillStyle = p.tau; c.globalAlpha = pOn ? .28 : .14; c.fill(); c.globalAlpha = pOn ? 1 : .5; c.strokeStyle = p.tau; c.lineWidth = pOn ? 2 : 1; c.stroke(); c.globalAlpha = 1;
    const kOn = isAct('k', 'kj', 'k2', 'D'), ke = A(scl3(kh, .3 + .13*kn), p.c, kOn ? 4.4 : 3); label(c, '𝐤', ke[0]+8, ke[1]-2, p.c, MATH);
    const par = scl3(kh, dot3(kh, NB)), perp = sub3(NB, par), nOn = isAct('Nl', 'lc', 'om'), gN = ease(s/1), gD = ease((s-1)/1.2), gR = ease((s-2.2)/1.2);
    if (s < 3.4) { const ne = A(scl3(NB, gN), p.eq, nOn ? 3.6 : 2.6, false, 1); label(c, 'N̂', ne[0]+8, ne[1]-4, p.eq, MATH); }
    else { A(NB, p.eq, 1.4, true, .35); }
    if (gD > 0) { const off = scl3(kh, .7*gR), a0 = proj(VB, ...off), a1 = proj(VB, ...add3(off, par)); c.globalAlpha = gD*(1-gR*.85); arrow(c, a0[0], a0[1], a1[0], a1[1], p.tau, 2.6, true); c.globalAlpha = 1;
      if (gR > .1 || pOn) label(c, '−∂ᵢp removes this', a1[0]+8, a1[1]+4, p.tau, B11); }
    if (gD > 0) { const pe = A(perp, p.eq, s >= 3.4 || nOn || pOn ? 3.8 : 2.4, s < 3.4, s >= 3.4 ? 1 : gD*.8); if (s >= 3.4) label(c, 'P N̂ (kept)', pe[0]+8, pe[1]+12, p.eq, B11); }
    // pills: what this wave means
    const nu = 0.01, dtt = 0.1, dec = Math.exp(-nu*kk*dtt), pn = sub3(NB, scl3(kv, dot3(kv, NB)/kk));
    let x = 12; const y1 = c.H-40, y2 = c.H-14;
    x = pill(c, x, y1, `𝐤 = (${kv.join(', ')})`, p.c); x = pill(c, x, y1, `|𝐤| = ${kn.toFixed(2)}`, p.c); x = pill(c, x, y1, `λ = 2π/|𝐤| = ${(TAU/kn).toFixed(2)}`, isAct('uh', 'F') ? p.ink : p.mut);
    x = 12; x = pill(c, x, y2, `∂ₓ → i·${kv[0]}`, isAct('D', 'kj') ? p.c : p.mut); x = pill(c, x, y2, `P N̂ = ${fv(pn)}`, p.eq); pill(c, x, y2, `e^(−νk²Δt) = ${dec.toFixed(3)}`, isAct('V', 'nu', 'k2') ? p.nu : p.mut);
  }
  label(c, 'one wave cos(kⱼxⱼ) on the walls; the push N̂ on that wave', 12, 20, p.mut, F11);
  if (hold) label(c, 'held: projected state', W-12, 20, p.tau, F10, 'right');
  triad(c, VB, 30, 330, p);
}

// ===================== C · model spectrum, the grid cutoff, and the cascade =====================
const CC = hidpi($('resviz')); let cRe = Math.pow(10, 3.5), cN = 512, cGhost = [], cStart = null, cLast = null;
const KG = [...Array(260)].map((_, i) => Math.pow(10, 5*i/259));
function cModel(Re, N){ const E = KG.map(k => dnsPope(k, Re)), D = E.map((e, i) => 2*KG[i]*KG[i]*e/Re), km = N/3; let tot = 0, res = 0;
  for (let i=1;i<KG.length;i++){ const a = (D[i]+D[i-1])/2*(KG[i]-KG[i-1]); tot += a; if (KG[i] <= km) res += a; }
  return {E, D, km, frac: res/tot, eta: Math.pow(Re, -.75), dmax: Math.max(...D)}; }
let cM = cModel(cRe, cN);
const casc = [...Array(46)].map((_, i) => ({ lk: Math.random()*1.2, y: 0, st: 0, w: i }));
function cUpd(){ cRe = Math.pow(10, +$('cre').value); cN = Math.pow(2, +$('cn').value); $('crev').textContent = big(cRe); $('cnv').textContent = big(cN); cM = cModel(cRe, cN); if (reduce) drawC(0); }
['cre', 'cn'].forEach(id => { const el = $(id); el.oninput = cUpd; el.addEventListener('pointerdown', () => cStart = {Re: cRe, N: cN}); el.addEventListener('change', () => { if (cStart && (cStart.Re !== cRe || cStart.N !== cN)) cGhost = [{...cStart, m: cModel(cStart.Re, cStart.N)}, ...cGhost].slice(0, 3); cStart = null; }); });
function drawC(now){
  const dt = cLast === null ? 0 : Math.min(100, now - cLast); cLast = now;
  const c = CC, W = c.W, p = P(), m = cM, x0 = 52, x1 = 336, LX = k => x0 + (x1-x0)*Math.log10(k)/5, eT = 26, eB = 146, dT = 172, dB = 270, LE = e => eB - (eB-eT)*(Math.log10(Math.max(e, 1e-12)) + 12)/12;
  c.clearRect(0, 0, W, c.H);
  label(c, 'energy spectrum E(k)', x0, 16, isAct('Ek') ? p.f : p.ink, SANS); label(c, 'dissipation 2νk²E(k)', x0, dT-6, isAct('eps', 'nu', 'k2') ? p.nu : p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, eT); c.lineTo(x0, eB); c.lineTo(x1, eB); c.moveTo(x0, dT); c.lineTo(x0, dB); c.lineTo(x1, dB); c.stroke();
  for (let d=0; d<=5; d++){ label(c, d ? '10' + '⁰¹²³⁴⁵'[d] : '1', LX(Math.pow(10, d)), dB+14, p.mut, F10, 'center'); }
  label(c, 'k (box units, L = 1)', x1, dB+28, p.mut, F10, 'right'); label(c, '10⁰', x0-4, LE(1)+4, p.mut, F10, 'right'); label(c, '10⁻⁶', x0-4, LE(1e-6)+4, p.mut, F10, 'right'); label(c, '10⁻¹²', x0-4, eB, p.mut, F10, 'right');
  const kmx = LX(Math.min(1e5, m.km));
  // what the grid cannot hold
  c.fillStyle = p.eq; c.globalAlpha = .07; c.fillRect(kmx, eT, x1-kmx, dB-eT); c.globalAlpha = 1;
  cGhost.forEach((g, j) => { c.globalAlpha = .4 - .1*j; c.strokeStyle = p.nu; c.lineWidth = 1.2; c.beginPath(); g.m.D.forEach((d, i) => { const y = dB - (dB-dT)*d/g.m.dmax; i ? c.lineTo(LX(KG[i]), y) : c.moveTo(LX(KG[i]), y); }); c.stroke();
    const ix = g.m.D.indexOf(g.m.dmax); label(c, `Re ${big(g.Re)}`, LX(KG[ix]), dB-(dB-dT)-4, p.nu, '9px "IBM Plex Mono", monospace', 'center'); c.globalAlpha = 1; });
  // dissipation spectrum, the missed part filled
  c.beginPath(); m.D.forEach((d, i) => { const y = dB - (dB-dT)*d/m.dmax; i ? c.lineTo(LX(KG[i]), y) : c.moveTo(LX(KG[i]), y); }); c.strokeStyle = p.nu; c.lineWidth = isAct('eps', 'nu', 'k2') ? 3 : 2; c.stroke();
  c.beginPath(); let started = false; m.D.forEach((d, i) => { if (KG[i] < m.km) return; const x = LX(KG[i]), y = dB - (dB-dT)*d/m.dmax; if (!started) { c.moveTo(x, dB); started = true; } c.lineTo(x, y); }); if (started) { c.lineTo(x1, dB); c.closePath(); c.fillStyle = p.nu; c.globalAlpha = .35; c.fill(); c.globalAlpha = 1; }
  // energy spectrum and the −5/3 guide
  c.beginPath(); m.E.forEach((e, i) => { const y = LE(e); i ? c.lineTo(LX(KG[i]), y) : c.moveTo(LX(KG[i]), y); }); c.strokeStyle = p.f; c.lineWidth = isAct('Ek') ? 3 : 2; c.stroke();
  c.setLineDash([3,4]); c.strokeStyle = p.mut; c.lineWidth = 1; c.beginPath(); c.moveTo(LX(3), LE(1.5*Math.pow(3, -5/3))); c.lineTo(LX(300), LE(1.5*Math.pow(300, -5/3))); c.stroke(); c.setLineDash([]); label(c, 'k^(−5/3)', LX(6), LE(1.5*Math.pow(300, -5/3)), p.mut, F10);
  // markers: 1/η and k_max
  const ex = LX(1/m.eta), eOn = isAct('eta'); c.setLineDash([2,3]); c.strokeStyle = p.cs; c.lineWidth = eOn ? 2.4 : 1.4; c.beginPath(); c.moveTo(ex, eT); c.lineTo(ex, dB); c.stroke(); c.setLineDash([]); label(c, '1/η', ex+4, eT+10, p.cs, eOn ? B11 : F10);
  const kOn = isAct('kmax', 'N', 'grp'); c.strokeStyle = p.eq; c.lineWidth = kOn ? 4 : 2.6; c.beginPath(); c.moveTo(kmx, eT-6); c.lineTo(kmx, dB); c.stroke(); label(c, 'k_max = N/3', kmx-4, dT+12, p.eq, B11, 'right');
  if (isAct('L')) { c.strokeStyle = p.ink; c.lineWidth = 1.4; c.beginPath(); c.moveTo(LX(1), eT); c.lineTo(LX(1), dB); c.stroke(); label(c, '1/L', LX(1)+4, eT+38, p.ink, F10); }
  // the cascade: energy rides down the spectrum, is burned by viscosity, or piles up at the cutoff
  const lkm = Math.log10(m.km), dts = reduce ? 0 : dt/1000; let piled = 0;
  casc.forEach(o => { if (o.st === 0) { o.lk += dts*0.35*Math.pow(Math.pow(10, o.lk), .12); const i = Math.min(KG.length-1, Math.round(o.lk/5*259)), burn = m.D[i]/m.dmax;
      if (Math.random() < burn*dts*3.5) { o.st = 2; o.y = 1; } if (o.lk >= lkm) { o.lk = lkm; o.st = 1; o.y = 3; } }
    else if (o.st === 1) { o.y += dts; if (o.y > 6) { o.st = 0; o.lk = Math.random()*.3; } }
    else { o.y -= dts*2; if (o.y <= 0) { o.st = 0; o.lk = Math.random()*.3; } }
    if (o.lk > 5) { o.st = 0; o.lk = 0; }
    let x = LX(Math.pow(10, o.lk)), y = LE(dnsPope(Math.pow(10, o.lk), cRe)), col = p.f, al = .8;
    if (o.st === 1) { x = kmx - 4 - (piled % 3)*5; y = LE(dnsPope(m.km, cRe)) - 6 - Math.floor(piled/3)*5; piled++; col = p.eq; }
    if (o.st === 2) { col = p.nu; al = o.y; }
    if (y < eT || y > eB) return; c.fillStyle = col; c.globalAlpha = al; c.beginPath(); c.arc(x, y, 2.6, 0, 7); c.fill(); c.globalAlpha = 1; });
  // right: cost
  const rx = 378, rw = 150, ry0 = 30, ry1 = 200, GX = r => rx + rw*(Math.log10(r)-2)/4, GY = n => ry1 - (ry1-ry0)*(Math.log10(n)-1)/4.5;
  label(c, 'grid needed vs Re', rx, 16, isAct('Re', 'N') ? p.ink : p.mut, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(rx, ry0); c.lineTo(rx, ry1); c.lineTo(rx+rw, ry1); c.stroke();
  [[2, '10²'], [4, '10⁴'], [6, '10⁶']].forEach(([e, t]) => label(c, t, GX(Math.pow(10, e)), ry1+13, p.mut, F10, 'center'));
  [[100, '100'], [1e3, '10³'], [1e4, '10⁴'], [1e5, '10⁵']].forEach(([n, t]) => label(c, t, rx-4, GY(n)+4, p.mut, F10, 'right'));
  [[4096, 'Kaneda 2003'], [18432, '2020']].forEach(([n, t]) => { c.setLineDash([2,3]); c.strokeStyle = p.mut; c.beginPath(); c.moveTo(rx, GY(n)); c.lineTo(rx+rw, GY(n)); c.stroke(); c.setLineDash([]); label(c, `${n} · ${t}`, rx+rw, GY(n)-3, p.mut, '9px "IBM Plex Mono", monospace', 'right'); });
  c.strokeStyle = p.ok; c.lineWidth = 2; c.beginPath(); for (let q=0;q<=40;q++){ const r = Math.pow(10, 2+4*q/40), n = 4.5*Math.pow(r, .75); q ? c.lineTo(GX(r), GY(n)) : c.moveTo(GX(r), GY(n)); } c.stroke();
  label(c, 'k_max η = 1.5', GX(1e5), GY(4.5*Math.pow(1e5, .75))+14, p.ok, F10, 'center');
  const ok = m.km*m.eta; c.fillStyle = ok >= 1 ? p.ok : p.nu; c.beginPath(); c.arc(GX(cRe), clamp(GY(cN), ry0, ry1), isAct('Re', 'N') ? 7 : 5, 0, 7); c.fill();
  // numbers
  const steps = cN, x = rx; let y = 228;
  [[`η = ${sci(m.eta)}`, p.cs], [`k_max η = ${ok.toFixed(2)}`, ok >= 1.5 ? p.ok : ok >= 1 ? p.ok : p.nu], [`ε resolved: ${(100*m.frac).toFixed(m.frac > .999 ? 2 : 1)} %`, p.nu], [`N³ = ${sci(Math.pow(cN, 3))}`, p.ink], [`points × steps ∼ N⁴ ≈ ${sci(Math.pow(cN, 3)*steps)}`, isAct('dt') ? p.ink : p.mut]].forEach(([t, col]) => { label(c, t, x, y, col, F11); y += 17; });
  $('ccap').textContent = `Re = ${big(cRe)}, N = ${big(cN)}: ${ok >= 1.5 ? 'resolved: a true DNS' : ok >= 1 ? 'resolved by the relaxed criterion (k_max η ≥ 1)' : ok >= .5 ? 'marginal: the dissipation peak is cut' : 'under-resolved: energy piles up at k_max, not a DNS any more'}. Needed for k_max η = 1.5: N ≈ ${big(4.5*Math.pow(cRe, .75))}.`;
}

// ===================== Build · the running DNS =====================
const SC = hidpi($('sim')), VS = {th:-0.72, ph:0.42, s:96, ox:170, oy:200}; orbit($('sim'), VS);
const TEND = 12; let sim = null, subMs = 1, stAcc = 0, running = false, reIdx = 1, simGhost = [], stageMs = 5, simSteps = -1, wTex = null, wDots = [], wmax = 1, crunchT = 0, minKE = Infinity;
const reIn = $('re'), simRe = () => DNS_RES[reIdx];
function regime(v){ return v >= 1.5 ? ['well resolved', 'ok'] : v >= 1 ? ['resolved (k_max η ≥ 1)', 'ok'] : v >= .5 ? ['marginal', 'cs'] : ['under-resolved: not a DNS any more', 'nu']; }
function simInit(){ if (!sim) sim = dnsMake(32); if (sim.hist && sim.hist.length > 10) simGhost = [{Re: sim.reRun, h: sim.hist.slice()}, ...simGhost.filter(g => g.Re !== simRe())].slice(0, 3);
  sim.init(1/simRe()); sim.reRun = simRe(); simSteps = -1; minKE = Infinity; fieldVis(); }
// vorticity pictures: slices on the walls of the box, and the strongest cells as dots
function fieldVis(){ const n = sim.n, [W0, W1, W2] = sim.W, M = n*n*n, mag = new Float32Array(M); let mx = 0;
  for (let q=0;q<M;q++){ const v = Math.sqrt(W0[q]*W0[q]+W1[q]*W1[q]+W2[q]*W2[q]); mag[q] = v; if (v > mx) mx = v; } wmax = mx || 1;
  const p = P(), a = hex(p.bg), hi = hex(p.cs), idx = (x, y, z) => (z*n+y)*n+x;
  wTex = [0, 1, 2].map(ax => tex(n, (i, j) => { const q = [0, 0, 0], [b, d] = AX[ax]; q[b] = i; q[d] = j; const v = Math.min(1, mag[idx(q[0], q[1], q[2])]/wmax); return [...hi.map((x, m) => a[m]+(x-a[m])*Math.pow(v, .8)), 1]; }));
  let thr = .55; wDots = []; for (let k=0;k<3 && (k === 0 || wDots.length > 2600);k++){ wDots = []; for (let q=0;q<M;q++) if (mag[q] > thr*wmax) wDots.push(q); thr += .12; }
  wDots = wDots.map(q => { const x = q%n, y = ((q/n)|0)%n, z = (q/(n*n))|0; return [x/n*2-1+1/n, y/n*2-1+1/n, z/n*2-1+1/n, W2[q] >= 0 ? 1 : 0, mag[q]/wmax]; }); }
function drawSim(){
  const c = SC, W = c.W, p = P(), s = sim; c.clearRect(0, 0, W, c.H);
  // left: the box
  c.globalAlpha = .9; backFaces(VS).forEach(([a, sd]) => face(c, VS, wTex[a], a, sd)); c.globalAlpha = 1; box(c, VS, 1, 1, 1, p.mut, 1);
  const pos = p.acc, neg = p.warm; wDots.forEach(([x, y, z, sg, m]) => { const e = proj(VS, x, y, z); c.fillStyle = sg ? pos : neg; c.globalAlpha = .25 + .5*m; c.fillRect(e[0]-1.4, e[1]-1.4, 2.8, 2.8); }); c.globalAlpha = 1;
  label(c, '|ω| on the walls · dots: strongest vorticity', 12, 18, p.mut, F11); label(c, '● ω_z > 0   ● ω_z < 0', 12, 34, p.mut, F10);
  c.fillStyle = pos; c.fillRect(12, 28, 7, 7); c.fillStyle = neg; c.fillRect(82, 28, 7, 7);
  triad(c, VS, 36, 352, p); label(c, `t = ${s.t.toFixed(2)}`, 310, 380, p.ink, B12, 'right'); label(c, `32³ · Re ${simRe()}`, 310, 396, p.mut, F10, 'right');
  // top right: ε(t), two ways, against the finer-grid reference
  const x0 = 392, x1 = 744, y0 = 26, y1 = 188, X = t => x0 + (x1-x0)*t/TEND, Y = e => y1 - (y1-y0)*e/0.017;
  label(c, 'dissipation ε(t)', x0, 14, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x0, y1); c.lineTo(x1, y1); c.stroke();
  for (let t=0;t<=TEND;t+=3) label(c, String(t), X(t), y1+13, p.mut, F10, 'center'); label(c, 't', x1+8, y1+4, p.mut, MATH);
  [0, .005, .01, .015].forEach(e => label(c, e ? e.toFixed(3) : '0', x0-4, Y(e)+4, p.mut, F10, 'right'));
  simGhost.forEach((g, j) => { c.globalAlpha = .45-.1*j; c.strokeStyle = p.nu; c.lineWidth = 1.2; c.beginPath(); g.h.forEach(([t,, e], i) => i ? c.lineTo(X(t), Y(e)) : c.moveTo(X(t), Y(e))); c.stroke();
    const l = g.h[g.h.length-1]; label(c, 'Re '+g.Re, X(l[0])+3, Y(l[2])-3, p.nu, '9px "IBM Plex Mono", monospace'); c.globalAlpha = 1; });
  const ref = DNS_REF[simRe()]; if (ref && ref[1]) { c.setLineDash([6,4]); c.strokeStyle = p.ink; c.lineWidth = 1.4; c.beginPath(); ref[1].forEach((e, i) => i ? c.lineTo(X(i*.25), Y(e)) : c.moveTo(X(i*.25), Y(e))); c.stroke(); c.setLineDash([]); label(c, `${ref[0]}³ reference`, X(TEND)-2, Y(ref[1][ref[1].length-1])-6, p.ink, F10, 'right'); }
  { const cx = X(9), cy = Y(0.0127); c.strokeStyle = p.mut; c.lineWidth = 1.4; c.beginPath(); c.moveTo(cx-5, cy); c.lineTo(cx+5, cy); c.moveTo(cx, cy-5); c.lineTo(cx, cy+5); c.stroke(); label(c, 'Re 1600 peak, 512³', cx-7, cy-6, p.mut, '9px "IBM Plex Mono", monospace', 'right'); }
  const H = s.hist; c.strokeStyle = p.nu; c.lineWidth = 2.2; c.beginPath(); H.forEach(([t,, e], i) => i ? c.lineTo(X(t), Y(e)) : c.moveTo(X(t), Y(e))); c.stroke();
  c.fillStyle = p.f; for (let m=1;m<H.length-1;m+=2){ const d = dnsDEdt(H, m); if (d === null) continue; c.beginPath(); c.arc(X(H[m][0]), Y(d), 2.2, 0, 7); c.fill(); }
  label(c, '— 2νΩ', x0+8, y0+12, p.nu, F10); label(c, '● −dE/dt', x0+60, y0+12, p.f, F10); label(c, '┄ finer grid', x0+140, y0+12, p.ink, F10);
  // bottom right: spectrum
  const sx0 = 392, sx1 = 744, sy0 = 232, sy1 = 360, KX_ = k => sx0 + (sx1-sx0)*(k-1)/17, LY = e => sy1 - (sy1-sy0)*(Math.log10(Math.max(e, 1e-13)) + 13)/12.5;
  label(c, 'energy spectrum E(k)', sx0, 222, p.ink, SANS);
  c.fillStyle = p.eq; c.globalAlpha = .08; c.fillRect(KX_(s.K+.5), sy0, sx1-KX_(s.K+.5), sy1-sy0); c.globalAlpha = 1; label(c, 'shells only partly kept', KX_(14), sy0+12, p.eq, F10, 'center');
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(sx0, sy0); c.lineTo(sx0, sy1); c.lineTo(sx1, sy1); c.stroke();
  for (let k=1;k<=18;k+=3) label(c, String(k), KX_(k), sy1+13, p.mut, F10, 'center'); label(c, 'k', sx1, sy1+13, p.mut, MATH, 'right');
  [[-1, '10⁻¹'], [-5, '10⁻⁵'], [-9, '10⁻⁹'], [-13, '10⁻¹³']].forEach(([e, t]) => label(c, t, sx0-4, LY(Math.pow(10, e))+4, p.mut, F10, 'right'));
  c.strokeStyle = p.eq; c.lineWidth = 2.2; c.beginPath(); c.moveTo(KX_(s.K), sy0); c.lineTo(KX_(s.K), sy1); c.stroke(); label(c, 'k_max = 10', KX_(s.K)-4, sy0+12, p.eq, B11, 'right');
  const ie = 1/s.eta; if (ie < 18.5) { c.setLineDash([2,3]); c.strokeStyle = p.cs; c.lineWidth = 1.6; c.beginPath(); c.moveTo(KX_(ie), sy0); c.lineTo(KX_(ie), sy1); c.stroke(); c.setLineDash([]); label(c, '1/η', KX_(ie)+4, sy1-6, p.cs, F10); }
  else label(c, `1/η = ${ie.toFixed(0)} →`, sx1, sy1-6, p.cs, F10, 'right');
  c.strokeStyle = p.f; c.lineWidth = 2.2; c.beginPath(); let first = true; for (let k=1;k<s.spec.length;k++){ const e = s.spec[k]; if (!(e > 1e-14)) continue; const xx = KX_(k), yy = LY(e); first ? c.moveTo(xx, yy) : c.lineTo(xx, yy); first = false; } c.stroke();
  c.fillStyle = p.f; for (let k=1;k<s.spec.length;k++){ const e = s.spec[k]; if (e > 1e-14) { c.beginPath(); c.arc(KX_(k), LY(e), 2.4, 0, 7); c.fill(); } }
  // caption
  const kn = s.K*s.eta; minKE = Math.min(minKE, kn); const [rg] = regime(minKE), m = H.length-2, d = dnsDEdt(H, m);
  $('simcap').textContent = `t = ${s.t.toFixed(2)} · step ${s.steps} · Δt = ${s.dt.toFixed(3)} · ${stageMs.toFixed(1)} ms per RK stage (3 per step) · E = ${s.E.toFixed(4)} · ε = 2νΩ = ${s.eps.toFixed(5)}${d !== null ? ` (−dE/dt ${H[m][2] ? (100*(d/H[m][2]-1)).toFixed(2) : '0'} % off)` : ''} · k_max η = ${kn.toFixed(2)}, lowest so far ${minKE.toFixed(2)}: ${rg}${s.t >= TEND ? ' · finished: Restart or change Re' : ''}`;
}
function simAdvance(budget){ const t0 = now0(); let did = 0;
  while (sim.t < TEND && (did === 0 || now0() - t0 + subMs < budget)){ const a = now0(); sim.work(); const d = now0()-a; subMs = Math.max(.9*subMs, d); stAcc += d; did++;
    if (sim.sub === 0) { stageMs = .8*stageMs + .2*stAcc; stAcc = 0; } }
  if (sim.steps !== simSteps) { simSteps = sim.steps; fieldVis(); } }
function crunch(){ if (!running || sim.t >= TEND) return; const t = Math.floor(sim.t); simAdvance(9); if (Math.floor(sim.t) !== t || sim.t >= TEND) drawSim(); setTimeout(crunch, 0); }
reIn.oninput = () => { reIdx = +reIn.value; $('rev').textContent = simRe(); simInit(); drawSim(); if (reduce && running) { clearTimeout(crunchT); crunch(); } };
$('run').onclick = e => { running = !running; e.target.textContent = running ? 'Pause' : 'Run'; if (reduce && running) crunch(); };
$('restart').onclick = () => { simInit(); drawSim(); };

// ===================== Parallelize · slabs and pencils =====================
const CD = hidpi($('decomp')); let pMode = 'slab';
function pState(){ const N = Math.pow(2, +$('pn').value), Pn = Math.pow(2, +$('pp').value), P1 = Math.pow(2, Math.floor(+$('pp').value/2)), P2 = Pn/P1; return {N, Pn, P1, P2}; }
const bytes = b => b >= 1e12 ? (b/1e12).toFixed(1)+' TB' : b >= 1e9 ? (b/1e9).toFixed(1)+' GB' : b >= 1e6 ? (b/1e6).toFixed(1)+' MB' : b >= 1e3 ? (b/1e3).toFixed(1)+' kB' : b.toFixed(0)+' B';
function drawDecomp(){ const c = CD, p = P(), {N, Pn, P1, P2} = pState(), V = {th:-0.6, ph:0.45, s:64, ox:150, oy:112}, cols = [p.f, p.eq, p.c, p.tau, p.u, p.rho, p.cs, p.nu];
  c.clearRect(0, 0, c.W, c.H);
  const quad = (pts, col, al) => { c.beginPath(); pts.forEach((q, i) => { const e = proj(V, ...q); i ? c.lineTo(e[0], e[1]) : c.moveTo(e[0], e[1]); }); c.closePath(); c.fillStyle = col; c.globalAlpha = al; c.fill(); c.globalAlpha = 1; c.strokeStyle = p.panel; c.lineWidth = .8; c.stroke(); };
  const fail = pMode === 'slab' ? Pn > N : Pn > N*N;
  if (pMode === 'slab') { const n = Math.min(Pn, 16); for (let i=0;i<n;i++){ const z0 = -1 + 2*i/n, z1 = -1 + 2*(i+1)/n, col = cols[i % 8];
      quad([[-1,1,z0],[1,1,z0],[1,1,z1],[-1,1,z1]], col, .75); quad([[1,-1,z0],[1,1,z0],[1,1,z1],[1,-1,z1]], col, .55); if (i === n-1) quad([[-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]], col, .65); }
    label(c, `${Math.min(Pn, 16)}${Pn > 16 ? ' of ' + big(Pn) : ''} slabs shown (planes of constant z)`, 10, c.H-10, p.mut, F10); }
  else { const a = Math.min(P1, 8), b = Math.min(P2, 8); for (let i=0;i<a;i++) for (let j=0;j<b;j++){ const y0 = -1 + 2*i/a, y1 = -1 + 2*(i+1)/a, z0 = -1 + 2*j/b, z1 = -1 + 2*(j+1)/b, col = cols[(i*3+j) % 8];
      if (i === a-1) quad([[-1,1,z0],[1,1,z0],[1,1,z1],[-1,1,z1]], col, .75); if (j === b-1) quad([[-1,y0,1],[1,y0,1],[1,y1,1],[-1,y1,1]], col, .65); quad([[1,y0,z0],[1,y1,z0],[1,y1,z1],[1,y0,z1]], col, .5); }
    label(c, `pencils along x: ${big(P1)} × ${big(P2)} ranks${P1 > 8 || P2 > 8 ? ' (8 × 8 shown)' : ''}`, 10, c.H-10, p.mut, F10); }
  box(c, V, 1, 1, 1, p.mut, 1); triad(c, V, 280, 200, p);
  if (fail) { c.strokeStyle = p.nu; c.lineWidth = 4; c.beginPath(); c.moveTo(60, 30); c.lineTo(240, 190); c.moveTo(240, 30); c.lineTo(60, 190); c.stroke(); label(c, pMode === 'slab' ? 'P > N: less than one plane per rank' : 'P > N²', 150, 20, p.nu, B11, 'center'); } }
function pUpd(){ const {N, Pn, P1, P2} = pState(), fb = $('pfb'), per = Math.pow(N, 3)/Pn*16, step = 15;
  $('pnv').textContent = big(N); $('ppv').textContent = big(Pn); drawDecomp();
  const slabOk = Pn <= N, penOk = P1 <= N && P2 <= N, tSl = `slab: ${slabOk ? `${big(N/Pn)} plane${N/Pn > 1 ? 's' : ''} per rank, 1 all-to-all among ${big(Pn)} ranks per FFT` : 'impossible (P > N)'}`;
  const tPe = `pencil: ${penOk ? `a ${big(N)} × ${big(N/P1)} × ${big(N/P2)} column per rank, 2 transposes among ${big(P1)} and ${big(P2)} ranks per FFT` : 'impossible (P > N²)'}`;
  const vol = `Each transpose moves ${bytes(per)} per rank (one complex field, ${bytes(per*Pn)} in all); ${step} FFTs per step`;
  if (pMode === 'pencil' && Pn > N && penOk) { fb.className = 'fb good'; fb.textContent = `✓ ${tPe}. Slabs would need ${big(Pn/N)} ranks per plane. ${vol}; messages per rank ${big(P1-1+P2-1)} instead of ${big(Pn-1)}.`; K.done('parallel'); }
  else if (pMode === 'slab' && !slabOk) { fb.className = 'fb bad'; fb.textContent = `✕ ${tSl}. Try Pencil.`; }
  else { fb.className = 'fb'; fb.textContent = `${pMode === 'slab' ? tSl : tPe}. ${vol}.${Pn <= N ? ' Both work here: raise P above N.' : ''}`; } }
['pn', 'pp'].forEach(id => $(id).oninput = pUpd);
$('slab').onclick = () => { pMode = 'slab'; $('slab').classList.add('pri'); $('pencil').classList.remove('pri'); pUpd(); };
$('pencil').onclick = () => { pMode = 'pencil'; $('pencil').classList.add('pri'); $('slab').classList.remove('pri'); pUpd(); };

this.ops = { F: HOW.F, D: HOW.D, P: HOW.P, N: HOW.N, V: HOW.V };
let openB = '0';
function drawLearn(now){ if (openB === '0') drawOps(now); if (openB === 'A') drawA(now); if (openB === 'B') drawB(now); if (openB === 'C') drawC(now); }
drawOps(0); drawA(0); drawB(0); drawC(0);
return {
  frame(now, stp){ if (stp === 0) drawLearn(now);
    if (stp === 1 && sim) { if (running && sim.t < TEND) simAdvance(9); else if (!VS.drag) VS.th += 0.002; drawSim(); }
    if (stp === 2) {} },
  onStep(stp){ if (stp === 1) { if (!sim) simInit(); drawSim(); } if (stp === 2) pUpd(); },
  onBlock(k){ openB = k; if (reduce) drawLearn(0); },
  buildReset(){ running = false; $('run').textContent = 'Run'; simInit(); drawSim(); },
  buildStart(){ running = true; $('run').textContent = 'Pause'; if (reduce) crunch(); }
};
}
