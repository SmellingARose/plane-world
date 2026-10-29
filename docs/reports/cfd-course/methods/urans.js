// URANS (unsteady RANS): BDF2 + dual time stepping, projection, Spalart–Allmaras. See ../README.md for the spec.
// The Build solver (makeURANS) lives at module level so bench() can run it headless.
(() => {
// lexical copies of the globals the solver uses in hot loops (fast lookups also in a sandboxed context)
const Math = globalThis.Math, Float64Array = globalThis.Float64Array, Uint8Array = globalThis.Uint8Array;
// The Build solver. 3D incompressible URANS around a square cylinder (side D = 1, inflow U = 1): MAC grid, BDF2 + dual time stepping (symmetric Gauss–Seidel pseudo-time sweeps), incremental
// projection (spanwise Fourier modes + PCG per mode), Spalart–Allmaras (noft2). Square cylinder D = 1, U = 1.
const clockNow = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
function makeURANS(o){
  const Dc = o.Dc || 6, NX = o.NX || 13*Dc, NY = o.NY || 8*Dc, NZ = o.NZ || 4, G = 2;
  const SX = NX+2*G+1, SY = NY+2*G+1, SZ = NZ+2*G, SXY = SX*SY, S = SXY*SZ, h = 1/Dc, h2 = h*h;
  const I = (i,j,k) => (k+G)*SXY + (j+G)*SX + (i+G);
  const i0 = o.i0 != null ? o.i0 : Math.round(3.5*Dc), j0 = (NY - Dc) >> 1, i1 = i0 + Dc, j1 = j0 + Dc;
  const F = () => new Float64Array(S);
  const st = { NX, NY, NZ, Dc, h, i0, j0, i1, j1, Re: o.Re || 22000, dt: o.dt || 0.1, M: o.M || 8, tol: o.tol || 0.01, cgTol: o.cgTol || 1e-4, kt: o.kt || 1, first: true, t: 0, n: 0,
    u: F(), v: F(), w: F(), un: F(), vn: F(), wn: F(), um: F(), vm: F(), wm: F(),
    p: F(), phi: F(), rmap: F(), rec: false, nt: F(), ntn: F(), ntm: F(), nt2: F(), nut: F(), nue: F(), Om: F(), d: F(), div: F(),
    solid: new Uint8Array(S), hist: [], res: [], divBefore: 0, divAfter: 0, cgIts: 0, blown: false };
  const { solid, d } = st;
  const nu = 1/st.Re;
  for (let k=-G;k<NZ+G;k++) for (let j=-G;j<NY+G+1;j++) for (let i=-G;i<NX+G+1;i++){ const c = I(i,j,k);
    if (i>=i0 && i<i1 && j>=j0 && j<j1) solid[c] = 1;
    const x = (i+.5)*h, y = (j+.5)*h, dx = Math.max(i0*h - x, 0, x - i1*h), dy = Math.max(j0*h - y, 0, y - j1*h); d[c] = Math.max(Math.hypot(dx, dy), 0.5*h); }
  const fu = new Uint8Array(S), fv = new Uint8Array(S), fw = new Uint8Array(S);
  for (let k=0;k<NZ;k++) for (let j=0;j<NY;j++) for (let i=0;i<=NX;i++){ const c = I(i,j,k); if (i>=1 && i<=NX-1 && !solid[c] && !solid[c-1]) fu[c] = 1; }
  for (let k=0;k<NZ;k++) for (let j=0;j<=NY;j++) for (let i=0;i<NX;i++){ const c = I(i,j,k); if (j>=1 && j<=NY-1 && !solid[c] && !solid[c-SX]) fv[c] = 1; }
  for (let k=0;k<NZ;k++) for (let j=0;j<NY;j++) for (let i=0;i<NX;i++){ const c = I(i,j,k); if (!solid[c]) fw[c] = 1; }
  st.fu = fu; st.fv = fv; st.fw = fw; let nFree = 0; for (let c=0;c<S;c++) nFree += fu[c]+fv[c]+fw[c];
  const cb1 = 0.1355, cb2 = 0.622, sig = 2/3, kap = 0.41, cw1 = cb1/(kap*kap) + (1+cb2)/sig, cw2 = 0.3, cw3 = 2, cv1 = 7.1, cv13 = cv1**3, cw36 = cw3**6;
  const ntInf = 3*nu;
  const fv1 = chi => { const c3 = chi*chi*chi; return c3/(c3 + cv13); };

  function perZ(a){ for (let g=1; g<=G; g++){ a.copyWithin(I(-G, -G, -g), I(-G, -G, NZ-g), I(-G, -G, NZ-g) + SXY); a.copyWithin(I(-G, -G, NZ-1+g), I(-G, -G, g-1), I(-G, -G, g-1) + SXY); } }
  function bcVel(a, b, c){
    for (let k=0;k<NZ;k++){
      for (let j=0;j<NY;j++){ a[I(0,j,k)] = 1; a[I(-1,j,k)] = 1; a[I(-2,j,k)] = 1; a[I(NX+1,j,k)] = a[I(NX,j,k)]; a[I(NX+2,j,k)] = a[I(NX,j,k)];
        for (const q of [b, c]) { q[I(-1,j,k)] = -q[I(0,j,k)]; q[I(-2,j,k)] = -q[I(1,j,k)]; q[I(NX,j,k)] = q[I(NX-1,j,k)]; q[I(NX+1,j,k)] = q[I(NX-1,j,k)]; } }
      for (let i=-G;i<NX+G+1;i++){ b[I(i,0,k)] = 0; b[I(i,NY,k)] = 0; b[I(i,-1,k)] = -b[I(i,1,k)]; b[I(i,NY+1,k)] = -b[I(i,NY-1,k)];
        for (const q of [a, c]) { q[I(i,-1,k)] = q[I(i,0,k)]; q[I(i,-2,k)] = q[I(i,1,k)]; q[I(i,NY,k)] = q[I(i,NY-1,k)]; q[I(i,NY+1,k)] = q[I(i,NY-2,k)]; } }
    }
    for (let k=0;k<NZ;k++) for (let j=j0-1;j<=j1;j++) for (let i=i0-1;i<=i1;i++){ const cc = I(i,j,k);
      if (solid[cc] || solid[cc-1]) a[cc] = 0; if (solid[cc] || solid[cc-SX]) b[cc] = 0; if (solid[cc]) c[cc] = 0; }
    perZ(a); perZ(b); perZ(c);
  }
  function bcScal(a, inflow){
    for (let k=0;k<NZ;k++){
      for (let j=0;j<NY;j++){ const L = inflow == null ? a[I(0,j,k)] : inflow; a[I(-1,j,k)] = L; a[I(-2,j,k)] = L; a[I(NX,j,k)] = a[I(NX-1,j,k)]; a[I(NX+1,j,k)] = a[I(NX-1,j,k)]; }
      for (let i=-G;i<NX+G;i++){ a[I(i,-1,k)] = a[I(i,0,k)]; a[I(i,-2,k)] = a[I(i,1,k)]; a[I(i,NY,k)] = a[I(i,NY-1,k)]; a[I(i,NY+1,k)] = a[I(i,NY-2,k)]; } }
    perZ(a);
  }
  function closure(){ const { nt, nut, nue } = st;
    for (let c=0;c<S;c++){ const t = solid[c] ? 0 : st.kt*nt[c]*fv1(nt[c]/nu); nut[c] = t; nue[c] = nu + t; } }
  const D3 = (f, c, s, a) => a > 0 ? (2*f[c+s] + 3*f[c] - 6*f[c-s] + f[c-2*s])/(6*h) : (-2*f[c-s] - 3*f[c] + 6*f[c+s] - f[c+2*s])/(6*h);
  const bdf = () => st.first ? [1, -1, 0] : [1.5, -2, 0.5];

  // one pseudo-time sweep (Gauss–Seidel, in place) on the BDF2 residual of the three momentum equations
  function sweep(back){
    const { u, v, w, un, vn, wn, um, vm, wm, p, nue } = st, dt = st.dt, [a0, a1, a2] = bdf(), A0 = a0/dt, om = 1;
    let rs = 0; const cA = I(0,0,0), cB = I(NX,NY,NZ-1), rec = st.rec, rmap = st.rmap; if (rec) rmap.fill(0);
    if (back) { for (let c = cB; c >= cA; c--) rs += upd(c); } else { for (let c = cA; c <= cB; c++) rs += upd(c); }
    bcVel(u, v, w);
    return Math.sqrt(rs/nFree);
    function upd(c){ let rs = 0;
      if (fu[c]) { const uc = u[c], vb = .25*(v[c-1]+v[c]+v[c-1+SX]+v[c+SX]), wb = .25*(w[c-1]+w[c]+w[c-1+SXY]+w[c+SXY]);
        const nE = nue[c], nW = nue[c-1], nN = .25*(nE+nW+nue[c+SX]+nue[c-1+SX]), nS = .25*(nE+nW+nue[c-SX]+nue[c-1-SX]), nF = .25*(nE+nW+nue[c+SXY]+nue[c-1+SXY]), nB = .25*(nE+nW+nue[c-SXY]+nue[c-1-SXY]);
        const R = (a0*uc + a1*un[c] + a2*um[c])/dt + uc*D3(u,c,1,uc) + vb*D3(u,c,SX,vb) + wb*D3(u,c,SXY,wb)
          - (nE*(u[c+1]-uc) - nW*(uc-u[c-1]) + nN*(u[c+SX]-uc) - nS*(uc-u[c-SX]) + nF*(u[c+SXY]-uc) - nB*(uc-u[c-SXY]))/h2 + (p[c]-p[c-1])/h;
        u[c] = uc - om*R/(A0 + (Math.abs(uc)+Math.abs(vb)+Math.abs(wb))/h + (nE+nW+nN+nS+nF+nB)/h2); rs += R*R; }
      if (fv[c]) { const vc = v[c], ub = .25*(u[c-SX]+u[c+1-SX]+u[c]+u[c+1]), wb = .25*(w[c-SX]+w[c]+w[c-SX+SXY]+w[c+SXY]);
        const nN = nue[c], nS = nue[c-SX], nE = .25*(nN+nS+nue[c+1]+nue[c+1-SX]), nW = .25*(nN+nS+nue[c-1]+nue[c-1-SX]), nF = .25*(nN+nS+nue[c+SXY]+nue[c-SX+SXY]), nB = .25*(nN+nS+nue[c-SXY]+nue[c-SX-SXY]);
        const R = (a0*vc + a1*vn[c] + a2*vm[c])/dt + ub*D3(v,c,1,ub) + vc*D3(v,c,SX,vc) + wb*D3(v,c,SXY,wb)
          - (nE*(v[c+1]-vc) - nW*(vc-v[c-1]) + nN*(v[c+SX]-vc) - nS*(vc-v[c-SX]) + nF*(v[c+SXY]-vc) - nB*(vc-v[c-SXY]))/h2 + (p[c]-p[c-SX])/h;
        v[c] = vc - om*R/(A0 + (Math.abs(ub)+Math.abs(vc)+Math.abs(wb))/h + (nE+nW+nN+nS+nF+nB)/h2); rs += R*R; }
      if (fw[c]) { const wc = w[c], ub = .25*(u[c-SXY]+u[c+1-SXY]+u[c]+u[c+1]), vb = .25*(v[c-SXY]+v[c+SX-SXY]+v[c]+v[c+SX]);
        const nF = nue[c], nB = nue[c-SXY], nE = .25*(nF+nB+nue[c+1]+nue[c+1-SXY]), nW = .25*(nF+nB+nue[c-1]+nue[c-1-SXY]), nN = .25*(nF+nB+nue[c+SX]+nue[c+SX-SXY]), nS = .25*(nF+nB+nue[c-SX]+nue[c-SX-SXY]);
        const R = (a0*wc + a1*wn[c] + a2*wm[c])/dt + ub*D3(w,c,1,ub) + vb*D3(w,c,SX,vb) + wc*D3(w,c,SXY,wc)
          - (nE*(w[c+1]-wc) - nW*(wc-w[c-1]) + nN*(w[c+SX]-wc) - nS*(wc-w[c-SX]) + nF*(w[c+SXY]-wc) - nB*(wc-w[c-SXY]))/h2 + (p[c]-p[c-SXY])/h;
        w[c] = wc - om*R/(A0 + (Math.abs(ub)+Math.abs(vb)+Math.abs(wc))/h + (nE+nW+nN+nS+nF+nB)/h2); rs += R*R; }
      if (rec) rmap[c] = rs;
      return rs; }
  }

  const NC = NX*NY, basis = [], lam = [];
  for (let m=0; m<=NZ/2; m++){ const L = (2-2*Math.cos(2*Math.PI*m/NZ))/h2;
    const cosv = [...Array(NZ)].map((_,k) => Math.cos(2*Math.PI*m*k/NZ)), sinv = [...Array(NZ)].map((_,k) => Math.sin(2*Math.PI*m*k/NZ));
    for (const b of (m === 0 || m === NZ/2) ? [cosv] : [cosv, sinv]) { const nn = Math.hypot(...b); basis.push(b.map(x => x/nn)); lam.push(L); } }
  st.basis = basis; st.lam = lam;
  const fl = new Uint8Array(NC), J = (i,j) => j*NX + i;
  for (let j=0;j<NY;j++) for (let i=0;i<NX;i++) fl[J(i,j)] = solid[I(i,j,0)] ? 0 : 1;
  const ax = new Uint8Array(NC), axm = new Uint8Array(NC), ay = new Uint8Array(NC), aym = new Uint8Array(NC);
  for (let j=0;j<NY;j++) for (let i=0;i<NX;i++){ const q = J(i,j); if (!fl[q]) continue; axm[q] = fu[I(i,j,0)]; ax[q] = fu[I(i+1,j,0)]; aym[q] = fv[I(i,j,0)]; ay[q] = fv[I(i,j+1,0)]; }
  const nM = basis.length, rhs = basis.map(() => new Float64Array(NC)), sol = basis.map(() => new Float64Array(NC));
  const rr_ = new Float64Array(NC), zz = new Float64Array(NC), pp = new Float64Array(NC), Ap = new Float64Array(NC), dgm = new Float64Array(NC);
  function Amul(x, y, l){ for (let q=0;q<NC;q++){ if (!fl[q]) { y[q] = 0; continue; } const xq = x[q];
    let s = l*xq; if (axm[q]) s += xq - x[q-1]; if (ax[q]) s += xq - x[q+1]; if (aym[q]) s += xq - x[q-NX]; if (ay[q]) s += xq - x[q+NX]; y[q] = s; } }
  function* pcg(m, tol, maxIt){ const l = lam[m]*h2, b = rhs[m], x = sol[m];
    for (let q=0;q<NC;q++) dgm[q] = fl[q] ? (axm[q]+ax[q]+aym[q]+ay[q]+l) || 1 : 1;
    if (l === 0) { let s = 0, c = 0; for (let q=0;q<NC;q++) if (fl[q]) { s += b[q]; c++; } s /= c; for (let q=0;q<NC;q++) if (fl[q]) b[q] -= s; }
    Amul(x, Ap, l); let bn = 0, rz = 0; for (let q=0;q<NC;q++){ rr_[q] = fl[q] ? b[q] - Ap[q] : 0; zz[q] = rr_[q]/dgm[q]; pp[q] = zz[q]; rz += rr_[q]*zz[q]; bn += b[q]*b[q]; }
    bn = Math.sqrt(bn) || 1; let it = 0;
    for (; it<maxIt; it++){ Amul(pp, Ap, l); let pAp = 0; for (let q=0;q<NC;q++) pAp += pp[q]*Ap[q]; if (!(pAp > 0)) break; const al = rz/pAp; let rn = 0, rz2 = 0;
      for (let q=0;q<NC;q++){ x[q] += al*pp[q]; rr_[q] -= al*Ap[q]; zz[q] = rr_[q]/dgm[q]; rn += rr_[q]*rr_[q]; rz2 += rr_[q]*zz[q]; }
      if (Math.sqrt(rn)/bn < tol) { it++; break; }
      const be = rz2/rz; rz = rz2; for (let q=0;q<NC;q++) pp[q] = zz[q] + be*pp[q];
      if (it % 10 === 9) yield 'cg'; }
    st.cgIts += it; }
  function divergence(){ const { u, v, w, div } = st; let mx = 0;
    for (let k=0;k<NZ;k++) for (let j=0;j<NY;j++) for (let i=0;i<NX;i++){ const c = I(i,j,k); const dv = solid[c] ? 0 : (u[c+1]-u[c] + v[c+SX]-v[c] + w[c+SXY]-w[c])/h; div[c] = dv; mx = Math.max(mx, Math.abs(dv)); } return mx; }
  function* project(scale){
    const { u, v, w, div, phi, p } = st;
    st.divBefore = divergence(); if (st.rec) st.divB = st.div.slice();
    for (let m=0;m<nM;m++){ const b = rhs[m], B = basis[m]; b.fill(0); for (let k=0;k<NZ;k++) for (let j=0;j<NY;j++) for (let i=0;i<NX;i++) b[J(i,j)] -= h2*scale*div[I(i,j,k)]*B[k]; }
    st.cgIts = 0; for (let m=0;m<nM;m++) yield* pcg(m, st.cgTol, 400);
    for (let k=0;k<NZ;k++) for (let j=0;j<NY;j++) for (let i=0;i<NX;i++){ let s = 0; for (let m=0;m<nM;m++) s += sol[m][J(i,j)]*basis[m][k]; phi[I(i,j,k)] = s; }
    bcScal(phi);
    for (let c=0;c<S;c++){ if (fu[c]) u[c] -= (phi[c]-phi[c-1])/(h*scale); if (fv[c]) v[c] -= (phi[c]-phi[c-SX])/(h*scale); if (fw[c]) w[c] -= (phi[c]-phi[c-SXY])/(h*scale); }
    bcVel(u, v, w);
    for (let c=0;c<S;c++) p[c] += phi[c];
    st.divAfter = divergence();
  }
  function outflow(){ const { u, un } = st; let qo = 0;
    for (let k=0;k<NZ;k++) for (let j=0;j<NY;j++){ const c = I(NX,j,k); u[c] = un[c] - st.dt*(un[c]-un[c-1])/h; qo += u[c]; }
    const cor = (NY*NZ - qo)/(NY*NZ); for (let k=0;k<NZ;k++) for (let j=0;j<NY;j++) u[I(NX,j,k)] += cor; }
  function vorticity(){ const { u, v, w, Om } = st;
    const uc = c => .5*(u[c]+u[c+1]), vc = c => .5*(v[c]+v[c+SX]), wc = c => .5*(w[c]+w[c+SXY]);
    for (let k=0;k<NZ;k++) for (let j=0;j<NY;j++) for (let i=0;i<NX;i++){ const c = I(i,j,k);
      if (solid[c]) { Om[c] = 0; continue; }
      const wy = (wc(c+SX)-wc(c-SX))/(2*h), vz = (vc(c+SXY)-vc(c-SXY))/(2*h), uz = (uc(c+SXY)-uc(c-SXY))/(2*h), wx = (wc(c+1)-wc(c-1))/(2*h), vx = (vc(c+1)-vc(c-1))/(2*h), uy = (uc(c+SX)-uc(c-SX))/(2*h);
      Om[c] = Math.hypot(wy-vz, uz-wx, vx-uy); } }
  function saSweep(back){
    const { u, v, w, nt, ntn, ntm, Om } = st, dt = st.dt, [a0, a1, a2] = bdf(), k2 = kap*kap;
    let rs = 0, cnt = 0;
    for (let k=0;k<NZ;k++) for (let j=0;j<NY;j++){ for (let ii=0;ii<NX;ii++){ const i = back ? NX-1-ii : ii, c = I(i,j,k);
      if (solid[c]) { nt[c] = 0; continue; }
      const N = nt[c], dd = d[c], chi = N/nu, f1 = fv1(chi), f2 = 1 - chi/(1 + chi*f1);
      const Stl = Math.max(Om[c] + N*f2/(k2*dd*dd), 0.3*Om[c]);
      const r = Stl > 1e-12 ? Math.min(N/(Stl*k2*dd*dd), 10) : 10, g = r + cw2*(r**6 - r), fw_ = g*Math.pow((1+cw36)/(g**6+cw36), 1/6);
      const ucx = .5*(u[c]+u[c+1]), vcy = .5*(v[c]+v[c+SX]), wcz = .5*(w[c]+w[c+SXY]);
      const adv = ucx*(ucx > 0 ? N - nt[c-1] : nt[c+1] - N)/h + vcy*(vcy > 0 ? N - nt[c-SX] : nt[c+SX] - N)/h + wcz*(wcz > 0 ? N - nt[c-SXY] : nt[c+SXY] - N)/h;
      let dif = 0, dsum = 0;
      for (const q of [c+1, c-1, c+SX, c-SX, c+SXY, c-SXY]) { const kf = nu + .5*(N + nt[q]); dif += kf*(nt[q] - N); dsum += kf; }
      const gx = (nt[c+1]-nt[c-1])/(2*h), gy = (nt[c+SX]-nt[c-SX])/(2*h), gz = (nt[c+SXY]-nt[c-SXY])/(2*h);
      const R = (a0*N + a1*ntn[c] + a2*ntm[c])/dt + adv - cb1*Stl*N + cw1*fw_*(N/dd)**2 - (dif/h2 + cb2*(gx*gx+gy*gy+gz*gz))/sig;
      const dg = a0/dt + (Math.abs(ucx)+Math.abs(vcy)+Math.abs(wcz))/h + dsum/(sig*h2) + 2*cw1*fw_*N/(dd*dd);
      nt[c] = Math.max(0, N - R/dg); rs += R*R; cnt++; } }
    bcScal(nt, ntInf); return Math.sqrt(rs/cnt);
  }
  function forces(){ const { p } = st; let fx = 0, fy = 0;
    for (let k=0;k<NZ;k++){ for (let j=j0;j<j1;j++) fx += p[I(i0-1,j,k)] - p[I(i1,j,k)]; for (let i=i0;i<i1;i++) fy += p[I(i,j0-1,k)] - p[I(i,j1,k)]; }
    const ref = 0.5*(NZ*h); return [fx*h2/ref, fy*h2/ref]; }
  function span3D(){ const { u } = st; let s = 0, c2 = 0;
    for (let j=0;j<NY;j++) for (let i=1;i<NX;i++){ let m = 0; for (let k=0;k<NZ;k++) m += u[I(i,j,k)]; m /= NZ; for (let k=0;k<NZ;k++){ const dl = u[I(i,j,k)] - m; s += dl*dl; c2++; } }
    return Math.sqrt(s/c2); }
  // one physical time step n → n+1, as a generator: it yields between chunks (and names the stage) so the
  // browser can spread the work over several frames and the walkthrough can stop after each operator
  function* step(){
    const { u, v, w, un, vn, wn, um, vm, wm, nt, ntn, ntm } = st;
    closure(); yield 'E';                                                         // E: ν_t from ν̃
    if (!st.first) for (let c=0;c<S;c++){ u[c] = 2*un[c]-um[c]; v[c] = 2*vn[c]-vm[c]; w[c] = 2*wn[c]-wm[c]; }
    bcVel(u, v, w); yield 'B';                                                    // B: guess for uⁿ⁺¹, BDF2 residual
    const res = []; let r0 = 0;
    for (let m=0;m<st.M;m++){ const r = sweep(m & 1); if (m === 0) r0 = r || 1; res.push(r/r0); st.res = res; yield 'T'; if (r/r0 < st.tol) break; }   // T
    outflow(); bcVel(u, v, w);
    yield* project(bdf()[0]/st.dt); yield 'P';                                    // P
    vorticity(); saSweep(0); yield 'nt'; saSweep(1);                              // ν̃ (Spalart–Allmaras)
    um.set(un); vm.set(vn); wm.set(wn); un.set(u); vn.set(v); wn.set(w); ntm.set(ntn); ntn.set(nt);
    st.n++; st.t += st.dt; st.first = false;
    const [cd, cl] = forces(); st.hist.push([st.t, cd, cl, span3D()]);
    if (!(Math.abs(cd) < 50)) st.blown = true;
  }
  function init(){
    const { u, v, w, nt, p } = st;
    for (const a of [u,v,w,p,st.phi,st.nut]) a.fill(0); nt.fill(ntInf); st.hist = []; st.t = 0; st.n = 0; st.blown = false; st.first = true; for (const s_ of sol) s_.fill(0);
    let seed = 3; const rnd = () => (seed = (seed*16807) % 2147483647)/2147483647 - .5;
    const xc = (i0+i1)/2*h, yc = (j0+j1)/2*h;
    for (let k=0;k<NZ;k++) for (let j=0;j<NY;j++) for (let i=0;i<=NX;i++){ const c = I(i,j,k), x2 = (i+.5)*h, y2 = j*h;
      u[c] = 1; v[c] = 0.6*Math.exp(-((x2-xc-1.6)**2 + (y2-yc-0.3)**2)/0.5);
      w[c] = 0.08*Math.sin(2*Math.PI*(k+.5)/NZ)*Math.exp(-((x2-xc-2)**2 + (y2-yc)**2)/1.5) + 0.02*rnd(); }
    bcVel(u, v, w); bcScal(nt, ntInf);
    const tl = st.cgTol; st.cgTol = 1e-8; const g = project(1); while (!g.next().done); st.cgTol = tl;
    p.fill(0);
    st.un.set(u); st.vn.set(v); st.wn.set(w); st.um.set(u); st.vm.set(v); st.wm.set(w); st.ntn.set(nt); st.ntm.set(nt);
  }
  function strouhal(){ const H = st.hist, z = []; for (let q=1;q<H.length;q++){ const a = H[q-1], b = H[q]; if (a[2] < 0 && b[2] >= 0) z.push(a[0] + (b[0]-a[0])*(-a[2])/(b[2]-a[2])); }
    if (z.length < 3) return null; const k = Math.min(4, z.length-1), T = (z[z.length-1] - z[z.length-1-k])/k; return { St: 1/T, T, cycles: z.length-1 }; }
  Object.assign(st, { init, step, closure, strouhal, I, SX, SXY, S, forces, fv1, nu, divergence, span3D });
  init();
  return st;
}

// ---- MathML helpers (every symbol carries data-t so the framework colours and links it) ----
const X = (k, x) => `<mrow data-t="${k}">${x}</mrow>`;
const ob = (x, op, txt) => `<munder><munder><mrow>${x}</mrow><mo stretchy="true">⏟</mo></munder><mtext data-t="${op}" class="opl">${txt}</mtext></munder>`;
const ij = n => `<mi data-t="ij">${n}</mi>`;
const nS = '<mi data-t="n">n</mi>', nP = '<mrow><mi data-t="n">n</mi><mo>+</mo><mn>1</mn></mrow>', nM = '<mrow><mi data-t="n">n</mi><mo>−</mo><mn>1</mn></mrow>';
const mS = '<mrow><mo>(</mo><mi data-t="m">m</mi><mo>)</mo></mrow>', mP = '<mrow><mo>(</mo><mi data-t="m">m</mi><mo>+</mo><mn>1</mn><mo>)</mo></mrow>';
const U = (n, sup) => X('u', sup ? `<msubsup><mi>u</mi>${ij(n || 'i')}${sup}</msubsup>` : `<msub><mi>u</mi>${ij(n || 'i')}</msub>`);
const UA = n => X('u', `<mo>⟨</mo><msub><mi>u</mi>${ij(n || 'i')}</msub><mo>⟩</mo>`);
const UB = n => X('ubar', `<msub><mover accent="true"><mi>u</mi><mo>¯</mo></mover>${ij(n || 'i')}</msub>`);
const UT = n => X('util', `<msub><mover accent="true"><mi>u</mi><mo>˜</mo></mover>${ij(n || 'i')}</msub>`);
const UP = n => X('upr', `<msubsup><mi>u</mi>${ij(n || 'i')}<mo>′</mo></msubsup>`);
const D = n => X('grad', `<msub><mo>∂</mo>${n === 't' ? '<mi data-t="t">t</mi>' : ij(n)}</msub>`);
const NUT = X('nut', '<msub><mi>ν</mi><mi>t</mi></msub>'), NU = '<mi data-t="nu">ν</mi>', NT = X('nt', '<mover accent="true"><mi>ν</mi><mo>˜</mo></mover>');
const PA = X('p', '<mo>⟨</mo><mi>p</mi><mo>⟩</mo>'), PP = '<mi data-t="p">p</mi>';
const DT = X('dt', '<mi>Δ</mi><mi>t</mi>'), DTAU = X('dtau', '<mi>Δ</mi><mi>τ</mi>');
const fr = (a, b) => `<mfrac><mrow>${a}</mrow><mrow>${b}</mrow></mfrac>`;
const RS = a => X('Rs', '<msup><mi>R</mi><mo>*</mo></msup>') + `<mo>(</mo>${a}<mo>)</mo>`;
const GRID = '<msup><mi>ℝ</mi><mrow><mn>5</mn><mo>×</mo><msub data-t="N"><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub data-t="N"><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub data-t="N"><mi>N</mi><mi>z</mi></msub></mrow></msup>';
const R3N = k => `<msup><mi>ℝ</mi><mrow>${k ? `<mn>${k}</mn><mo>×</mo>` : ''}<msub><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub><mi>N</mi><mi>z</mi></msub></mrow></msup>`;
const RP = '<msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', R0 = '<msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>';
const IDX = (s, rg, im, t) => `<div class="ir" data-t="${t}"><span class="is"><math>${s}</math></span><span class="rg"><math>${rg}</math></span><span class="im">${im}</span></div>`;
const DSTEP = (k, m, p) => `<div class="dstep"><span class="k">${k}</span><div class="dm"><math display="block">${m}</math></div><p>${p}</p></div>`;
const DEEP = (steps) => `<details class="deep"><summary>Going a bit deeper <span class="note">· ${steps.length} steps</span></summary>${steps.join('')}</details>`;

const TERMS = {
 q: { sym: '<msub><mi>q</mi><mrow><mi>x</mi><mi>y</mi><mi>z</mi></mrow></msub>', name: 'State', col: '--c-u',
  def: 'Everything one cell stores at one time level: the 3 resolved velocity components, the pressure and the turbulence variable ν̃. 5 numbers per cell.',
  space: `<msup><mi>q</mi><mi>n</mi></msup><mo>∈</mo>${R3N(5)}` },
 u: { sym: '<mo>⟨</mo><msub><mi>u</mi><mi>i</mi></msub><mo>⟩</mo>', name: 'Resolved velocity', col: '--c-u',
  def: 'The phase (ensemble) average of the velocity: the mean plus the coherent, periodic part. This is what URANS computes; from block B on it is written uᵢ.',
  space: `<mo>⟨</mo><msub><mi>u</mi><mi>i</mi></msub><mo>⟩</mo><mo>∈</mo>${R3N(3)}<mspace width=".4em"/><mtext>per time level</mtext>` },
 ubar: { sym: '<msub><mover accent="true"><mi>u</mi><mo>¯</mo></mover><mi>i</mi></msub>', name: 'Time mean', col: '--c-f',
  def: 'The long-time average: what a steady RANS solver would aim for. It does not change with time.',
  space: `<msub><mover accent="true"><mi>u</mi><mo>¯</mo></mover><mi>i</mi></msub><mo>∈</mo>${R3N(3)}<mspace width=".4em"/><mtext>(no time index)</mtext>` },
 util: { sym: '<msub><mover accent="true"><mi>u</mi><mo>˜</mo></mover><mi>i</mi></msub>', name: 'Coherent part', col: '--c-c',
  def: 'The organised, repeating motion: here the vortices shed alternately from the two sides. Periodic with the shedding frequency, zero on time-average.',
  space: '<msub><mover accent="true"><mi>u</mi><mo>˜</mo></mover><mi>i</mi></msub><mo>:</mo><mtext>phase θ</mtext><mo>↦</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mtext> per point, periodic</mtext>' },
 upr: { sym: '<msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup>', name: 'Turbulent fluctuation', col: '--c-w',
  def: 'The random, broadband rest. It averages to zero at every phase. URANS never resolves it; its effect enters only through ν_t.',
  space: '<msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup><mo>∈</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>,</mo><mspace width=".4em"/><mo>⟨</mo><msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup><mo>⟩</mo><mo>=</mo><mn>0</mn>' },
 A: { sym: '<mo>⟨</mo><mo>·</mo><mo>⟩</mo>', name: 'Phase (ensemble) average', col: '--ink', op: 'A',
  def: 'Average over many shedding cycles at the same phase θ (or over many repeats of the experiment at the same time). Removes u′, keeps ū + ũ.',
  space: '<mo>⟨</mo><mo>·</mo><mo>⟩</mo><mo>:</mo><mtext>signals in time</mtext><mo>→</mo><mtext>functions of phase</mtext><mo>,</mo><mspace width=".4em"/><mtext>linear</mtext>' },
 p: { sym: '<mo>⟨</mo><mi>p</mi><mo>⟩</mo>', name: 'Pressure (kinematic)', col: '--c-rho',
  def: 'Phase-averaged pressure divided by density. In incompressible flow it is not a state variable you march; it is whatever keeps ∂ᵢuᵢ = 0.',
  space: `<mo>⟨</mo><mi>p</mi><mo>⟩</mo><mo>∈</mo>${R3N()}` },
 phi: { sym: '<mi>φ</mi>', name: 'Pressure correction', col: '--c-rho', op: 'P',
  def: 'The pressure increment found by the Poisson solve. Its gradient removes the divergence; then p ← p + φ.',
  space: `<mi>φ</mi><mo>∈</mo>${R3N()}` },
 us: { sym: '<msubsup><mi>u</mi><mi>i</mi><mo>*</mo></msubsup>', name: 'Intermediate velocity', col: '--c-u', op: 'P',
  def: 'The velocity after the inner loop T and before the projection: it satisfies momentum but not yet ∂ᵢuᵢ = 0.',
  space: `<msubsup><mi>u</mi><mi>i</mi><mo>*</mo></msubsup><mo>∈</mo>${R3N(3)}` },
 div: { sym: '<msub><mo>∂</mo><mi>i</mi></msub><msub><mi>u</mi><mi>i</mi></msub>', name: 'Divergence', col: '--c-rho', op: 'P',
  def: 'Net outflow of a cell per unit volume: ∂ₓuₓ + ∂ᵧuᵧ + ∂_zu_z. Zero for incompressible flow; the projection enforces it.',
  space: `<msub><mo>∂</mo><mi>i</mi></msub><msub><mi>u</mi><mi>i</mi></msub><mo>:</mo>${R3N(3)}<mo>→</mo>${R3N()}` },
 nu: { sym: '<mi>ν</mi>', name: 'Molecular viscosity', col: '--ink',
  def: 'The fluid\'s own viscosity. With U = D = 1 it is 1/Re; at Re = 22 000 it is tiny (4.5 × 10⁻⁵).',
  space: `<mi>ν</mi><mo>∈</mo>${RP}<mspace width=".4em"/><mtext>(constant)</mtext>` },
 nut: { sym: '<msub><mi>ν</mi><mi>t</mi></msub>', name: 'Eddy viscosity', col: '--c-nu', op: 'E',
  def: 'Extra viscosity standing in for the unresolved turbulence: the mixing done by u′. It varies from cell to cell and in time.',
  space: `<msub><mi>ν</mi><mi>t</mi></msub><mo>∈</mo><msup><mrow>${R0}</mrow><mrow><msub><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub><mi>N</mi><mi>z</mi></msub></mrow></msup>` },
 nt: { sym: '<mover accent="true"><mi>ν</mi><mo>˜</mo></mover>', name: 'SA variable ν̃', col: '--c-eq', op: 'E',
  def: 'The one quantity the Spalart–Allmaras model transports. Away from walls it equals ν_t; near walls it is damped by f_v1.',
  space: `<mover accent="true"><mi>ν</mi><mo>˜</mo></mover><mo>∈</mo>${R3N()}<mo>,</mo><mspace width=".4em"/><mover accent="true"><mi>ν</mi><mo>˜</mo></mover><mo>≥</mo><mn>0</mn>` },
 chi: { sym: '<mi>χ</mi>', name: 'Viscosity ratio', col: '--c-eq', op: 'E',
  def: 'χ = ν̃/ν: how much stronger the turbulent mixing is than molecular viscosity.',
  space: `<mi>χ</mi><mo>∈</mo>${R0}` },
 fv1: { sym: '<msub><mi>f</mi><mrow><mi>v</mi><mn>1</mn></mrow></msub>', name: 'Wall damping function', col: '--c-eq', op: 'E',
  def: 'χ³/(χ³ + c_v1³): ≈ 0 when χ is small (near walls), → 1 when χ is large (free shear layers, wake).',
  space: `<msub><mi>f</mi><mrow><mi>v</mi><mn>1</mn></mrow></msub><mo>:</mo>${R0}<mo>→</mo><mo>[</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>)</mo>` },
 cv1: { sym: '<msub><mi>c</mi><mrow><mi>v</mi><mn>1</mn></mrow></msub>', name: 'Model constant', col: '--c-w',
  def: 'c_v1 = 7.1 (Spalart & Allmaras). At χ = 7.1 exactly half of ν̃ counts as eddy viscosity.',
  space: '<msub><mi>c</mi><mrow><mi>v</mi><mn>1</mn></mrow></msub><mo>=</mo><mn>7.1</mn>' },
 prod: { sym: '<msub><mi>c</mi><mrow><mi>b</mi><mn>1</mn></mrow></msub><mover accent="true"><mi>S</mi><mo>˜</mo></mover><mover accent="true"><mi>ν</mi><mo>˜</mo></mover>', name: 'Production', col: '--c-c',
  def: 'Turbulence is made where the flow spins (vorticity S̃): in the shear layers that leave the corners. c_b1 = 0.1355.',
  space: `<msub><mi>c</mi><mrow><mi>b</mi><mn>1</mn></mrow></msub><mover accent="true"><mi>S</mi><mo>˜</mo></mover><mover accent="true"><mi>ν</mi><mo>˜</mo></mover><mo>∈</mo>${R3N()}` },
 dest: { sym: '<msub><mi>c</mi><mrow><mi>w</mi><mn>1</mn></mrow></msub><msub><mi>f</mi><mi>w</mi></msub><msup><mrow><mo>(</mo><mover accent="true"><mi>ν</mi><mo>˜</mo></mover><mo>/</mo><mi>d</mi><mo>)</mo></mrow><mn>2</mn></msup>', name: 'Destruction', col: '--c-nu',
  def: 'A wall blocks large eddies, so ν̃ is destroyed close to it (small d). c_w1 = c_b1/κ² + (1 + c_b2)/σ ≈ 3.24.',
  space: `<msub><mi>c</mi><mrow><mi>w</mi><mn>1</mn></mrow></msub><msub><mi>f</mi><mi>w</mi></msub><msup><mrow><mo>(</mo><mover accent="true"><mi>ν</mi><mo>˜</mo></mover><mo>/</mo><mi>d</mi><mo>)</mo></mrow><mn>2</mn></msup><mo>∈</mo>${R3N()}` },
 diff: { sym: '<mfrac><mn>1</mn><mi>σ</mi></mfrac><mo>[</mo><mo>…</mo><mo>]</mo>', name: 'Diffusion', col: '--c-f',
  def: 'ν̃ spreads itself out, faster where it is large. σ = 2/3, c_b2 = 0.622.',
  space: `<mtext>diffusion</mtext><mo>:</mo>${R3N()}<mo>→</mo>${R3N()}` },
 d: { sym: '<mi>d</mi>', name: 'Wall distance', col: '--ink',
  def: 'Distance from the cell centre to the nearest wall (here: the square). Computed once.',
  space: `<mi>d</mi><mo>∈</mo>${RP}<mtext> per cell</mtext>` },
 ij: { sym: '<mi>i</mi><mo>,</mo><mi>j</mi>', name: 'Axis index', col: '--ink',
  def: 'x, y or z. Repeated twice in one term means summed over all three (Einstein): uⱼ∂ⱼ = uₓ∂ₓ + uᵧ∂ᵧ + u_z∂_z.',
  space: '<mi>i</mi><mo>,</mo><mi>j</mi><mo>∈</mo><mo>{</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>}</mo>' },
 ix: { sym: '<mi>x</mi>', name: 'Cell column', col: '--ink', def: 'Which column of cells, along the flow: 0 … Nₓ−1.',
  space: '<mi>x</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>x</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>' },
 iy: { sym: '<mi>y</mi>', name: 'Cell row', col: '--ink', def: 'Which row, across the flow: 0 … N_y−1.',
  space: '<mi>y</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>' },
 iz: { sym: '<mi>z</mi>', name: 'Cell layer', col: '--ink', def: 'Which layer along the span (the cylinder\'s axis): 0 … N_z−1, periodic.',
  space: '<mi>z</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>' },
 N: { sym: '<msub><mi>N</mi><mi>x</mi></msub><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub>', name: 'Grid size', col: '--ink',
  def: 'Cells along x, y, z: 78 × 48 × 4 in the Build step (6 cells per side of the square).',
  space: '<msub><mi>N</mi><mi>x</mi></msub><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>∈</mo><mi>ℕ</mi>' },
 t: { sym: '<mi>t</mi>', name: 'Physical time', col: '--c-cs',
  def: 'Real time. Unlike steady RANS, URANS keeps ∂ₜ: the answer is a movie, not a single picture.',
  space: `<mi>t</mi><mo>∈</mo>${R0}` },
 n: { sym: '<mi>n</mi>', name: 'Time level', col: '--c-cs',
  def: 'Which frame of the movie: tₙ = nΔt. As a superscript (uⁿ) it is a label, not a power.',
  space: '<mi>n</mi><mo>∈</mo><mi>ℕ</mi>' },
 dt: { sym: '<mi>Δ</mi><mi>t</mi>', name: 'Physical time step', col: '--c-cs', op: 'B',
  def: 'Time between two frames. Chosen for accuracy (enough steps per shedding period), not for stability: BDF2 is implicit.',
  space: `<mi>Δ</mi><mi>t</mi><mo>∈</mo>${RP}` },
 m: { sym: '<mi>m</mi>', name: 'Pseudo-time iteration', col: '--c-tau', op: 'T',
  def: 'Counts inner iterations within one physical step. The clock does not move while m counts up.',
  space: '<mi>m</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>M</mi><mo>}</mo>' },
 M: { sym: '<mi>M</mi>', name: 'Inner iterations', col: '--c-tau', op: 'T',
  def: 'How many pseudo-time sweeps per physical step (at most); the loop stops early once the residual has dropped enough.',
  space: '<mi>M</mi><mo>∈</mo><mi>ℕ</mi>' },
 tau: { sym: '<mi>τ</mi>', name: 'Pseudo-time', col: '--c-tau', op: 'T',
  def: 'A fictitious clock used only to iterate: march in τ until nothing changes; then the implicit equation is solved.',
  space: `<mi>τ</mi><mo>∈</mo>${R0}<mtext> (fictitious)</mtext>` },
 dtau: { sym: '<mi>Δ</mi><mi>τ</mi>', name: 'Pseudo-time step', col: '--c-tau', op: 'T',
  def: 'Step size of the inner loop. It may differ from cell to cell (local stepping) because only the end result matters.',
  space: `<mi>Δ</mi><mi>τ</mi><mo>∈</mo>${RP}<mtext> per cell</mtext>` },
 R: { sym: '<mi>R</mi><mo>(</mo><mi>u</mi><mo>)</mo>', name: 'Steady residual', col: '--ink',
  def: 'Everything in the momentum equation except ∂ₜ: convection, pressure gradient, viscous + eddy-viscous stress. A steady RANS solver drives this to 0.',
  space: `<mi>R</mi><mo>:</mo>${R3N(3)}<mo>→</mo>${R3N(3)}<mo>,</mo><mspace width=".4em"/><mtext>nonlinear</mtext>` },
 Rs: { sym: '<msup><mi>R</mi><mo>*</mo></msup>', name: 'Unsteady residual', col: '--c-cs', op: 'B',
  def: 'The BDF2 time-derivative plus R(u). The inner loop drives it to 0, which is exactly the implicit step.',
  space: `<msup><mi>R</mi><mo>*</mo></msup><mo>:</mo>${R3N(3)}<mo>→</mo>${R3N(3)}` },
 CFL: { sym: '<mtext>CFL</mtext>', name: 'Courant number', col: '--c-cs',
  def: 'How many cells the flow crosses in one step, |u|Δt/Δx. Explicit schemes need ≲ 1; implicit BDF2 runs at 1–5 but loses accuracy.',
  space: `<mtext>CFL</mtext><mo>∈</mo>${RP}` },
 grad: { sym: '<msub><mo>∂</mo><mi>j</mi></msub>', name: 'Partial derivative', col: '--ink',
  def: 'Rate of change along axis j (or in time, ∂ₜ). On the grid: differences between neighbouring cells.',
  space: '<msub><mo>∂</mo><mi>j</mi></msub><mo>:</mo><mtext>field</mtext><mo>→</mo><mtext>field</mtext><mtext> (linear)</mtext>' },
 delta: { sym: '<msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Kronecker delta', col: '--c-w',
  def: '1 if i = j, else 0: the 3 × 3 identity.', space: '<msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo><mn>3</mn></mrow></msup>' },
 k: { sym: '<mi>k</mi>', name: 'Turbulent kinetic energy', col: '--c-w',
  def: 'k = ½⟨u′ᵢu′ᵢ⟩: energy of the unresolved part. Its −⅔kδᵢⱼ share is absorbed into the pressure.',
  space: `<mi>k</mi><mo>∈</mo>${R0}` },
 theta: { sym: '<mi>θ</mi>', name: 'Phase', col: '--c-c',
  def: 'Where in the shedding cycle we are: 0 to 2π, then it repeats.', space: '<mi>θ</mi><mo>∈</mo><mo>[</mo><mn>0</mn><mo>,</mo><mn>2</mn><mi>π</mi><mo>)</mo>' },
 r: { sym: '<mi>r</mi>', name: 'Cycle (realisation) index', col: '--ink',
  def: 'Which cycle (or which repeat of the experiment) a sample comes from; the average runs over r.', space: '<mi>r</mi><mo>∈</mo><mo>{</mo><mn>1</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>r</mi></msub><mo>}</mo>' },
 fs: { sym: '<msub><mi>f</mi><mi>s</mi></msub>', name: 'Shedding frequency', col: '--c-c',
  def: 'How many vortex pairs leave the body per unit time. URANS resolves it; the turbulence is much faster.', space: `<msub><mi>f</mi><mi>s</mi></msub><mo>∈</mo>${RP}` },
 St: { sym: '<mtext>St</mtext>', name: 'Strouhal number', col: '--c-c',
  def: 'St = f_sD/U, the shedding frequency in body units: ≈ 0.2 for a circular cylinder, ≈ 0.13 for a square one.', space: `<mtext>St</mtext><mo>∈</mo>${RP}<mtext> (dimensionless)</mtext>` },
 Reff: { sym: '<msub><mtext>Re</mtext><mtext>eff</mtext></msub>', name: 'Effective Reynolds number', col: '--c-nu',
  def: 'UD/(ν + ν_t): the Reynolds number the resolved flow "feels". Below ≈ 50 a bluff-body wake stops shedding.', space: `<msub><mtext>Re</mtext><mtext>eff</mtext></msub><mo>∈</mo>${RP}` },
 B: { sym: '<mi>B</mi>', name: 'BDF2 time operator', col: '--c-cs', op: 'B',
  def: 'Builds the equation the new frame must satisfy: a parabola through the last two frames and the new one gives ∂ₜu; together with R it forms R*.',
  space: `<mi>B</mi><mo>:</mo><mo>(</mo><msup><mi>u</mi><mi>n</mi></msup><mo>,</mo><msup><mi>u</mi><mrow><mi>n</mi><mo>−</mo><mn>1</mn></mrow></msup><mo>)</mo><mo>↦</mo><msup><mi>R</mi><mo>*</mo></msup><mo>:</mo>${R3N(3)}<mo>→</mo>${R3N(3)}` },
 T: { sym: '<mi>T</mi>', name: 'Pseudo-time sweep', col: '--c-tau', op: 'T',
  def: 'One inner iteration: nudge every cell against its residual R*. Repeated M times it solves the implicit step, like redrafting until the editor finds nothing.',
  space: `<mi>T</mi><mo>:</mo>${R3N(3)}<mo>→</mo>${R3N(3)}<mo>,</mo><mspace width=".4em"/><msup><mi>u</mi><mrow><mo>(</mo><mi>m</mi><mo>)</mo></mrow></msup><mo>↦</mo><msup><mi>u</mi><mrow><mo>(</mo><mi>m</mi><mo>+</mo><mn>1</mn><mo>)</mo></mrow></msup>` },
 P: { sym: '<mi>P</mi>', name: 'Projection', col: '--c-rho', op: 'P',
  def: 'Removes the part of the velocity that would compress the fluid: solve one Poisson equation for φ, subtract ∇φ. Like squeezing a water balloon: water cannot pile up.',
  space: `<mi>P</mi><mo>:</mo>${R3N(3)}<mo>→</mo><mo>{</mo><mi>u</mi><mo>:</mo><msub><mo>∂</mo><mi>i</mi></msub><msub><mi>u</mi><mi>i</mi></msub><mo>=</mo><mn>0</mn><mo>}</mo><mo>,</mo><mspace width=".4em"/><mtext>linear</mtext>` },
 E: { sym: '<mi>E</mi>', name: 'Eddy-viscosity closure', col: '--c-nu', op: 'E',
  def: 'Turns the turbulence variable into an extra viscosity, cell by cell: ν_t = ν̃ f_v1. Like a thermostat reading converted to a heater setting.',
  space: `<mi>E</mi><mo>:</mo>${R3N()}<mo>→</mo>${R3N()}<mo>,</mo><mspace width=".4em"/><mtext>pointwise</mtext>` },
};

const QX = X('q', '<msubsup><mi>q</mi><mrow><mi data-t="ix">x</mi><mi data-t="iy">y</mi><mi data-t="iz">z</mi></mrow><mi data-t="n">n</mi></msubsup>');
const BLOCK0 = `<div class="eqhero"><math display="block">${QX}<mo>=</mo><mo>(</mo>${UA()}<mo>,</mo>${PA}<mo>,</mo>${NT}<mo>)</mo><mo>∈</mo>${GRID}</math>
  <math display="block" class="sm">${X('q','<msup><mi>q</mi>'+nP+'</msup>')}<mo>=</mo><mi data-t="P">P</mi><mo>(</mo><msup><mi data-t="T">T</mi><mi data-t="M">M</mi></msup><mo>(</mo><mi data-t="B">B</mi><mo>(</mo>${X('q','<msup><mi>q</mi>'+nS+'</msup>')}<mo>,</mo>${X('q','<msup><mi>q</mi>'+nM+'</msup>')}<mo>)</mo><mo>)</mo><mo>)</mo><mo>,</mo><mspace width="1.5em"/>${NUT}<mo>=</mo><mi data-t="E">E</mi><mo>(</mo>${NT}<mo>)</mo></math></div>
 <div class="idx"><span class="eyebrow">Every index</span>
  ${IDX('<mi>i</mi><mo>,</mo><mi>j</mi>', '<mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi>', 'Axis of a vector or derivative (u<sub>i</sub>, ∂<sub>j</sub>). Twice in one term → summed: u<sub>j</sub>∂<sub>j</sub>u<sub>i</sub> = u<sub>x</sub>∂<sub>x</sub>u<sub>i</sub> + u<sub>y</sub>∂<sub>y</sub>u<sub>i</sub> + u<sub>z</sub>∂<sub>z</sub>u<sub>i</sub>.', 'ij')}
  ${IDX('<mi>x</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>x</mi></msub><mo>−</mo><mn>1</mn>', 'Cell column, along the flow (78 in Build).', 'ix')}
  ${IDX('<mi>y</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>−</mo><mn>1</mn>', 'Cell row, across the flow (48).', 'iy')}
  ${IDX('<mi>z</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>−</mo><mn>1</mn>', 'Cell layer along the span (4, periodic: layer 4 is layer 0).', 'iz')}
  ${IDX('<mi>t</mi>', '<mi>t</mi><mo>≥</mo><mn>0</mn>', 'Physical time, continuous. URANS keeps ∂ₜ; steady RANS drops it.', 't')}
  ${IDX('<mi>n</mi>', '<mn>0</mn><mo>,</mo><mn>1</mn><mo>,</mo><mn>2</mn><mo>,</mo><mo>…</mo>', 'Physical time level, tₙ = nΔt. In qⁿ it is a label, not a power. BDF2 needs two old levels, n and n−1.', 'n')}
  ${IDX('<mi>m</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>M</mi>', 'Pseudo-time iteration inside one physical step: the clock stays at tₙ₊₁ while m counts.', 'm')}
  ${IDX('<mi>θ</mi>', '<mo>[</mo><mn>0</mn><mo>,</mo><mn>2</mn><mi>π</mi><mo>)</mo>', 'Phase of the shedding cycle; the average ⟨·⟩ is taken at fixed θ.', 'theta')}
  ${IDX('<mi>r</mi>', '<mn>1</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>r</mi></msub>', 'Cycle (or experiment repeat) being averaged over.', 'r')}</div>
 <div class="dims">
  <div class="dim"><b>Fix i, x, y, z, n</b><math>${UA()}<mo>∈</mo><mi>ℝ</mi></math><span>one number</span></div>
  <div class="dim"><b>Fix x, y, z, n</b><math>${X('q','<msub><mi>q</mi><mrow><mi>x</mi><mi>y</mi><mi>z</mi></mrow></msub>')}<mo>∈</mo><msup><mi>ℝ</mi><mn>5</mn></msup></math><span>one cell: uₓ, uᵧ, u_z, p, ν̃</span></div>
  <div class="dim"><b>Fix n (one frame)</b><math>${X('q','<msup><mi>q</mi><mi>n</mi></msup>')}<mo>∈</mo>${GRID}</math><span>78 × 48 × 4 = 14 976 cells → 74 880 numbers</span></div>
  <div class="dim"><b>What one step holds</b><math>${X('q','<msup><mi>q</mi><mi>n</mi></msup>')}<mo>,</mo>${X('q','<msup><mi>q</mi><mrow><mi>n</mi><mo>−</mo><mn>1</mn></mrow></msup>')}<mo>,</mo>${X('q','<msup><mi>q</mi><mrow><mo>(</mo><mi>m</mi><mo>)</mo></mrow></msup>')}</math><span>two old frames + the iterate: 3 copies</span></div>
 </div>
 <span class="eyebrow">What the operators do, on a real (tiny) URANS grid</span>
 <figure class="viz"><div class="scrollx"><canvas id="urans-opviz" data-w="880" data-h="370" aria-label="Animated walkthrough of one URANS time step on a 24 by 12 by 2 grid: closure E, BDF2 residual B, pseudo-time sweeps T, projection P, shift of time levels"></canvas></div>
  <div class="opctl"><button class="b" id="urans-opplay">Pause</button><div id="urans-opsteps" class="btns"></div></div>
  <p class="opcap" id="urans-opcap"></p></figure>
 <aside class="insp" data-terms="q,E,B,T,P,A,M,N,n,m"></aside>
 ${DEEP([
  DSTEP('B', `${RS(U('i',nP))}<mo>=</mo>${fr(`<mn>3</mn>${U('i',nP)}<mo>−</mo><mn>4</mn>${U('i',nS)}<mo>+</mo>${U('i',nM)}`, `<mn>2</mn>${DT}`)}<mo>+</mo><mi data-t="R">R</mi><mo>(</mo>${U('i',nP)}<mo>)</mo>`, 'B does not compute anything new by itself: it turns the two stored frames into the equation R* = 0 that the next frame must satisfy. The unknown uⁿ⁺¹ appears inside R, so the equation is nonlinear and implicit.'),
  DSTEP('T', `${U('i',mP)}<mo>=</mo>${U('i',mS)}<mo>−</mo>${DTAU}${RS(U('i',mS))}`, 'T is one sweep of an iterative solver dressed as a time step in a fictitious time τ. When the iterate stops changing, R* = 0: the implicit step is solved. Steady RANS uses the very same loop with R in place of R*.'),
  DSTEP('P', `${U('i',nP)}<mo>=</mo>${X('us','<msubsup><mi>u</mi><mi>i</mi><mo>*</mo></msubsup>')}<mo>−</mo>${fr(`<mn>2</mn>${DT}`,'<mn>3</mn>')}${D('i')}<mi data-t="phi">φ</mi><mo>,</mo><mspace width="1em"/>${D('j')}${D('j')}<mi data-t="phi">φ</mi><mo>=</mo>${fr('<mn>3</mn>',`<mn>2</mn>${DT}`)}${D('j')}${X('us','<msubsup><mi>u</mi><mi>j</mi><mo>*</mo></msubsup>')}`, 'P is a linear map that keeps the divergence-free part of a field and removes the rest (a Helmholtz projection). It is the only operator that couples every cell to every other in one go, which is why it dominates parallel cost.')])}`;

const BLOCKA = `<div class="eqhero"><math display="block"><msub><mi>u</mi>${ij('i')}</msub><mo>=</mo>${ob(`${UB()}<mo>+</mo>${UT()}`, 'A', 'A: ⟨uᵢ⟩, what URANS resolves')}<mo>+</mo>${ob(UP(), 'E', 'E: modelled by ν_t')}</math>
  <math display="block" class="sm">${ob(`${D('t')}${UA()}`, 'B', 'B: kept (steady RANS drops it)')}<mo>+</mo>${UA('j')}${D('j')}${UA()}<mo>=</mo><mo>−</mo>${D('i')}${PA}<mo>+</mo>${D('j')}${ob(`<mo>[</mo><mo>(</mo>${NU}<mo>+</mo>${NUT}<mo>)</mo><mo>(</mo>${D('j')}${UA()}<mo>+</mo>${D('i')}${UA('j')}<mo>)</mo><mo>]</mo>`, 'E', 'E: viscous + eddy stress')}<mo>,</mo><mspace width="1em"/>${ob(`${D('i')}${UA()}<mo>=</mo><mn>0</mn>`, 'P', 'P: enforced')}</math></div>
 <div class="bb">
  <figure class="viz">
   <canvas id="urans-sigviz" data-w="460" data-h="430" aria-label="A wake velocity signal split into mean, coherent shedding and turbulence; its phase average converging; and its spectrum with the spectral gap"></canvas>
   <div class="lg"><span style="color:var(--c-f)"><i class="ln"></i>mean ū</span><span style="color:var(--c-c)"><i class="ln"></i>coherent ũ</span><span style="color:var(--c-w)"><i class="ln"></i>turbulence u′</span><span style="color:var(--c-u)"><i class="ln"></i>phase average ⟨u⟩</span></div>
   <div class="ctl"><label for="urans-sep" class="sym" style="color:var(--c-w)">f<sub>t</sub>/f<sub>s</sub></label><input type="range" id="urans-sep" min="0" max="1" step="0.01" value="0.75"><output id="urans-sepv">20</output></div>
   <div class="note" id="urans-sepcap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="A,u,ubar,util,upr,theta,r,fs,t,nut,B,E,P,p,ij,grad,nu"></aside>
 </div>
 ${DEEP([
  DSTEP('1', `${UA()}<mo>(</mo><mi data-t="theta">θ</mi><mo>)</mo><mo>=</mo>${fr('<mn>1</mn>','<msub><mi>N</mi><mi>r</mi></msub>')}<munderover><mo>∑</mo><mrow><mi data-t="r">r</mi><mo>=</mo><mn>1</mn></mrow><msub><mi>N</mi><mi>r</mi></msub></munderover><msub><mi>u</mi>${ij('i')}</msub><mo>(</mo><msub><mi>t</mi><mn>0</mn></msub><mo>+</mo>${fr('<mi data-t="theta">θ</mi><mo>/</mo><mn>2</mn><mi>π</mi><mo>+</mo><mi data-t="r">r</mi>', X('fs','<msub><mi>f</mi><mi>s</mi></msub>'))}<mo>)</mo>`, 'The phase average: sample the same point in the same phase of many cycles and average. ⟨u′⟩ = 0 by definition, while ⟨ū + ũ⟩ = ū + ũ. Without a clean period one averages over repeats of the whole experiment instead (an ensemble).'),
  DSTEP('2', `${D('t')}${UA()}<mo>+</mo>${UA('j')}${D('j')}${UA()}<mo>=</mo><mo>−</mo>${D('i')}${PA}<mo>+</mo>${NU}${D('j')}${D('j')}${UA()}<mo>−</mo>${D('j')}<mo>⟨</mo>${UP('i')}${UP('j')}<mo>⟩</mo>`, 'Put uᵢ = ⟨uᵢ⟩ + u′ᵢ into Navier–Stokes and average at fixed phase. Every term stays the same except one new unknown: the turbulent stress ⟨u′ᵢu′ⱼ⟩. The coherent stresses (ũ times ũ) are not modelled: they are resolved, inside ⟨uⱼ⟩∂ⱼ⟨uᵢ⟩.'),
  DSTEP('3', `<mo>−</mo><mo>⟨</mo>${UP('i')}${UP('j')}<mo>⟩</mo><mo>=</mo>${NUT}<mo>(</mo>${D('j')}${UA()}<mo>+</mo>${D('i')}${UA('j')}<mo>)</mo><mo>−</mo><mfrac><mn>2</mn><mn>3</mn></mfrac><mi data-t="k">k</mi><msub data-t="delta"><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>`, 'Boussinesq closure, as in steady RANS (the ⅔kδᵢⱼ part joins the pressure). The hidden assumption: turbulence reacts instantly to the resolved flow. That needs scale separation: turbulent eddies much faster than the shedding (a spectral gap). Slide f_t/f_s down to see the gap close.')])}`;

const BLOCKB = `<div class="eqhero"><math display="block">${ob(`${fr(`<mn>3</mn>${U('i',nP)}<mo>−</mo><mn>4</mn>${U('i',nS)}<mo>+</mo>${U('i',nM)}`, `<mn>2</mn>${DT}`)}<mo>+</mo><mi data-t="R">R</mi><mo>(</mo>${U('i',nP)}<mo>)</mo>`, 'B', 'B: BDF2, the residual R*(uⁿ⁺¹)')}<mo>=</mo><mn>0</mn></math>
  <math display="block" class="sm">${ob(`${U('i',mP)}<mo>=</mo>${U('i',mS)}<mo>−</mo>${DTAU}${RS(U('i',mS))}`, 'T', 'T: one pseudo-time sweep, m = 0 … M−1')}<mspace width="1.5em"/>${X('CFL','<mtext>CFL</mtext>')}<mo>=</mo>${fr(`<mo>|</mo>${U()}<mo>|</mo>${DT}`,'<mi>Δ</mi><mi>x</mi>')}</math>
  <math display="block" class="sm"><mi data-t="R">R</mi><mo>(</mo>${U()}<mo>)</mo><mo>=</mo>${U('j')}${D('j')}${U()}<mo>+</mo>${D('i')}${PP}<mo>−</mo>${D('j')}<mo>[</mo><mo>(</mo>${NU}<mo>+</mo>${NUT}<mo>)</mo><mo>(</mo>${D('j')}${U()}<mo>+</mo>${D('i')}${U('j')}<mo>)</mo><mo>]</mo></math></div>
 <p class="note">From here on uᵢ means the resolved ⟨uᵢ⟩. The picture solves the same kind of step for one shedding-like oscillation, du/dt = iωu (period 1), with real numbers.</p>
 <div class="bb">
  <figure class="viz">
   <canvas id="urans-bdfviz" data-w="460" data-h="430" aria-label="BDF2 with dual time stepping on an oscillation: exact curve, BDF2 levels, the inner pseudo-time iterations, the residual per iteration and the damping per period"></canvas>
   <div class="lg"><span style="color:var(--c-w)"><i class="ln dash"></i>exact</span><span style="color:var(--c-cs)"><i class="ln"></i>BDF2 levels uⁿ</span><span style="color:var(--c-tau)"><i class="ln"></i>inner iterates u⁽ᵐ⁾</span><span style="color:var(--c-nu)"><i class="ln dash"></i>explicit Euler</span></div>
   <div class="ctl3"><label for="urans-npp" class="sym" style="color:var(--c-cs)">steps/period</label><input type="range" id="urans-npp" min="4" max="48" step="1" value="12"><output id="urans-nppv">12</output><label for="urans-mi" class="sym" style="color:var(--c-tau)">M</label><input type="range" id="urans-mi" min="1" max="12" step="1" value="6"><output id="urans-miv">6</output></div>
   <div class="note" id="urans-bdfcap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="B,T,dt,n,m,M,tau,dtau,Rs,R,CFL,u,t"></aside>
 </div>
 ${DEEP([
  DSTEP('1', `${D('t')}${U()}<mo>(</mo><msub><mi>t</mi>${nP}</msub><mo>)</mo><mo>=</mo>${fr(`<mn>3</mn>${U('i',nP)}<mo>−</mo><mn>4</mn>${U('i',nS)}<mo>+</mo>${U('i',nM)}`, `<mn>2</mn>${DT}`)}<mo>+</mo>${fr(`${X('dt','<msup><mrow><mi>Δ</mi><mi>t</mi></mrow><mn>2</mn></msup>')}`,'<mn>3</mn>')}<msubsup><mo>∂</mo><mi data-t="t">t</mi><mn>3</mn></msubsup>${U()}<mo>+</mo><mo>…</mo>`, 'Fit a parabola through the three frames n−1, n, n+1 and take its slope at the newest one: that is BDF2. The leftover term shrinks like Δt²: halve the step, quarter the error.'),
  DSTEP('2', `<mo>(</mo><mn>3</mn><mo>−</mo><mn>2</mn><mi>z</mi><mo>)</mo><msup><mi>G</mi><mn>2</mn></msup><mo>−</mo><mn>4</mn><mi>G</mi><mo>+</mo><mn>1</mn><mo>=</mo><mn>0</mn><mo>,</mo><mspace width="1em"/><mi>z</mi><mo>=</mo><mi>i</mi><mi>ω</mi>${DT}<mo>⇒</mo><mo>|</mo><mi>G</mi><mo>|</mo><mo>≈</mo><mn>1</mn><mo>−</mo>${fr('<msup><mrow><mo>(</mo><mi>ω</mi><mi>Δ</mi><mi>t</mi><mo>)</mo></mrow><mn>4</mn></msup>','<mn>4</mn>')}`, 'Growth factor per step G for a pure oscillation. |G| < 1 for every Δt (A-stable: no CFL limit), but slightly: an oscillation loses about (ωΔt)⁴/4 per step and lags by about (ωΔt)²/3 of a step. At 16 steps per period that is 7% amplitude per period: large steps damp the shedding.'),
  DSTEP('3', `${fr(`<mi>d</mi>${U()}`, X('tau','<mi>d</mi><mi>τ</mi>'))}<mo>=</mo><mo>−</mo>${RS(U())}<mo>,</mo><mspace width="1em"/>${DTAU}<mo>=</mo>${fr('<mn>1</mn>',`${fr('<mn>3</mn>',`<mn>2</mn>${DT}`)}<mo>+</mo>${fr(`<mo>|</mo>${U()}<mo>|</mo>`,'<mi>Δ</mi><mi>x</mi>')}<mo>+</mo>${fr(`<mn>6</mn><mo>(</mo>${NU}<mo>+</mo>${NUT}<mo>)</mo>`,'<msup><mrow><mi>Δ</mi><mi>x</mi></mrow><mn>2</mn></msup>')}`)}`, 'Dual time stepping (Jameson 1991): march the fictitious time τ to a steady state of R*. Taking the 3/(2Δt) term into the local Δτ ("point-implicit", Melson et al. 1993) keeps the inner loop stable even when Δτ would exceed Δt. Our solver uses exactly this Δτ, sweeping cells in place (Gauss–Seidel), forward then backward.')])}`;

const BLOCKC = `<div class="eqhero"><math display="block">${ob(`${NUT}<mo>=</mo>${NT}${X('fv1','<msub><mi>f</mi><mrow><mi>v</mi><mn>1</mn></mrow></msub>')}<mo>(</mo><mi data-t="chi">χ</mi><mo>)</mo>`, 'E', 'E: eddy viscosity, cell by cell')}<mo>,</mo><mspace width="1em"/><mi data-t="chi">χ</mi><mo>=</mo>${fr(NT, NU)}<mo>,</mo><mspace width="1em"/>${X('fv1','<msub><mi>f</mi><mrow><mi>v</mi><mn>1</mn></mrow></msub>')}<mo>=</mo>${fr('<msup><mi data-t="chi">χ</mi><mn>3</mn></msup>', `<msup><mi data-t="chi">χ</mi><mn>3</mn></msup><mo>+</mo>${X('cv1','<msubsup><mi>c</mi><mrow><mi>v</mi><mn>1</mn></mrow><mn>3</mn></msubsup>')}`)}</math>
  <math display="block" class="sm">${fr(`<mi>D</mi>${NT}`,'<mi>D</mi><mi data-t="t">t</mi>')}<mo>=</mo>${ob(X('prod',`<msub><mi>c</mi><mrow><mi>b</mi><mn>1</mn></mrow></msub><mover accent="true"><mi>S</mi><mo>˜</mo></mover>`)+NT, 'prod', 'production')}<mo>−</mo>${ob(X('dest','<msub><mi>c</mi><mrow><mi>w</mi><mn>1</mn></mrow></msub><msub><mi>f</mi><mi>w</mi></msub>')+`<msup><mrow><mo>(</mo>${fr(NT,'<mi data-t="d">d</mi>')}<mo>)</mo></mrow><mn>2</mn></msup>`, 'dest', 'destruction near walls')}<mo>+</mo>${ob(X('diff','<mfrac><mn>1</mn><mi>σ</mi></mfrac>')+`<mo>[</mo>${D('j')}<mo>(</mo><mo>(</mo>${NU}<mo>+</mo>${NT}<mo>)</mo>${D('j')}${NT}<mo>)</mo><mo>+</mo><msub><mi>c</mi><mrow><mi>b</mi><mn>2</mn></mrow></msub>${D('j')}${NT}${D('j')}${NT}<mo>]</mo>`, 'diff', 'diffusion')}</math>
  <math display="block" class="sm">${X('Reff','<msub><mtext>Re</mtext><mtext>eff</mtext></msub>')}<mo>=</mo>${fr('<mi>U</mi><mi>D</mi>',`${NU}<mo>+</mo>${NUT}`)}<mo>,</mo><mspace width="1.5em"/>${X('St','<mtext>St</mtext>')}<mo>=</mo>${fr(X('fs','<msub><mi>f</mi><mi>s</mi></msub>')+'<mi>D</mi>','<mi>U</mi>')}</math></div>
 <div class="bb">
  <figure class="viz">
   <canvas id="urans-ntviz" data-w="460" data-h="400" aria-label="Left: the damping function f_v1 and the eddy viscosity it gives. Right: the effective Reynolds number and how the shedding amplitude grows or dies"></canvas>
   <div class="ctl"><label for="urans-ntr" class="sym" style="color:var(--c-nu)">ν<sub>t</sub>/ν</label><input type="range" id="urans-ntr" min="0" max="3.6" step="0.02" value="2.2"><output id="urans-ntrv">158</output></div>
   <div class="note" id="urans-ntcap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="E,nut,nt,chi,fv1,cv1,nu,prod,dest,diff,d,Reff,St,fs"></aside>
 </div>
 ${DEEP([
  DSTEP('1', `${NT}<mo>≈</mo><mi>κ</mi><msub><mi>u</mi><mi>τ</mi></msub><mi data-t="d">d</mi><mspace width="1em"/><mtext>but</mtext><mspace width="1em"/>${NUT}<mo>→</mo><mn>0</mn><mtext> at the wall</mtext>`, 'Why two variables: Spalart and Allmaras chose ν̃ so that it stays a simple straight line κu_τd all the way to the wall, which is easy to compute. The real ν_t must die off in the viscous sublayer; f_v1 does that damping. Away from walls f_v1 → 1 and ν_t = ν̃.'),
  DSTEP('2', `${X('Reff','<msub><mtext>Re</mtext><mtext>eff</mtext></msub>')}<mo>&lt;</mo><msub><mtext>Re</mtext><mi>c</mi></msub><mo>≈</mo><mn>50</mn><mspace width="1em"/><mo>⇒</mo><mspace width="1em"/><mtext>no shedding</mtext>`, 'Over-damping: a wake sheds only if its effective Reynolds number is above the onset value (≈ 47 for a circular cylinder, about 50 for a square). If the model makes ν_t too large, URANS returns a steady wake although the real one sheds. The standard k–ε model does this at the front stagnation point (it produces k from pure strain); Kato and Launder (1993) fixed it by using vorticity, as SA does.'),
  DSTEP('3', `<msub><mi>u</mi>${ij('i')}</msub><mo>−</mo>${UA()}<mo>=</mo>${UP()}<mo>:</mo><mspace width=".6em"/><mtext>never resolved</mtext>`, 'What URANS cannot give: the broadband turbulence itself (no spectrum beyond the shedding harmonics), the 3D eddies along the span (in the Build solver the spanwise variation decays: URANS keeps a 2D-like wake), and cycle-to-cycle variation. It gives the phase-averaged flow, which is what Lyn et al. (1995) measured, so that is the fair comparison.')])}`;

const CHECKS = {
 '0': [
  ['At one cell and one time level, how many numbers does the URANS state hold here?', ['3', '5: three velocity components, pressure and ν̃', '19'], 1, 'q = (u_x, u_y, u_z, p, ν̃): five numbers per cell (a two-equation model like k–ω would make it six).'],
  ['Why does a BDF2 step need both qⁿ and qⁿ⁻¹?', ['For the halo exchange', 'Its time derivative is a parabola through three frames: n−1, n and the new n+1', 'To store the pressure'], 1, 'Second order in time needs three points; the newest one is the unknown.'],
  ['While the pseudo-time index m counts up, what happens to the physical time?', ['It advances by Δτ each sweep', 'Nothing: it stays at tₙ₊₁ until the inner loop ends', 'It goes backwards'], 1, 'τ is fictitious. Only when the inner loop has converged is the frame accepted and n increases.'],
  ['Which operator couples every cell of the grid to every other in one go?', ['E, the closure', 'T, one sweep', 'P, the projection (a Poisson solve)'], 2, 'E is pointwise, a sweep touches neighbours; the Poisson equation for φ is global.'],
  ['You double the cells along x, y and z and keep the same number of steps per shedding period. The state grows by…', ['2×', '8×', '16×'], 1, '2³ = 8× the cells, so 8× the numbers per frame (and more steps too if Δt must follow Δx).']],
 A: [
  ['What does URANS resolve?', ['Only the time mean ū', 'The phase average ū + ũ: mean plus coherent shedding', 'Everything, including u′'], 1, 'The average is taken at fixed phase, so the periodic shedding survives; only the random u′ is averaged away.'],
  ['What is ⟨u′⟩, the phase average of the turbulent part?', ['Zero, by definition', 'ν_t', 'The shedding amplitude'], 0, 'u′ is defined as what is left after removing ⟨u⟩, so its own average is zero at every phase.'],
  ['The turbulent eddies become as slow as the shedding (no spectral gap). What goes wrong?', ['Nothing', 'The closure assumes turbulence adapts instantly; now it cannot, so ν_t is a poor model and URANS loses its basis', 'The flow becomes compressible'], 1, 'URANS needs scale separation. Without it you need scale-resolving methods (DES, LES).'],
  ['Compared with steady RANS, which single term does URANS keep?', ['The pressure gradient', '∂ₜ⟨uᵢ⟩', 'The eddy viscosity'], 1, 'Same equations, same closure; only the time derivative stays.'],
  ['Are the stresses of the coherent motion (ũ times ũ) modelled by ν_t?', ['Yes', 'No: they are resolved, because ũ is part of ⟨u⟩', 'Only near walls'], 1, 'They sit inside the resolved convection term; ν_t only replaces ⟨u′ᵢu′ⱼ⟩.']],
 B: [
  ['BDF2 is implicit. What does that buy you?', ['No inner iterations', 'No CFL stability limit: Δt is set by accuracy', 'Exact answers'], 1, 'A-stable: any Δt is stable, but large steps damp and delay the oscillation.'],
  ['You stop the inner loop after one sweep at a large Δt. What happens?', ['The solution is still exact BDF2', 'The implicit equation is not solved: wrong amplitude, possibly instability', 'It becomes LES'], 1, 'Only a converged inner loop gives BDF2. In the Build solver a too-small M at large Δt gives inaccurate shedding.'],
  ['How many BDF2 steps per shedding period keep amplitude loss under ~1% per period?', ['About 4', 'About 32 or more', 'Exactly 1'], 1, 'Damping is about (ωΔt)⁴/4 per step: 0.7% per period at N = 32, 7% at N = 16.'],
  ['Explicit Euler on a pure oscillation, any Δt:', ['Decays slowly', 'Grows every step: |G| = √(1 + (ωΔt)²) > 1', 'Is exact'], 1, 'That is why explicit unsteady codes need small steps or better schemes, and why URANS codes use implicit BDF2.'],
  ['Halving Δt reduces the BDF2 truncation error by…', ['2×', '4×', '8×'], 1, 'Second order: error ∝ Δt².']],
 C: [
  ['What is f_v1 at χ = c_v1 = 7.1?', ['0', '0.5', '1'], 1, 'χ³/(χ³ + χ³) = ½.'],
  ['The model multiplies ν_t by 12. In the Build solver what happens to the shedding?', ['It gets stronger', 'It is damped almost away (lift rms 0.76 → 0.20): Re_eff drops toward the onset value', 'The frequency doubles'], 1, 'Over-damping: too much eddy viscosity and the resolved wake goes nearly steady.'],
  ['Where is ν̃ produced?', ['In the free stream', 'Where the flow spins: shear layers from the corners and the wake', 'Only inside the solid'], 1, 'Production c_b1 S̃ ν̃ needs vorticity.'],
  ['Why is the destruction term ∝ (ν̃/d)²?', ['A wall blocks large eddies, so close to it (small d) ν̃ must be destroyed', 'For numerical stability', 'It models compressibility'], 0, 'Blocking by the wall shrinks the eddies near it; the term vanishes far away.'],
  ['URANS of this square cylinder: what can you NOT read off it?', ['The Strouhal number', 'The mean drag', 'The broadband turbulence spectrum and 3D eddies along the span'], 2, 'Those live in u′, which URANS never resolves.']],
};
const QUIZ = [
 ['When is URANS the right tool?', ['Statistically steady flow without coherent unsteadiness', 'Flows with a strong, slow coherent unsteadiness well separated from the turbulence, like regular vortex shedding', 'When you need the full turbulence spectrum'], 1, 'Scale separation is the condition; then the phase average is meaningful and cheap to compute.'],
 ['What is the inner (pseudo-time) loop for?', ['To advance physical time faster', 'To solve the implicit BDF2 equation of each physical step', 'To average over cycles'], 1, 'Dual time stepping: τ is fictitious; converged inner iterations give R* = 0.'],
 ['A URANS run is mesh-converged but the wake does not shed although experiments show shedding. The most likely culprit?', ['Too many time steps', 'Too much eddy viscosity from the model (over-damping)', 'Too fine a mesh'], 1, 'Re_eff = UD/(ν + ν_t) has fallen below onset; models such as standard k–ε are known for this.'],
 ['Why is the pressure Poisson solve the parallel bottleneck of each step?', ['It is pointwise', 'It couples all cells: Krylov iterations need global dot products and multigrid needs coarse levels with little work per rank', 'It needs double precision'], 1, 'Latency of global reductions and coarse grids sets a floor on time per step.'],
 ['Why can\'t you simply run 1000 time steps on 1000 groups of processors at once?', ['Each step needs the previous one: time is sequential', 'Memory is too small', 'BDF2 forbids it'], 0, 'Parallel-in-time methods (Parareal) exist but converge poorly for advection-dominated flows; it is research.'],
 ['Your URANS Strouhal number is 0.16; experiments give 0.132. A sensible first check?', ['Make Δt larger', 'Blockage (domain height), grid resolution near the corners, and steps per period', 'Switch off the turbulence model'], 1, 'Here 12.5% blockage and 6 cells per side raise St; refinement and a wider domain bring it down.'],
 ['Why do URANS spanwise variations die out on a square cylinder here, while experiments show 3D turbulence?', ['The grid is periodic', 'Eddy viscosity damps small 3D disturbances; the resolved flow is the phase average, which is nearly 2D', 'BDF2 removes the z-direction'], 1, 'The 3D, random part is u′, which is modelled, not resolved.'],
];
const BUILD = {
 intro: 'Put the operators of one URANS time step in order. When it\'s right, your 3D solver runs below: a square cylinder (Re = 22 000, Spalart–Allmaras) in a thin spanwise-periodic slab, 78 × 48 × 4 cells.',
 html: `<div class="scrollx"><canvas class="sim" id="urans-sim" data-w="780" data-h="350" aria-label="Your 3D URANS solver: mid-span slice of the wake behind a square cylinder in a 3D slab, with lift and drag histories and the inner-loop residuals; drag the 3D view to rotate"></canvas></div>
  <div class="btns" id="urans-modes"><button class="b pri" data-mode="w">vorticity ω_z</button><button class="b" data-mode="nut">eddy viscosity ν_t/ν</button><button class="b" data-mode="z">spanwise variation</button><button class="b" id="urans-restart">Restart</button></div>
  <div class="ctl"><label for="urans-dt" class="sym" style="color:var(--c-cs)">Δt</label><input type="range" id="urans-dt" min="0.025" max="0.4" step="0.025" value="0.1"><output id="urans-dtv">0.100</output></div>
  <div class="ctl"><label for="urans-kt" class="sym" style="color:var(--c-nu)">ν<sub>t</sub> ×</label><input type="range" id="urans-kt" min="-2" max="4" step="0.25" value="0"><output id="urans-ktv">1</output></div>
  <div class="ctl"><label for="urans-M" class="sym" style="color:var(--c-tau)">M</label><input type="range" id="urans-M" min="1" max="16" step="1" value="8"><output id="urans-Mv">8</output></div>
  <p class="note" id="urans-read">&nbsp;</p>`,
 steps: ['E: eddy viscosity ν_t from ν̃', 'B: guess uⁿ⁺¹ and build the BDF2 residual', 'T: pseudo-time sweeps until R* drops', 'P: solve the Poisson equation, subtract ∇φ', 'Advance ν̃ (Spalart–Allmaras) with the new flow', 'Shift levels: n−1 ← n ← n+1'],
 hint: 'Momentum needs ν_t first; the inner loop solves momentum; the projection makes it divergence-free; the turbulence model follows the new flow; shifting comes last.',
 success: 'Your 3D URANS solver is running. Watch the lift settle into a regular rhythm: the measured Strouhal number appears after a few cycles. Experiments (Lyn et al. 1995) give St = 0.132 and C_D ≈ 2.1.',
};
const PARALLEL = `<div class="par"><div class="stack">
  <p><strong>Each time step is a small steady solve.</strong> The grid is cut into blocks, one per rank (domain decomposition). Sweeps T and the closure E only need neighbours: before each sweep, ranks swap a <em>halo</em> two cells deep (the third-order stencil reaches two cells).</p>
  <p><strong>The pressure solve P is global.</strong> Production codes use a Krylov method (CG or GMRES) preconditioned by multigrid. Every Krylov iteration needs global dot products (an all-reduce whose cost grows like log P), and coarse multigrid levels have almost no work per rank: latency, not arithmetic, sets the floor.</p>
  <p><strong>Time is sequential.</strong> Step n+1 needs step n. Shedding needs ~20–60 steps per period and tens of periods for statistics, so thousands of steps run one after another. Parallel-in-time methods (Parareal) are research.</p></div>
  <canvas id="urans-dd" data-w="300" data-h="220" style="width:100%;max-width:300px;border-radius:8px;background:var(--bg)" aria-label="A 3D grid cut into blocks with halo layers"></canvas></div>
 <h3 style="font-size:16px">Strong scaling: same problem, more ranks</h3>
 <p>A 3D URANS of 50 million cells. Model per step: compute ∝ cells per rank, halo exchange ∝ block surface, plus about 60 all-reduces (CG with a multigrid preconditioner). Move the slider and find where adding ranks stops paying off.</p>
 <div class="scrollx"><canvas id="urans-scal" data-w="680" data-h="270" aria-label="Time per step and parallel efficiency versus number of ranks"></canvas></div>
 <div class="ctl"><label for="urans-ranks" class="sym">ranks</label><input type="range" id="urans-ranks" min="0" max="17" step="1" value="4"><output id="urans-ranksv">16</output></div>
 <div class="fb" id="urans-scalfb"></div>
 <details><summary>Parareal: parallel in time (research)</summary><p>Lions, Maday &amp; Turinici (2001): split the run into time slices, sweep a cheap coarse solver G across all slices in sequence, run the expensive fine solver F on every slice in parallel, then correct: Uₙ₊₁ᵏ⁺¹ = G(Uₙᵏ⁺¹) + F(Uₙᵏ) − G(Uₙᵏ). Speed-up is at most slices ÷ iterations. For diffusion it works well; for advection-dominated flows like a shedding wake it converges slowly (Gander &amp; Vandewalle 2007), so production URANS codes still march step by step.</p></details>`;
const SOURCES = [
 ['Lyn, Einav, Rodi & Park (1995). A laser-Doppler velocimetry study of ensemble-averaged characteristics of the turbulent near wake of a square cylinder. J. Fluid Mech. 304', 'https://doi.org/10.1017/S002211209500440X'],
 ['Reynolds & Hussain (1972). The mechanics of an organized wave in turbulent shear flow, part 3 (triple decomposition). J. Fluid Mech. 54', 'https://doi.org/10.1017/S0022112072000679'],
 ['Spalart & Allmaras (1992). A one-equation turbulence model for aerodynamic flows. AIAA 92-0439', 'https://doi.org/10.2514/6.1992-439'],
 ['NASA Turbulence Modeling Resource: the Spalart–Allmaras model (constants, SA-noft2)', 'https://turbmodels.larc.nasa.gov/spalart.html'],
 ['Jameson (1991). Time dependent calculations using multigrid, with applications to unsteady flows past airfoils and wings. AIAA 91-1596', 'https://doi.org/10.2514/6.1991-1596'],
 ['Guermond, Minev & Shen (2006). An overview of projection methods for incompressible flows. CMAME 195', 'https://doi.org/10.1016/j.cma.2005.10.010'],
 ['Okajima (1982). Strouhal numbers of rectangular cylinders. J. Fluid Mech. 123', 'https://doi.org/10.1017/S0022112082003115'],
 ['Williamson (1996). Vortex dynamics in the cylinder wake. Annu. Rev. Fluid Mech. 28', 'https://doi.org/10.1146/annurev.fl.28.010196.002401'],
 ['Rodi (1997). Comparison of LES and RANS calculations of the flow around bluff bodies. J. Wind Eng. Ind. Aerodyn. 69–71', 'https://doi.org/10.1016/S0167-6105(97)00147-5'],
 ['Spalart (2000). Strategies for turbulence modelling and simulations. Int. J. Heat Fluid Flow 21', 'https://doi.org/10.1016/S0142-727X(00)00007-2'],
 ['Provansal, Mathis & Boyer (1987). Bénard–von Kármán instability: transient and forced regimes. J. Fluid Mech. 182', 'https://doi.org/10.1017/S0022112087002234'],
 ['Lions, Maday & Turinici (2001). A "parareal" in time discretization of PDEs. C. R. Acad. Sci. Paris 332', 'https://doi.org/10.1016/S0764-4442(00)01793-6'],
 ['Gander & Vandewalle (2007). Analysis of the parareal time-parallel time-integration method. SIAM J. Sci. Comput. 29', 'https://doi.org/10.1137/05064607X'],
];

function mount(root, K){
const {$, P, hidpi, arrow, rr, pill, label, ease, lerp, clamp, proj, box, orbit, isAct, MONO, MATH, reduce} = K;
const SMF = '10px "IBM Plex Mono", monospace', BF = '600 11px "IBM Plex Mono", monospace', SANS = '600 12px "IBM Plex Sans", sans-serif';
const f3 = (v, d=3) => v.toFixed(d), ex = v => v.toExponential(1).replace('e-', '·10⁻').replace('e+', '·10^');
let openB = '0';

// ===== 0: one real URANS step on a tiny 24 × 12 × 2 grid, stopped after every operator =====
const WT = makeURANS({ Dc: 3, NX: 24, NY: 12, NZ: 2, i0: 6, dt: 0.15, M: 6, tol: 1e-3 });
for (let n=0;n<90;n++){ const g = WT.step(); while (!g.next().done); }
const WSX = WT.SX, PI_ = 13, PJ = 7, PC = WT.I(PI_, PJ, 0);
const cuv = (u, v, c) => [.5*(u[c]+u[c+1]), .5*(v[c]+v[c+WSX])];
let snap = null;
function wtStep(){
  const W = WT, cp = a => Float64Array.from(a);
  const sn = { un: [cp(W.un), cp(W.vn)], um: [cp(W.um), cp(W.vm)], sw: [], wz: .5*(W.wn[PC]+W.wn[PC+W.SXY]), p: W.p[PC], ntn: W.ntn[PC], ntm: W.ntm[PC], t0: W.t };
  W.rec = true; const g = W.step(); let r;
  while (!(r = g.next()).done){ const L = r.value;
    if (L === 'E') sn.nut = cp(W.nut);
    if (L === 'B') sn.guess = [cp(W.u), cp(W.v)];
    if (L === 'T') sn.sw.push({ r: cp(W.rmap), u: cp(W.u), v: cp(W.v) });
    if (L === 'P') { sn.divB = W.divB; sn.divA = cp(W.div); sn.uP = [cp(W.u), cp(W.v)]; sn.cg = W.cgIts; sn.dB = W.divBefore; sn.dA = W.divAfter; } }
  W.rec = false; sn.res = W.res.slice(); sn.t = W.t; sn.hist = W.hist.slice(-80);
  let mx = 0; for (const x of sn.nut) mx = Math.max(mx, x); sn.nutMax = mx;
  let rm = 0; for (const x of sn.sw[0].r) rm = Math.max(rm, Math.sqrt(x)); sn.rMax = rm || 1;
  let dm = 0; for (const x of sn.divB) dm = Math.max(dm, Math.abs(x)); sn.dMax = dm || 1;
  snap = sn;
}
wtStep();
const CO = hidpi($('opviz'));
const OPS = [['qⁿ', null], ['E', 'E'], ['B', 'B'], ['T', 'T'], ['P', 'P'], ['n+1', 'n']];
const opCapText = k => { const s = snap, W = WT;
  return [
  `Start: two stored frames, uⁿ⁻¹ (faint grey) and uⁿ (pink), on a 24 × 12 × 2 grid around a square (one layer shown). Like the last two frames of a film: BDF2 needs both. The probe cell ◆ holds 5 numbers, listed right.`,
  `E: every cell turns its ν̃ into an eddy viscosity, ν_t = ν̃ f_v1(ν̃/ν). Here ν_t peaks at ${f3(s.nutMax,4)} = ${Math.round(s.nutMax/W.nu)}× ν, in the shear layers and wake. Purely local, like reading a thermostat and setting the heater.`,
  `B: guess the new frame by extrapolating, 2uⁿ − uⁿ⁻¹ (ochre arrows), and measure the BDF2 residual R*: how far each cell is from satisfying momentum at tₙ₊₁. The clock now points at n+1.`,
  `T: pseudo-time sweeps. Each one nudges every cell against its own residual while the clock stays at tₙ₊₁. ${s.res.length} sweeps cut R* to ${(100*s.res[s.res.length-1]).toFixed(1)}% of the first. Like redrafting until the editor finds nothing.`,
  `P: the swept velocity u* leaks: max |∂ᵢuᵢ| = ${f3(s.dB,3)}. One Poisson solve (${s.cg} CG iterations over 2 spanwise modes) gives φ; subtracting its gradient leaves ${ex(s.dA)}. Like squeezing a water balloon: water cannot pile up anywhere.`,
  `Accept the frame: ν̃ is advanced with the new flow, then n−1 ← n ← n+1 (t = ${f3(s.t,2)}). The film moves on one frame; the lift of this tiny run is plotted right. Next step: back to E.`][k]; };
let opStage = 0, opT = 0, opPlay = !reduce, opLast = null;
const opBtns = $('opsteps');
opBtns.innerHTML = OPS.map(([n],k) => `<button class="b opb" data-k="${k}">${k+1} · ${n}</button>`).join('');
opBtns.onclick = e => { const b = e.target.closest('.opb'); if (!b) return; opStage = +b.dataset.k; opT = 0; opCap(); K.pin(OPS[opStage][1]); if (reduce) drawOps(0); };
$('opplay').onclick = e => { opPlay = !opPlay; e.target.textContent = opPlay ? 'Pause' : 'Play'; };
function opCap(){ $('opcap').textContent = opCapText(opStage); opBtns.querySelectorAll('.opb').forEach((b,k) => b.classList.toggle('pri', k === opStage)); }
opCap();
const stageLen = k => k === 3 ? 0.9*snap.sw.length + 1.2 : 3.8;
function drawOps(now){
  const dt = opLast === null ? 0 : Math.min(100, now - opLast); opLast = now;
  opT = Math.min(opPlay ? 99 : 30, opT + dt/1000);
  if (opPlay && opT > stageLen(opStage)) { opT = 0; opStage = (opStage+1) % OPS.length; if (opStage === 0) wtStep(); opCap(); }
  const c = CO, W = c.W, H = c.H, p = P(), s = snap, e = reduce ? 1 : ease(opT/1.6), NXw = WT.NX, NYw = WT.NY, cs = 21, gx = 18, gy = 92, st = opStage;
  c.clearRect(0,0,W,H);
  // timeline: n−1, n, n+1 and the pseudo-time loop
  const tl = [60, 190, 320], ty = 40;
  c.strokeStyle = p.rule; c.lineWidth = 2; c.beginPath(); c.moveTo(30, ty); c.lineTo(380, ty); c.stroke();
  const sh = st === 5 ? e*130 : 0;
  ['n−1','n','n+1'].forEach((nm,k) => { const on = (st === 0 && k < 2) || (st >= 2 && st <= 4 && k === 2) || isAct('n'); const x = tl[k] - sh;
    c.fillStyle = on ? p.cs : p.mut; c.beginPath(); c.arc(x, ty, on ? 6 : 4, 0, 7); c.fill(); label(c, 't' + ['ₙ₋₁','ₙ','ₙ₊₁'][k], x, ty+20, on ? p.cs : p.mut, MATH, 'center'); });
  label(c, 'physical time', 392, ty+4, p.mut, SMF);
  if (st === 3 || isAct('T','m','tau')) { const x = tl[2], m = Math.min(s.sw.length, Math.floor(opT/0.9)+1);
    c.strokeStyle = p.tau; c.lineWidth = 2; c.beginPath(); c.arc(x, ty-16, 11, 0.3, Math.PI*2-0.3); c.stroke(); arrow(c, x+10, ty-20, x+11, ty-13, p.tau, 2);
    label(c, `pseudo-time m = ${st === 3 ? m : s.sw.length}`, x+22, ty-18, p.tau, BF); }
  // the grid, one z-layer: fill shows the quantity the current operator acts on
  const lastSw = s.sw[s.sw.length-1], swk = Math.min(s.sw.length-1, Math.floor(opT/0.9)), swf = clamp(opT/0.9 - swk, 0, 1);
  for (let j=0;j<NYw;j++) for (let i=0;i<NXw;i++){ const cc = WT.I(i,j,0), x = gx+i*cs, y = gy+(NYw-1-j)*cs;
    if (WT.solid[cc]) { c.fillStyle = p.ink; c.fillRect(x, y, cs, cs); continue; }
    let v = 0, col = p.u;
    if (st === 0 || st === 5) { const [a,b] = cuv(st === 5 ? s.uP[0] : s.un[0], st === 5 ? s.uP[1] : s.un[1], cc); v = .3*Math.hypot(a,b)/1.6; }
    else if (st === 1) { v = Math.log10(1 + s.nut[cc]/WT.nu)/Math.log10(1 + s.nutMax/WT.nu)*e; col = p.nu; }
    else if (st === 2) { v = Math.sqrt(s.sw[0].r[cc])/s.rMax*e; col = p.cs; }
    else if (st === 3) { const a = Math.sqrt(s.sw[Math.max(0,swk-1)].r[cc]), b = Math.sqrt(s.sw[swk].r[cc]); v = Math.min(1, Math.sqrt(lerp(a, b, swf)/s.rMax)); col = p.tau; }
    else if (st === 4) { v = Math.min(1, Math.abs(lerp(s.divB[cc], s.divA[cc], e))/s.dMax*1.5); col = p.rho; }
    c.fillStyle = p.panel; c.fillRect(x, y, cs, cs); c.globalAlpha = Math.min(1, v); c.fillStyle = col; c.fillRect(x, y, cs, cs); c.globalAlpha = 1; }
  c.strokeStyle = p.rule; c.lineWidth = .6; c.beginPath(); for (let i=0;i<=NXw;i++){ c.moveTo(gx+i*cs, gy); c.lineTo(gx+i*cs, gy+NYw*cs); } for (let j=0;j<=NYw;j++){ c.moveTo(gx, gy+j*cs); c.lineTo(gx+NXw*cs, gy+j*cs); } c.stroke();
  // arrows: cell-centred velocity of the frame being shown
  const fld = st === 0 ? s.un : st === 1 ? s.un : st === 2 ? s.guess : st === 3 ? [s.sw[swk].u, s.sw[swk].v] : st === 4 ? null : s.uP;
  const sc = cs*.55;
  for (let j=0;j<NYw;j++) for (let i=0;i<NXw;i++){ const cc = WT.I(i,j,0); if (WT.solid[cc]) continue; const x = gx+(i+.5)*cs, y = gy+(NYw-.5-j)*cs;
    if (st === 0) { const [a,b] = cuv(s.um[0], s.um[1], cc); c.globalAlpha = .45; arrow(c, x, y, x+a*sc, y-b*sc, p.w, 1.1); c.globalAlpha = 1; }
    let a, b;
    if (st === 4) { const [a0,b0] = cuv(lastSw.u, lastSw.v, cc), [a1,b1] = cuv(s.uP[0], s.uP[1], cc); a = lerp(a0,a1,e); b = lerp(b0,b1,e); }
    else [a,b] = cuv(fld[0], fld[1], cc);
    const col = st === 2 ? p.cs : st === 3 ? p.tau : st === 4 ? p.rho : st === 1 ? p.mut : p.u;
    arrow(c, x, y, x+a*sc, y-b*sc, col, st === 1 ? 1 : 1.4); }
  { const x = gx+(PI_+.5)*cs, y = gy+(NYw-.5-PJ)*cs; c.strokeStyle = p.ink; c.lineWidth = 2; c.beginPath(); c.moveTo(x, y-7); c.lineTo(x+7, y); c.lineTo(x, y+7); c.lineTo(x-7, y); c.closePath(); c.stroke(); }
  label(c, ['|uⁿ| shaded', 'ν_t / ν (log)', '|R*| of the guess', `|R*| after sweep ${swk+1}`, '|∂ᵢuᵢ|: before → after P', '|uⁿ⁺¹| shaded'][st], gx, gy-10, p.mut, SMF);
  // right panel: the probe cell's numbers for this operator
  const rx = 560, rw = 300;
  label(c, ['probe cell ◆: the 5 numbers', 'E at the probe cell', 'B at the probe cell (u_x)', 'T: residual per sweep', 'P: divergence, before and after', 'lift C_L of this tiny run'][st], rx, 76, p.ink, SANS);
  if (st === 0) { const [ux,uy] = cuv(s.un[0], s.un[1], PC), [vx,vy] = cuv(s.um[0], s.um[1], PC);
    const rows = [['u_x', ux, vx, p.u], ['u_y', uy, vy, p.u], ['u_z', s.wz, null, p.u], ['p', s.p, null, p.rho], ['ν̃', s.ntn, s.ntm, p.eq]];
    label(c, 'level n', rx+150, 104, p.cs, SMF, 'right'); label(c, 'level n−1', rx+260, 104, p.mut, SMF, 'right');
    rows.forEach(([n,a,b,col],k) => { const y = 132 + k*30; label(c, n, rx, y, col, MATH); label(c, a.toExponential(3), rx+150, y, p.ink, BF, 'right'); label(c, b == null ? '—' : b.toExponential(3), rx+260, y, p.mut, MONO, 'right'); });
    label(c, '5 numbers × 576 cells × 2 levels', rx, 300, p.mut, SMF); }
  if (st === 1) { const x0 = rx+10, x1 = rx+rw-20, y0 = 280, y1 = 110, cm = 40, Xc = q => x0+(x1-x0)*q/cm, Yf = f => y0-(y0-y1)*f, fv = q => q**3/(q**3+357.911);
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y1-6); c.lineTo(x0, y0); c.lineTo(x1, y0); c.stroke();
    c.strokeStyle = p.eq; c.lineWidth = 2.4; c.beginPath(); for (let q=0;q<=80;q++){ const ch = cm*q/80; q ? c.lineTo(Xc(ch), Yf(fv(ch))) : c.moveTo(Xc(ch), Yf(fv(ch))); } c.stroke();
    const ch = s.nut[PC] > 0 ? WT.ntn[PC]/WT.nu : 0, chi = Math.min(cm, s.ntn/WT.nu), f = fv(s.ntn/WT.nu);
    c.fillStyle = p.nu; c.beginPath(); c.arc(Xc(chi), Yf(f), 6, 0, 7); c.fill();
    label(c, 'χ = ν̃/ν', x1, y0+16, p.eq, SMF, 'right'); label(c, 'f_v1', x0-4, y1-10, p.eq, SMF); label(c, '1', x0-6, Yf(1)+4, p.mut, SMF, 'right');
    label(c, `ν̃ = ${s.ntn.toExponential(2)}  χ = ${(s.ntn/WT.nu).toFixed(1)}`, rx, 316, p.ink, MONO); label(c, `f_v1 = ${f3(f)} → ν_t = ${s.nut[PC].toExponential(2)}`, rx, 334, p.nu, BF); void ch; }
  if (st === 2) { const [ux] = cuv(s.un[0], s.un[1], PC), [vx] = cuv(s.um[0], s.um[1], PC), [gx_] = cuv(s.guess[0], s.guess[1], PC), vals = [vx, ux, gx_];
    const lo = Math.min(...vals) - .05, hi = Math.max(...vals) + .05, Y = v => 270 - (v-lo)/(hi-lo)*150, xs = [rx+40, rx+140, rx+240];
    c.setLineDash([4,4]); c.strokeStyle = p.cs; c.lineWidth = 1.4; c.beginPath(); c.moveTo(xs[0], Y(vx)); c.lineTo(xs[2], Y(gx_)); c.stroke(); c.setLineDash([]);
    vals.forEach((v,k) => { c.fillStyle = k === 2 ? p.cs : p.u; c.beginPath(); c.arc(xs[k], Y(v), 6, 0, 7); c.fill(); label(c, ['n−1','n','guess n+1'][k], xs[k], 292, p.mut, SMF, 'center'); label(c, f3(v), xs[k], Y(v)-12, p.ink, SMF, 'center'); });
    const dd = (3*gx_ - 4*ux + vx)/(2*WT.dt);
    label(c, `∂ₜu ≈ (3·${f3(gx_)} − 4·${f3(ux)} + ${f3(vx)}) / (2·${WT.dt})`, rx, 318, p.ink, SMF); label(c, `   = ${f3(dd)}  (the B part of R*)`, rx, 336, p.cs, BF); }
  if (st === 3) { const n = s.res.length, bw = Math.min(36, (rw-30)/n), Y = r => 120 + (-Math.log10(Math.max(r,1e-4)))/4*160;
    for (let m=0;m<n;m++){ if (m > swk) break; const y = Y(s.res[m]), x = rx+10+m*(bw+6); c.fillStyle = p.tau; rr(c, x, 120, bw, Math.max(2, y-120), 3); c.fill(); label(c, String(m+1), x+bw/2, 296, p.mut, SMF, 'center'); label(c, s.res[m] >= .01 ? s.res[m].toFixed(2) : s.res[m].toExponential(0), x+bw/2, y+14, p.ink, SMF, 'center'); }
    label(c, 'bars grow down = residual falling (log)', rx, 318, p.mut, SMF); label(c, 'sweep m', rx, 336, p.tau, SMF); }
  if (st === 4) { const bars = [['before', s.dB, p.rho], ['after', s.dA, p.ok]], L = v => Math.max(4, (Math.log10(v)+9)/9*180);
    bars.forEach(([n,v,col],k) => { const x = rx+30+k*120, h = L(v); c.fillStyle = col; rr(c, x, 290-h, 60, h, 4); c.fill(); label(c, n, x+30, 308, p.mut, SMF, 'center'); label(c, v.toExponential(1), x+30, 284-h, p.ink, BF, 'center'); });
    label(c, `max |∂ᵢuᵢ|, log scale · ${s.cg} CG iterations`, rx, 334, p.mut, SMF); }
  if (st === 5) { const Hh = s.hist, x0 = rx+10, x1 = rx+rw-10, t0 = Hh[0][0], t1 = Hh[Hh.length-1][0], Xh = t => x0+(x1-x0)*(t-t0)/(t1-t0 || 1), Yh = v => 200 - v*60;
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, 200); c.lineTo(x1, 200); c.stroke();
    c.strokeStyle = p.u; c.lineWidth = 2; c.beginPath(); Hh.forEach((h,k) => k ? c.lineTo(Xh(h[0]), Yh(h[2])) : c.moveTo(Xh(h[0]), Yh(h[2]))); c.stroke();
    const hl = Hh[Hh.length-1]; c.fillStyle = p.cs; c.beginPath(); c.arc(Xh(hl[0]), Yh(hl[2]), 5, 0, 7); c.fill();
    label(c, `C_L = ${f3(hl[2])}, C_D = ${f3(hl[1])} at t = ${f3(hl[0],2)}`, rx, 318, p.ink, MONO); label(c, 'a coarse grid: shape only', rx, 336, p.mut, SMF); }
}

// ===== A: a wake signal = mean + coherent shedding + turbulence; phase average and spectrum, computed live =====
// u′ is an Ornstein–Uhlenbeck process (exactly discretised) with corner frequency f_t: a simple model of broadband turbulence.
const CA = hidpi($('sigviz')), SPC = 64, NBIN = 32, NBUF = 1024, UBAR = 0.6, SIG = 0.16;
const coh = th => 0.35*Math.sin(th) + 0.1*Math.sin(2*th + 0.6);
let seedA = 11; const rndA = () => (seedA = (seedA*16807) % 2147483647)/2147483647;
const gauss = () => Math.sqrt(-2*Math.log(rndA() + 1e-12))*Math.cos(2*Math.PI*rndA());
let sep = 15.8, ou = 0, kA = 0, bufU = new Float64Array(NBUF), bufP = new Float64Array(NBUF), binS = new Float64Array(NBIN), binN = new Float64Array(NBIN);
let spec = null, ghostsA = [], fA = 0;
function sigReset(){ binS.fill(0); binN.fill(0); }
function sigSample(){ const th = 2*Math.PI*(kA % SPC)/SPC, tauT = 1/(2*Math.PI*sep), a = Math.exp(-(1/SPC)/tauT);
  ou = ou*a + SIG*Math.sqrt(1-a*a)*gauss(); const v = UBAR + coh(th) + ou, q = kA % NBUF; bufU[q] = v; bufP[q] = th; kA++;
  const b = Math.floor(th/(2*Math.PI)*NBIN); binS[b] += v; binN[b]++; }
for (let q=0;q<NBUF;q++) sigSample(); sigReset();
// radix-2 FFT, in place
function fft(re, im){ const n = re.length; for (let i=1,j=0;i<n;i++){ let b = n>>1; for (; j & b; b >>= 1) j ^= b; j ^= b; if (i < j) { [re[i],re[j]] = [re[j],re[i]]; [im[i],im[j]] = [im[j],im[i]]; } }
  for (let len=2; len<=n; len<<=1){ const a = -2*Math.PI/len; for (let i=0;i<n;i+=len) for (let k=0;k<len/2;k++){ const c = Math.cos(a*k), s = Math.sin(a*k), xr = re[i+k+len/2]*c - im[i+k+len/2]*s, xi = re[i+k+len/2]*s + im[i+k+len/2]*c;
    re[i+k+len/2] = re[i+k] - xr; im[i+k+len/2] = im[i+k] - xi; re[i+k] += xr; im[i+k] += xi; } } }
function spectrum(){ const re = new Float64Array(NBUF), im = new Float64Array(NBUF); let m = 0; for (let q=0;q<NBUF;q++) m += bufU[q]; m /= NBUF;
  for (let q=0;q<NBUF;q++){ const w = .5 - .5*Math.cos(2*Math.PI*q/(NBUF-1)); re[q] = (bufU[(kA+q) % NBUF] - m)*w; }
  fft(re, im);
  // average the periodogram into log-spaced bins, so the shape (peaks, plateau, roll-off) reads clearly
  const NBL = 44, lo = Math.log10(1/16), hi = Math.log10(32), sum = new Float64Array(NBL), cnt = new Float64Array(NBL);
  for (let k=1;k<NBUF/2;k++){ const f = k/(NBUF/SPC), b = Math.floor((Math.log10(f)-lo)/(hi-lo)*NBL); if (b >= 0 && b < NBL) { sum[b] += re[k]*re[k] + im[k]*im[k]; cnt[b]++; } }
  const out = []; for (let b=0;b<NBL;b++) if (cnt[b]) out.push([Math.pow(10, lo + (b+.5)*(hi-lo)/NBL), sum[b]/cnt[b]]); return out; }
const sepIn = $('sep');
const sepText = () => { const v = +sepIn.value; sep = Math.pow(10, 1.6*v); $('sepv').textContent = sep < 10 ? sep.toFixed(1) : Math.round(sep);
  $('sepcap').textContent = sep > 6 ? `Spectral gap: turbulence is ~${Math.round(sep)}× faster than the shedding. The phase average is clean and ν_t can stand in for u′: URANS territory.` :
    sep > 2.5 ? 'The gap is closing: turbulence time scales approach the shedding period. URANS still runs, but its closure is on thin ice.' : 'No spectral gap: turbulence is as slow as the shedding. "Instant" eddy viscosity is the wrong model; this needs scale-resolving methods (DES, LES).'; };
sepIn.addEventListener('pointerdown', () => { if (spec) ghostsA = [{ s: spec, f: sep }, ...ghostsA].slice(0, 2); });
sepIn.oninput = () => { sepText(); sigReset(); if (reduce) { for (let q=0;q<NBUF;q++) sigSample(); spec = spectrum(); drawSig(); } };
sepText();
function drawSig(){
  if (!reduce) for (let q=0;q<6;q++) sigSample();
  if (!spec || ++fA % 8 === 0) spec = spectrum();
  const c = CA, W = c.W, p = P(); c.clearRect(0,0,W,c.H);
  // 1. the signal over the last 4 cycles
  { const n = 4*SPC, x0 = 30, x1 = W-12, X = q => x0 + (x1-x0)*q/n, Y = v => 112 - (v-UBAR)*120, k0 = kA - n;
    label(c, 'velocity at a wake point, last 4 shedding cycles', x0, 16, p.ink, SANS);
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, 28); c.lineTo(x0, 196); c.stroke();
    if (isAct('upr','nut')) { c.fillStyle = p.w; c.globalAlpha = .18; c.beginPath(); for (let q=0;q<n;q++){ const th = bufP[(k0+q) % NBUF]; c.lineTo(X(q), Y(bufU[(k0+q) % NBUF])); } for (let q=n-1;q>=0;q--){ const th = bufP[(k0+q) % NBUF]; c.lineTo(X(q), Y(UBAR + coh(th))); } c.fill(); c.globalAlpha = 1; }
    c.strokeStyle = p.w; c.lineWidth = isAct('upr') ? 1.8 : 1.1; c.beginPath(); for (let q=0;q<n;q++){ const v = bufU[(k0+q) % NBUF]; q ? c.lineTo(X(q), Y(v)) : c.moveTo(X(q), Y(v)); } c.stroke();
    c.strokeStyle = p.c; c.lineWidth = isAct('util','u','fs','theta') ? 3.4 : 2; c.beginPath(); for (let q=0;q<n;q++){ const v = UBAR + coh(bufP[(k0+q) % NBUF]); q ? c.lineTo(X(q), Y(v)) : c.moveTo(X(q), Y(v)); } c.stroke();
    c.setLineDash([6,4]); c.strokeStyle = p.f; c.lineWidth = isAct('ubar') ? 3 : 1.6; c.beginPath(); c.moveTo(x0, Y(UBAR)); c.lineTo(x1, Y(UBAR)); c.stroke(); c.setLineDash([]);
    label(c, 'ū', x0-8, Y(UBAR)+4, p.f, MATH, 'right');
    label(c, isAct('t') ? 't →' : 'time →', x1, 206, isAct('t') ? p.cs : p.mut, SMF, 'right');
    if (isAct('nut')) label(c, 'grey band = u′: replaced by ν_t', x0+8, 40, p.nu, BF);
    if (isAct('B')) label(c, 'green wiggle = what ∂ₜ⟨u⟩ follows', x0+8, 40, p.cs, BF); }
  // 2. phase average, binned live
  const top = 236, bot = 412;
  { const x0 = 30, x1 = 218, X = th => x0 + (x1-x0)*th/(2*Math.PI), Y = v => (top+bot)/2 - (v-UBAR)*110, cyc = Math.floor(binN.reduce((a,b) => a+b, 0)/SPC);
    label(c, `phase average, ${cyc} cycles`, x0, top-12, isAct('A','r') ? p.ink : p.ink, SANS);
    c.fillStyle = p.w; c.globalAlpha = .35; for (let q=0;q<320;q++){ const k = (kA-1-q+NBUF) % NBUF; c.fillRect(X(bufP[k])-1, Y(bufU[k])-1, 2, 2); } c.globalAlpha = 1;
    c.setLineDash([4,4]); c.strokeStyle = p.c; c.lineWidth = 1.6; c.beginPath(); for (let q=0;q<=60;q++){ const th = 2*Math.PI*q/60; q ? c.lineTo(X(th), Y(UBAR+coh(th))) : c.moveTo(X(th), Y(UBAR+coh(th))); } c.stroke(); c.setLineDash([]);
    let err = 0, ne = 0; c.strokeStyle = p.u; c.lineWidth = isAct('u','A') ? 3.6 : 2.4; c.beginPath();
    for (let b=0;b<NBIN;b++){ if (!binN[b]) continue; const th = 2*Math.PI*(b+.5)/NBIN, v = binS[b]/binN[b]; err += (v - UBAR - coh(th))**2; ne++; b ? c.lineTo(X(th), Y(v)) : c.moveTo(X(th), Y(v)); } c.stroke();
    if (isAct('A','r')) for (let b=0;b<NBIN;b+=2){ const th = 2*Math.PI*(b+.5)/NBIN; c.fillStyle = p.u; c.beginPath(); c.arc(X(th), Y(binS[b]/(binN[b]||1)), 3, 0, 7); c.fill(); }
    label(c, isAct('theta') ? 'θ: 0 → 2π' : 'phase θ', x1, bot+14, isAct('theta') ? p.c : p.mut, SMF, 'right');
    label(c, `rms error vs ū+ũ: ${ne ? Math.sqrt(err/ne).toFixed(3) : '—'}`, x0, bot+14, p.u, SMF); }
  // 3. spectrum (log–log), with the gap between shedding harmonics and turbulence
  { const x0 = 262, x1 = W-12, fl = Math.log10(1/16), fh = Math.log10(32), X = f => x0 + (x1-x0)*(Math.log10(f)-fl)/(fh-fl), Y = e => bot - (Math.log10(e)+2)/8*(bot-top);
    label(c, 'spectrum', x0, top-12, p.ink, SANS);
    if (sep > 4) { c.fillStyle = p.c; c.globalAlpha = .08; c.fillRect(X(2.5), top, X(sep/1.6)-X(2.5), bot-top); c.globalAlpha = 1; label(c, 'gap', (X(2.5)+X(sep/1.6))/2, top+14, p.c, SMF, 'center'); }
    const line = (sp, col, lw, a) => { c.globalAlpha = a; c.strokeStyle = col; c.lineWidth = lw; c.beginPath(); sp.forEach(([f,e],k) => { const y = Math.min(bot, Y(Math.max(e, 1e-3))); k ? c.lineTo(X(f), y) : c.moveTo(X(f), y); }); c.stroke(); c.globalAlpha = 1; };
    ghostsA.forEach((g,j) => line(g.s, p.w, 1, .35 - .12*j));
    line(spec, isAct('upr') ? p.ink : p.u, 1.4, 1);
    c.setLineDash([3,3]); c.strokeStyle = isAct('fs','St') ? p.c : p.rule; c.lineWidth = 1.2; c.beginPath(); c.moveTo(X(1), top); c.lineTo(X(1), bot); c.stroke();
    c.strokeStyle = p.w; c.beginPath(); c.moveTo(X(sep), top); c.lineTo(X(sep), bot); c.stroke(); c.setLineDash([]);
    label(c, 'f_s', X(1), bot+14, isAct('fs') ? p.c : p.mut, SMF, 'center'); label(c, 'f_t', X(Math.min(sep, 24)), bot+14, p.w, SMF, 'center');
    label(c, 'f / f_s, log', x0, bot+28, p.mut, SMF); }
}

// ===== B: BDF2 + dual time stepping on du/dt = iωu (period 1), complex arithmetic, live =====
const CB = hidpi($('bdfviz')), OM = 2*Math.PI;
const cm = (a,b) => [a[0]*b[0]-a[1]*b[1], a[0]*b[1]+a[1]*b[0]], cabs = a => Math.hypot(a[0], a[1]);
// BDF2 growth factor per step for z = iωΔt: the larger root of (3 − 2z)G² − 4G + 1 = 0
function bdfG(th){ const A = [3, -2*th], disc = [16 - 4*A[0], -4*A[1]], r = Math.hypot(...disc), an = Math.atan2(disc[1], disc[0])/2, sq = [Math.sqrt(r)*Math.cos(an), Math.sqrt(r)*Math.sin(an)];
  const dv = (x, y) => { const d = y[0]*y[0]+y[1]*y[1]; return [(x[0]*y[0]+x[1]*y[1])/d, (x[1]*y[0]-x[0]*y[1])/d]; };
  const g1 = dv([4+sq[0], sq[1]], [2*A[0], 2*A[1]]), g2 = dv([4-sq[0], -sq[1]], [2*A[0], 2*A[1]]); return cabs(g1) > cabs(g2) ? g1 : g2; }
let NB = 12, MB = 6, bd, ghostsB = [], bLast = null, bClock = 0;
function bdfReset(){ const dt = 1/NB; bd = { dt, lv: [[-dt, [Math.cos(-OM*dt), Math.sin(-OM*dt)]], [0, [1, 0]]], it: [], res: [], ee: [[0, [1,0]]], k: 0, amp: [] }; bClock = 0; bdfStep(); }
function bdfStep(){ // one physical step: guess, then M pseudo-time iterations with the point-implicit local Δτ
  const dt = bd.dt, n = bd.lv.length, yn = bd.lv[n-1][1], ym = bd.lv[n-2][1], dtau = 1/(1.5/dt + OM);
  let y = [2*yn[0]-ym[0], 2*yn[1]-ym[1]]; const it = [y], res = [];
  const Rs = y => { const iw = cm([0, OM], y); return [(3*y[0]-4*yn[0]+ym[0])/(2*dt) - iw[0], (3*y[1]-4*yn[1]+ym[1])/(2*dt) - iw[1]]; };
  for (let m=0;m<MB;m++){ const r = Rs(y); res.push(cabs(r)); y = [y[0]-dtau*r[0], y[1]-dtau*r[1]]; it.push(y); }
  res.push(cabs(Rs(y)));
  bd.it = it; bd.res = res; bd.next = [bd.lv[n-1][0] + dt, y];
  const e = bd.ee[bd.ee.length-1]; bd.ee.push([e[0]+dt, cm(e[1], [1, OM*dt])]); }
const nppIn = $('npp'), miIn = $('mi');
const bdfInput = () => { const g = bd && bd.lv.length > NB+1 ? { N: NB, M: MB, a: cabs(bd.lv[NB+1][1]) } : null; if (g) ghostsB = [g, ...ghostsB].slice(0, 3);
  NB = +nppIn.value; MB = +miIn.value; $('nppv').textContent = NB; $('miv').textContent = MB; bdfReset(); if (reduce) { while (bd.lv.length < 3*NB+2) { bd.lv.push(bd.next); bdfStep(); } drawBdf(0); } };
nppIn.oninput = bdfInput; miIn.oninput = bdfInput; bdfReset();
function drawBdf(now){
  const dtm = bLast === null ? 0 : Math.min(100, now - bLast); bLast = now;
  const per = 0.12 + 0.07*MB; if (!reduce) { bClock += dtm/1000; if (bClock > per) { bClock = 0; bd.lv.push(bd.next); if (bd.lv.length > 3*NB+2) bdfReset(); else bdfStep(); } }
  const c = CB, W = c.W, p = P(), x0 = 34, x1 = W-12, X = t => x0 + (x1-x0)*t/3, Y = v => 112 - v*72, prog = reduce ? 1 : clamp(bClock/per, 0, 1);
  c.clearRect(0,0,W,c.H);
  label(c, 'Re u(t): exact vs BDF2, 3 periods', x0, 16, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, 112); c.lineTo(x1, 112); c.stroke();
  for (let k=1;k<3;k++){ c.beginPath(); c.moveTo(X(k), 36); c.lineTo(X(k), 190); c.stroke(); }
  c.setLineDash([5,4]); c.strokeStyle = p.w; c.lineWidth = 1.6; c.beginPath(); for (let q=0;q<=180;q++){ const t = 3*q/180; q ? c.lineTo(X(t), Y(Math.cos(OM*t))) : c.moveTo(X(t), Y(Math.cos(OM*t))); } c.stroke();
  // explicit Euler: grows every step
  c.strokeStyle = p.nu; c.lineWidth = 1.2; c.beginPath(); bd.ee.forEach(([t,y],k) => { const yy = Math.max(-1.25, Math.min(1.25, y[0])); k ? c.lineTo(X(t), Y(yy)) : c.moveTo(X(t), Y(yy)); }); c.stroke(); c.setLineDash([]);
  // BDF2 levels
  c.strokeStyle = p.cs; c.lineWidth = isAct('B','u') ? 2.6 : 1.6; c.beginPath(); bd.lv.forEach(([t,y],k) => k ? c.lineTo(X(t), Y(y[0])) : c.moveTo(X(t), Y(y[0]))); c.stroke();
  bd.lv.forEach(([t,y],k) => { if (t < 0) return; c.fillStyle = p.cs; c.beginPath(); c.arc(X(t), Y(y[0]), isAct('n','dt') ? 4.5 : 3.2, 0, 7); c.fill(); });
  if (isAct('dt')) { const n = bd.lv.length, t0 = bd.lv[n-1][0]; arrow(c, X(t0), 200, X(t0+bd.dt), 200, p.cs, 1.6); label(c, 'Δt', X(t0+bd.dt/2), 214, p.cs, SMF, 'center'); }
  // inner iterates at t_{n+1}: the pseudo-time path, revealed one by one
  { const shown = Math.floor(prog*(bd.it.length)), tN = bd.next[0];
    for (let m=0;m<Math.max(1,shown);m++){ const y = bd.it[m]; c.fillStyle = p.tau; c.globalAlpha = .35 + .65*(m+1)/bd.it.length; c.beginPath(); c.arc(X(tN), Y(y[0]), isAct('T','m','tau','dtau') ? 4.5 : 3, 0, 7); c.fill(); }
    c.globalAlpha = 1; if (isAct('T','m','tau')) label(c, 'u⁽ᵐ⁾', X(tN)+8, Y(bd.it[0][0])-6, p.tau, BF); }
  label(c, 'period 1', X(.5), 202, p.mut, SMF, 'center'); label(c, 'explicit Euler', x1, 30, p.nu, SMF, 'right');
  // residual of the inner loop, this step
  const top = 250, bot = 400;
  { const bx = 34, n = bd.res.length, bw = Math.min(22, 170/n - 4), Yr = r => top + 10 + Math.min(1, (-Math.log10(Math.max(r/bd.res[0], 1e-8)))/8)*(bot-top-20);
    label(c, 'inner loop: |R*| per sweep m (log)', bx, top-10, isAct('Rs','T','m') ? p.tau : p.ink, SANS);
    for (let m=0;m<n;m++){ const y = Yr(bd.res[m]), x = bx + m*(bw+4); c.fillStyle = m === n-1 ? p.cs : p.tau; rr(c, x, top+10, bw, Math.max(2, y-top-10), 3); c.fill(); }
    const drop = bd.res[n-1]/bd.res[0]; label(c, 'bars grow down as R* falls', bx, bot-4, p.mut, SMF); label(c, `drop ${drop < 1e-3 ? drop.toExponential(0) : drop.toFixed(3)} after M = ${MB}`, bx, bot+16, drop < 1e-3 ? p.ok : p.warm, SMF); }
  // damping per period: exact BDF2 (converged) curve vs what this run measured
  { const bx0 = 250, bx1 = W-12, Xn = N => bx0 + (bx1-bx0)*(N-4)/44, Ya = a => bot - a*(bot-top-10);
    label(c, 'amplitude after 1 period', bx0, top-10, p.ink, SANS);
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(bx0, top); c.lineTo(bx0, bot); c.lineTo(bx1, bot); c.stroke(); label(c, '1', bx0-4, Ya(1)+4, p.mut, SMF, 'right');
    c.strokeStyle = p.cs; c.lineWidth = 2; c.beginPath(); for (let N=4;N<=48;N++){ const a = Math.pow(cabs(bdfG(OM/N)), N); N > 4 ? c.lineTo(Xn(N), Ya(a)) : c.moveTo(Xn(N), Ya(a)); } c.stroke();
    ghostsB.forEach((g,j) => { c.globalAlpha = .5 - .13*j; c.fillStyle = p.tau; c.beginPath(); c.arc(Xn(g.N), Ya(Math.min(1.2, g.a)), 4, 0, 7); c.fill(); label(c, `M ${g.M}`, Xn(g.N), Ya(Math.min(1.2, g.a))-8, p.tau, SMF, 'center'); c.globalAlpha = 1; });
    const exa = Math.pow(cabs(bdfG(OM/NB)), NB); c.fillStyle = p.cs; c.beginPath(); c.arc(Xn(NB), Ya(exa), 5, 0, 7); c.fill();
    if (bd.lv.length > NB+1) { const a = cabs(bd.lv[NB+1][1]); c.strokeStyle = p.tau; c.lineWidth = 2; c.beginPath(); c.arc(Xn(NB), Ya(Math.min(1.2, a)), 7, 0, 7); c.stroke(); }
    [4, 16, 32, 48].forEach(N => label(c, String(N), Xn(N), bot+14, p.mut, SMF, 'center')); label(c, 'steps per period', bx1, bot+28, p.mut, SMF, 'right'); label(c, '● converged BDF2  ○ this run', bx0+8, top+8, p.mut, SMF); }
  const exa = Math.pow(cabs(bdfG(OM/NB)), NB), wdt = OM/NB, lastA = bd.lv.length > NB+1 ? cabs(bd.lv[NB+1][1]) : null;
  $('bdfcap').textContent = `ωΔt = ${wdt.toFixed(2)} rad per step (the CFL-like number here). Converged BDF2 keeps ${(exa*100).toFixed(1)}% per period` + (lastA != null ? `; this run with M = ${MB}: ${(lastA*100).toFixed(1)}%` : '') + (lastA != null && Math.abs(lastA-exa) > .01 ? ' → inner loop not converged: raise M.' : '.');
}

// ===== C: closure E, and over-damping through the effective Reynolds number =====
const CC = hidpi($('ntviz')), RE = 22000, REC = 50, cv13 = 7.1**3, fv1 = x => x*x*x/(x*x*x + cv13);
let ntr = 158, Aamp = 0.5, ghostsC = [], cLast = null, cHist = [];
const chiOf = r => { let lo = 0, hi = r + 20; for (let k=0;k<60;k++){ const m = (lo+hi)/2; if (m*fv1(m) < r) lo = m; else hi = m; } return (lo+hi)/2; };
const ntrIn = $('ntr');
ntrIn.addEventListener('pointerdown', () => { if (cHist.length > 20) ghostsC = [{ h: cHist, r: ntr }, ...ghostsC].slice(0, 2); });
ntrIn.oninput = () => { ntr = Math.pow(10, +ntrIn.value); $('ntrv').textContent = ntr < 10 ? ntr.toFixed(1) : Math.round(ntr); Aamp = 0.5; cHist = []; if (reduce) drawNt(0); };
function drawNt(now){
  const dtm = cLast === null ? 0 : Math.min(100, now - cLast); cLast = now;
  const reff = RE/(1 + ntr), sig = Math.max(-2, 1 - REC/reff), steps = reduce ? 400 : 2;
  for (let s=0;s<steps;s++){ if (cHist.length >= 400) break; Aamp += 0.03*(sig*Aamp - Aamp**3); cHist.push(Aamp); }
  const c = CC, W = c.W, p = P(); c.clearRect(0,0,W,c.H);
  // left: f_v1(χ) on a log axis and the marker for this ν_t/ν
  const chi = chiOf(ntr), f = fv1(chi);
  { const x0 = 34, x1 = 214, top = 40, bot = 200, X = x => x0 + (x1-x0)*(Math.log10(x)+1)/5, Y = v => bot - v*(bot-top);
    label(c, 'E: f_v1(χ)', x0, 18, isAct('E','fv1') ? p.eq : p.ink, SANS);
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, top-6); c.lineTo(x0, bot); c.lineTo(x1, bot); c.stroke();
    c.setLineDash([3,3]); c.strokeStyle = isAct('cv1') ? p.w : p.rule; c.beginPath(); c.moveTo(X(7.1), bot); c.lineTo(X(7.1), Y(.5)); c.lineTo(x0, Y(.5)); c.stroke(); c.setLineDash([]);
    label(c, 'c_v1', X(7.1), bot+26, isAct('cv1') ? p.ink : p.mut, SMF, 'center');
    c.strokeStyle = p.eq; c.lineWidth = isAct('fv1','E') ? 3.4 : 2.2; c.beginPath(); for (let q=0;q<=100;q++){ const x = Math.pow(10, -1 + 5*q/100); q ? c.lineTo(X(x), Y(fv1(x))) : c.moveTo(X(x), Y(fv1(x))); } c.stroke();
    c.fillStyle = p.nu; c.beginPath(); c.arc(X(Math.max(.1, chi)), Y(f), isAct('chi','nt','nut') ? 7 : 5.5, 0, 7); c.fill();
    ['0.1','1','10','100','10³','10⁴'].forEach((s,k) => label(c, s, X(Math.pow(10, k-1)), bot+14, p.mut, SMF, 'center'));
    label(c, 'χ = ν̃/ν', x1, top-10, isAct('chi') ? p.eq : p.mut, SMF, 'right'); label(c, '1', x0-5, Y(1)+4, p.mut, SMF, 'right');
    const by = 252; label(c, `χ = ${chi.toFixed(1)}, f_v1 = ${f.toFixed(3)}`, x0, by, p.eq, BF);
    label(c, `ν_t = ν̃·f_v1 = ${ntr < 10 ? ntr.toFixed(1) : Math.round(ntr)} ν`, x0, by+18, p.nu, BF);
    label(c, `= ${(ntr/RE).toExponential(1)} UD`, x0, by+36, p.mut, SMF);
    if (isAct('prod','dest','diff','d')) label(c, 'ν̃ itself comes from the SA equation:', x0, by+62, p.ink, SMF), label(c, 'made in shear layers, destroyed near walls', x0, by+78, p.ink, SMF); }
  // right: effective Reynolds number and the shedding amplitude it allows
  { const x0 = 250, x1 = W-14, X = r => x0 + (x1-x0)*(Math.log10(r))/Math.log10(RE), y = 60;
    label(c, 'Re_eff = UD / (ν + ν_t)', x0, 18, isAct('Reff') ? p.nu : p.ink, SANS);
    c.lineCap = 'round'; c.lineWidth = 6; c.strokeStyle = p.rule; c.beginPath(); c.moveTo(X(1), y); c.lineTo(X(RE), y); c.stroke();
    c.strokeStyle = p.ok; c.globalAlpha = .4; c.beginPath(); c.moveTo(X(REC), y); c.lineTo(X(RE), y); c.stroke(); c.globalAlpha = 1;
    c.fillStyle = p.ink; c.fillRect(X(REC)-1, y-12, 2, 24); label(c, 'onset ≈ 50', X(REC), y+26, p.ink, SMF, 'center');
    c.fillStyle = p.nu; c.beginPath(); c.arc(X(reff), y, 7, 0, 7); c.fill(); label(c, Math.round(reff).toString(), X(reff), y-14, p.nu, BF, 'center');
    label(c, '1', X(1), y+26, p.mut, SMF, 'center'); label(c, '22 000', X(RE), y+26, p.mut, SMF, 'right');
    // the band of ν_t/ν the Build solver's SA model actually produces in the wake
    const bA = X(RE/(1+220)), bB = X(RE/(1+130)); c.fillStyle = p.c; c.globalAlpha = .25; c.fillRect(bA, y+34, bB-bA, 6); c.globalAlpha = 1; label(c, 'Build solver (SA)', (bA+bB)/2, y+52, p.c, SMF, 'center');
    const top = 150, bot = 330, Xt = k => x0 + (x1-x0)*k/400, Ya = a => bot - a*(bot-top)/1.1;
    label(c, 'shedding amplitude (Landau model)', x0, top-14, p.ink, SANS);
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, top); c.lineTo(x0, bot); c.lineTo(x1, bot); c.stroke();
    ghostsC.forEach((g,j) => { c.globalAlpha = .4 - .12*j; c.strokeStyle = p.nu; c.lineWidth = 1.4; c.beginPath(); g.h.forEach((a,k) => k ? c.lineTo(Xt(k), Ya(a)) : c.moveTo(Xt(k), Ya(a))); c.stroke(); label(c, `ν_t/ν ${Math.round(g.r)}`, Xt(g.h.length-1), Ya(g.h[g.h.length-1])-6, p.nu, SMF, 'right'); c.globalAlpha = 1; });
    c.strokeStyle = p.c; c.lineWidth = 2.6; c.beginPath(); cHist.forEach((a,k) => k ? c.lineTo(Xt(k), Ya(a)) : c.moveTo(Xt(k), Ya(a))); c.stroke();
    label(c, 'time →', x1, bot+14, p.mut, SMF, 'right'); }
  $('ntcap').textContent = reff > REC ? `Re_eff ≈ ${Math.round(reff)} > 50: the wake keeps shedding (amplitude ∝ √(Re_eff − Re_c) near onset, Provansal et al. 1987). Time scale illustrative.` :
    `Re_eff ≈ ${Math.round(reff)} < 50: over-damped. The model's eddy viscosity has killed the shedding a real wake would show. In the Build solver, ν_t × 12 does this.`;
}

// ===== HOW IT WORKS: one panel per operator, each with a worked example on real numbers =====
const mt = s => `<div class="hm"><math display="block">${s}</math></div>`, tc = (col, x) => `<mrow style="color:var(${col})">${x}</mrow>`, sw = col => `<i class="tb" style="background:var(${col})"></i>`;
const exb = (key, list, cur, fmt) => `<div class="eex"><span>Example</span>${list.map(v => `<button class="b${v === cur ? ' pri' : ''}" data-${key}="${v}">${fmt(v)}</button>`).join('')}</div>`;
const bindEx = (key, set) => function(root){ root.querySelectorAll(`[data-${key}]`).forEach(b => b.onclick = () => { set(+b.dataset[key]); root.querySelectorAll(`[data-${key}]`).forEach(x => x.classList.toggle('pri', x === b)); this.draw(root); }); };
const HS = { A: 8, B: 8, T: 1, P: 0, E: 7.1 };
const HOW = {
 A: { html: () => `<span class="eyebrow">How ⟨·⟩ works</span>
   ${mt(`<mo>⟨</mo><mi>u</mi><mo>⟩</mo><mo>(</mo><mi>θ</mi><mo>)</mo><mo>=</mo>${tc('--c-w','<mfrac><mn>1</mn><msub><mi>N</mi><mi>r</mi></msub></mfrac><munder><mo>∑</mo><mi>r</mi></munder>')}<mi>u</mi><mo>(</mo>${tc('--c-c','<mi>θ</mi><mo>,</mo><mtext> cycle </mtext><mi>r</mi>')}<mo>)</mo>`)}
   <div class="eterms"><span>${sw('--c-c')}same θ</span><span>Take the value at the same point of the cycle, once per cycle r.</span>
    <span>${sw('--c-w')}1/N_r Σ</span><span>Average them: the random u′ cancels (its error shrinks like 1/√N_r), the coherent ũ stays.</span></div>
   ${exb('na', [2, 8, 32, 128], HS.A, v => `N_r = ${v}`)}<canvas class="hc" data-w="420" data-h="96"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), N = HS.A, th = Math.PI/2, tru = UBAR + coh(th); let s = 9; const r = () => (s = (s*16807) % 2147483647)/2147483647;
   const v = []; for (let k=0;k<N;k++) v.push(tru + SIG*Math.sqrt(-2*Math.log(r()+1e-12))*Math.cos(2*Math.PI*r()));
   const m = v.reduce((a,b) => a+b, 0)/N, X = u => 20 + (u - tru + .5)*380;
   c.clearRect(0,0,c.W,c.H); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(20, 50); c.lineTo(400, 50); c.stroke();
   c.fillStyle = p.w; v.forEach((u,k) => { c.globalAlpha = .6; c.beginPath(); c.arc(X(u), 50 - 14 + (k % 5)*7, 3, 0, 7); c.fill(); }); c.globalAlpha = 1;
   c.fillStyle = p.c; c.fillRect(X(tru)-1, 22, 2, 56); label(c, 'ū + ũ', X(tru), 92, p.c, SMF, 'center');
   c.fillStyle = p.u; c.beginPath(); c.arc(X(m), 50, 6, 0, 7); c.fill(); label(c, '⟨u⟩', X(m), 16, p.u, BF, 'center');
   root.querySelector('.ecalc').textContent = `θ = 90°, ${N} cycles: ⟨u⟩ = (${v.slice(0,3).map(x => x.toFixed(3)).join(' + ')}${N > 3 ? ' + …' : ''}) / ${N} = ${m.toFixed(3)}; true ū + ũ = ${tru.toFixed(3)}, error ${Math.abs(m-tru).toFixed(3)} (expected ≈ σ/√N = ${(SIG/Math.sqrt(N)).toFixed(3)})`; } },
 B: { html: () => `<span class="eyebrow">How B works</span>
   ${mt(`<msub><mo>∂</mo><mi>t</mi></msub><mi>u</mi><mo>≈</mo><mfrac><mrow>${tc('--c-cs','<mn>3</mn><msup><mi>u</mi><mrow><mi>n</mi><mo>+</mo><mn>1</mn></mrow></msup>')}<mo>−</mo>${tc('--c-u','<mn>4</mn><msup><mi>u</mi><mi>n</mi></msup>')}<mo>+</mo>${tc('--c-w','<msup><mi>u</mi><mrow><mi>n</mi><mo>−</mo><mn>1</mn></mrow></msup>')}</mrow><mrow><mn>2</mn><mi>Δ</mi><mi>t</mi></mrow></mfrac><mo>,</mo><mspace width="1em"/><msup><mi>R</mi><mo>*</mo></msup><mo>=</mo><msub><mo>∂</mo><mi>t</mi></msub><mi>u</mi><mo>+</mo><mi>R</mi><mo>(</mo><msup><mi>u</mi><mrow><mi>n</mi><mo>+</mo><mn>1</mn></mrow></msup><mo>)</mo>`)}
   <div class="eterms"><span>${sw('--c-cs')}3 uⁿ⁺¹</span><span>The unknown new frame, weighted most: the slope is taken there.</span>
    <span>${sw('--c-u')}−4 uⁿ</span><span>The current frame.</span><span>${sw('--c-w')}+ uⁿ⁻¹</span><span>The frame before: with it, a parabola instead of a straight line, so second order.</span></div>
   ${exb('nb', [4, 8, 16, 32], HS.B, v => `${v} steps/period`)}<canvas class="hc" data-w="420" data-h="110"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), N = HS.B, dt = 1/N, t1 = .3, f = t => Math.sin(OM*t), y = [f(t1-2*dt), f(t1-dt), f(t1)];
   const b2 = (3*y[2] - 4*y[1] + y[0])/(2*dt), b1 = (y[2]-y[1])/dt, ex_ = OM*Math.cos(OM*t1), X = t => 20 + (t - (t1-.55))*380/.7, Y = v => 55 - v*40;
   c.clearRect(0,0,c.W,c.H); c.strokeStyle = p.w; c.setLineDash([4,4]); c.lineWidth = 1.4; c.beginPath(); for (let q=0;q<=80;q++){ const t = t1-.55+.7*q/80; q ? c.lineTo(X(t), Y(f(t))) : c.moveTo(X(t), Y(f(t))); } c.stroke(); c.setLineDash([]);
   const tan = (s, col) => { c.strokeStyle = col; c.lineWidth = 2; c.beginPath(); c.moveTo(X(t1-.12), Y(y[2]-.12*s)); c.lineTo(X(t1+.12), Y(y[2]+.12*s)); c.stroke(); };
   tan(ex_, p.ink); tan(b2, p.cs); tan(b1, p.nu);
   y.forEach((v,k) => { c.fillStyle = [p.w, p.u, p.cs][k]; c.beginPath(); c.arc(X(t1-(2-k)*dt), Y(v), 5, 0, 7); c.fill(); });
   label(c, '— exact slope', 20, 104, p.ink, SMF); label(c, '— BDF2', 150, 104, p.cs, SMF); label(c, '— BDF1 (Euler)', 240, 104, p.nu, SMF);
   root.querySelector('.ecalc').textContent = `u = sin 2πt at t = 0.3, Δt = 1/${N}: (3·${y[2].toFixed(3)} − 4·${y[1].toFixed(3)} + ${y[0].toFixed(3)}) / ${(2*dt).toFixed(3)} = ${b2.toFixed(3)}; exact ${ex_.toFixed(3)} (error ${Math.abs(b2-ex_).toFixed(3)}); first-order BDF1 gives ${b1.toFixed(3)} (error ${Math.abs(b1-ex_).toFixed(3)}).`; } },
 T: { html: () => `<span class="eyebrow">How T works</span>
   ${mt(`<msup><mi>u</mi><mrow><mo>(</mo><mi>m</mi><mo>+</mo><mn>1</mn><mo>)</mo></mrow></msup><mo>=</mo>${tc('--c-u','<msup><mi>u</mi><mrow><mo>(</mo><mi>m</mi><mo>)</mo></mrow></msup>')}<mo>−</mo>${tc('--c-tau','<mi>Δ</mi><mi>τ</mi>')}${tc('--c-cs','<msup><mi>R</mi><mo>*</mo></msup><mo>(</mo><msup><mi>u</mi><mrow><mo>(</mo><mi>m</mi><mo>)</mo></mrow></msup><mo>)</mo>')}<mo>,</mo><mspace width="1em"/>${tc('--c-tau','<mi>Δ</mi><mi>τ</mi>')}<mo>=</mo><mfrac><mi>c</mi><mrow><mfrac><mn>3</mn><mrow><mn>2</mn><mi>Δ</mi><mi>t</mi></mrow></mfrac><mo>+</mo><mo>|</mo><mi>a</mi><mo>|</mo></mrow></mfrac>`)}
   <div class="eterms"><span>${sw('--c-u')}u⁽ᵐ⁾</span><span>The current guess for the new frame.</span>
    <span>${sw('--c-cs')}R*</span><span>How wrong it is (block B's residual).</span>
    <span>${sw('--c-tau')}Δτ</span><span>How far to step against it. c = 1 is the point-implicit choice the solver uses; too large and the loop diverges.</span></div>
   ${exb('ct', [0.5, 1, 1.6, 2.2], HS.T, v => `c = ${v}`)}<canvas class="hc" data-w="420" data-h="96"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), N = 8, dt = 1/N, yn = [1,0], ym = [Math.cos(OM*dt), -Math.sin(OM*dt)], dtau = HS.T/(1.5/dt + OM);
   let y = [2*yn[0]-ym[0], 2*yn[1]-ym[1]]; const res = [];
   for (let m=0;m<8;m++){ const iw = cm([0,OM], y), r = [(3*y[0]-4*yn[0]+ym[0])/(2*dt) - iw[0], (3*y[1]-4*yn[1]+ym[1])/(2*dt) - iw[1]]; res.push(cabs(r)); y = [y[0]-dtau*r[0], y[1]-dtau*r[1]]; }
   c.clearRect(0,0,c.W,c.H); const Yr = r => 10 + Math.min(80, Math.max(0, (Math.log10(res[0]) - Math.log10(r) + 1.2)*14));
   res.forEach((r,m) => { const x = 20 + m*48, h = Yr(r); c.fillStyle = r > res[0] ? p.nu : p.tau; rr(c, x, 90-h, 34, h, 3); c.fill(); label(c, 'm=' + m, x+17, 90-h-4, p.mut, SMF, 'center'); });
   root.querySelector('.ecalc').textContent = `du/dt = iωu, 8 steps/period, Δτ = ${HS.T} / (3/(2Δt) + ω) = ${dtau.toFixed(4)}: |R*| = ${res.slice(0,5).map(r => r.toFixed(r < .01 ? 4 : 2)).join(' → ')} …  factor per sweep ${(res[4]/res[3]).toFixed(2)}${res[7] > res[0] ? ': diverges' : ''}.`; } },
 P: { html: () => `<span class="eyebrow">How P works</span>
   ${mt(`${tc('--c-rho','<msub><mo>∂</mo><mi>j</mi></msub><msub><mo>∂</mo><mi>j</mi></msub><mi>φ</mi>')}<mo>=</mo><mfrac><mn>3</mn><mrow><mn>2</mn><mi>Δ</mi><mi>t</mi></mrow></mfrac>${tc('--c-u','<msub><mo>∂</mo><mi>j</mi></msub><msubsup><mi>u</mi><mi>j</mi><mo>*</mo></msubsup>')}<mo>,</mo><mspace width="1em"/><msub><mi>u</mi><mi>i</mi></msub><mo>=</mo><msubsup><mi>u</mi><mi>i</mi><mo>*</mo></msubsup><mo>−</mo>${tc('--c-c','<mfrac><mrow><mn>2</mn><mi>Δ</mi><mi>t</mi></mrow><mn>3</mn></mfrac><msub><mo>∂</mo><mi>i</mi></msub><mi>φ</mi>')}`)}
   <div class="eterms"><span>${sw('--c-u')}∂ⱼu*ⱼ</span><span>Where u* creates or destroys fluid.</span>
    <span>${sw('--c-rho')}∇²φ</span><span>A Poisson equation: one global linear solve (CG, multigrid) for a "pressure" that would push the leak away.</span>
    <span>${sw('--c-c')}−∇φ</span><span>Subtract its gradient: what is left has zero divergence in every cell.</span></div>
   ${exb('pf', [0, 1, 2], HS.P, v => ['source', 'random', 'swirl + leak'][v])}<canvas class="hc" data-w="420" data-h="150"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), n = 5, kind = HS.P; let s = 5; const r = () => (s = (s*16807) % 2147483647)/2147483647 - .5;
   // a 5 × 5 periodic layer of cells (one z-layer of a 5 × 5 × 1 periodic box); u on x-faces, v on y-faces
   const u = new Float64Array(n*n), v = new Float64Array(n*n), id = (i,j) => ((j+n)%n)*n + (i+n)%n;
   for (let j=0;j<n;j++) for (let i=0;i<n;i++){ const q = id(i,j);
     if (kind === 0) { u[q] = i === 3 ? .6 : i === 2 ? -.6 : 0; v[q] = j === 3 ? .6 : j === 2 ? -.6 : 0; }
     else if (kind === 1) { u[q] = r(); v[q] = r(); }
     else { u[q] = .5*Math.sin(2*Math.PI*(j+.5)/n) + (i === 1 ? .4 : 0); v[q] = -.5*Math.sin(2*Math.PI*(i+.5)/n); } }
   const div = (U,V) => { const d = new Float64Array(n*n); for (let j=0;j<n;j++) for (let i=0;i<n;i++) d[id(i,j)] = U[id(i+1,j)] - U[id(i,j)] + V[id(i,j+1)] - V[id(i,j)]; return d; };
   const d0 = div(u, v), phi = new Float64Array(n*n);
   for (let it=0; it<400; it++) for (let j=0;j<n;j++) for (let i=0;i<n;i++) phi[id(i,j)] = (phi[id(i+1,j)] + phi[id(i-1,j)] + phi[id(i,j+1)] + phi[id(i,j-1)] - d0[id(i,j)])/4;
   const u1 = u.map((x,q) => x - (phi[q] - phi[id(q % n - 1, Math.floor(q/n))])), v1 = v.map((x,q) => x - (phi[q] - phi[id(q % n, Math.floor(q/n) - 1)])), d1 = div(u1, v1);
   c.clearRect(0,0,c.W,c.H); const cs = 26;
   [[u, v, d0, 14, 'u* (before)'], [u1, v1, d1, 230, 'u = P(u*) (after)']].forEach(([U,V,Dv,x0,nm]) => {
     label(c, nm, x0, 12, p.ink, SMF);
     for (let j=0;j<n;j++) for (let i=0;i<n;i++){ const x = x0 + i*cs, y = 18 + (n-1-j)*cs, dv = Dv[id(i,j)];
       c.fillStyle = p.panel; c.fillRect(x, y, cs, cs); c.globalAlpha = Math.min(1, Math.abs(dv)*1.2); c.fillStyle = p.rho; c.fillRect(x, y, cs, cs); c.globalAlpha = 1;
       c.strokeStyle = p.rule; c.lineWidth = .8; c.strokeRect(x, y, cs, cs);
       arrow(c, x, y+cs/2, x + U[id(i,j)]*cs*.8, y+cs/2, p.u, 1.4); arrow(c, x+cs/2, y+cs, x+cs/2, y+cs - V[id(i,j)]*cs*.8, p.u, 1.4); } });
   const mx = a => Math.max(...a.map(Math.abs));
   root.querySelector('.ecalc').textContent = `Shading = |∂ᵢuᵢ| per cell. Before: max ${mx(d0).toFixed(3)}, sum ${d0.reduce((a,b)=>a+b,0).toFixed(3)} (a periodic box must sum to 0). Poisson solved (400 Gauss–Seidel sweeps), gradient subtracted. After: max ${mx(d1).toExponential(1)}.`; } },
 E: { html: () => `<span class="eyebrow">How E works</span>
   ${mt(`<msub><mi>ν</mi><mi>t</mi></msub><mo>=</mo>${tc('--c-eq','<mover accent="true"><mi>ν</mi><mo>˜</mo></mover>')}<mo>·</mo>${tc('--c-nu','<mfrac><msup><mi>χ</mi><mn>3</mn></msup><mrow><msup><mi>χ</mi><mn>3</mn></msup><mo>+</mo><msup><mn>7.1</mn><mn>3</mn></msup></mrow></mfrac>')}<mo>,</mo><mspace width="1em"/><mi>χ</mi><mo>=</mo><mfrac><mover accent="true"><mi>ν</mi><mo>˜</mo></mover><mi>ν</mi></mfrac>`)}
   <div class="eterms"><span>${sw('--c-eq')}ν̃</span><span>The transported turbulence variable of this cell.</span>
    <span>${sw('--c-nu')}f_v1</span><span>Wall damping: switches ν_t off where turbulence is weak compared with molecular viscosity (the viscous sublayer), on (→ 1) elsewhere.</span></div>
   ${exb('ce', [1, 3, 7.1, 20, 100], HS.E, v => `χ = ${v}`)}<canvas class="hc" data-w="420" data-h="90"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), chi = HS.E, f = fv1(chi), nu_ = 1/22000, X = x => 20 + 380*Math.log10(x*10)/4, Y = v => 76 - v*62;
   c.clearRect(0,0,c.W,c.H); c.strokeStyle = p.eq; c.lineWidth = 2.2; c.beginPath(); for (let q=0;q<=80;q++){ const x = Math.pow(10, -1 + 4*q/80); q ? c.lineTo(X(x), Y(fv1(x))) : c.moveTo(X(x), Y(fv1(x))); } c.stroke();
   c.fillStyle = p.nu; c.beginPath(); c.arc(X(chi), Y(f), 6, 0, 7); c.fill(); label(c, 'χ (log)', 400, 88, p.mut, SMF, 'right'); label(c, 'f_v1', 20, 10, p.eq, SMF);
   root.querySelector('.ecalc').textContent = `Re = 22 000 → ν = ${nu_.toExponential(2)}. χ = ${chi}: ν̃ = ${(chi*nu_).toExponential(2)}, f_v1 = ${chi}³ / (${chi}³ + 357.9) = ${f.toFixed(4)} → ν_t = ${(chi*nu_*f).toExponential(2)} (${(chi*f).toFixed(2)} ν).`; } },
};
HOW.A.bind = bindEx('na', v => HS.A = v); HOW.B.bind = bindEx('nb', v => HS.B = v); HOW.T.bind = bindEx('ct', v => HS.T = v); HOW.P.bind = bindEx('pf', v => HS.P = v); HOW.E.bind = bindEx('ce', v => HS.E = v);

// ===== BUILD: the real 3D URANS solver, its work spread over frames =====
let SIM = null, gen = null, running = false, mode = 'w', segT = 0, ghostsS = [], pend = null, msStep = 0, stepT0 = 0, workMs = 0;
const SC = hidpi($("sim")), VS = { th: -0.3, ph: 0.3, s: 31, ox: 228, oy: 182 };
orbit($('sim'), VS, () => { if (reduce) drawSim(); });
const offS = document.createElement('canvas');
function simReset(){ SIM = makeURANS({ dt: +$('dt').value, kt: Math.pow(2, +$('kt').value), M: +$('M').value }); gen = null; segT = 0; ghostsS = []; offS.width = SIM.NX; offS.height = SIM.NY; }
function newSeg(){ if (!SIM) return; const H = SIM.hist.filter(h => h[0] >= segT); if (H.length > 20) ghostsS = [{ H, lab: segLabel() }, ...ghostsS].slice(0, 2); segT = SIM.t; }
const segLabel = () => `Δt ${SIM.dt}, ν_t ×${+SIM.kt.toFixed(2)}, M ${SIM.M}`;
$('dt').oninput = () => { const v = +$('dt').value; $('dtv').textContent = v.toFixed(3); newSeg(); pend = Object.assign(pend || {}, { dt: v }); };
$('kt').oninput = () => { const v = Math.pow(2, +$('kt').value); $('ktv').textContent = v < 1 ? v.toFixed(2) : +v.toFixed(2); newSeg(); SIM.kt = v; };
$('M').oninput = () => { const v = +$('M').value; $('Mv').textContent = v; newSeg(); pend = Object.assign(pend || {}, { M: v }); };
$('modes').onclick = e => { const b = e.target.closest('[data-mode]'); if (!b) return; mode = b.dataset.mode; $('modes').querySelectorAll('[data-mode]').forEach(x => x.classList.toggle('pri', x === b)); drawSim(); };
$('restart').onclick = () => { simReset(); drawSim(); };
function measure(){ const H = SIM.hist, t0 = segT + (segT === 0 ? 15 : 8), z = [], Hs = H.filter(h => h[0] > t0);
  for (let q=1;q<Hs.length;q++){ const a = Hs[q-1], b = Hs[q]; if (a[2] < 0 && b[2] >= 0) z.push(a[0] + (b[0]-a[0])*(-a[2])/(b[2]-a[2])); }
  const cd = Hs.length ? Hs.reduce((s,h) => s + h[1], 0)/Hs.length : null, cl = Hs.length ? Math.sqrt(Hs.reduce((s,h) => s + h[2]*h[2], 0)/Hs.length) : null;
  return { St: z.length >= 3 ? (z.length-1)/(z[z.length-1]-z[0]) : null, cyc: Math.max(0, z.length-1), cd, cl }; }
function runSim(budget){ const t0 = performance.now();
  do { if (!gen) { if (pend) { if (pend.dt) { SIM.dt = pend.dt; SIM.first = true; } if (pend.M) SIM.M = pend.M; pend = null; } gen = SIM.step(); stepT0 = 0; }
    const c0 = performance.now(), r = gen.next(); stepT0 += performance.now() - c0;
    if (r.done) { gen = null; msStep = msStep ? .9*msStep + .1*stepT0 : stepT0; if (SIM.blown) { $('read').textContent = 'The run blew up (the inner loop did not converge at this Δt): restarting. Raise M or lower Δt.'; simReset(); return; } }
  } while (performance.now() - t0 < budget); workMs = performance.now() - t0; }
function drawSim(){
  if (!SIM) return;
  const c = SC, W = c.W, H = c.H, p = P(), S = SIM, NX = S.NX, NY = S.NY, NZ = S.NZ, h = S.h, I = S.I, SX = S.SX, k0 = NZ >> 1;
  c.clearRect(0,0,W,H);
  // slice image at mid-span
  const img = new ImageData(NX, NY), a = K.hex(p.acc), b = K.hex(p.warm), bg = K.hex(p.bg), nr = K.hex(p.nu), u = S.u, v = S.v;
  const uc = q => .5*(u[q]+u[q+1]), vc = q => .5*(v[q]+v[q+SX]);
  for (let j=0;j<NY;j++) for (let i=0;i<NX;i++){ const q = I(i,j,k0), o = ((NY-1-j)*NX+i)*4; let col = bg, t = 0;
    if (S.solid[q]) { const k_ = K.hex(p.ink); col = k_; t = 1; }
    else if (mode === 'w') { const wz = (vc(q+1)-vc(q-1) - uc(q+SX) + uc(q-SX))/(2*h), s = Math.tanh(wz/3); col = s > 0 ? a : b; t = Math.abs(s)**.8; }
    else if (mode === 'nut') { t = Math.min(1, Math.log10(1 + S.nut[q]/S.nu)/2.6); col = nr; }
    else { let m = 0; for (let k=0;k<NZ;k++) m += uc(I(i,j,k)); m /= NZ; const s = Math.tanh((uc(q)-m)/0.02); col = s > 0 ? a : b; t = Math.abs(s); }
    for (let z=0;z<3;z++) img.data[o+z] = bg[z] + (col[z]-bg[z])*t; img.data[o+3] = 255; }
  offS.getContext('2d').putImageData(img, 0, 0);
  const Lx = NX*h, Ly = NY*h, Lz = NZ*h, Pp = (x, y, z) => proj(VS, x - Lx/2, y - Ly/2, z - Lz/2);
  const O = Pp(0, 0, Lz/2), ex_ = Pp(1, 0, Lz/2), ey = Pp(0, 1, Lz/2);
  c.save(); c.transform((ex_[0]-O[0])*h, (ex_[1]-O[1])*h, -(ey[0]-O[0])*h, -(ey[1]-O[1])*h, O[0] + (ey[0]-O[0])*Ly, O[1] + (ey[1]-O[1])*Ly);
  c.imageSmoothingEnabled = true; c.drawImage(offS, 0, 0); c.restore();
  box(c, VS, Lx/2, Ly/2, Lz/2, p.mut, 1);
  // the square cylinder, extruded through the span
  const x0 = S.i0*h, x1 = S.i1*h, y0 = S.j0*h, y1 = S.j1*h;
  c.strokeStyle = p.ink; c.lineWidth = 1.2; c.beginPath();
  [[x0,y0],[x1,y0],[x1,y1],[x0,y1]].forEach(([x,y]) => { const A1 = Pp(x,y,0), A2 = Pp(x,y,Lz); c.moveTo(A1[0],A1[1]); c.lineTo(A2[0],A2[1]); });
  [0, Lz].forEach(z => { const q = [[x0,y0],[x1,y0],[x1,y1],[x0,y1]].map(([x,y]) => Pp(x,y,z)); c.moveTo(q[0][0],q[0][1]); q.forEach(r => c.lineTo(r[0], r[1])); c.lineTo(q[0][0],q[0][1]); }); c.stroke();
  const f0 = Pp(-1.4, Ly/2, Lz/2), f1 = Pp(-0.3, Ly/2, Lz/2); arrow(c, f0[0], f0[1], f1[0], f1[1], p.ink, 2); label(c, 'U', f0[0]-6, f0[1]-6, p.ink, MATH, 'right');
  K.triad(c, VS, 26, 318, p);
  label(c, `${NX}×${NY}×${NZ} cells · slice z = mid-span · drag to rotate`, 14, 18, p.mut, SMF);
  label(c, mode === 'w' ? 'colour: spanwise vorticity ω_z' : mode === 'nut' ? 'colour: ν_t/ν (log, 1 … 400)' : 'colour: u − its spanwise mean (±0.02)', 14, 34, p.mut, SMF);
  // right: lift and drag histories with ghosts of earlier settings
  const rx0 = 470, rx1 = W-12, Hh = S.hist, tEnd = Math.max(40, S.t), tBeg = tEnd - 40, X = t => rx0 + (rx1-rx0)*(t-tBeg)/40;
  const lift = (yc, sc, idx, col, Hd, lw, al) => { c.globalAlpha = al; c.strokeStyle = col; c.lineWidth = lw; c.beginPath(); let st = false;
    for (const hh of Hd){ const tt = Hd === Hh ? hh[0] : tEnd - (Hd[Hd.length-1][0] - hh[0]); if (tt < tBeg) continue; const y = yc - Math.max(-1.6, Math.min(1.6, hh[idx]))*sc; st ? c.lineTo(X(tt), y) : c.moveTo(X(tt), y); st = true; } c.stroke(); c.globalAlpha = 1; };
  label(c, 'lift C_L', rx0, 18, p.c, SANS); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(rx0, 80); c.lineTo(rx1, 80); c.stroke();
  ghostsS.forEach((g,j) => lift(80, 34, 2, p.w, g.H, 1.2, .5 - .15*j)); lift(80, 34, 2, p.c, Hh, 1.8, 1);
  label(c, 'drag C_D', rx0, 148, p.f, SANS); const cdY = v => 230 - (v - 1.5)*60;
  c.setLineDash([3,3]); c.strokeStyle = p.mut; c.beginPath(); c.moveTo(rx0, cdY(2.1)); c.lineTo(rx1, cdY(2.1)); c.stroke(); c.setLineDash([]); label(c, 'exp. 2.1', rx1, cdY(2.1)-4, p.mut, SMF, 'right');
  c.strokeStyle = p.f; c.lineWidth = 1.6; c.beginPath(); let st2 = false; for (const hh of Hh){ if (hh[0] < tBeg) continue; const y = Math.max(150, Math.min(250, cdY(hh[1]))); st2 ? c.lineTo(X(hh[0]), y) : c.moveTo(X(hh[0]), y); st2 = true; } c.stroke();
  label(c, `t = ${S.t.toFixed(1)} D/U`, rx1, 260, p.mut, SMF, 'right');
  // inner-loop residuals of the latest step: dual time stepping at work
  label(c, 'inner loop, last step: R* per sweep', rx0, 282, p.tau, SMF);
  S.res.forEach((r,m) => { const hgt = Math.max(2, (Math.log10(Math.max(r, 1e-4)) + 4)/4*44); c.fillStyle = p.tau; rr(c, rx0 + m*16, 340 - hgt, 12, hgt, 2); c.fill(); });
  label(c, `|∂ᵢuᵢ|: ${S.divBefore.toExponential(0)} → ${S.divAfter.toExponential(0)} (${S.cgIts} CG)`, rx1, 334, p.rho, SMF, 'right');
  const m = measure(), cfl = 1.5*S.dt/h;
  $('read').textContent = `CFL ≈ ${cfl.toFixed(1)} · ${msStep ? msStep.toFixed(0) + ' ms per step, spread over ' + Math.max(1, Math.ceil(msStep/7)) + ' frames · ' : ''}` +
    (m.St ? `St = ${m.St.toFixed(3)} over ${m.cyc} cycles (Lyn et al. exp. 0.132; this coarse 6-cells-per-side grid with 12.5% blockage reads high) · mean C_D = ${m.cd.toFixed(2)} (exp. ≈ 2.1) · C_L rms ${m.cl.toFixed(2)}` : 'measuring the Strouhal number once a few clean cycles have passed…') +
    (m.cl != null && m.cl < 0.3 && S.t - segT > 30 ? ' · shedding is dying out: over-damped' : '') + ` · 3D content (spanwise rms of u) ${(Hh.length ? Hh[Hh.length-1][3] : 0).toExponential(1)}`;
}

// ===== PARALLEL =====
function drawDD(){ const c = hidpi($('dd')), p = P(), V = { th: -0.6, ph: 0.45, s: 44, ox: 150, oy: 100 }; c.clearRect(0,0,c.W,c.H);
  const blocks = []; for (const a of [-1, 1]) for (const b of [-1, 1]) blocks.push([a, b]);
  blocks.forEach(([a,b],k) => { const o = [a*.55, b*.55, 0], q = [[-.5,-.5],[.5,-.5],[.5,.5],[-.5,.5]].map(([x,y]) => proj(V, o[0]+x, o[1]+y, .5));
    c.fillStyle = k === 0 ? p.accSoft : p.panel; c.strokeStyle = k === 0 ? p.acc : p.rule; c.lineWidth = 1.4; c.beginPath(); q.forEach((r,i) => i ? c.lineTo(r[0],r[1]) : c.moveTo(r[0],r[1])); c.closePath(); c.fill(); c.stroke(); });
  const h1 = proj(V, .05+.55, -1.05, .5), h2 = proj(V, .05+.55, .05, .5); c.strokeStyle = p.warm; c.lineWidth = 6; c.globalAlpha = .5; c.beginPath(); c.moveTo(h1[0], h1[1]); c.lineTo(h2[0], h2[1]); c.stroke(); c.globalAlpha = 1;
  label(c, 'one block = one rank', 10, c.H-40, p.acc, SMF); label(c, 'orange: 2-cell halo it copies', 10, c.H-26, p.warm, SMF); label(c, 'from its neighbour every sweep', 10, c.H-12, p.mut, SMF); }
const NCELL = 50e6, US = 2.2e-6, ALPHA = 2e-6, BETA = 1e10, NH = 60, NR = 60;
const tStep = Pn => { const loc = NCELL/Pn, face = Math.pow(loc, 2/3), halo = Pn > 1 ? NH*(6*ALPHA + 6*face*2*5*8/BETA) : 0, red = Pn > 1 ? NR*ALPHA*Math.log2(Pn) : 0; return [loc*US, halo, red]; };
const SC2 = hidpi($('scal'));
function drawScal(){ const c = SC2, p = P(), W = c.W, x0 = 60, x1 = W-60, top = 24, bot = 220, v = +$('ranks').value, Pn = 2**v, X = k => x0 + (x1-x0)*k/17;
  const T1 = tStep(1).reduce((a,b) => a+b), Yt = t => bot - (Math.log10(t)+3.5)/6*(bot-top), Ye = e => bot - e*(bot-top);
  c.clearRect(0,0,W,c.H); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, top); c.lineTo(x0, bot); c.lineTo(x1, bot); c.lineTo(x1, top); c.stroke();
  c.setLineDash([4,4]); c.strokeStyle = p.mut; c.beginPath(); for (let k=0;k<=17;k++){ const y = Yt(T1/2**k); k ? c.lineTo(X(k), y) : c.moveTo(X(k), y); } c.stroke(); c.setLineDash([]);
  const parts = [[0, p.f, 'compute'], [1, p.warm, 'halo'], [2, p.nu, 'all-reduce']];
  c.lineWidth = 2.4; c.strokeStyle = p.ink; c.beginPath(); for (let k=0;k<=17;k++){ const y = Yt(tStep(2**k).reduce((a,b) => a+b)); k ? c.lineTo(X(k), y) : c.moveTo(X(k), y); } c.stroke();
  parts.forEach(([i,col]) => { c.lineWidth = 1.4; c.strokeStyle = col; c.beginPath(); let s = false; for (let k=1;k<=17;k++){ const t = tStep(2**k)[i]; if (t <= 0) continue; const y = Yt(t); s ? c.lineTo(X(k), y) : c.moveTo(X(k), y); s = true; } c.stroke(); });
  c.strokeStyle = p.ok; c.lineWidth = 2; c.beginPath(); for (let k=0;k<=17;k++){ const e = T1/(2**k*tStep(2**k).reduce((a,b) => a+b)); k ? c.lineTo(X(k), Ye(e)) : c.moveTo(X(k), Ye(e)); } c.stroke();
  c.fillStyle = p.ink; c.fillRect(X(v)-1, top, 2, bot-top);
  [0, 4, 8, 12, 16].forEach(k => label(c, k < 10 ? String(2**k) : '2^' + k, X(k), bot+14, p.mut, SMF, 'center'));
  label(c, 'ranks', x1, bot+30, p.mut, SMF, 'right'); label(c, 'time per step (log)', x0, top-8, p.ink, SMF); label(c, 'efficiency', x1, top-8, p.ok, SMF, 'right');
  ['100 s','1 s','10 ms','1 ms'].forEach((s,k) => label(c, s, x0-4, Yt([100,1,.01,.001][k])+4, p.mut, SMF, 'right')); label(c, '100%', x1+4, Ye(1)+4, p.ok, SMF); label(c, '50%', x1+4, Ye(.5)+4, p.ok, SMF);
  let lx = x0+10; parts.forEach(([,col,n]) => { label(c, '— ' + n, lx, c.H-8, col, SMF); lx += 100; }); label(c, '— total   ┄ ideal', lx, c.H-8, p.ink, SMF);
  const t = tStep(Pn), tot = t.reduce((a,b) => a+b), eff = T1/(Pn*tot), steps = 30*48;
  $('ranksv').textContent = Pn;
  const fb = $('scalfb'), hrs = steps*tot/3600;
  fb.className = 'fb' + (eff < .5 ? ' good' : '');
  fb.textContent = `${Pn} ranks: ${(NCELL/Pn).toExponential(1)} cells each, ${(tot*1000).toFixed(1)} ms per step (compute ${(t[0]*1000).toFixed(1)}, halo ${(t[1]*1000).toFixed(2)}, all-reduce ${(t[2]*1000).toFixed(2)}), efficiency ${(eff*100).toFixed(0)}%. 30 shedding periods × 48 steps = ${steps} sequential steps → ${hrs < 1 ? (hrs*60).toFixed(1) + ' min' : hrs.toFixed(1) + ' h'}.` +
    (eff < .5 ? ' ✓ Communication floor reached: latency of halos and global reductions now dominates. More ranks barely help, and the time steps still run one after another.' : ' Keep adding ranks until efficiency drops below 50%.');
  if (eff < .5) K.done('parallel'); }
$('ranks').oninput = drawScal;

const drawLearn = now => { if (openB === '0') drawOps(now); else if (openB === 'A') drawSig(); else if (openB === 'B') drawBdf(now); else if (openB === 'C') drawNt(now); };
if (reduce) { drawOps(0); drawSig(); drawBdf(0); drawNt(0); }
this.ops = HOW;
return {
  frame(now, stp){ if (stp === 0) { if (reduce) { drawOps(0); drawSig(); drawBdf(0); drawNt(0); } else drawLearn(now); }
    if (stp === 1 && SIM) { if (running && !reduce) runSim(7); drawSim(); } },
  onBlock(k){ openB = k; },
  onStep(stp){ if (stp === 2) { drawDD(); drawScal(); } if (stp === 1 && !SIM) { simReset(); drawSim(); } },
  buildReset(){ running = false; simReset(); drawSim(); $('read').textContent = 'Put the steps in order to start the solver.'; },
  buildStart(){ running = true; if (reduce) { const tick = () => { if (!running) return; runSim(30); drawSim(); setTimeout(tick, 60); }; tick(); } },
};
}

const SPEC = {
 id: 'urans', name: 'URANS', sub: 'averaged, in time',
 lede: 'Steady RANS with the clock left in: average over the turbulence but <strong>not over the shedding</strong>, then march in time with an <strong>implicit step solved by an inner loop</strong>.',
 uncoloured: [],
 blocks: [
  { key: '0', title: 'The objects', note: 'what goes in, what comes out', html: BLOCK0 },
  { key: 'A', title: 'Averaging in time', note: 'mean + coherent + turbulent', html: BLOCKA },
  { key: 'B', title: 'Stepping in time', note: 'BDF2 and the pseudo-time loop', html: BLOCKB },
  { key: 'C', title: 'Closure, and what it misses', note: 'eddy viscosity and over-damping', html: BLOCKC }],
 checks: CHECKS, quiz: QUIZ, build: BUILD, parallel: { html: PARALLEL },
 unlock: 'The URANS row of the comparison is now visible: coherent unsteadiness (vortex shedding, buffet frequency) at RANS cost, but no broadband turbulence and a risk of over-damping. Complete the other methods to open the full page.',
 sources: SOURCES, terms: TERMS,
 bench(){ const now = clockNow, s = makeURANS({ dt: 0.1 }); let tot = 0, mx = 0, ch = 0;
  for (let n=0;n<40;n++){ const g = s.step(); let r; do { const c0 = now(); r = g.next(); const d = now() - c0; if (n >= 10) { tot += d; mx = Math.max(mx, d); ch++; } } while (!r.done); }
  return `${s.NX}×${s.NY}×${s.NZ} cells: ${(tot/30).toFixed(1)} ms per time step in ${(ch/30).toFixed(0)} chunks, largest chunk ${mx.toFixed(1)} ms (frame budget 9 ms; the frame loop runs chunks for 7 ms, so one step spans ~${Math.ceil(tot/30/7)} frames)`; },
 mount,
};
CFD.register(SPEC);
})();
