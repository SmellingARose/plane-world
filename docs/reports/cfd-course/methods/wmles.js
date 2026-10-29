// Wall-modelled LES: filtered Navier–Stokes, an eddy-viscosity subgrid model and an equilibrium
// wall-stress model. See ../README.md for the module spec; methods/lbm.js is the reference module.
(() => {
// local aliases: global lookups inside hot loops are slow in some hosts (e.g. node's vm contexts used by tools/check.mjs)
const Math = globalThis.Math, Float64Array = globalThis.Float64Array, Int32Array = globalThis.Int32Array;
const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
const KAP = 0.41, BLOG = 5.2;

// ---------- numerics shared by the Learn visuals, the how-it-works panels and the Build solver ----------
// radix-2 complex FFT (in place); fftTab precomputes bit reversal and twiddles for one length
function fftTab(n){ const rev = new Int32Array(n), lg = Math.round(Math.log2(n)); for (let i=0;i<n;i++){ let r=0; for (let b=0;b<lg;b++) if (i>>b&1) r |= 1<<(lg-1-b); rev[i]=r; }
  const cr = new Float64Array(n/2), ci = new Float64Array(n/2); for (let i=0;i<n/2;i++){ cr[i]=Math.cos(2*Math.PI*i/n); ci[i]=-Math.sin(2*Math.PI*i/n); } return {n, rev, cr, ci}; }
function fft(T, re, im, inv){ const n=T.n, rev=T.rev; for (let i=0;i<n;i++){ const j=rev[i]; if (j>i){ let t=re[i]; re[i]=re[j]; re[j]=t; t=im[i]; im[i]=im[j]; im[j]=t; } }
  const sg = inv ? -1 : 1;
  for (let s=2;s<=n;s<<=1){ const h=s>>1, st=n/s; for (let b=0;b<n;b+=s) for (let k=0;k<h;k++){ const wr=T.cr[k*st], wi=sg*T.ci[k*st], a=b+k, c=a+h, xr=re[c]*wr-im[c]*wi, xi=re[c]*wi+im[c]*wr; re[c]=re[a]-xr; im[c]=im[a]-xi; re[a]+=xr; im[a]+=xi; } } }
// 3D FFT of an n×n×n complex array, index i + n(j + n k); inverse includes the 1/n³
function fft3(re, im, n, inv){ const T = fftTab(n), br = new Float64Array(n), bi = new Float64Array(n), sc = inv ? 1/(n*n*n) : 1;
  for (const [st, s2, s3] of [[1,n,n*n],[n,1,n*n],[n*n,1,n]]) for (let a=0;a<n;a++) for (let b=0;b<n;b++){ const o = a*s2 + b*s3;
    for (let q=0;q<n;q++){ br[q]=re[o+q*st]; bi[q]=im[o+q*st]; } fft(T, br, bi, inv); for (let q=0;q<n;q++){ re[o+q*st]=br[q]; im[o+q*st]=bi[q]; } }
  if (inv) for (let c=0;c<re.length;c++){ re[c]*=sc; im[c]*=sc; } }
const rng = seed => { let s = seed; return () => (s = (s*16807) % 2147483647) / 2147483647; };
const logLaw = yp => Math.log(yp)/KAP + BLOG;
// Spalding's (1961) law of the wall, y+ = u+ + e^(-kB)[e^(k u+) - 1 - k u+ - (k u+)^2/2 - (k u+)^3/6]: one smooth curve through the
// viscous sublayer, buffer and log layer that becomes exactly the log law (same kappa, B) far from the wall. Inverted by Newton.
function spald(yp){ if (yp <= 0) return 0; const e = Math.exp(-KAP*BLOG); let u = Math.min(yp, logLaw(Math.max(yp, 1)));
  for (let k=0;k<50;k++){ const ku = KAP*u, ex = Math.exp(ku), g = u + e*(ex - 1 - ku - ku*ku/2 - ku*ku*ku/6) - yp, gp = 1 + e*KAP*(ex - 1 - ku - ku*ku/2); const du = g/gp; u -= du; if (Math.abs(du) < 1e-12) break; }
  return u; }
// the equilibrium wall model: solve U = u_t [ ln(h u_t / nu)/kappa + B ] for u_t by Newton's method; returns the iterates
function newtonIts(U, h, nu, q0, n){ const its = [q0]; let q = q0;
  for (let k=0;k<(n||8);k++){ const L = Math.log(h*q/nu), f = q*(L/KAP + BLOG) - U, fp = L/KAP + BLOG + 1/KAP; let qn = q - f/fp; if (!(qn > 1e-9)) qn = q*0.5; q = qn; its.push(q); if (Math.abs(f) < 1e-12*U) break; }
  return its; }
// velocity gradient a_ij = du_i/dx_j (3×3, row-major) → Smagorinsky, Vreman, WALE eddy viscosities (Delta per direction d[0..2])
function sgsModels(a, d, Cs, Cw){ const D = Math.cbrt(d[0]*d[1]*d[2]);
  const S = [0,1,2].map(i => [0,1,2].map(j => .5*(a[3*i+j]+a[3*j+i]))); let SS = 0; for (let i=0;i<3;i++) for (let j=0;j<3;j++) SS += S[i][j]*S[i][j];
  const Smag = Math.sqrt(2*SS), smag = (Cs*D)**2*Smag;
  const b = (i,j) => { let s=0; for (let m=0;m<3;m++) s += d[m]*d[m]*a[3*i+m]*a[3*j+m]; return s; };
  const Bb = b(0,0)*b(1,1)-b(0,1)**2 + b(0,0)*b(2,2)-b(0,2)**2 + b(1,1)*b(2,2)-b(1,2)**2; let aa = 0; for (let k=0;k<9;k++) aa += a[k]*a[k];
  const vrem = aa > 1e-30 && Bb > 0 ? 2.5*Cs*Cs*Math.sqrt(Bb/aa) : 0;
  const g2 = (i,j) => a[3*i]*a[j] + a[3*i+1]*a[3+j] + a[3*i+2]*a[6+j], tr = g2(0,0)+g2(1,1)+g2(2,2); let SdSd = 0;
  for (let i=0;i<3;i++) for (let j=0;j<3;j++){ const sd = .5*(g2(i,j)+g2(j,i)) - (i===j ? tr/3 : 0); SdSd += sd*sd; }
  const den = SS**2.5 + SdSd**1.25, wale = den > 1e-300 ? (Cw*D)**2*SdSd**1.5/den : 0;
  return { S, SS, Smag, smag, vrem, wale, Bb, aa }; }

// ---------- the Build solver: a small periodic channel, wall-modelled LES ----------
// staggered (MAC) grid: u on x-faces, v on y-faces (v = 0 on both walls), w on z-faces, pressure at cell centres.
// index c = i + NX (k + NZ j): an x–z plane of NP = NX·NZ values is contiguous, j counts planes away from the bottom wall.
function Channel(o){
  o = o || {};
  const NX=32, NY=24, NZ=16, LX=Math.PI, LY=2, LZ=Math.PI/2;
  const dx=LX/NX, dy=LY/NY, dz=LZ/NZ, NP=NX*NZ, NC=NP*NY, NV=NP*(NY+1);
  const S = { NX, NY, NZ, LX, LY, LZ, dx, dy, dz, NP, NC, retau: o.retau||2000, model: o.model||'vreman', jh: o.jh==null?2:o.jh, Cs: 0.17, t: 0, n: 0, tw: 1, twHist: [], tWall: 0, tStep: 0 };
  const u=new Float64Array(NC), v=new Float64Array(NV), w=new Float64Array(NC), qu=new Float64Array(NC), qv=new Float64Array(NV), qw=new Float64Array(NC);
  const Fu=new Float64Array(NC), Fv=new Float64Array(NV), Fw=new Float64Array(NC);
  const uc=new Float64Array(NC), vc=new Float64Array(NC), wc=new Float64Array(NC), nut=new Float64Array(NC);
  const Fxx=new Float64Array(NC), Fyy=new Float64Array(NC), Fzz=new Float64Array(NC), Fxz=new Float64Array(NC), Fxy=new Float64Array(NV), Fyz=new Float64Array(NV);
  const phr=new Float64Array(NC), phi=new Float64Array(NC);
  const twx=[new Float64Array(NP), new Float64Array(NP)], twz=[new Float64Array(NP), new Float64Array(NP)], utau=[new Float64Array(NP).fill(1), new Float64Array(NP).fill(1)], tc=new Float64Array(NP), tz=new Float64Array(NP);
  const IP=new Int32Array(NX), IM=new Int32Array(NX), KP=new Int32Array(NZ), KM=new Int32Array(NZ);
  for (let i=0;i<NX;i++){ IP[i]=(i+1)%NX; IM[i]=(i+NX-1)%NX; } for (let k=0;k<NZ;k++){ KP[k]=(k+1)%NZ; KM[k]=(k+NZ-1)%NZ; }
  const TX=fftTab(NX), TZ=fftTab(NZ), lx=new Float64Array(NX), lz=new Float64Array(NZ);
  for (let m=0;m<NX;m++) lx[m] = -(2-2*Math.cos(2*Math.PI*m/NX))/(dx*dx); for (let m=0;m<NZ;m++) lz[m] = -(2-2*Math.cos(2*Math.PI*m/NZ))/(dz*dz);
  const bx=new Float64Array(NX), by=new Float64Array(NX), bz=new Float64Array(NZ), b2=new Float64Array(NZ), cp=new Float64Array(NY), dr=new Float64Array(NY), di=new Float64Array(NY);
  const mean = new Float64Array(NY), meanAcc = new Float64Array(NY); let nAcc = 0;
  Object.assign(S, { u, v, w, nut, uc, vc, wc, utau, twx, twz, mean });
  const Uplus = yw => { const yp = yw*S.retau; return yp < 11 ? yp : logLaw(yp); };
  function init(seed){ const r = rng(seed||12345), rnd = () => r() - .5;
    for (let j=0;j<NY;j++){ const y=(j+.5)*dy, U=Uplus(Math.min(y, LY-y));
      for (let k=0;k<NZ;k++) for (let i=0;i<NX;i++){ const c=i+NX*(k+NZ*j), x=i*dx, z=(k+.5)*dz;
        u[c] = U*(1 + 0.3*rnd()) + 3*Math.sin(4*Math.PI*z/LZ)*Math.sin(Math.PI*y/LY)*Math.cos(2*Math.PI*x/LX);
        w[c] = 2*rnd() + 2*Math.sin(2*Math.PI*x/LX)*Math.sin(Math.PI*y/LY); } }
    v.fill(0); for (let j=1;j<NY;j++) for (let p=0;p<NP;p++) v[j*NP+p] = 2*rnd()*Math.sin(Math.PI*j*dy/LY);
    project(); stg = 0; qu.fill(0); qv.fill(0); qw.fill(0); S.t=0; S.n=0; utau[0].fill(1); utau[1].fill(1); centres(); resetStats(); }
  function resetStats(){ meanAcc.fill(0); nAcc = 0; S.twHist = []; S.tAcc0 = S.t; }
  function newton(U, h, q0){ const nu = 1/S.retau; let q = q0 > 1e-6 ? q0 : 1;
    for (let it=0; it<8; it++){ const L = Math.log(h*q/nu), f = q*(L/KAP + BLOG) - U, qn = q - f/(L/KAP + BLOG + 1/KAP); q = qn > 1e-6 ? qn : q*0.5; if (Math.abs(f) < 1e-10*U) break; }
    return h*q/nu < 11 ? Math.sqrt(U*nu/h) : q; }   // inside the viscous sublayer the log law is replaced by u+ = y+
  // W: sample the LES velocity jh cells off each wall, solve for u_tau, return the wall shear stress on u- and w-faces
  function wallModel(){ const t0 = now(), jh = S.jh, h = (jh+.5)*dy; let sum = 0;
    for (let side=0; side<2; side++){ const j = side ? NY-1-jh : jh, ut = utau[side], TX_ = twx[side], TZ_ = twz[side];
      for (let p=0;p<NP;p++){ const c = p + NP*j, U1 = uc[c], W1 = wc[c], U = Math.hypot(U1, W1) + 1e-12, q = newton(U, h, ut[p]), t = q*q; ut[p] = q; sum += t; tc[p] = t*U1/U; tz[p] = t*W1/U; }
      for (let k=0;k<NZ;k++) for (let i=0;i<NX;i++){ const p = i+NX*k; TX_[p] = .5*(tc[p] + tc[IM[i]+NX*k]); TZ_[p] = .5*(tz[p] + tz[i+NX*KM[k]]); } }
    S.tWall += now() - t0; return sum/(2*NP); }
  function centres(){ for (let j=0;j<NY;j++) for (let k=0;k<NZ;k++){ const o=NX*(k+NZ*j), okp=NX*(KP[k]+NZ*j);
      for (let i=0;i<NX;i++){ const c=o+i; uc[c] = .5*(u[c]+u[o+IP[i]]); vc[c] = .5*(v[c]+v[c+NP]); wc[c] = .5*(w[c]+w[okp+i]); } } }
  // M: eddy viscosity at every cell centre from the resolved velocity gradient
  function sgs(){ const vr = S.model === 'vreman', D = Math.cbrt(dx*dy*dz), cS = (S.Cs*D)**2, cV = 2.5*S.Cs*S.Cs, d1=dx*dx, d2=dy*dy, d3=dz*dz;
    for (let j=0;j<NY;j++){ const jp = j<NY-1 ? NP : 0, jm = j>0 ? -NP : 0, fy = 1/((jp-jm)/NP*dy);
      for (let k=0;k<NZ;k++){ const o=NX*(k+NZ*j), okp=NX*(KP[k]+NZ*j), okm=NX*(KM[k]+NZ*j);
        for (let i=0;i<NX;i++){ const c=o+i, ip=o+IP[i], im=o+IM[i];
          const a11=(u[ip]-u[c])/dx, a12=(uc[c+jp]-uc[c+jm])*fy, a13=(uc[okp+i]-uc[okm+i])/(2*dz);
          const a21=(vc[ip]-vc[im])/(2*dx), a22=(v[c+NP]-v[c])/dy, a23=(vc[okp+i]-vc[okm+i])/(2*dz);
          const a31=(wc[ip]-wc[im])/(2*dx), a32=(wc[c+jp]-wc[c+jm])*fy, a33=(w[okp+i]-w[c])/dz;
          if (vr){ const b11=d1*a11*a11+d2*a12*a12+d3*a13*a13, b22=d1*a21*a21+d2*a22*a22+d3*a23*a23, b33=d1*a31*a31+d2*a32*a32+d3*a33*a33;
            const b12=d1*a11*a21+d2*a12*a22+d3*a13*a23, b13=d1*a11*a31+d2*a12*a32+d3*a13*a33, b23=d1*a21*a31+d2*a22*a32+d3*a23*a33;
            const Bb = b11*b22-b12*b12 + b11*b33-b13*b13 + b22*b33-b23*b23, aa = a11*a11+a12*a12+a13*a13+a21*a21+a22*a22+a23*a23+a31*a31+a32*a32+a33*a33;
            nut[c] = aa > 1e-12 && Bb > 0 ? cV*Math.sqrt(Bb/aa) : 0;
          } else { const s12=.5*(a12+a21), s13=.5*(a13+a31), s23=.5*(a23+a32);
            nut[c] = cS*Math.sqrt(2*(a11*a11+a22*a22+a33*a33 + 2*(s12*s12+s13*s13+s23*s23))); } } } } }
  // momentum fluxes (advection + (nu + nu_sgs) times the strain) on faces and edges; the wall model supplies the wall flux
  function rhs(){
    centres(); const tw = wallModel(); sgs(); const nu0 = 1/S.retau;
    for (let j=0;j<NY;j++) for (let k=0;k<NZ;k++){ const o=NX*(k+NZ*j), okp=NX*(KP[k]+NZ*j), okm=NX*(KM[k]+NZ*j);
      for (let i=0;i<NX;i++){ const c=o+i, ne=nu0+nut[c], im=o+IM[i], km=okm+i, imkm=okm+IM[i];
        Fxx[c] = uc[c]*uc[c] - 2*ne*(u[o+IP[i]]-u[c])/dx; Fyy[c] = vc[c]*vc[c] - 2*ne*(v[c+NP]-v[c])/dy; Fzz[c] = wc[c]*wc[c] - 2*ne*(w[okp+i]-w[c])/dz;
        const nxz = nu0 + .25*(nut[c]+nut[im]+nut[km]+nut[imkm]);
        Fxz[c] = .25*(u[km]+u[c])*(w[im]+w[c]) - nxz*((u[c]-u[km])/dz + (w[c]-w[im])/dx); } }
    for (let p=0;p<NP;p++){ Fxy[p] = -twx[0][p]; Fyz[p] = -twz[0][p]; Fxy[NY*NP+p] = twx[1][p]; Fyz[NY*NP+p] = twz[1][p]; }
    for (let j=1;j<NY;j++) for (let k=0;k<NZ;k++){ const o=NX*(k+NZ*j), okm=NX*(KM[k]+NZ*j);
      for (let i=0;i<NX;i++){ const c=o+i, im=o+IM[i], km=okm+i, b=c-NP;
        const nxy = nu0 + .25*(nut[c]+nut[im]+nut[b]+nut[im-NP]), nyz = nu0 + .25*(nut[c]+nut[km]+nut[b]+nut[km-NP]);
        Fxy[c] = .25*(u[b]+u[c])*(v[im]+v[c]) - nxy*((u[c]-u[b])/dy + (v[c]-v[im])/dx);
        Fyz[c] = .25*(w[b]+w[c])*(v[km]+v[c]) - nyz*((w[c]-w[b])/dy + (v[c]-v[km])/dz); } }
    for (let j=0;j<NY;j++) for (let k=0;k<NZ;k++){ const o=NX*(k+NZ*j), okp=NX*(KP[k]+NZ*j), okm=NX*(KM[k]+NZ*j);
      for (let i=0;i<NX;i++){ const c=o+i, ip=o+IP[i], im=o+IM[i];
        Fu[c] = -(Fxx[c]-Fxx[im])/dx - (Fxy[c+NP]-Fxy[c])/dy - (Fxz[okp+i]-Fxz[c])/dz + 1;   // + 1: the driving pressure gradient
        Fw[c] = -(Fxz[ip]-Fxz[c])/dx - (Fyz[c+NP]-Fyz[c])/dy - (Fzz[c]-Fzz[okm+i])/dz;
        if (j) Fv[c] = -(Fxy[ip]-Fxy[c])/dx - (Fyy[c]-Fyy[c-NP])/dy - (Fyz[okp+i]-Fyz[c])/dz; } }
    return tw; }
  // P: solve L phi = div u (FFT along x and z, tridiagonal along y with dphi/dy = 0 at the walls), then u -= grad phi
  function fft2(o, inv){ const sc = inv ? 1/NP : 1;
    for (let k=0;k<NZ;k++){ const r=o+NX*k; for (let i=0;i<NX;i++){ bx[i]=phr[r+i]; by[i]=phi[r+i]; } fft(TX, bx, by, inv); for (let i=0;i<NX;i++){ phr[r+i]=bx[i]; phi[r+i]=by[i]; } }
    for (let i=0;i<NX;i++){ for (let k=0;k<NZ;k++){ bz[k]=phr[o+i+NX*k]; b2[k]=phi[o+i+NX*k]; } fft(TZ, bz, b2, inv); for (let k=0;k<NZ;k++){ phr[o+i+NX*k]=bz[k]*sc; phi[o+i+NX*k]=b2[k]*sc; } } }
  function project(){
    for (let j=0;j<NY;j++) for (let k=0;k<NZ;k++){ const o=NX*(k+NZ*j), okp=NX*(KP[k]+NZ*j);
      for (let i=0;i<NX;i++){ const c=o+i; phr[c] = (u[o+IP[i]]-u[c])/dx + (v[c+NP]-v[c])/dy + (w[okp+i]-w[c])/dz; phi[c] = 0; } }
    for (let j=0;j<NY;j++) fft2(NP*j, false);
    const iy2 = 1/(dy*dy);
    for (let p=0;p<NP;p++){ const lam = lx[p%NX]+lz[(p/NX)|0], zero = p === 0;
      const b0 = zero ? 1 : -iy2 + lam; cp[0] = (zero ? 0 : iy2)/b0; dr[0] = (zero ? 0 : phr[p])/b0; di[0] = (zero ? 0 : phi[p])/b0;
      for (let j=1;j<NY;j++){ const m = (j === NY-1 ? -iy2 : -2*iy2) + lam - iy2*cp[j-1], c = p+NP*j; cp[j] = iy2/m; dr[j] = (phr[c] - iy2*dr[j-1])/m; di[j] = (phi[c] - iy2*di[j-1])/m; }
      for (let j=NY-2;j>=0;j--){ dr[j] -= cp[j]*dr[j+1]; di[j] -= cp[j]*di[j+1]; }
      for (let j=0;j<NY;j++){ phr[p+NP*j] = dr[j]; phi[p+NP*j] = di[j]; } }
    for (let j=0;j<NY;j++) fft2(NP*j, true);
    for (let j=0;j<NY;j++) for (let k=0;k<NZ;k++){ const o=NX*(k+NZ*j), okm=NX*(KM[k]+NZ*j);
      for (let i=0;i<NX;i++){ const c=o+i; u[c] -= (phr[c]-phr[o+IM[i]])/dx; w[c] -= (phr[c]-phr[okm+i])/dz; if (j) v[c] -= (phr[c]-phr[c-NP])/dy; } } }
  function divMax(){ let m=0; for (let j=0;j<NY;j++) for (let k=0;k<NZ;k++){ const o=NX*(k+NZ*j), okp=NX*(KP[k]+NZ*j); for (let i=0;i<NX;i++){ const c=o+i; m=Math.max(m, Math.abs((u[o+IP[i]]-u[c])/dx + (v[c+NP]-v[c])/dy + (w[okp+i]-w[c])/dz)); } } return m; }
  // one time step = 3 stages of Williamson's low-storage RK3, projecting after every stage; dt from the CFL and diffusion limits.
  // stage() is the unit of work the page schedules, so one animation frame never has to finish a whole step.
  const RA=[0,-5/9,-153/128], RB=[1/3,15/16,8/15]; let stg = 0, dt = 0.004, tAcc = 0;
  function stage(){ const t0 = now();
    if (stg === 0){ let um=0, nm=0; for (let c=0;c<NC;c++){ um = Math.max(um, Math.abs(u[c])/dx + Math.abs(w[c])/dz + Math.abs(v[c])/dy); nm = Math.max(nm, nut[c]); }
      dt = Math.min(1.2/um, 0.3/((nm + 1/S.retau)*(2/(dx*dx)+2/(dy*dy)+2/(dz*dz))), 0.01); S.dt = dt; tAcc = 0; }
    const a = RA[stg], b = RB[stg], tw = rhs(); if (stg === 0) S.tw = tw;
    for (let c=0;c<NC;c++){ qu[c] = a*qu[c] + dt*Fu[c]; qw[c] = a*qw[c] + dt*Fw[c]; u[c] += b*qu[c]; w[c] += b*qw[c]; }
    for (let c=NP;c<NP*NY;c++){ qv[c] = a*qv[c] + dt*Fv[c]; v[c] += b*qv[c]; }
    project(); stg = (stg + 1) % 3;
    if (stg === 0){ S.t += dt; S.n++; centres();
      for (let j=0;j<NY;j++){ let s=0; for (let p=0;p<NP;p++) s += u[p+NP*j]; mean[j] = s/NP; }
      if (S.t - S.tAcc0 > 1){ for (let j=0;j<NY;j++) meanAcc[j] += mean[j]; nAcc++; }   // statistics start one eddy turnover (delta/u_tau) after a change
      S.twHist.push([S.t, S.tw]); if (S.twHist.length > 3000) S.twHist.splice(0, 1000); }
    S.tStage = now() - t0; tAcc += S.tStage; S.tTot = (S.tTot||0) + S.tStage; if (stg === 0) S.tStep = tAcc; return stg === 0; }
  function step(){ do stage(); while (stg !== 0); }
  S.meanAvg = () => { if (!nAcc) return null; const r = new Float64Array(NY); for (let j=0;j<NY;j++) r[j] = meanAcc[j]/nAcc; return r; };
  S.nAcc = () => nAcc;
  S.ub = () => { let s=0; for (let c=0;c<NC;c++) s += u[c]; return s/NC; };
  Object.assign(S, { init, step, stage, project, divMax, resetStats, centres });
  init(o.seed);
  return S;
}
// Dean (1978) correlation for channel skin friction: Cf = 0.073 Re_b^(-1/4), Re_b = 2 delta U_b / nu (fit for 6e3 < Re_b < 6e5)
function deanUb(retau){ let U = 22; for (let k=0;k<40;k++) U = Math.sqrt(2/(0.073*Math.pow(2*U*retau, -0.25))); return U; }

// ---------- block A: a synthetic 3D turbulent field (random phases, divergence-free, model spectrum with a −5/3 range) ----------
const NA = 32, NA3 = NA*NA*NA, wnum = q => q <= NA/2 ? q : q - NA;
function makeField(seed){ const r = rng(seed), g = () => { let s = 0; for (let q=0;q<6;q++) s += r(); return s - 3; };
  const uh = [0,1,2].map(() => [new Float64Array(NA3), new Float64Array(NA3)]);
  for (let kz=0;kz<NA;kz++) for (let ky=0;ky<NA;ky++) for (let kx=0;kx<NA;kx++){ const k = [wnum(kx), wnum(ky), wnum(kz)], kk = Math.hypot(...k); if (kk < .5 || kk > NA/2 - .5) continue;
    const E = kk**4/(1 + (kk/1.0)**2)**(17/6), amp = Math.sqrt(E/(4*Math.PI*kk*kk)), c = kx + NA*(ky + NA*kz);
    for (const part of [0,1]){ const a = [g(), g(), g()], dot = (a[0]*k[0]+a[1]*k[1]+a[2]*k[2])/(kk*kk); for (let d=0;d<3;d++) uh[d][part][c] = amp*(a[d] - dot*k[d]); } }
  const u = uh.map(([re, im]) => { const R2 = Float64Array.from(re), I2 = Float64Array.from(im); fft3(R2, I2, NA, true); return R2; });
  let s2 = 0; for (let c=0;c<NA3;c++) s2 += u[0][c]**2; const sc = 1/Math.sqrt(s2/NA3);
  u.forEach(f => { for (let c=0;c<NA3;c++) f[c] *= sc; }); uh.forEach(([re, im]) => { for (let c=0;c<NA3;c++){ re[c] *= sc; im[c] *= sc; } });
  const pr = new Float64Array(NA3), pi = new Float64Array(NA3); for (let c=0;c<NA3;c++) pr[c] = u[0][c]*u[1][c]; fft3(pr, pi, NA, false);   // spectrum of u_x u_y, for tau_xy
  return { uh, u, uvh: [pr, pi] }; }
// filter transfer function: box = product of sinc(k_d Δ/2) (cell width h = 1), Gaussian = exp(−|k|²Δ²/24) (Pope 2000)
function gHat(kx, ky, kz, D, gauss){ return g1(kx, D, gauss)*g1(ky, D, gauss)*g1(kz, D, gauss); }   // both kernels are separable
function g1(k, D, gauss){ const x = k*2*Math.PI/NA; return gauss ? Math.exp(-x*x*D*D/24) : Math.abs(x) < 1e-9 ? 1 : Math.sin(x*D/2)/(x*D/2); }
function filterField(F, D, gauss){ const G = new Float64Array(NA3), g = [...Array(NA)].map((_,q) => g1(wnum(q), D, gauss));
  for (let kz=0;kz<NA;kz++) for (let ky=0;ky<NA;ky++) for (let kx=0;kx<NA;kx++) G[kx + NA*(ky + NA*kz)] = g[kx]*g[ky]*g[kz];
  const filt = (re, im) => { const R2 = new Float64Array(NA3), I2 = new Float64Array(NA3); for (let c=0;c<NA3;c++){ R2[c] = re[c]*G[c]; I2[c] = im[c]*G[c]; } fft3(R2, I2, NA, true); return R2; };
  const ub = [filt(...F.uh[0]), filt(...F.uh[1])];
  const uv = filt(F.uvh[0], F.uvh[1]), tau = new Float64Array(NA3); for (let c=0;c<NA3;c++) tau[c] = uv[c] - ub[0][c]*ub[1][c];
  // shell spectra of the true and the filtered field
  const E = new Float64Array(NA/2+1), Ef = new Float64Array(NA/2+1);
  for (let kz=0;kz<NA;kz++) for (let ky=0;ky<NA;ky++) for (let kx=0;kx<NA;kx++){ const c = kx + NA*(ky + NA*kz), s = Math.round(Math.hypot(wnum(kx), wnum(ky), wnum(kz))); if (s > NA/2) continue;
    let e = 0; for (let d=0;d<3;d++) e += F.uh[d][0][c]**2 + F.uh[d][1][c]**2; E[s] += e/2; Ef[s] += e/2*G[c]*G[c]; }
  let et = 0, ef = 0; for (let s=0;s<=NA/2;s++){ et += E[s]; ef += Ef[s]; }
  return { ub, tau, E, Ef, frac: ef/et }; }
// ---------- P demo: exact projection of a random staggered field on a periodic 8×8×8 box ----------
function projDemo(seed){ const nn = 8, N3 = nn*nn*nn, r = rng(seed), id = (i,j,k) => ((i+nn)%nn) + nn*(((j+nn)%nn) + nn*((k+nn)%nn));
  const U = [0,1,2].map(() => new Float64Array(N3));
  for (let d=0;d<3;d++) for (let q=0;q<5;q++){ const kx = 1 + (r()*3|0), ky = 1 + (r()*3|0), kz = r()*3|0, a = r() - .5, ph = r()*6.283;
    for (let k=0;k<nn;k++) for (let j=0;j<nn;j++) for (let i=0;i<nn;i++) U[d][id(i,j,k)] += a*Math.sin(2*Math.PI*(kx*i + ky*j + kz*k)/nn + ph); }
  const div = () => { const D = new Float64Array(N3); for (let k=0;k<nn;k++) for (let j=0;j<nn;j++) for (let i=0;i<nn;i++) D[id(i,j,k)] = U[0][id(i+1,j,k)]-U[0][id(i,j,k)] + U[1][id(i,j+1,k)]-U[1][id(i,j,k)] + U[2][id(i,j,k+1)]-U[2][id(i,j,k)]; return D; };
  const ke = () => { let s = 0; for (let d=0;d<3;d++) for (let c=0;c<N3;c++) s += U[d][c]**2; return s/2; };
  const k0 = ke(); for (let d=0;d<3;d++) for (let c=0;c<N3;c++) U[d][c] /= Math.sqrt(k0/N3*2/3*1.5);
  const before = U.map(f => Float64Array.from(f)), D0 = div(), ke0 = ke(), mx0 = D0.reduce((a,b) => Math.max(a, Math.abs(b)), 0);
  const re = Float64Array.from(D0), im = new Float64Array(N3); fft3(re, im, nn, false);
  const lam = q => -(2 - 2*Math.cos(2*Math.PI*q/nn));
  for (let k=0;k<nn;k++) for (let j=0;j<nn;j++) for (let i=0;i<nn;i++){ const c = id(i,j,k), L = lam(i)+lam(j)+lam(k); if (c === 0){ re[c] = 0; im[c] = 0; } else { re[c] /= L; im[c] /= L; } }
  fft3(re, im, nn, true);
  for (let k=0;k<nn;k++) for (let j=0;j<nn;j++) for (let i=0;i<nn;i++){ const c = id(i,j,k); U[0][c] -= re[c]-re[id(i-1,j,k)]; U[1][c] -= re[c]-re[id(i,j-1,k)]; U[2][c] -= re[c]-re[id(i,j,k-1)]; }
  const D1 = div(); return { nn, id, before, after: U, D0, mx0, mx1: D1.reduce((a,b) => Math.max(a, Math.abs(b)), 0), ke0, ke1: ke() }; }
// ---------- MathML helpers (MathML only; every symbol tagged with data-t) ----------
const R = (k, x) => `<mrow data-t="${k}">${x}</mrow>`, I = (x, k) => `<mi data-t="${k}">${x}</mi>`;
const m = x => `<mi>${x}</mi>`, o = x => `<mo>${x}</mo>`, n = x => `<mn>${x}</mn>`, tx = x => `<mtext>${x}</mtext>`, row = (...a) => `<mrow>${a.join('')}</mrow>`;
const sb = (a, b) => `<msub>${a}${b}</msub>`, sp = (a, b) => `<msup>${a}${b}</msup>`, ss = (a, b, c) => `<msubsup>${a}${b}${c}</msubsup>`;
const fr = (a, b) => `<mfrac><mrow>${a}</mrow><mrow>${b}</mrow></mfrac>`, sq = x => `<msqrt>${x}</msqrt>`, bar = x => `<mover>${x}<mo stretchy="true">―</mo></mover>`;
const UB = (x, k, t) => `<munder><munder><mrow>${x}</mrow><mo stretchy="true">⏟</mo></munder><mtext data-t="${k}" class="opl">${t}</mtext></munder>`;
const MB = (x, cls) => `<math display="block"${cls ? ` class="${cls}"` : ''}>${x}</math>`, MI = x => `<math>${x}</math>`, SPC = w => `<mspace width="${w}"/>`;
const ii = I('i','alpha'), jj = I('j','alpha'), kk = I('k','alpha'), ij = row(ii, jj), dd = o('∂');
const tt = I('t','t'), DT = R('dt', m('Δ') + m('t'));
const uB = i => R('ub', sb(bar(m('u')), i)), uT = i => R('uf', sb(m('u'), i)), xJ = j => R('xx', sb(m('x'), j));
const UBi = uB(ii), UBj = uB(jj), Ui = uT(ii), Uj = uT(jj);
const TAU = R('tau', sb(m('τ'), ij)), SIJ = R('S', sb(bar(m('S')), ij)), SMAG = R('Smag', o('|') + bar(m('S')) + o('|'));
const NUT = R('nut', sb(m('ν'), tx('sgs'))), NU = I('ν','nu'), PB = R('p', bar(m('p'))), DEL = I('Δ','Delta'), CS = R('Cs', sb(m('C'), m('s')));
const UT = R('utau', sb(m('u'), m('τ'))), TW = R('tw', sb(m('τ'), tx('w'))), HWM = R('hwm', sb(m('h'), tx('wm'))), KAPPA = I('κ','kap'), BC = I('B','Bc'), RHO = I('ρ','rho');
const UPAR = R('upar', o('|') + sb(bar(m('u')), o('∥')) + o('|')), PHI = I('φ','phi'), DIJ = R('delta', sb(m('δ'), ij));
const NN = a => R('N', sb(m('N'), m(a))), GRID = row(n(3), o('×'), NN('x'), o('×'), NN('y'), o('×'), NN('z'));
const RR = e => sp(m('ℝ'), row(e)), dpar = (a, b) => fr(dd + a, dd + b);
const OPG = I('G','G'), OPM = I('M','M'), OPW = I('W','W'), OPP = I('P','P');

// ---------- the four Learn blocks ----------
const BLOCK0 = `<div class="eqhero">
  ${MB(R('ub', ss(bar(m('u')), row(ii, I('x','ix'), I('y','iy'), I('z','iz')), tt)) + o('∈') + RR(GRID) + SPC('2em') +
     sp(bar(m('u')), row(tt, o('+'), DT)) + o('=') + OPP + o('(') + R('ub', sp(bar(m('u')), tt)) + o(',') + OPM + o('(') + sp(bar(m('u')), tt) + o(')') + o(',') + OPW + o('(') + sp(bar(m('u')), tt) + o(')') + o(')'))}
  ${MB(UBi + o('=') + OPG + o('∗') + Ui + SPC('2em') + NUT + o('=') + OPM + o('(') + bar(m('u')) + o(')') + SPC('2em') + R('tw', sb(m('τ'), row(tx('w'), o(','), ii))) + o('=') + OPW + o('(') + bar(m('u')) + o(')'), 'sm')}
</div>
<div class="idx"><span class="eyebrow">Every index</span>
  <div class="ir" data-t="alpha"><span class="is">${MI(m('i') + o(',') + m('j') + o(',') + m('k'))}</span><span class="rg">${MI(m('x') + o(',') + m('y') + o(',') + m('z'))}</span><span class="im">Axis of a vector or tensor (ū<sub>i</sub>, τ<sub>ij</sub>). Repeated in one term → summed over x, y, z: ∂ū<sub>j</sub>/∂x<sub>j</sub> = ∂ū<sub>x</sub>/∂x + ∂ū<sub>y</sub>/∂y + ∂ū<sub>z</sub>/∂z.</span></div>
  <div class="ir" data-t="ix"><span class="is">${MI(m('x'))}</span><span class="rg">${MI(n(0) + o(',') + o('…') + o(',') + sb(m('N'), m('x')) + o('−') + n(1))}</span><span class="im">Cell column along the flow (streamwise, periodic).</span></div>
  <div class="ir" data-t="iy"><span class="is">${MI(m('y'))}</span><span class="rg">${MI(n(0) + o(',') + o('…') + o(',') + sb(m('N'), m('y')) + o('−') + n(1))}</span><span class="im">Cell row away from the wall: y = 0 touches the bottom wall, y = N<sub>y</sub>−1 the top wall.</span></div>
  <div class="ir" data-t="iz"><span class="is">${MI(m('z'))}</span><span class="rg">${MI(n(0) + o(',') + o('…') + o(',') + sb(m('N'), m('z')) + o('−') + n(1))}</span><span class="im">Cell layer across the flow (spanwise, periodic).</span></div>
  <div class="ir" data-t="t"><span class="is">${MI(m('t'))}</span><span class="rg">${MI(n(0) + o(',') + m('Δ') + m('t') + o(',') + n(2) + m('Δ') + m('t') + o(',') + o('…'))}</span><span class="im">Time level. Written up top (ūᵗ) it labels the time; it is not a power.</span></div>
  <div class="ir" data-t="lab"><span class="is">${MI(tx('w') + o(',') + tx('sgs') + o(',') + tx('wm'))}</span><span class="rg">labels</span><span class="im">Names, not indices: w = at the wall, sgs = subgrid scale, wm = wall model. Nothing is summed over them.</span></div>
</div>
<div class="dims">
  <div class="dim"><b>Fix i, x, y, z</b>${MI(sb(bar(m('u')), row(ii, I('x','ix'), I('y','iy'), I('z','iz'))) + o('∈') + m('ℝ'))}<span>one number: one velocity component in one cell</span></div>
  <div class="dim"><b>Fix x, y, z</b>${MI(UBi + o('∈') + sp(m('ℝ'), n(3)) + o(',') + SPC('.4em') + TAU + o('∈') + sp(m('ℝ'), row(n(3), o('×'), n(3))))}<span>one cell: a velocity vector; its subgrid stress is a symmetric 3×3 matrix (6 numbers)</span></div>
  <div class="dim"><b>Nothing fixed (the state)</b>${MI(bar(m('u')) + o('∈') + RR(GRID))}<span>32 × 24 × 16 grid → 36 864 velocities (+ 12 288 pressures)</span></div>
  <div class="dim"><b>The wall data</b>${MI(R('tw', sb(m('τ'), row(tx('w'), o(','), ii))) + o('∈') + sp(m('ℝ'), row(n(2), o('×'), n(2), o('×'), NN('x'), o('×'), NN('z'))))}<span>2 walls × 2 wall-parallel components (x, z) × one per wall face: 2 048 numbers</span></div>
</div>
<span class="eyebrow">What the operators do, on one column of cells</span>
<figure class="viz"><div class="scrollx"><canvas id="wmles-opviz" data-w="880" data-h="340" aria-label="Animated walkthrough on one wall-normal column of cells: G averages the true velocity into cells, M turns the resolved gradient into an eddy viscosity, W solves the log law for the wall stress, P steps and removes divergence"></canvas></div>
  <div class="opctl"><button class="b" id="wmles-opplay">Pause</button><div id="wmles-opsteps" class="btns"></div></div>
  <p class="opcap" id="wmles-opcap"></p></figure>
<aside class="insp" data-terms="G,M,W,P,ub,uf,nut,tw,N"></aside>
<details class="deep"><summary>Going a bit deeper <span class="note">· 3 steps</span></summary>
  <div class="dstep"><span class="k">G</span><div class="dm">${MB(UBi + o('(') + R('xx', m('𝐱')) + o(',') + tt + o(')') + o('=') + o('∫') + OPG + o('(') + R('xx', m('𝐱')) + o('−') + R('xx', sp(m('𝐱'), o('′'))) + o(')') + SPC('.2em') + Ui + o('(') + R('xx', sp(m('𝐱'), o('′'))) + o(',') + tt + o(')') + SPC('.2em') + m('d') + sp(R('xx', sp(m('𝐱'), o('′'))), n(3)))}</div><p>The filter as a convolution: a weighted average of u over a blob of width Δ around 𝐱. In most codes nobody applies G explicitly: the grid and the numerics act as the filter, and Δ is the cell size ("implicit filtering").</p></div>
  <div class="dstep"><span class="k">M</span><div class="dm">${MB(NUT + o('=') + sp(row(o('('), CS, DEL, o(')')), n(2)) + SMAG + SPC('1em') + o('⇒') + SPC('1em') + TAU + o('−') + fr(n(1), n(3)) + R('tau', sb(m('τ'), row(kk, kk))) + DIJ + o('=') + o('−') + n(2) + NUT + SIJ)}</div><p>M is local: each cell needs only the velocity differences to its neighbours. It is nonlinear: |S̄| grows with the strain, so ν_sgs does too.</p></div>
  <div class="dstep"><span class="k">P</span><div class="dm">${MB(sp(bar(m('u')), row(tt, o('+'), DT)) + o('=') + sp(bar(m('u')), tt) + o('+') + DT + o('[') + o('−') + dpar(row(UBi, UBj), xJ(jj)) + o('+') + sb(dd, jj) + o('(') + n(2) + o('(') + NU + o('+') + NUT + o(')') + SIJ + o(')') + o(']') + o('−') + DT + R('p', o('∇')) + R('p', bar(m('p'))))}</div><p>P is one explicit step (here a 3-stage Runge–Kutta) followed by the pressure projection that keeps ∇·ū = 0. The wall model enters as the flux through the wall faces.</p></div>
</details>`;

const BLOCKA = `<div class="eqhero">
  ${MB(UB(UBi + o('(') + R('xx', m('𝐱')) + o(')') + o('=') + o('∫') + OPG + o('(') + R('xx', m('𝐱')) + o('−') + R('xx', sp(m('𝐱'), o('′'))) + o(';') + DEL + o(')') + Ui + o('(') + R('xx', sp(m('𝐱'), o('′'))) + o(')') + SPC('.2em') + m('d') + sp(R('xx', sp(m('𝐱'), o('′'))), n(3)), 'G', 'G: blur at width Δ'), 'sm')}
  ${MB(UB(dpar(UBi, tt) + o('+') + dpar(row(UBi, UBj), xJ(jj)) + o('=') + o('−') + dpar(PB, xJ(ii)) + o('+') + NU + fr(sp(dd, n(2)) + UBi, dd + xJ(jj) + dd + xJ(jj)), 'P', 'P: step, then project') + o('−') + UB(dpar(TAU, xJ(jj)), 'M', 'M: subgrid force'))}
  ${MB(TAU + o('=') + R('uf', bar(row(sb(m('u'), ii), sb(m('u'), jj)))) + o('−') + UBi + UBj + SPC('2em') + dpar(UBj, xJ(jj)) + o('=') + n(0), 'sm')}
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="wmles-afviz" data-w="460" data-h="440" aria-label="A 3D turbulent velocity field and the same field filtered at width Delta, the subgrid stress tau_xy on a slice, and the energy spectrum with the filter; drag the cubes to rotate"></canvas>
    <div class="lg"><span style="color:var(--c-f)"><i class="ln"></i>true <math><msub><mi>u</mi><mi>x</mi></msub></math></span><span style="color:var(--c-u)"><i class="ln"></i>filtered <math><msub><mover><mi>u</mi><mo>―</mo></mover><mi>x</mi></msub></math></span><span style="color:var(--c-cs)"><i class="ln dash"></i>filter <math><mi>G</mi></math></span><span class="note">drag to rotate</span></div>
    <div class="ctl"><label for="wmles-adel" class="sym" style="color:var(--c-cs)">Δ</label><input type="range" id="wmles-adel" min="1" max="8" step="1" value="2"><output id="wmles-adelv">2 h</output></div>
    <div class="btns"><button class="b pri" id="wmles-fbox">box filter</button><button class="b" id="wmles-fgau">Gaussian filter</button></div>
    <div class="note" id="wmles-acap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="G,Delta,ub,uf,tau,p,nu,xx,alpha,t,P,M"></aside>
</div>
<details class="deep"><summary>Going a bit deeper <span class="note">· 3 steps</span></summary>
  <div class="dstep"><span class="k">1</span><div class="dm">${MB(bar(row(dpar(Ui, xJ(jj)))) + o('=') + dpar(UBi, xJ(jj)) + SPC('1.5em') + bar(row(dpar(row(Ui, Uj), xJ(jj)))) + o('=') + dpar(R('uf', bar(row(sb(m('u'), ii), sb(m('u'), jj)))), xJ(jj)))}</div><p>Filter the Navier–Stokes equations term by term. With a uniform Δ the filter commutes with derivatives, so every linear term just gets a bar. The quadratic term does not: the average of a product is not the product of the averages.</p></div>
  <div class="dstep"><span class="k">2</span><div class="dm">${MB(R('uf', bar(row(sb(m('u'), ii), sb(m('u'), jj)))) + o('=') + UBi + UBj + o('+') + TAU)}</div><p>Split the product into the part the grid can compute (ū<sub>i</sub>ū<sub>j</sub>) and the rest. The rest, τ<sub>ij</sub>, is the only new unknown: this is the LES closure problem. It has 6 independent components because it is symmetric.</p></div>
  <div class="dstep"><span class="k">3</span><div class="dm">${MB(R('tau', m('Π')) + o('=') + o('−') + TAU + SIJ + SPC('1em') + o('>') + n(0) + SPC('.5em') + tx('on average'))}</div><p>τ<sub>ij</sub>S̄<sub>ij</sub> moves kinetic energy from the resolved eddies to the subgrid ones, where it is dissipated by viscosity. The model must drain energy at this rate, or energy piles up at the grid scale.</p></div>
</details>`;

const BLOCKB = `<div class="eqhero">
  ${MB(TAU + o('−') + fr(n(1), n(3)) + R('tau', sb(m('τ'), row(kk, kk))) + DIJ + o('=') + UB(o('−') + n(2) + NUT + SIJ, 'M', 'M: eddy viscosity'))}
  ${MB(SIJ + o('=') + fr(n(1), n(2)) + o('(') + dpar(UBi, xJ(jj)) + o('+') + dpar(UBj, xJ(ii)) + o(')') + SPC('1.5em') + NUT + o('=') + sp(row(o('('), CS, DEL, o(')')), n(2)) + SMAG + o(',') + SPC('.6em') + SMAG + o('=') + sq(n(2) + SIJ + SIJ), 'sm')}
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="wmles-sgviz" data-w="460" data-h="440" aria-label="A fluid blob of one cell being strained by the resolved flow, with the eddy viscosity of three models, and the eddy viscosity of each model approaching a wall"></canvas>
    <div class="lg"><span style="color:var(--c-nu)"><i class="ln"></i>Smagorinsky</span><span style="color:var(--c-tau)"><i class="ln"></i>Vreman</span><span style="color:var(--c-c)"><i class="ln"></i>WALE</span><span style="color:var(--c-w)"><i class="ln dash"></i>Smag. + van Driest</span></div>
    <div class="ctl"><label for="wmles-bcs" class="sym" style="color:var(--c-nu)">C<sub>s</sub></label><input type="range" id="wmles-bcs" min="0.05" max="0.25" step="0.01" value="0.17"><output id="wmles-bcsv">0.17</output></div>
    <div class="btns" id="wmles-bcase"><button class="b pri" data-c="0">near-wall shear</button><button class="b" data-c="1">3D strain</button><button class="b" data-c="2">pure rotation</button></div>
    <div class="note" id="wmles-bcap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="M,tau,S,Smag,nut,Cs,Delta,delta,nu,alpha"></aside>
</div>
<details class="deep"><summary>Going a bit deeper <span class="note">· 3 steps</span></summary>
  <div class="dstep"><span class="k">1</span><div class="dm">${MB(R('tau', m('Π')) + o('=') + n(2) + NUT + SIJ + SIJ + o('=') + NUT + sp(SMAG, n(2)) + SPC('.6em') + o('≈') + SPC('.6em') + m('ε') + SPC('1em') + o('⇒') + SPC('1em') + CS + o('≈') + n('0.17'))}</div><p>Where C<sub>s</sub> comes from (Lilly 1967): if the energy drained at the grid scale equals the dissipation ε of a Kolmogorov −5/3 spectrum, the constant comes out near 0.17. In channels about 0.1 is used, because mean shear inflates |S̄|.</p></div>
  <div class="dstep"><span class="k">2</span><div class="dm">${MB(NUT + o('→') + sp(row(o('('), CS, DEL, o(')')), n(2)) + o('|') + fr(m('d') + m('U'), m('d') + m('y')) + o('|') + o('≠') + n(0) + SPC('1.5em') + tx('but the truth is ') + NUT + o('∝') + sp(m('y'), n(3)))}</div><p>The wall problem: the mean shear at a wall is large, so Smagorinsky stays switched on where the true turbulent stress vanishes like y³. The old fix multiplies by van Driest's damping (1 − e<sup>−y⁺/26</sup>)², which needs the wall distance.</p></div>
  <div class="dstep"><span class="k">3</span><div class="dm">${MB(NUT + o('=') + R('Vr', m('c')) + sq(fr(R('Vr', sb(m('B'), m('β'))), row(sb(m('α'), ij), sb(m('α'), ij)))) + o(',') + SPC('.5em') + R('Vr', sb(m('β'), ij)) + o('=') + sp(sb(m('Δ'), m('m')), n(2)) + sb(m('α'), row(m('m'), ii)) + sb(m('α'), row(m('m'), jj)) + o(',') + SPC('.5em') + R('Vr', m('c')) + o('≈') + n('2.5') + sp(CS, n(2)))}</div><p>Vreman (2004) uses only the local gradient α<sub>ij</sub> = ∂ū<sub>j</sub>/∂x<sub>i</sub>, yet B<sub>β</sub> is exactly 0 in pure shear and in many other simple laminar flows, so it switches itself off in near-wall shear and in laminar regions. WALE (Nicoud &amp; Ducros 1999) builds ν<sub>sgs</sub> from the traceless square of the gradient and gets the y³ wall behaviour right.</p></div>
</details>`;

const BLOCKC = `<div class="eqhero">
  ${MB(UB(fr(UPAR, UT) + o('=') + fr(n(1), KAPPA) + m('ln') + o('(') + fr(HWM + SPC('.1em') + UT, NU) + o(')') + o('+') + BC, 'W', 'W: solve for u_τ (Newton)') + SPC('1.5em') + TW + o('=') + RHO + sp(UT, n(2)))}
  ${MB(o('(') + NU + o('+') + NUT + o(')') + sb(row(dpar(UBi, I('y','iy'))), row(o('|'), tx('wall'))) + o('=') + fr(TW, RHO) + fr(UBi, UPAR) + o(',') + SPC('.6em') + ii + o('∈') + o('{') + m('x') + o(',') + m('z') + o('}'), 'sm')}
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="wmles-wmviz" data-w="460" data-h="460" aria-label="Near-wall region: true velocity profile, coarse LES cells, the matching point at h_wm, the log law fitted through it and the resulting wall shear stress; Newton iterations for u_tau"></canvas>
    <div class="lg"><span style="color:var(--c-f)"><i class="ln"></i>true mean profile</span><span style="color:var(--c-u)"><i class="ln"></i>LES cell values</span><span style="color:var(--c-c)"><i class="ln dash"></i>wall model (log law)</span></div>
    <div class="ctl3"><label for="wmles-chwm" class="sym" style="color:var(--c-cs)">h<sub>wm</sub></label><input type="range" id="wmles-chwm" min="0" max="5" step="1" value="0"><output id="wmles-chwmv">1st</output>
      <label for="wmles-cre" class="sym" style="color:var(--c-w)">Re<sub>τ</sub></label><input type="range" id="wmles-cre" min="3" max="5" step="0.05" value="3.3"><output id="wmles-crev">2000</output></div>
    <div class="note" id="wmles-ccap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="W,upar,utau,hwm,kap,Bc,tw,rho,nu,yp,Re"></aside>
</div>
<details class="deep"><summary>Going a bit deeper <span class="note">· 3 steps</span></summary>
  <div class="dstep"><span class="k">1</span><div class="dm">${MB(sb(m('N'), tx('DNS')) + o('∼') + sp(R('Re', sb(m('Re'), sb(m('L'), m('x')))), fr(n(37), n(14))) + o(',') + SPC('1em') + sb(m('N'), tx('wall-resolved')) + o('∼') + sp(R('Re', sb(m('Re'), sb(m('L'), m('x')))), fr(n(13), n(7))) + o(',') + SPC('1em') + sb(m('N'), tx('wall-modelled')) + o('∼') + R('Re', sb(m('Re'), sb(m('L'), m('x')))))}</div><p>Why model the wall (Chapman 1979; Choi &amp; Moin 2012): the eddies of the inner layer are about 100 ν/u<sub>τ</sub> across, and ν/u<sub>τ</sub> shrinks as the Reynolds number grows. Resolving them makes the cell count explode; skipping them leaves only the outer eddies, which scale with δ.</p></div>
  <div class="dstep"><span class="k">2</span><div class="dm">${MB(fr(m('d'), m('d') + I('y','iy')) + o('[') + o('(') + NU + o('+') + sb(m('ν'), m('t')) + o(')') + fr(m('d') + m('U'), m('d') + I('y','iy')) + o(']') + o('=') + n(0) + SPC('1em') + o('⇒') + SPC('1em') + o('(') + NU + o('+') + sb(m('ν'), m('t')) + o(')') + fr(m('d') + m('U'), m('d') + I('y','iy')) + o('=') + fr(TW, RHO))}</div><p>The "equilibrium" assumption: below h<sub>wm</sub>, drop time change, convection and pressure gradient, so the total stress is constant. With ν<sub>t</sub> = κ y u<sub>τ</sub> this integrates exactly to the log law: the wall model is that ODE, solved in closed form.</p></div>
  <div class="dstep"><span class="k">3</span><div class="dm">${MB(HWM + o('≈') + n('0.1') + R('dbl', m('δ')) + SPC('1em') + tx('and') + SPC('1em') + HWM + o('≥') + n(3) + tx('–') + n(5) + SPC('.2em') + R('Delta', m('Δ') + m('y')))}</div><p>Log-layer mismatch (Kawai &amp; Larsson 2012): the first few cells of an LES are under-resolved, so the velocity there is wrong. Feeding it to the wall model gives a wrong τ<sub>w</sub> (errors of up to ~15% in u<sub>τ</sub> are reported) and a log law shifted up. Reading the LES a few cells up, where it is trustworthy, removes the shift.</p></div>
</details>`;

// ---------- checks and final quiz: [question, options, answer, why] ----------
const CHECKS = {
 '0': [
  ['At one cell and one time, what is ū<sub>i</sub> (i free)?', ['One number', 'A vector in ℝ³: the cell\'s filtered velocity', 'A 3×3 matrix'], 1, 'With x, y, z fixed and i free, ū_i has 3 components: one velocity vector per cell.'],
  ['Which operator turns the resolved velocity into the drag on the wall?', ['G, the filter', 'M, the subgrid model', 'W, the wall model'], 2, 'W samples ū at h_wm and returns τ_w, which the step then uses as the momentum flux through the wall.'],
  ['Which of the four operators couples every cell of the grid to every other cell?', ['M', 'W', 'P, through the pressure Poisson equation'], 2, 'M and W are local (a cell and its neighbours, a wall column). Removing divergence needs pressure everywhere at once.'],
  ['What does the LES state NOT contain?', ['The filtered velocity in each cell', 'The eddies smaller than a cell', 'The pressure in each cell'], 1, 'Sub-cell eddies are gone after filtering; their effect comes back only through the model τ_ij.'],
  ['You halve the cell size in all three directions. How many velocities does the state hold?', ['2× as many', '4× as many', '8× as many'], 2, 'Three directions each doubled: 2³ = 8× the cells, each with 3 velocity components.']
 ],
 A: [
  ['Which term of the filtered equations is new compared with Navier–Stokes?', ['∂ū_i/∂t', '−∂τ_ij/∂x_j, the subgrid force', 'ν ∂²ū_i/∂x_j∂x_j'], 1, 'Every other term is the familiar one with bars on; τ_ij = (u_iu_j)‾ − ū_iū_j comes from filtering the nonlinear term.'],
  ['Why can τ_ij not be computed from ū alone?', ['It needs the unfiltered u, which the grid does not store', 'It is too expensive', 'It is always zero'], 0, '(u_iu_j)‾ needs u inside each cell; the LES only knows cell averages. So τ_ij must be modelled.'],
  ['What happens to the filtered field if you make Δ larger?', ['More of the turbulence is resolved', 'More eddies fall below the filter, so τ_ij grows', 'Nothing'], 1, 'A wider blur keeps fewer eddies; the energy they held moves into the subgrid stress.'],
  ['With Δ → 0, what does LES become?', ['RANS', 'DNS: every eddy resolved, τ_ij → 0', 'Potential flow'], 1, 'No blur means ū = u and τ_ij vanishes: the filtered equations are Navier–Stokes again.'],
  ['What does −τ_ij S̄_ij measure?', ['Pressure', 'The energy handed from resolved to subgrid eddies', 'The wall stress'], 1, 'It is the energy flux across the filter scale; on average energy cascades down, so it is positive.']
 ],
 B: [
  ['Smagorinsky sets ν_sgs = (C_sΔ)²|S̄|. If the cell size Δ is halved, ν_sgs…', ['Doubles', 'Drops to a quarter at the same strain', 'Is unchanged'], 1, 'ν_sgs ∝ Δ²: finer grids need less modelling, and as Δ → 0 the model fades away.'],
  ['Why does plain Smagorinsky misbehave next to a wall?', ['It goes negative', 'The mean shear keeps |S̄| large, so ν_sgs stays on where turbulence actually dies out like y³', 'It ignores the pressure'], 1, 'The model cannot tell mean shear from turbulence. Van Driest damping, Vreman or WALE fix that.'],
  ['In pure shear (only ∂ū_x/∂y ≠ 0), the Vreman model gives…', ['The same as Smagorinsky', 'Zero', 'Infinity'], 1, 'With only ∂ū_x/∂y nonzero, Vreman\'s invariant B_β is exactly 0, so laminar shear gets no eddy viscosity.'],
  ['In the Build channel, swapping Vreman for Smagorinsky (same C_s = 0.17) with h_wm in the 1st cell does what?', ['Nothing: the wall model fixes everything', 'The profile overshoots the log law even more, since excess near-wall ν_sgs adds to the mismatch', 'The flow becomes laminar'], 1, 'Measured in this course\'s solver: bulk velocity about 10% above Dean\'s correlation with Smagorinsky vs about 5% with Vreman (both with the first cell).'],
  ['τ_ij − ⅓τ_kkδ_ij = −2ν_sgsS̄_ij. Why only the trace-free part?', ['The trace ⅓τ_kk is absorbed into a modified pressure', 'The trace is always zero', 'To save memory'], 0, 'S̄_ii = 0 (incompressible), so the model can only produce a trace-free stress; the isotropic part acts like pressure and is lumped in.']
 ],
 C: [
  ['What does the wall model solve for?', ['The velocity at the wall', 'The friction velocity u_τ, then τ_w = ρu_τ²', 'The pressure gradient'], 1, 'Given |ū_∥| at h_wm, the log law has one unknown, u_τ; Newton finds it in a few iterations.'],
  ['Why is h_wm placed a few cells off the wall instead of in the first cell?', ['To save time', 'The first cells are under-resolved; their velocity gives a shifted log law (log-layer mismatch)', 'The log law is invalid above the first cell'], 1, 'Kawai & Larsson (2012): read the LES where it is accurate; the wall model covers the rest.'],
  ['κ = 0.41 and B = 5.2. What is u/u_τ at y⁺ = 1000 in the log layer?', ['≈ 22.0', '≈ 5.2', '≈ 41'], 0, '(1/0.41)·ln 1000 + 5.2 = 16.85 + 5.2 = 22.0.'],
  ['Cost of wall-resolved LES grows like Re^{13/7}; wall-modelled like Re. What happens at 10× the Reynolds number?', ['Both ×10', 'Wall-resolved ×72, wall-modelled ×10', 'Both ×72'], 1, '10^{13/7} ≈ 72 vs 10¹ = 10 (Choi & Moin 2012).'],
  ['The equilibrium wall model assumes…', ['Constant total stress between the wall and h_wm', 'A separated flow', 'No viscosity anywhere'], 0, 'Dropping convection, pressure gradient and time change below h_wm makes the stress constant, giving the log law. Strong pressure gradients and separation break this.']
 ]
};
const QUIZ = [
 ['What does LES resolve and what does it model?', ['Resolves the mean, models all turbulence', 'Resolves eddies larger than Δ, models the smaller ones through τ_ij', 'Resolves everything'], 1, 'The filter splits the scales; only the subgrid part needs a model, which is why LES is more universal than RANS.'],
 ['Why is a wall-resolved LES of an aircraft wing still out of reach?', ['The far field is too large', 'Near-wall eddies shrink like ν/u_τ, so the grid grows like Re^{13/7}', 'The time step is fixed'], 1, 'At flight Reynolds numbers this means far more cells than with a wall model, whose cost grows only like Re.'],
 ['Where does the wall model plug into the LES?', ['It replaces the no-slip condition by a prescribed wall shear stress τ_w', 'It changes the pressure equation', 'It adds a source in the centre of the channel'], 0, 'The LES sees the wall only through the momentum flux τ_w on the wall faces; the wall-normal velocity stays zero.'],
 ['Moving h_wm from the 1st to the 3rd cell in the Build solver makes the mean profile…', ['Move further from the log law', 'Fall back onto the log law: the log-layer mismatch shrinks', 'Turn laminar'], 1, 'Measured here: bulk velocity from about 4–5% above Dean\'s correlation to within about 1%.'],
 ['Which step of a WMLES time step needs global communication on a cluster?', ['The wall model', 'The SGS model', 'The pressure Poisson solve'], 2, 'Explicit fluxes, ν_sgs and the wall model use only neighbours; the Poisson equation couples every cell (FFT transposes or multigrid).'],
 ['Why might the equilibrium wall model fail behind a bump where the flow separates?', ['Separation violates the constant-stress, log-law assumption', 'The grid is too fine', 'Vreman turns off'], 0, 'With strong pressure gradients or reverse flow, the near-wall profile is not a log law; non-equilibrium (ODE/PDE) wall models add those terms.'],
 ['Why is Vreman a better default than plain Smagorinsky in wall-bounded LES?', ['It is cheaper', 'It switches itself off in pure shear and laminar regions without wall-distance damping', 'It has no constant'], 1, 'B_β = 0 in pure shear, so it adds no spurious viscosity at walls or in laminar parts of the flow.'],
 ['Doubling Re_τ in the Build solver (same grid) costs…', ['About the same per step: the wall model absorbs the thinner inner layer', '2^{13/7} more cells', '8× more'], 0, 'Only ν in the wall model changes; the outer eddies the grid resolves scale with δ, not with ν/u_τ.']
];

const BUILD = {
  intro: 'Put the steps of one wall-modelled LES time step in order. When it\'s right, your 3D channel solver runs below: 32 × 24 × 16 cells between two walls, the Vreman subgrid model and the equilibrium wall model on both walls.',
  html: `<div class="scrollx"><canvas class="sim" id="wmles-sim" data-w="760" data-h="400" aria-label="Your 3D wall-modelled LES of a channel: streaks on a plane at the matching height, the streamwise velocity on the back walls, the running mean profile against the log law and the wall-model shear stress over time"></canvas></div>
  <div class="row"><label for="wmles-hwm">h<sub>wm</sub> = <span id="wmles-hwmv"></span></label><input type="range" id="wmles-hwm" min="0" max="3" step="1" value="2"><span class="note" id="wmles-hwmn"></span></div>
  <div class="row"><span class="note">subgrid model</span><button class="b pri" id="wmles-mv">Vreman</button><button class="b" id="wmles-ms">Smagorinsky</button><span class="note">Re<sub>τ</sub></span><button class="b pri" id="wmles-r2">2 000</button><button class="b" id="wmles-r5">5 200</button><button class="b" id="wmles-r20">20 000</button><button class="b" id="wmles-run">Run 1 δ/u<sub>τ</sub></button></div>
  <p class="note" id="wmles-simcap">&nbsp;</p>`,
  steps: ['Sample ū at h_wm above every wall face', 'Newton-solve the log law for u_τ; τ_w = ρu_τ²', 'Compute ν_sgs from the resolved gradients', 'Explicit step: advection + (ν + ν_sgs) stress, τ_w as wall flux → u*', 'Solve the pressure Poisson equation ∇²φ = ∇·u*', 'Project: ū = u* − ∇φ, now divergence-free'],
  hint: 'Work from the wall inward: the wall stress (sample first, then solve) and the subgrid viscosity are inputs to the fluxes. The pressure solve needs u*, and the correction needs φ.',
  success: 'Your wall-modelled LES is running: 12 288 cells at Re_τ = 2 000, where a wall-resolved LES needs millions. Statistics start one eddy turnover after each change. Drag h_wm to the 1st cell and watch the profile rise above the log law: the log-layer mismatch.'
};

const PARALLEL = `<div class="par">
  <div class="stack">
    <p><strong>Local work</strong>: the fluxes, the explicit step and ν<sub>sgs</sub> use one layer of neighbours. Split the grid into blocks, one per GPU or core, and swap a one-cell halo with the neighbours each stage.</p>
    <p><strong>The wall model is local too</strong>: one Newton solve per wall face, independent of every other face. It is a thin 2D layer of work: <span id="wmles-wmshare">a small share</span> of a step in your Build solver.</p>
    <p><strong>The pressure Poisson equation is global</strong>: ∇²φ = ∇·u* couples every cell to every other. With periodic x and z, FFTs turn it into one small tridiagonal solve per Fourier mode, but each FFT needs a whole line of data on one processor: the grid must be <strong>transposed</strong> (all-to-all messages) between directions. Without periodicity, multigrid does the job with neighbour exchanges on ever coarser grids.</p>
  </div>
  <canvas id="wmles-pencil" data-w="320" data-h="260" style="width:100%;max-width:320px;border-radius:8px;background:var(--bg)" aria-label="A 3D grid split into pencils owned by 4 processors, transposed between x-, z- and y-pencils during the pressure solve"></canvas>
</div>
<span class="eyebrow">Run one pressure solve on 4 processors (2 × 2 pencils): click the stages in order</span>
<div class="btns" id="wmles-pstages"></div>
<div class="fb" id="wmles-pfb"></div>
<h3 style="font-size:16px">Why wall models at all: cost against Reynolds number</h3>
<div class="ctl"><label for="wmles-pre" class="sym">Re<sub>Lx</sub></label><input type="range" id="wmles-pre" min="6" max="10" step="0.1" value="8"><output id="wmles-prev"></output></div>
<canvas id="wmles-cost" data-w="560" data-h="190" style="width:100%;max-width:560px;border-radius:8px;background:var(--bg)" aria-label="Growth of the grid-point count from Re = 10^6 for wall-modelled LES, wall-resolved LES and DNS"></canvas>
<p class="note">Growth factors only (exponents from Choi &amp; Moin 2012: N ∝ Re<sub>Lx</sub>, Re<sub>Lx</sub><sup>13/7</sup>, Re<sub>Lx</sub><sup>37/14</sup>); each bar is the factor by which that method's grid grows from Re<sub>Lx</sub> = 10⁶. An airliner wing is around Re<sub>Lx</sub> ≈ 10⁷–10⁸.</p>
<details><summary>Further optimizations</summary><p>Use real-to-complex FFTs (half the data), overlap transposes with computation, and keep the tridiagonal y-solves on the processor that owns the y-pencil. On GPUs, the FFTs and transposes dominate; the explicit stencil and wall model are memory-bound and fast.</p></details>`;
// ---------- every symbol: plain definition, where it lives, colour, and the operator that explains it ----------
const NXYZ = row(sb(m('N'), m('x')), o('×'), sb(m('N'), m('y')), o('×'), sb(m('N'), m('z')));
const TERMS = {
 ub: { sym: sb(bar(m('u')), m('i')), name: 'Filtered velocity', def: 'What the grid holds: the velocity averaged over a cell-sized blob. Component i is along x, y or z.', space: sb(bar(m('u')), m('i')) + o('∈') + m('ℝ') + tx(' per cell,') + SPC('.4em') + bar(m('u')) + o('∈') + sp(m('ℝ'), row(n(3), o('×'), NXYZ)), col: '--c-u' },
 uf: { sym: sb(m('u'), m('i')), name: 'True velocity', def: 'The real velocity with every eddy down to the smallest. The LES never stores it; it only appears inside the filter and in τᵢⱼ.', space: sb(m('u'), m('i')) + o(':') + sp(m('ℝ'), n(3)) + o('×') + m('ℝ') + o('→') + m('ℝ') + tx(' (a continuous field)'), col: '--c-f' },
 p: { sym: bar(m('p')), name: 'Filtered pressure', def: 'Pressure divided by density (kinematic). It is whatever it must be to keep ∇·ū = 0; the projection P computes it.', space: bar(m('p')) + o('∈') + sp(m('ℝ'), NXYZ), col: '--c-rho', op: 'P' },
 phi: { sym: m('φ'), name: 'Pressure correction', def: 'The potential whose gradient removes the divergence of u*: φ = Δt·p̄ for one stage.', space: m('φ') + o('∈') + sp(m('ℝ'), NXYZ), col: '--c-rho', op: 'P' },
 G: { sym: m('G'), name: 'Filter G', def: 'A blur: weights that average u over a neighbourhood of width Δ and add up to 1. Box (plain average) or Gaussian (soft edges).', space: m('G') + o(':') + sp(m('ℝ'), n(3)) + o('→') + sb(m('ℝ'), row(o('≥'), n(0))) + o(',') + SPC('.4em') + o('∫') + m('G') + SPC('.15em') + m('d') + sp(m('𝐱'), n(3)) + o('=') + n(1), col: '--c-cs', op: 'G' },
 Delta: { sym: m('Δ'), name: 'Filter width', def: 'Size of the blur; in practice the cell size, Δ = (Δx Δy Δz)^⅓. Eddies smaller than Δ are subgrid.', space: m('Δ') + o('∈') + sb(m('ℝ'), row(o('>'), n(0))) + tx(' (a length)'), col: '--c-cs', op: 'G' },
 tau: { sym: sb(m('τ'), row(m('i'), m('j'))), name: 'Subgrid stress', def: 'The momentum carried by the eddies smaller than Δ: (uᵢuⱼ)‾ − ūᵢūⱼ. It needs the true u, so it must be modelled.', space: sb(m('τ'), row(m('i'), m('j'))) + o('∈') + sp(m('ℝ'), row(n(3), o('×'), n(3))) + tx(' symmetric, per cell'), col: '--c-tau', op: 'M' },
 S: { sym: sb(bar(m('S')), row(m('i'), m('j'))), name: 'Resolved strain rate', def: 'How fast the resolved flow stretches and squeezes a fluid blob: the symmetric half of the velocity gradient. Rotation is left out.', space: sb(bar(m('S')), row(m('i'), m('j'))) + o('∈') + sp(m('ℝ'), row(n(3), o('×'), n(3))) + tx(' symmetric, trace 0'), col: '--c-eq', op: 'M' },
 Smag: { sym: o('|') + bar(m('S')) + o('|'), name: 'Strain magnitude', def: '√(2S̄ᵢⱼS̄ᵢⱼ): one number per cell saying how hard the resolved flow is straining (units 1/s).', space: o('|') + bar(m('S')) + o('|') + o('∈') + sb(m('ℝ'), row(o('≥'), n(0))), col: '--c-eq', op: 'M' },
 nut: { sym: sb(m('ν'), tx('sgs')), name: 'Subgrid (eddy) viscosity', def: 'Extra viscosity that stands in for the eddies smaller than Δ: they mix momentum like a much thicker fluid. Often 10–100× ν.', space: sb(m('ν'), tx('sgs')) + o('∈') + sb(m('ℝ'), row(o('≥'), n(0))) + tx(' per cell'), col: '--c-nu', op: 'M' },
 nu: { sym: m('ν'), name: 'Molecular viscosity', def: 'The fluid\'s own viscosity, 1.5 × 10⁻⁵ m²/s for air. In wall units ν = 1/Re_τ.', space: m('ν') + o('∈') + sb(m('ℝ'), row(o('>'), n(0))) + tx(' (constant)'), col: '--c-w' },
 Cs: { sym: sb(m('C'), m('s')), name: 'Smagorinsky constant', def: '≈ 0.17 from isotropic turbulence (Lilly); about 0.1 in channels. Sets the model length C_sΔ.', space: sb(m('C'), m('s')) + o('∈') + o('(') + n(0) + o(',') + n('0.25') + o(')') + tx(' (a model constant)'), col: '--c-nu', op: 'M' },
 delta: { sym: sb(m('δ'), row(m('i'), m('j'))), name: 'Kronecker delta', def: '1 if i = j, else 0: the 3×3 identity written with indices.', space: sb(m('δ'), row(m('i'), m('j'))) + o('∈') + sp(m('ℝ'), row(n(3), o('×'), n(3))), col: '--c-w' },
 alpha: { sym: row(m('i'), o(','), m('j'), o(','), m('k')), name: 'Axis index', def: 'x, y or z. An index repeated in one term is summed over all three (Einstein convention).', space: m('i') + o(',') + m('j') + o(',') + m('k') + o('∈') + o('{') + m('x') + o(',') + m('y') + o(',') + m('z') + o('}'), col: '--ink' },
 xx: { sym: sb(m('x'), m('j')), name: 'Position', def: 'Component j of the position 𝐱 = (x, y, z): x along the flow, y away from the wall, z across.', space: m('𝐱') + o('∈') + sp(m('ℝ'), n(3)) + o(',') + SPC('.4em') + sb(m('x'), m('j')) + o('∈') + m('ℝ'), col: '--ink' },
 ix: { sym: m('x'), name: 'Cell column', def: 'Which cell along the flow, 0 … Nₓ−1 (periodic).', space: m('x') + o('∈') + o('{') + n(0) + o(',') + o('…') + o(',') + sb(m('N'), m('x')) + o('−') + n(1) + o('}'), col: '--ink' },
 iy: { sym: m('y'), name: 'Wall-normal row / distance', def: 'As an index: which row from the bottom wall, 0 … N_y−1. In a derivative: the distance from the wall.', space: m('y') + o('∈') + o('{') + n(0) + o(',') + o('…') + o(',') + sb(m('N'), m('y')) + o('−') + n(1) + o('}'), col: '--ink' },
 iz: { sym: m('z'), name: 'Cell layer', def: 'Which cell across the flow, 0 … N_z−1 (periodic).', space: m('z') + o('∈') + o('{') + n(0) + o(',') + o('…') + o(',') + sb(m('N'), m('z')) + o('−') + n(1) + o('}'), col: '--ink' },
 t: { sym: m('t'), name: 'Time level', def: 'Which step: 0, Δt, 2Δt, … As a superscript it labels the time; it is not a power.', space: m('t') + o('∈') + o('{') + n(0) + o(',') + m('Δ') + m('t') + o(',') + n(2) + m('Δ') + m('t') + o(',') + o('…') + o('}'), col: '--c-w' },
 dt: { sym: m('Δ') + m('t'), name: 'Time step', def: 'One update. Explicit, so it must stay below the CFL limit: a fluid parcel may cross at most about one cell per step.', space: m('Δ') + m('t') + o('∈') + sb(m('ℝ'), row(o('>'), n(0))), col: '--c-w' },
 N: { sym: row(sb(m('N'), m('x')), o(','), sb(m('N'), m('y')), o(','), sb(m('N'), m('z'))), name: 'Grid size', def: 'Cells along x, y and z: 32 × 24 × 16 in the Build step.', space: sb(m('N'), m('x')) + o(',') + sb(m('N'), m('y')) + o(',') + sb(m('N'), m('z')) + o('∈') + m('ℕ'), col: '--ink' },
 lab: { sym: tx('w, sgs, wm'), name: 'Labels', def: 'Names, not indices: w = at the wall, sgs = subgrid scale, wm = wall model.', space: tx('text labels (no range, no summation)'), col: '--c-w' },
 M: { sym: m('M'), name: 'Subgrid model M', def: 'From the resolved velocity gradient in each cell, an eddy viscosity ν_sgs, and from it the subgrid stress τᵢⱼ = −2ν_sgsS̄ᵢⱼ. A tax on resolved motion that pays for the eddies you cannot see.', space: m('M') + o(':') + sp(m('ℝ'), row(n(3), o('×'), NXYZ)) + o('→') + sp(m('ℝ'), NXYZ) + o(',') + SPC('.4em') + tx('local, nonlinear'), col: '--c-tau', op: 'M' },
 W: { sym: m('W'), name: 'Wall model W', def: 'Reads the LES velocity at h_wm above every wall face, solves the law of the wall for u_τ and returns the wall shear stress. Like reading a speedometer to know the toll.', space: m('W') + o(':') + sp(m('ℝ'), row(n(3), o('×'), NXYZ)) + o('→') + sp(m('ℝ'), row(n(2), o('×'), n(2), o('×'), sb(m('N'), m('x')), o('×'), sb(m('N'), m('z')))) + o(',') + SPC('.4em') + tx('per wall face'), col: '--c-c', op: 'W' },
 P: { sym: m('P'), name: 'Step-and-project map P', def: 'One explicit time step with all fluxes (advection, ν + ν_sgs, τ_w at the walls, the driving pressure gradient), then the pressure projection that makes ∇·ū = 0.', space: m('P') + o(':') + sp(m('ℝ'), row(n(3), o('×'), NXYZ)) + o('→') + sp(m('ℝ'), row(n(3), o('×'), NXYZ)) + o(',') + SPC('.4em') + tx('global (Poisson)'), col: '--c-rho', op: 'P' },
 utau: { sym: sb(m('u'), m('τ')), name: 'Friction velocity', def: '√(τ_w/ρ): the velocity scale of the near-wall eddies. Wall units: y⁺ = y u_τ/ν, u⁺ = u/u_τ.', space: sb(m('u'), m('τ')) + o('∈') + sb(m('ℝ'), row(o('>'), n(0))) + tx(' per wall face'), col: '--c-c', op: 'W' },
 tw: { sym: sb(m('τ'), tx('w')), name: 'Wall shear stress', def: 'Drag per unit wall area, ρu_τ². Its x and z parts point along the near-wall flow. The LES sees the wall only through it.', space: sb(m('τ'), row(tx('w'), o(','), m('i'))) + o('∈') + sp(m('ℝ'), row(n(2), o('×'), n(2), o('×'), sb(m('N'), m('x')), o('×'), sb(m('N'), m('z')))), col: '--c-c', op: 'W' },
 hwm: { sym: sb(m('h'), tx('wm')), name: 'Matching height', def: 'Where the wall model reads the LES: about 0.1δ and at least a few cells off the wall, so the LES value there is trustworthy.', space: sb(m('h'), tx('wm')) + o('∈') + o('(') + n(0) + o(',') + m('δ') + o(')'), col: '--c-cs', op: 'W' },
 upar: { sym: o('|') + sb(bar(m('u')), o('∥')) + o('|'), name: 'Wall-parallel speed', def: 'Speed of the LES flow parallel to the wall at h_wm: √(ūₓ² + ū_z²). The wall model\'s only input.', space: o('|') + sb(bar(m('u')), o('∥')) + o('|') + o('∈') + sb(m('ℝ'), row(o('≥'), n(0))) + tx(' per wall face'), col: '--c-u', op: 'W' },
 kap: { sym: m('κ'), name: 'von Kármán constant', def: '0.41: the slope of the log law, 1/κ ≈ 2.44 u_τ per factor e in wall distance. Close to universal.', space: m('κ') + o('=') + n('0.41') + tx(' (empirical constant)'), col: '--c-w', op: 'W' },
 Bc: { sym: m('B'), name: 'Log-law intercept', def: '≈ 5.2 for a smooth wall: u⁺ of the log law extended down to y⁺ = 1. Roughness lowers it.', space: m('B') + o('≈') + n('5.2') + tx(' (empirical constant)'), col: '--c-w', op: 'W' },
 rho: { sym: m('ρ'), name: 'Density', def: 'Constant here (incompressible flow); 1.2 kg/m³ for air.', space: m('ρ') + o('∈') + sb(m('ℝ'), row(o('>'), n(0))), col: '--c-rho' },
 yp: { sym: sp(m('y'), o('+')), name: 'Wall units', def: 'Distance from the wall in viscous lengths: y⁺ = y u_τ/ν. Sublayer y⁺ < 5, log layer y⁺ ≳ 30 up to about 0.15δ.', space: sp(m('y'), o('+')) + o('∈') + sb(m('ℝ'), row(o('≥'), n(0))) + tx(' (dimensionless)'), col: '--c-w' },
 Re: { sym: sb(m('Re'), m('τ')), name: 'Reynolds number', def: 'Re_τ = δu_τ/ν: how many viscous lengths fit in the boundary layer. Re_Lx = U x/ν is the plate-length version.', space: sb(m('Re'), m('τ')) + o('∈') + sb(m('ℝ'), row(o('>'), n(0))), col: '--c-w' },
 dbl: { sym: m('δ'), name: 'Outer length', def: 'Boundary-layer thickness, or the channel half-height. The big eddies are about δ in size.', space: m('δ') + o('∈') + sb(m('ℝ'), row(o('>'), n(0))), col: '--c-cs' },
 Vr: { sym: sb(m('B'), m('β')), name: 'Vreman\'s invariant', def: 'Built from β_ij = Δ_m²α_miα_mj; exactly zero in pure shear and many other simple laminar flows, so the model switches off there. c ≈ 2.5C_s².', space: sb(m('B'), m('β')) + o('∈') + sb(m('ℝ'), row(o('≥'), n(0))) + tx(' per cell'), col: '--c-tau', op: 'M' }
};
const SOURCES = [
 ['Smagorinsky, General circulation experiments with the primitive equations, Mon. Weather Rev. 1963', 'https://doi.org/10.1175/1520-0493(1963)091%3C0099:GCEWTP%3E2.3.CO;2'],
 ['Vreman, An eddy-viscosity subgrid-scale model for turbulent shear flow, Phys. Fluids 16, 2004', 'https://doi.org/10.1063/1.1785131'],
 ['Nicoud & Ducros, Subgrid-scale stress modelling based on the square of the velocity gradient tensor (WALE), Flow Turb. Combust. 62, 1999', 'https://doi.org/10.1023/A:1009995426001'],
 ['Nicoud, Toda, Cabrit, Bose & Lee, Using singular values to build a subgrid-scale model (near-wall behaviour of models), Phys. Fluids 23, 2011', 'https://doi.org/10.1063/1.3623274'],
 ['Pope, Ten questions concerning the large-eddy simulation of turbulent flows, New J. Phys. 6, 2004', 'https://doi.org/10.1088/1367-2630/6/1/035'],
 ['Chapman, Computational aerodynamics development and outlook, AIAA J. 17, 1979', 'https://doi.org/10.2514/3.61311'],
 ['Choi & Moin, Grid-point requirements for large eddy simulation: Chapman\'s estimates revisited, Phys. Fluids 24, 2012', 'https://doi.org/10.1063/1.3676783'],
 ['Kawai & Larsson, Wall-modeling in large eddy simulation: length scales, grid resolution, and accuracy, Phys. Fluids 24, 2012', 'https://doi.org/10.1063/1.3678331'],
 ['Larsson, Kawai, Bodart & Bermejo-Moreno, Large eddy simulation with modeled wall-stress: recent progress and future directions, Mech. Eng. Rev. 3, 2016', 'https://doi.org/10.1299/mer.15-00418'],
 ['Bose & Park, Wall-modeled large-eddy simulation for complex turbulent flows, Annu. Rev. Fluid Mech. 50, 2018', 'https://doi.org/10.1146/annurev-fluid-122316-045241'],
 ['Reichardt, Vollständige Darstellung der turbulenten Geschwindigkeitsverteilung in glatten Leitungen, ZAMM 31, 1951', 'https://doi.org/10.1002/zamm.19510310704'],
 ['Dean, Reynolds number dependence of skin friction and other bulk flow variables in two-dimensional rectangular duct flow, J. Fluids Eng. 100, 1978', 'https://doi.org/10.1115/1.3448633'],
 ['Williamson, Low-storage Runge–Kutta schemes, J. Comput. Phys. 35, 1980', 'https://doi.org/10.1016/0021-9991(80)90033-9'],
 ['Pekurovsky, P3DFFT: a framework for parallel computations of Fourier transforms in three dimensions (pencil decomposition), SIAM J. Sci. Comput. 34, 2012', 'https://doi.org/10.1137/11082748X']
];

// ---------- the module ----------
CFD.register({
 id: 'wmles', name: 'Wall-modelled LES', sub: 'filtered equations',
 lede: 'The grid keeps only the eddies bigger than a cell (<strong>filter</strong>); a <strong>subgrid model</strong> stands in for the rest, and a <strong>wall model</strong> replaces the thin layer at the wall that no affordable grid can resolve.',
 blocks: [
  { key: '0', title: 'The objects', note: 'what goes in, what comes out', html: BLOCK0 },
  { key: 'A', title: 'Filtered equations', note: 'blur, then one new term', html: BLOCKA },
  { key: 'B', title: 'Subgrid model', note: 'the eddies you cannot see', html: BLOCKB },
  { key: 'C', title: 'Wall model', note: 'skip the inner layer', html: BLOCKC } ],
 checks: CHECKS, quiz: QUIZ, build: BUILD, parallel: { html: PARALLEL },
 unlock: 'The Wall-modelled LES row of the comparison is now visible: unsteady 3D eddies at a cost that grows only like Re, paid for by a wall stress that comes from an equilibrium model. Complete the other methods to open the full page.',
 sources: SOURCES, terms: TERMS,
 bench(){
  const S = Channel({ jh: 2 }); for (let k=0;k<8;k++) S.step(); S.tWall = 0; S.tTot = 0;
  const N = 12, st = []; for (let k=0;k<3*N;k++){ S.stage(); st.push(S.tStage); } const ms = st.reduce((a,b) => a+b, 0)/N, smax = Math.max(...st);
  const t1 = now(), F = makeField(3), t2 = now(); filterField(F, 2, false); const t3 = now();
  return `channel 32×24×16: ${ms.toFixed(2)} ms per time step = 3 RK stages scheduled one at a time (mean ${(ms/3).toFixed(2)}, max ${smax.toFixed(2)} ms per stage call, budget 9 ms/frame); wall model ${(100*S.tWall/S.tTot).toFixed(1)}% of the work; max|∇·u| ${S.divMax().toExponential(1)}; ` +
    `block A: field ${(t2-t1).toFixed(0)} ms once at mount, re-filter ${(t3-t2).toFixed(0)} ms per slider move (at most once per frame)`; },
 mount(root, K){
const { $, reduce, MONO, MATH, P, hex, hidpi, arrow, rr, pill, label, ease, lerp, clamp, proj, box, orbit, isAct } = K;
const triad = K.triad;
const F9 = '9px "IBM Plex Mono", monospace', F10 = '10px "IBM Plex Mono", monospace', F11 = '11px "IBM Plex Mono", monospace', FB = '600 11px "IBM Plex Mono", monospace', FT = '600 12px "IBM Plex Sans", sans-serif';
const fx = (v, d=2) => (+v).toFixed(d), ex = v => v === 0 ? '0' : Math.abs(v) < 1e-3 ? v.toExponential(1) : fx(v, 3);
// colour maps built from the palette, so light and dark both work
const cols = p => ({ bg: hex(p.bg), a: hex(p.acc), w: hex(p.warm), u: hex(p.u), f: hex(p.f), panel: hex(p.panel) });
const divc = (cs, s) => { const t = Math.min(1, Math.abs(s))**.8, c = s > 0 ? cs.a : cs.w; return [c[0], c[1], c[2]].map((v,q) => cs.bg[q] + (v - cs.bg[q])*t); };
const seqc = (cs, s) => { s = clamp(s, 0, 1); return s < .5 ? cs.bg.map((v,q) => v + (cs.f[q]-v)*s*2) : cs.f.map((v,q) => v + (cs.u[q]-v)*(s-.5)*2); };
function surf(w, h){ const cv = document.createElement('canvas'); cv.width = w; cv.height = h; const cx = cv.getContext('2d'); return { cv, cx, img: cx.createImageData(w, h) }; }
const put = (S, x, y, c) => { const o = (y*S.img.width + x)*4; S.img.data[o] = c[0]; S.img.data[o+1] = c[1]; S.img.data[o+2] = c[2]; S.img.data[o+3] = 255; };
// draw an image onto a 3D face: A = image corner (0,0), B = end of the first image row, D = end of the first image column (screen points)
function face(c, S, A, B, D, alpha){ S.cx.putImageData(S.img, 0, 0); c.save(); c.globalAlpha = alpha || 1; c.imageSmoothingEnabled = true;
  c.transform((B[0]-A[0])/S.cv.width, (B[1]-A[1])/S.cv.width, (D[0]-A[0])/S.cv.height, (D[1]-A[1])/S.cv.height, A[0], A[1]); c.drawImage(S.cv, 0, 0); c.restore(); }
const RE0 = 2000, NU0 = 1/RE0;

// ===== 0: one wall-normal column of cells (12 cells, wall → centre), true velocity with synthetic eddies =====
const NYC = 12, NF = 20, DYC = 1/NYC;
const colSig = (seed, amp, mean) => { const r = rng(seed), md = [...Array(24)].map((_,q) => ({ k: 2*Math.PI*(q+1)*1.3, a: amp*Math.pow(q+1, -5/6), ph: r()*6.283 }));
  return [...Array(NYC*NF)].map((_,s) => { const y = (s+.5)/(NYC*NF); let f = 0; md.forEach(d => f += d.a*Math.sin(d.k*y + d.ph)); return (mean ? spald(y*RE0) : 0) + f*Math.tanh(y*RE0/40); }); };
const colU = colSig(7, 1.0, true), colV = colSig(23, .7, false), colW = colSig(37, .9, false);
const cav = arr => [...Array(NYC)].map((_,j) => arr.slice(j*NF, (j+1)*NF).reduce((a,b) => a+b, 0)/NF);
const barU = cav(colU), barV = cav(colV), barW = cav(colW);
const DXB = Math.PI/32, DYB = 1/12, DZB = Math.PI/32, GA = [0.9, (barU[5]-barU[3])/(2*DYC), 0.6, -0.4, -0.5, 0.3, 1.1, -0.8, -0.4];
const mod0 = sgsModels(GA, [DXB, DYB, DZB], 0.17, 0.325), JH0 = 2, H0 = (JH0+.5)*DYC, its0 = newtonIts(barU[JH0], H0, NU0, 0.5, 6), q0 = its0[its0.length-1];
const PD = projDemo(5);
const OPS = [
 ['ū', 'Start: one column of the 3D grid, from the wall (bottom) to the channel centre: 12 cells. The state stores ū, one velocity vector per cell; the true velocity u (thin line) wiggles on scales far below a cell.'],
 ['G', `G blurs: each cell keeps only the average of u over its own box of width Δ, like a low-resolution photo. Cell 5: the mean of its ${NF} samples is ū = ${fx(barU[4])}. Click G to see how the weights work.`],
 ['M', `M reads how ū changes between neighbouring cells (the 3×3 gradient), keeps the stretching part S̄ᵢⱼ, squeezes it into one size |S̄| = ${fx(mod0.Smag,1)} and returns ν_sgs = ${ex(mod0.smag)}: ${fx(mod0.smag/NU0,0)}× the fluid's own viscosity. A tax on the resolved motion that pays for the eddies you cannot see.`],
 ['W', `W reads |ū∥| = ${fx(barU[JH0])} at h_wm = ${fx(H0,3)}δ and asks the law of the wall which friction velocity gives that speed at that height. Newton gets u_τ = ${fx(q0,4)} in ${its0.length-1} tries; τ_w = ρu_τ² = ${fx(q0*q0,3)} goes back as the wall's drag. Like reading a speedometer to know the toll.`],
 ['P', `P takes one explicit step with all these fluxes, then projects: pressure pushes back until no cell gains or loses volume. Like squeezing a water balloon: it cannot compress, it only bulges elsewhere. Real 8³ example: max |∇·u*| = ${fx(PD.mx0)} → ${PD.mx1.toExponential(1)}.`]];
let opStage = 0, opT = 0, opPlay = !reduce, opLast = null; const OPT = 4.2;
const opBtns = $('opsteps');
opBtns.innerHTML = OPS.map(([nm],k) => `<button class="b opb" data-k="${k}">${k+1} · ${nm}</button>`).join('');
opBtns.onclick = e => { const b = e.target.closest('.opb'); if (!b) return; opStage = +b.dataset.k; opT = 0; opCap(); K.pin([null,'G','M','W','P'][opStage]); if (reduce) drawOps(0); };
$('opplay').onclick = e => { opPlay = !opPlay; e.target.textContent = opPlay ? 'Pause' : 'Play'; };
function opCap(){ $('opcap').textContent = OPS[opStage][1]; opBtns.querySelectorAll('.opb').forEach((b,k) => b.classList.toggle('pri', k === opStage)); }
opCap();
const CO = hidpi($('opviz'));
// the 8×8 mid-slice of the projection demo: arrows (u_x, u_y), cells shaded by |∇·u|
function projSlice(c, p, x0, y0, sz, which, e, showDiv, D){ D = D || PD; const nn = D.nn, cw = sz/nn, k = nn>>1, cs = cols(p), A = D.before, B = D.after;
  for (let j=0;j<nn;j++) for (let i=0;i<nn;i++){ const d = showDiv ? D.D0[D.id(i,j,k)]*(1-e) : 0, cc = divc(cs, d/D.mx0);
    c.fillStyle = `rgb(${cc.map(Math.round).join(',')})`; c.fillRect(x0+i*cw, y0+(nn-1-j)*cw, cw-1, cw-1); }
  for (let j=0;j<nn;j++) for (let i=0;i<nn;i++){ const id = D.id(i,j,k), ux = which ? lerp(A[0][id], B[0][id], e) : A[0][id], uy = which ? lerp(A[1][id], B[1][id], e) : A[1][id];
    const cx = x0+(i+.5)*cw, cy = y0+(nn-1-j+.5)*cw; arrow(c, cx - ux*cw*.32, cy + uy*cw*.32, cx + ux*cw*.32, cy - uy*cw*.32, p.ink, 1.2); }
  c.strokeStyle = p.rule; c.lineWidth = 1; c.strokeRect(x0-.5, y0-.5, sz, sz); }
function drawOps(now){
  const dt = opLast === null ? 0 : Math.min(100, now - opLast); opLast = now;
  opT = Math.min(opPlay ? 99 : OPT, opT + dt/1000); if (opPlay && opT > OPT) { opT = 0; opStage = (opStage+1) % OPS.length; opCap(); }
  const c = CO, W = c.W, H = c.H, p = P(), e = reduce ? 1 : ease(opT/2.2);
  c.clearRect(0,0,W,H);
  // left: the column
  const Y = y => 300 - y*256, X = u => 44 + u/27*210, st = opStage;
  label(c, 'one column: wall → centre', 20, 20, p.ink, FT); label(c, 'u / u_τ  →', 196, 322, p.mut, F10);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(X(0), Y(1)); c.lineTo(X(0), Y(0)); c.lineTo(X(27), Y(0)); c.stroke();
  for (let q=0;q<10;q++){ c.beginPath(); c.moveTo(X(0)+q*22, Y(0)+2); c.lineTo(X(0)+q*22-7, Y(0)+9); c.stroke(); }
  label(c, 'wall', X(0)-6, Y(0)+4, p.mut, F10, 'right'); label(c, 'centre', X(0)-6, Y(1)+4, p.mut, F10, 'right');
  for (let j=0;j<NYC;j++){ const y0 = Y(j*DYC), y1 = Y((j+1)*DYC), hl = (st === 1 && j === 4) || (st === 2 && j >= 3 && j <= 5) || (st === 3 && j === JH0);
    c.strokeStyle = p.rule; c.beginPath(); c.moveTo(X(0), y1); c.lineTo(X(27), y1); c.stroke();
    c.fillStyle = p.u; c.globalAlpha = isAct('ub') || hl ? .5 : .25; c.fillRect(X(0), y1+1, X(barU[j])-X(0), y0-y1-2); c.globalAlpha = 1;
    c.fillStyle = p.u; c.fillRect(X(barU[j])-1.5, y1+1, 3, y0-y1-2);
    if (hl){ c.strokeStyle = st === 1 ? p.cs : st === 2 ? p.eq : p.c; c.lineWidth = 2; c.strokeRect(X(0)+1, y1+1, X(27)-X(0)-2, y0-y1-2); c.lineWidth = 1; } }
  c.beginPath(); colU.forEach((u,s) => { const y = Y((s+.5)/(NYC*NF)); s ? c.lineTo(X(u), y) : c.moveTo(X(u), y); }); c.strokeStyle = p.f; c.lineWidth = isAct('uf') ? 2 : 1.2; c.stroke();
  if (st === 3){ const yh = Y(H0); c.fillStyle = p.cs; c.beginPath(); c.arc(X(barU[JH0]), yh, 5, 0, 7); c.fill();
    c.setLineDash([4,3]); c.strokeStyle = p.c; c.lineWidth = 1.6; c.beginPath(); for (let q=0;q<=40;q++){ const y = H0*Math.pow(q/40, 3) + 1e-6, u = q0*spald(y*q0*RE0); q ? c.lineTo(X(u), Y(y)) : c.moveTo(X(u), Y(y)); } c.stroke(); c.setLineDash([]);
    arrow(c, X(0)+4, Y(0)-6, X(0)+4 + 46*q0*q0*e, Y(0)-6, p.c, 3); label(c, 'τ_w', X(0)+56, Y(0)-14, p.c, FB); }
  // right: the stage itself
  const x0 = 300;
  if (st === 0){ const V = {th:-0.62, ph:0.42, s:58, ox:470, oy:175}, hx = 1.6, hy = 1, hz = .8; box(c, V, hx, hy, hz, p.mut, 1.2);
    const cxl = .3, czl = .2, w = .1, q = [[-1,-1],[1,-1],[1,1],[-1,1]];
    [-1, 1].forEach(sy => { c.beginPath(); q.forEach(([a,b],k) => { const P3 = proj(V, cxl + a*w, sy*hy, czl + b*w*.6); k ? c.lineTo(P3[0], P3[1]) : c.moveTo(P3[0], P3[1]); }); c.closePath(); c.fillStyle = p.u; c.globalAlpha = .35; c.fill(); c.globalAlpha = 1; });
    for (let j=0;j<=NYC;j++){ const P3 = proj(V, cxl, -hy + j*hy/NYC, czl); c.fillStyle = p.u; c.fillRect(P3[0]-3, P3[1]-.5, 6, 1.5); }
    const pb = proj(V, cxl, -hy, czl), pt = proj(V, cxl, 0, czl); c.strokeStyle = p.u; c.lineWidth = 3; c.beginPath(); c.moveTo(pb[0], pb[1]); c.lineTo(pt[0], pt[1]); c.stroke();
    const f0 = proj(V, -hx-.5, 0, 0), f1 = proj(V, -hx-.1, 0, 0); arrow(c, f0[0], f0[1], f1[0], f1[1], p.ink, 2); label(c, 'flow', f0[0], f0[1]+16, p.mut, F10, 'center');
    label(c, 'walls at top and bottom; x, z periodic', 470, 318, p.mut, F10, 'center'); label(c, '32 × 24 × 16 cells', 470, 30, isAct('N') ? p.ink : p.mut, FB, 'center');
    triad(c, V, 330, 290, p);
    const j = 4; label(c, `cell 5 of this column:`, 640, 110, p.ink, FT);
    let py = 140; [['ū_x', barU[j]], ['ū_y', barV[j]], ['ū_z', barW[j]]].forEach(([nm, v]) => { pill(c, 640, py, `${nm} = ${fx(v)}`, p.u); py += 30; });
    label(c, 'ū ∈ ℝ³ per cell', 640, py+4, p.mut, F11); label(c, '(units of u_τ)', 640, py+20, p.mut, F10); }
  if (st === 1){ const j = 4, xs = x0+40, xw = 480, yy = u => 270 - (u - barU[j] + 2)/4*200;
    label(c, `G on cell 5: ${NF} samples of the true u → one cell value`, x0+20, 30, p.ink, FT);
    c.strokeStyle = p.rule; c.beginPath(); c.moveTo(xs, 70); c.lineTo(xs, 270); c.lineTo(xs+xw, 270); c.stroke();
    for (let s=0;s<NF;s++){ const u = colU[j*NF+s], X0 = xs + (s+.5)/NF*xw; c.fillStyle = p.f; c.beginPath(); c.arc(X0, lerp(yy(u), yy(barU[j]), e*.85), 4, 0, 7); c.fill();
      c.fillStyle = p.cs; c.globalAlpha = .55; c.fillRect(X0-6, 282, 12, 18); c.globalAlpha = 1; }
    label(c, `G = 1/${NF} each (box filter)`, xs, 316, p.cs, F11);
    c.strokeStyle = p.u; c.lineWidth = 3*e + .5; c.beginPath(); c.moveTo(xs, yy(barU[j])); c.lineTo(xs+xw, yy(barU[j])); c.stroke(); c.lineWidth = 1;
    label(c, `ū = (u₁ + … + u${'₂₀'})/${NF} = ${fx(barU[j])}`, xs+xw, yy(barU[j])-10, p.u, FB, 'right'); }
  if (st === 2){ const mat = (x, y, a, col, tl, al) => { c.globalAlpha = al; label(c, tl, x, y-16, p.ink, FT);
      for (let r=0;r<3;r++) for (let q=0;q<3;q++){ c.fillStyle = col; c.globalAlpha = al*.12; rr(c, x+q*52, y+r*34, 48, 30, 6); c.fill(); c.globalAlpha = al; label(c, fx(a[3*r+q], 1), x+q*52+24, y+r*34+19, col, F11, 'center'); }
      c.globalAlpha = 1; };
    const Sf = mod0.S.flat();
    mat(x0+10, 70, GA, p.ink, '∂ūᵢ/∂xⱼ  (u_τ/δ)', 1);
    arrow(c, x0+168, 120, x0+184, 120, p.ink, 2);
    mat(x0+190, 70, Sf, p.eq, 'S̄ᵢⱼ: symmetric half', clamp(e*2, .15, 1));
    arrow(c, x0+348, 120, x0+366, 120, p.ink, 2);
    c.globalAlpha = clamp(e*2-1, .15, 1);
    label(c, `|S̄| = √(2S̄ᵢⱼS̄ᵢⱼ) = ${fx(mod0.Smag, 2)}`, x0+372, 92, p.eq, FB);
    label(c, `Δ = (ΔxΔyΔz)^⅓ = ${fx(Math.cbrt(DXB*DYB*DZB), 4)}`, x0+372, 116, p.cs, F11);
    label(c, `ν_sgs = (0.17·Δ)²|S̄| = ${ex(mod0.smag)}`, x0+372, 140, p.nu, FB);
    label(c, `ν = 1/Re_τ = ${NU0}`, x0+372, 164, p.w, F11); c.globalAlpha = 1;
    const bw = clamp(e*2-1, 0, 1); label(c, 'eddy viscosity compared with the fluid\'s own:', x0+10, 236, p.ink, F11);
    c.fillStyle = p.w; c.fillRect(x0+10, 250, 4, 18); c.fillStyle = p.nu; c.fillRect(x0+10, 278, Math.min(520, 4*mod0.smag/NU0)*bw, 18);
    label(c, 'ν', x0+20, 264, p.w, F11); label(c, `ν_sgs = ${fx(mod0.smag/NU0,1)} ν`, x0+16+Math.min(520, 4*mod0.smag/NU0)*bw, 292, p.nu, FB); }
  if (st === 3){ const U = barU[JH0], f = q => q*(Math.log(H0*q/NU0)/KAP + BLOG) - U, xa = x0+30, xb = x0+300, qa = .3, qb = 1.4, fa = f(qa), fb = f(qb);
    const X2 = q => xa + (q-qa)/(qb-qa)*(xb-xa), Y2 = v => 270 - (v - fa)/(fb-fa)*210;
    label(c, `f(u_τ) = u_τ[ln(h_wm u_τ/ν)/κ + B] − |ū∥|`, x0+20, 30, p.ink, FT);
    c.strokeStyle = p.rule; c.beginPath(); c.moveTo(xa, Y2(0)); c.lineTo(xb, Y2(0)); c.stroke(); label(c, 'u_τ', xb+4, Y2(0)+4, p.mut, F10);
    c.beginPath(); for (let q=0;q<=60;q++){ const qq = qa + (qb-qa)*q/60; q ? c.lineTo(X2(qq), Y2(f(qq))) : c.moveTo(X2(qq), Y2(f(qq))); } c.strokeStyle = p.c; c.lineWidth = 2; c.stroke(); c.lineWidth = 1;
    const nIt = reduce ? its0.length-1 : Math.min(its0.length-1, Math.floor(opT/0.7));
    for (let k=0;k<nIt;k++){ const a = its0[k], b = its0[k+1]; c.strokeStyle = p.c; c.setLineDash([3,3]); c.beginPath(); c.moveTo(X2(a), Y2(f(a))); c.lineTo(X2(b), Y2(0)); c.stroke(); c.setLineDash([]);
      c.fillStyle = p.c; c.beginPath(); c.arc(X2(a), Y2(f(a)), 3.5, 0, 7); c.fill(); }
    c.fillStyle = p.ink; c.beginPath(); c.arc(X2(its0[nIt]), Y2(0), 4, 0, 7); c.fill();
    label(c, 'Newton iterates', 660, 60, p.ink, FT); its0.slice(0, nIt+1).forEach((q,k) => label(c, `u_τ${'⁰¹²³⁴⁵⁶'[k]} = ${fx(q, 5)}`, 660, 86+k*20, k === nIt ? p.c : p.mut, F11));
    if (nIt === its0.length-1) label(c, `τ_w = ρu_τ² = ${fx(q0*q0, 4)}`, 660, 96+its0.length*20, p.c, FB); }
  if (st === 4){ label(c, 'u* after the explicit step (8³ periodic box, mid slice)', x0+20, 30, p.ink, FT);
    projSlice(c, p, x0+30, 50, 220, 0, 0, true); label(c, `max |∇·u*| = ${fx(PD.mx0)}`, x0+30, 290, p.nu, FB);
    arrow(c, x0+262, 160, x0+300, 160, p.ink, 2); label(c, 'P', x0+281, 150, p.rho, MATH, 'center');
    projSlice(c, p, x0+310, 50, 220, 1, e, true); label(c, `after: ${e > .99 ? PD.mx1.toExponential(1) : fx(PD.mx0*(1-e))}`, x0+310, 290, p.c, FB);
    label(c, `kinetic energy ${fx(PD.ke0/PD.ke0, 3)} → ${fx(lerp(1, PD.ke1/PD.ke0, e), 3)}: only the compressing part is removed`, x0+30, 316, p.mut, F11); }
}

// ===== HOW IT WORKS: each operator explains itself =====
const mt = s => `<div class="hm"><math display="block">${s}</math></div>`, tc = (col, x) => `<mrow style="color:var(${col})">${x}</mrow>`, sw = col => `<i class="tb" style="background:var(${col})"></i>`;
const eexB = (key, list, cur) => `<div class="eex"><span>Example</span>${list.map((t,k) => `<button class="b${k === cur ? ' pri' : ''}" data-${key}="${k}">${t}</button>`).join('')}</div>`;
const HS = { G: 0, M: 0, W: 0, P: 0 };
const GEX = [['box, 5 samples', 5, false], ['box, 11', 11, false], ['Gaussian, 5', 5, true], ['Gaussian, 11', 11, true]];
const MEX = [['wall shear', [0,1,0, 0,0,0, 0,0,0]], ['3D strain', [1,.3,0, 0,-.4,0, 0,0,-.6]], ['pure rotation', [0,1,0, -1,0,0, 0,0,0]], ['walkthrough cell', GA]];
const WEX = [['channel, 3rd cell', barU[JH0], H0, NU0, 0, 'u_τ', 'δ'], ['airliner wing', 60, 0.005, 1.5e-5, 1.2, 'm/s', 'm'], ['car roof', 30, 0.01, 1.5e-5, 1.2, 'm/s', 'm']];
const PEX = [5, 9, 13].map(projDemo);
function bindEx(root, key, self){ root.querySelectorAll(`[data-${key}]`).forEach(b => b.onclick = () => { HS[key.toUpperCase()] = +b.dataset[key]; root.querySelectorAll(`[data-${key}]`).forEach(x => x.classList.toggle('pri', x === b)); self.draw(root); }); }
const HOW = {
 G: { html: () => `<span class="eyebrow">How G works</span>
   ${mt(`<mover><mi>u</mi><mo>―</mo></mover><mo>(</mo><msub><mi>x</mi><mn>0</mn></msub><mo>)</mo><mo>=</mo><munder><mo>∑</mo><mi>k</mi></munder>${tc('--c-cs','<msub><mi>G</mi><mi>k</mi></msub>')}${tc('--c-f','<mi>u</mi><mo>(</mo><msub><mi>x</mi><mi>k</mi></msub><mo>)</mo>')}<mo>,</mo><mspace width="1em"/><munder><mo>∑</mo><mi>k</mi></munder>${tc('--c-cs','<msub><mi>G</mi><mi>k</mi></msub>')}<mo>=</mo><mn>1</mn>`)}
   <div class="eterms"><span>${sw('--c-cs')}Gₖ</span><span>Weights. Box: all equal inside width Δ. Gaussian: ∝ e^(−6r²/Δ²), heaviest in the middle.</span>
     <span>${sw('--c-f')}u(xₖ)</span><span>The true velocity at nearby points (in 3D the sum runs over x, y and z).</span>
     <span>${sw('--c-u')}ū(x₀)</span><span>The blurred value: a weighted average, so it never overshoots the samples.</span></div>
   ${eexB('g', GEX.map(g => g[0]), HS.G)}<canvas class="hc" data-w="420" data-h="120"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), [, wd, gauss] = GEX[HS.G], s0 = 120, hw = gauss ? wd : (wd-1)/2, idx = [], wts = [];
   for (let r=-hw;r<=hw;r++){ idx.push(s0+r); wts.push(gauss ? Math.exp(-6*r*r/(wd*wd)) : 1); } const ws = wts.reduce((a,b) => a+b, 0); for (let k=0;k<wts.length;k++) wts[k] /= ws;
   const ub = idx.reduce((a,s,k) => a + wts[k]*colU[s], 0), lo = Math.min(...idx.map(s => colU[s]))-.3, hi = Math.max(...idx.map(s => colU[s]))+.3, X = s => 20 + (s - s0 + 12)/24*380, Yv = v => 62 - (v-lo)/(hi-lo)*52;
   c.clearRect(0,0,c.W,c.H);
   for (let s=s0-12;s<=s0+12;s++){ c.fillStyle = p.f; c.globalAlpha = Math.abs(s-s0) <= hw ? 1 : .3; c.beginPath(); c.arc(X(s), Yv(colU[s]), 3, 0, 7); c.fill(); } c.globalAlpha = 1;
   idx.forEach((s,k) => { c.fillStyle = p.cs; rr(c, X(s)-5, 112 - wts[k]*180, 10, wts[k]*180, 2); c.fill(); });
   c.strokeStyle = p.u; c.lineWidth = 2.5; c.beginPath(); c.moveTo(X(s0-hw)-6, Yv(ub)); c.lineTo(X(s0+hw)+6, Yv(ub)); c.stroke();
   label(c, 'weights Gₖ', 4, 110, p.cs, F10);
   const mid = idx.length >> 1, terms = [mid-1, mid, mid+1].map(k => `${fx(wts[k],3)}×${fx(colU[idx[k]])}`).join(' + ');
   root.querySelector('.ecalc').textContent = `ū = … + ${terms} + … (${idx.length} terms) = ${fx(ub, 3)}  (point value u(x₀) = ${fx(colU[s0], 3)}; ΣGₖ = ${fx(wts.reduce((a,b)=>a+b,0),3)})`; } },
 M: { html: () => `<span class="eyebrow">How M works</span>
   ${mt(`${tc('--c-nu','<msub><mi>ν</mi><mtext>sgs</mtext></msub>')}<mo>=</mo>${tc('--c-cs','<msup><mrow><mo>(</mo><msub><mi>C</mi><mi>s</mi></msub><mi>Δ</mi><mo>)</mo></mrow><mn>2</mn></msup>')}${tc('--c-eq','<msqrt><mn>2</mn><msub><mover><mi>S</mi><mo>―</mo></mover><mrow><mi>i</mi><mi>j</mi></mrow></msub><msub><mover><mi>S</mi><mo>―</mo></mover><mrow><mi>i</mi><mi>j</mi></mrow></msub></msqrt>')}<mo>,</mo><mspace width="1em"/><msub><mover><mi>S</mi><mo>―</mo></mover><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>=</mo><mfrac><mn>1</mn><mn>2</mn></mfrac><mo>(</mo><msub><mi>a</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>+</mo><msub><mi>a</mi><mrow><mi>j</mi><mi>i</mi></mrow></msub><mo>)</mo>`)}
   <div class="eterms"><span>${sw('--c-cs')}(C_sΔ)²</span><span>The model's mixing length squared: eddies just below the cell size.</span>
     <span>${sw('--c-eq')}|S̄|</span><span>How hard the resolved flow strains, from the gradient aᵢⱼ = ∂ūᵢ/∂xⱼ. Rotation (the antisymmetric half) is dropped.</span>
     <span>${sw('--c-nu')}ν_sgs</span><span>The product. Vreman and WALE use the same gradient but other invariants, so they react differently.</span></div>
   ${eexB('m', MEX.map(g => g[0]), HS.M)}<canvas class="hc" data-w="420" data-h="100"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), a = MEX[HS.M][1], d = HS.M === 3 ? [DXB, DYB, DZB] : [1,1,1], r = sgsModels(a, d, 0.17, 0.325);
   const vals = [['Smagorinsky', r.smag, p.nu], ['Vreman', r.vrem, p.tau], ['WALE', r.wale, p.c]], mx = Math.max(...vals.map(v => v[1]), 1e-12);
   c.clearRect(0,0,c.W,c.H);
   vals.forEach(([nm, v, col], k) => { const y = 10 + k*30; label(c, nm, 4, y+15, col, F11); c.fillStyle = col; rr(c, 100, y, Math.max(2, v/mx*250), 20, 4); c.fill(); label(c, ex(v), 110 + Math.max(2, v/mx*250), y+15, col, FB); });
   const S = r.S, u = HS.M === 3 ? ' (u_τ/δ, Δ from the Build grid)' : ' (Δ = 1)';
   root.querySelector('.ecalc').textContent = `S̄ = [${S.map(rw => rw.map(v => fx(v,2)).join(' ')).join(' | ')}] → 2S̄ᵢⱼS̄ᵢⱼ = ${fx(2*r.SS,3)} → |S̄| = ${fx(r.Smag,3)}; ν_Smag = (0.17·${fx(Math.cbrt(d[0]*d[1]*d[2]),3)})² × ${fx(r.Smag,3)} = ${ex(r.smag)}; Vreman ${ex(r.vrem)} (B_β = ${ex(r.Bb)}); WALE ${ex(r.wale)}${u}`; } },
 W: { html: () => `<span class="eyebrow">How W works</span>
   ${mt(`${tc('--c-c','<msubsup><mi>u</mi><mi>τ</mi><mrow><mi>n</mi><mo>+</mo><mn>1</mn></mrow></msubsup>')}<mo>=</mo><msubsup><mi>u</mi><mi>τ</mi><mi>n</mi></msubsup><mo>−</mo><mfrac>${tc('--c-c','<mi>f</mi><mo>(</mo><msubsup><mi>u</mi><mi>τ</mi><mi>n</mi></msubsup><mo>)</mo>')}${tc('--c-eq','<msup><mi>f</mi><mo>′</mo></msup><mo>(</mo><msubsup><mi>u</mi><mi>τ</mi><mi>n</mi></msubsup><mo>)</mo>')}</mfrac><mo>,</mo><mspace width="1em"/><mi>f</mi><mo>=</mo><msub><mi>u</mi><mi>τ</mi></msub><mo>[</mo><mfrac><mn>1</mn><mi>κ</mi></mfrac><mi>ln</mi><mfrac><mrow>${tc('--c-cs','<msub><mi>h</mi><mtext>wm</mtext></msub>')}<msub><mi>u</mi><mi>τ</mi></msub></mrow><mi>ν</mi></mfrac><mo>+</mo><mi>B</mi><mo>]</mo><mo>−</mo>${tc('--c-u','<mo>|</mo><msub><mover><mi>u</mi><mo>―</mo></mover><mo>∥</mo></msub><mo>|</mo>')}`)}
   <div class="eterms"><span>${sw('--c-u')}|ū∥|</span><span>Input: the LES speed parallel to the wall, read at the matching height.</span>
     <span>${sw('--c-cs')}h_wm</span><span>Input: that height. Together they fix one point the log law must pass through.</span>
     <span>${sw('--c-c')}f = 0</span><span>The log law rearranged. Its only unknown is u_τ.</span>
     <span>${sw('--c-eq')}f′</span><span>Slope: ln(h u_τ/ν)/κ + B + 1/κ. Follow the tangent to zero, repeat: 3–5 tries reach machine precision.</span></div>
   ${eexB('w', WEX.map(g => g[0]), HS.W)}<canvas class="hc" data-w="420" data-h="120"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), [, U, h, nu, rho, un, ln] = WEX[HS.W], its = newtonIts(U, h, nu, U/30, 8), qf = its[its.length-1];
   const f = q => q*(Math.log(h*q/nu)/KAP + BLOG) - U, qa = qf*.3, qb = qf*1.7, fa = f(qa), fb = f(qb), X = q => 30 + (q-qa)/(qb-qa)*370, Y = v => 108 - (v-fa)/(fb-fa)*96;
   c.clearRect(0,0,c.W,c.H); c.strokeStyle = p.rule; c.beginPath(); c.moveTo(30, Y(0)); c.lineTo(400, Y(0)); c.stroke();
   c.beginPath(); for (let k=0;k<=60;k++){ const q = qa + (qb-qa)*k/60; k ? c.lineTo(X(q), Y(f(q))) : c.moveTo(X(q), Y(f(q))); } c.strokeStyle = p.c; c.lineWidth = 2; c.stroke(); c.lineWidth = 1;
   for (let k=0;k<its.length-1;k++){ const a = its[k], b = its[k+1]; if (a < qa || a > qb) continue; c.strokeStyle = p.eq; c.setLineDash([3,3]); c.beginPath(); c.moveTo(X(a), Y(f(a))); c.lineTo(X(clamp(b,qa,qb)), Y(0)); c.stroke(); c.setLineDash([]); c.fillStyle = p.eq; c.beginPath(); c.arc(X(a), Y(f(a)), 3, 0, 7); c.fill(); }
   c.fillStyle = p.c; c.beginPath(); c.arc(X(qf), Y(0), 4.5, 0, 7); c.fill(); label(c, 'u_τ', 404, Y(0)+4, p.mut, F10);
   const tw = rho ? `τ_w = ρu_τ² = ${fx(rho*qf*qf, 2)} Pa` : `τ_w/ρ = u_τ² = ${fx(qf*qf, 4)}`;
   root.querySelector('.ecalc').textContent = `|ū∥| = ${U.toFixed(2)} ${un} at h = ${h} ${ln}, ν = ${nu.toExponential(2)}: u_τ = ${its.map(q => fx(q, 4)).join(' → ')} ${un} · h⁺ = ${fx(h*qf/nu, 0)} · ${tw}`; } },
 P: { html: () => `<span class="eyebrow">How P works</span>
   ${mt(`<msup><mo>∇</mo><mn>2</mn></msup>${tc('--c-rho','<mi>φ</mi>')}<mo>=</mo>${tc('--c-nu','<mo>∇</mo><mo>·</mo><msup><mi>u</mi><mo>*</mo></msup>')}<mo>,</mo><mspace width="1em"/><mover><mi>u</mi><mo>―</mo></mover><mo>=</mo><msup><mi>u</mi><mo>*</mo></msup>${tc('--c-c','<mo>−</mo><mo>∇</mo><mi>φ</mi>')}<mo>,</mo><mspace width="1em"/>${tc('--c-rho','<mover accent="true"><mi>φ</mi><mo>^</mo></mover>')}<mo>=</mo><mfrac>${tc('--c-nu','<mover accent="true"><mi>d</mi><mo>^</mo></mover>')}<mrow><mi>λ</mi><mo>(</mo><mi>𝐤</mi><mo>)</mo></mrow></mfrac>`)}
   <div class="eterms"><span>${sw('--c-nu')}∇·u*</span><span>How much each cell would swell or shrink after the explicit step.</span>
     <span>${sw('--c-rho')}φ</span><span>Pressure correction (Δt·p). One Poisson equation over the whole grid; in Fourier space each mode is one division by the Laplacian's eigenvalue λ(𝐤).</span>
     <span>${sw('--c-c')}−∇φ</span><span>The push that removes exactly the compressing part: the rest of u* is untouched.</span></div>
   ${eexB('p', ['field A', 'field B', 'field C'], HS.P)}<canvas class="hc" data-w="420" data-h="170"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), D = PEX[HS.P];
   c.clearRect(0,0,c.W,c.H); projSlice(c, p, 20, 6, 150, 0, 0, true, D); projSlice(c, p, 250, 6, 150, 1, 1, true, D);
   arrow(c, 182, 80, 238, 80, p.ink, 2); label(c, 'P', 210, 70, p.rho, MATH, 'center');
   root.querySelector('.ecalc').textContent = `8×8×8 periodic box, mid slice: max|∇·u*| = ${fx(D.mx0, 3)} → max|∇·ū| = ${D.mx1.toExponential(1)} · kinetic energy ${fx(D.ke0, 1)} → ${fx(D.ke1, 1)} (−${fx(100*(1-D.ke1/D.ke0), 1)}%: only the divergent part is removed)`; } }
};
['G','M','W','P'].forEach(k => HOW[k].bind = function(root){ bindEx(root, k.toLowerCase(), this); });
this.ops = HOW;

// ===== A: a real 3D field and its filtered version; drag to orbit; the field drifts through the box (frozen turbulence) =====
const FA = makeField(3); let aDel = 2, aGauss = false, FR = null, aDirty = true, aClock = 0, aLast = null, aHold = -1e9, ghostsA = [];
const CA = hidpi($('afviz')), VA = { th: -0.62, ph: 0.45, s: 50 }; orbit($('afviz'), VA);
const SAf = [0,1,2].map(() => surf(NA, NA)), SAb = [0,1,2].map(() => surf(NA, NA)), STa = surf(NA, NA);
function refilter(){ FR = filterField(FA, aDel, aGauss); let m2 = 0; for (let c=0;c<NA3;c++) m2 += FR.tau[c]**2; FR.tauS = 2.5*Math.sqrt(m2/NA3) || 1; aDirty = false;
  const pct = Math.round(FR.frac*100), reg = pct >= 80 ? 'well-resolved LES (Pope: resolve ≥ 80%)' : pct >= 50 ? 'coarse LES: the model carries a lot' : 'very coarse: most energy is subgrid';
  $('acap').textContent = `Δ = ${aDel}h, ${aGauss ? 'Gaussian' : 'box'} · resolved ${pct}% of the kinetic energy, subgrid ${100-pct}% · ${reg}`; }
const aChange = () => { if (FR) ghostsA = [{ Ef: FR.Ef, lab: `${aGauss ? 'G' : 'box'} ${aDel}h` }, ...ghostsA].slice(0, 3); aDirty = true; aHold = now(); if (reduce) drawA(0); };
$('adel').oninput = e => { const v = +e.target.value; $('adelv').textContent = v + ' h'; if (v !== aDel){ aDel = v; aChange(); } };
[['fbox', false], ['fgau', true]].forEach(([id, g]) => $(id).onclick = () => { $('fbox').classList.toggle('pri', !g); $('fgau').classList.toggle('pri', g); if (aGauss !== g){ aGauss = g; aChange(); } });
function cube(c, p, V, field, S3, sh, outline, kern){
  const cs = cols(p), Pp = (x,y,z) => proj(V, x, y, z), L = NA-1, at = (i,j,k) => field[((i+sh)%NA) + NA*(j + NA*k)];
  for (let r=0;r<NA;r++) for (let q=0;q<NA;q++){ put(S3[0], q, r, divc(cs, at(q, L, r)/2.2)); put(S3[1], q, r, divc(cs, at(q, L-r, L)/2.2)); put(S3[2], q, r, divc(cs, at(L, L-r, L-q)/2.2)); }
  face(c, S3[0], Pp(-1,1,-1), Pp(1,1,-1), Pp(-1,1,1)); face(c, S3[1], Pp(-1,1,1), Pp(1,1,1), Pp(-1,-1,1)); face(c, S3[2], Pp(1,1,1), Pp(1,1,-1), Pp(1,-1,1));
  box(c, V, 1, 1, 1, outline ? p.ink : p.mut, outline ? 2.2 : 1);
  if (kern){ const w = aDel/NA, pts = aGauss ? [...Array(24)].map((_,q) => [Math.cos(q/24*6.283)*w*1.2, Math.sin(q/24*6.283)*w*1.2]) : [[-w,-w],[w,-w],[w,w],[-w,w]];
    c.beginPath(); pts.forEach(([a,b],q) => { const s = Pp(a, b, 1); q ? c.lineTo(s[0], s[1]) : c.moveTo(s[0], s[1]); }); c.closePath(); c.strokeStyle = p.cs; c.lineWidth = 2.4; c.stroke(); c.fillStyle = p.cs; c.globalAlpha = .18; c.fill(); c.globalAlpha = 1; } }
function drawA(t){
  if (aDirty) refilter();
  const dt = aLast === null ? 0 : Math.min(100, t - aLast); aLast = t; if (!reduce && !VA.drag && t - aHold > 1800) aClock += dt;
  VA.th = clamp(VA.th, -1.25, -0.3); VA.ph = clamp(VA.ph, .2, 1.0);
  const c = CA, W = c.W, p = P(), sh = Math.floor(aClock/110) % NA, kern = isAct('G','Delta');
  c.clearRect(0,0,W,c.H);
  cube(c, p, Object.assign({}, VA, { ox: 116, oy: 128 }), FA.u[0], SAf, sh, isAct('uf'), kern);
  cube(c, p, Object.assign({}, VA, { ox: 344, oy: 128 }), FR.ub[0], SAb, sh, isAct('ub'), kern);
  label(c, 'true u_x (32³ field)', 116, 22, isAct('uf') ? p.f : p.ink, FT, 'center'); label(c, `filtered ū_x, Δ = ${aDel}h`, 344, 22, isAct('ub') ? p.u : p.ink, FT, 'center');
  arrow(c, 206, 128, 252, 128, isAct('G','Delta') ? p.cs : p.mut, 2.4); label(c, 'G', 229, 118, p.cs, MATH, 'center');
  label(c, 'flow →  (the field drifts through the box)', 230, 228, p.mut, F10, 'center');
  triad(c, Object.assign({}, VA, { ox: 30, oy: 214 }), 30, 214, p);
  // τ_xy on the front face
  const cs = cols(p), L = NA-1; for (let r=0;r<NA;r++) for (let q=0;q<NA;q++) put(STa, q, r, divc(cs, FR.tau[((q+sh)%NA) + NA*(L-r + NA*L)]/FR.tauS));
  STa.cx.putImageData(STa.img, 0, 0); c.imageSmoothingEnabled = true; c.drawImage(STa.cv, 30, 266, 150, 150);
  c.strokeStyle = isAct('tau') ? p.tau : p.rule; c.lineWidth = isAct('tau') ? 2.4 : 1; c.strokeRect(30, 266, 150, 150);
  label(c, 'τ_xy = (u_x u_y)‾ − ū_x ū_y', 30, 256, isAct('tau') ? p.tau : p.ink, FB); label(c, `front face, ±${fx(FR.tauS,2)}`, 30, 432, p.mut, F10);
  // spectrum: true E(k), filtered E(k)Ĝ², the filter's transfer function and the cutoff π/Δ
  const x0 = 222, x1 = 446, y0 = 262, y1 = 414, Emax = Math.max(...FR.E), lE = 2.6, X = k => x0 + Math.log(k)/Math.log(16)*(x1-x0), Y = e => y0 + Math.min(1, Math.log10(Emax/Math.max(e, 1e-30))/lE)*(y1-y0);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x0, y1); c.lineTo(x1, y1); c.stroke();
  label(c, 'energy spectrum E(k)', x0, 252, p.ink, FB); label(c, 'k →', x1, y1+14, p.mut, F10, 'right'); [1,2,4,8,16].forEach(k => label(c, String(k), X(k), y1+12, p.mut, F9, 'center'));
  ghostsA.forEach((g,j) => { c.beginPath(); for (let k=1;k<=16;k++) k > 1 ? c.lineTo(X(k), Y(g.Ef[k])) : c.moveTo(X(k), Y(g.Ef[k])); c.strokeStyle = p.u; c.globalAlpha = .35 - .09*j; c.lineWidth = 1.2; c.stroke(); c.globalAlpha = 1; });
  c.beginPath(); c.moveTo(X(1), y1); for (let k=1;k<=16;k++) c.lineTo(X(k), Y(FR.Ef[k])); c.lineTo(X(16), y1); c.closePath(); c.fillStyle = p.u; c.globalAlpha = isAct('ub') ? .35 : .2; c.fill(); c.globalAlpha = 1;
  c.beginPath(); for (let k=1;k<=16;k++) k > 1 ? c.lineTo(X(k), Y(FR.Ef[k])) : c.moveTo(X(k), Y(FR.Ef[k])); c.strokeStyle = p.u; c.lineWidth = 2; c.stroke();
  c.beginPath(); for (let k=1;k<=16;k++) k > 1 ? c.lineTo(X(k), Y(FR.E[k])) : c.moveTo(X(k), Y(FR.E[k])); c.strokeStyle = p.f; c.lineWidth = isAct('uf') ? 2.6 : 1.6; c.stroke();
  c.beginPath(); for (let q=0;q<=60;q++){ const k = Math.pow(16, q/60), gh = Math.max(0, gHat(k, 0, 0, aDel, aGauss)); q ? c.lineTo(X(k), y1 - gh*(y1-y0)) : c.moveTo(X(k), y1 - gh*(y1-y0)); }
  c.setLineDash([4,3]); c.strokeStyle = p.cs; c.lineWidth = kern ? 2.4 : 1.4; c.stroke(); c.setLineDash([]);
  const kc = 16/aDel; c.strokeStyle = p.cs; c.lineWidth = 1; c.beginPath(); c.moveTo(X(kc), y0); c.lineTo(X(kc), y1); c.stroke(); label(c, 'π/Δ', X(kc)+3, y0+10, p.cs, F10);
  label(c, `resolved ${Math.round(FR.frac*100)}%`, x0+6, y1-24, p.u, FB); label(c, `subgrid ${100-Math.round(FR.frac*100)}%`, x0+6, y1-8, p.tau, F11);
}

// ===== B: a strained blob of fluid in one cell, and the eddy viscosity of three models approaching a wall =====
const CB = hidpi($('sgviz')), VB = { th: -0.6, ph: 0.4, s: 54, ox: 110, oy: 112 }; orbit($('sgviz'), VB);
let bCs = 0.17, bCase = 0, bClock = 0, bLast = null, bHold = -1e9, ghostsB = [], NW = null;
const BCASES = [[0,1,0, 0,0,0, 0,0,0], [1,.3,0, 0,-.4,0, 0,0,-.6], [0,1,0, -1,0,0, 0,0,0]], BNAMES = ['near-wall shear', '3D strain', 'pure rotation'];
// near-wall eddies: random Taylor expansions that satisfy no-slip and continuity (wall units, Δ⁺ = 100)
const YPS = [...Array(36)].map((_,q) => 0.2*Math.pow(100, q/35)), DPL = 100;
const ENS = (() => { const r = rng(77), g = () => { let s = 0; for (let q=0;q<6;q++) s += r(); return s - 3; }, L = [];
  for (let s=0;s<160;s++) L.push({ a1: 1+.4*g(), a2: -.01+.005*g(), c1: .3*g(), c2: .005*g(), a1x: .05*g(), a1z: .05*g(), c1x: .05*g(), c1z: .05*g(), a2x: 5e-4*g(), a2z: 5e-4*g(), c2x: 5e-4*g(), c2z: 5e-4*g(), b2x: 2e-3*g(), b2z: 2e-3*g() }); return L; })();
function nearWall(Cs){ return YPS.map(y => { let sm = 0, vr = 0, wa = 0; ENS.forEach(e => { const b2 = -(e.a1x+e.c1z)/2, b3 = -(e.a2x+e.c2z)/3;
    const a = [e.a1x*y+e.a2x*y*y, e.a1+2*e.a2*y, e.a1z*y+e.a2z*y*y, e.b2x*y*y, 2*b2*y+3*b3*y*y, e.b2z*y*y, e.c1x*y+e.c2x*y*y, e.c1+2*e.c2*y, e.c1z*y+e.c2z*y*y];
    const r = sgsModels(a, [DPL,DPL,DPL], Cs, 0.325); sm += r.smag; vr += r.vrem; wa += r.wale; }); const N = ENS.length; return [sm/N, vr/N, wa/N]; }); }
const slope = (arr, m) => { const i1 = YPS.findIndex(y => y >= 0.3), i2 = YPS.findIndex(y => y >= 1.0); return Math.log(arr[i2][m]/arr[i1][m])/Math.log(YPS[i2]/YPS[i1]); };
NW = nearWall(bCs);
$('bcs').oninput = e => { bCs = +e.target.value; $('bcsv').textContent = bCs.toFixed(2); bHold = now(); NW = nearWall(bCs); if (reduce) drawB(0); };
$('bcs').addEventListener('pointerdown', () => { ghostsB = [{ cs: bCs, d: NW.map(v => v[0]) }, ...ghostsB.filter(g => g.cs !== bCs)].slice(0, 3); });
$('bcase').onclick = e => { const b = e.target.closest('[data-c]'); if (!b) return; bCase = +b.dataset.c; $('bcase').querySelectorAll('[data-c]').forEach(x => x.classList.toggle('pri', x === b)); bHold = now(); if (reduce) drawB(0); };
function eig3(S){ const a = S.map(r => r.slice()), v = [[1,0,0],[0,1,0],[0,0,1]];   // Jacobi rotations for a symmetric 3×3
  for (let sweep=0;sweep<12;sweep++) for (const [pq, qq] of [[0,1],[0,2],[1,2]]){ const apq = a[pq][qq]; if (Math.abs(apq) < 1e-12) continue;
    const th = .5*Math.atan2(2*apq, a[qq][qq]-a[pq][pq]), cs = Math.cos(th), sn = Math.sin(th);
    for (let k=0;k<3;k++){ const x = a[k][pq], y = a[k][qq]; a[k][pq] = cs*x - sn*y; a[k][qq] = sn*x + cs*y; }
    for (let k=0;k<3;k++){ const x = a[pq][k], y = a[qq][k]; a[pq][k] = cs*x - sn*y; a[qq][k] = sn*x + cs*y; }
    for (let k=0;k<3;k++){ const x = v[k][pq], y = v[k][qq]; v[k][pq] = cs*x - sn*y; v[k][qq] = sn*x + cs*y; } }
  return [0,1,2].map(k => ({ l: a[k][k], e: [v[0][k], v[1][k], v[2][k]] })); }
function drawB(t){
  const dt = bLast === null ? 0 : Math.min(100, t - bLast); bLast = t; const hold = t - bHold < 2000; if (!reduce && !hold) bClock += dt;
  const c = CB, W = c.W, p = P(), A = BCASES[bCase], r = sgsModels(A, [1,1,1], bCs, 0.325), amp = reduce || hold ? .45 : .45*(.5 - .5*Math.cos(bClock/3000*6.283));
  if (!VB.drag && !reduce && !hold) VB.th += dt*0.0001;
  const Pp = (x,y,z) => { const X = [x,y,z], d = [0,1,2].map(i => X[0]*A[3*i] + X[1]*A[3*i+1] + X[2]*A[3*i+2]); return proj(VB, x + amp*d[0], y + amp*d[1], z + amp*d[2]); };
  c.clearRect(0,0,W,c.H);
  box(c, VB, 1, 1, 1, isAct('Delta') ? p.cs : p.rule, isAct('Delta') ? 2.2 : 1); label(c, 'one cell, width Δ', 14, 20, isAct('Delta') ? p.cs : p.mut, F10);
  const ring = f => { c.beginPath(); for (let q=0;q<=48;q++){ const s = Pp(...f(q/48*6.283)); q ? c.lineTo(s[0], s[1]) : c.moveTo(s[0], s[1]); } c.stroke(); }, R0 = .72;
  c.strokeStyle = p.u; c.lineWidth = 1.3; c.globalAlpha = .8;
  [-.6,-.3,0,.3,.6].forEach(la => ring(a => [R0*Math.cos(la)*Math.cos(a), R0*Math.sin(la)*1.0, R0*Math.cos(la)*Math.sin(a)]));
  [0, 1.047, 2.094].forEach(lo => ring(a => [R0*Math.cos(a)*Math.cos(lo), R0*Math.sin(a), R0*Math.cos(a)*Math.sin(lo)])); c.globalAlpha = 1;
  if (r.Smag > 1e-9) eig3(r.S).forEach(({l, e}) => { const L = .95*(1 + amp*l), o = proj(VB, 0, 0, 0), s1 = proj(VB, e[0]*L, e[1]*L, e[2]*L), s2 = proj(VB, -e[0]*L, -e[1]*L, -e[2]*L), w = isAct('S','Smag') ? 3 : 1.8;
    if (l > 0){ arrow(c, o[0], o[1], s1[0], s1[1], p.eq, w); arrow(c, o[0], o[1], s2[0], s2[1], p.eq, w); } else if (l < 0){ arrow(c, s1[0], s1[1], (o[0]+s1[0])/2, (o[1]+s1[1])/2, p.eq, w); arrow(c, s2[0], s2[1], (o[0]+s2[0])/2, (o[1]+s2[1])/2, p.eq, w); }
    if (isAct('S')) label(c, fx(l, 2), s1[0]+6, s1[1], p.eq, F10); });
  triad(c, VB, 30, 196, p);
  const xs = 236; label(c, BNAMES[bCase], xs, 30, p.ink, FT); label(c, 'gradient aᵢⱼ = ∂ūᵢ/∂xⱼ:', xs, 50, p.mut, F10);
  for (let i=0;i<3;i++) label(c, A.slice(3*i, 3*i+3).map(v => (v >= 0 ? ' ' : '') + fx(v, 1)).join('  '), xs, 66+i*14, p.ink, F10);
  let py = 124; pill(c, xs, py, `|S̄| = ${fx(r.Smag, 3)}`, p.eq); py += 26;
  [['Smagorinsky', r.smag, p.nu], ['Vreman', r.vrem, p.tau], ['WALE', r.wale, p.c]].forEach(([nm, v, col]) => { pill(c, xs, py, `ν ${nm} = ${ex(v)}`, isAct('nut') || (nm === 'Smagorinsky' && isAct('Cs')) ? col : v === 0 ? p.mut : col); py += 24; });
  // near-wall plot
  const x0 = 54, x1 = 410, y0 = 248, y1 = 412, lx = y => x0 + Math.log(y/0.2)/Math.log(100)*(x1-x0), ly = v => y1 - (clamp(Math.log10(Math.max(v, 1e-12)), -5, 3) + 5)/8*(y1-y0);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x0, y1); c.lineTo(x1, y1); c.stroke();
  [-4,-2,0,2].forEach(e => label(c, `10${e < 0 ? '⁻' : ''}${'⁰¹²³⁴⁵'[Math.abs(e)]}`, x0-4, ly(10**e)+4, p.mut, F9, 'right')); [0.2,1,5,20].forEach(y => label(c, String(y), lx(y), y1+12, p.mut, F9, 'center'));
  label(c, 'ν_sgs / ν near a wall (Δ⁺ = 100)', x0, y0-8, isAct('nut') ? p.nu : p.ink, FB); label(c, 'y⁺ →', x1, y1+24, p.mut, F10, 'right');
  const line = (vals, col, w, dash, al) => { c.beginPath(); vals.forEach((v,q) => q ? c.lineTo(lx(YPS[q]), ly(v)) : c.moveTo(lx(YPS[q]), ly(v))); c.setLineDash(dash ? [5,4] : []); c.strokeStyle = col; c.lineWidth = w; c.globalAlpha = al || 1; c.stroke(); c.setLineDash([]); c.globalAlpha = 1; };
  ghostsB.forEach((g,j) => line(g.d, p.nu, 1.2, false, .35 - .09*j));
  const bw = isAct('nut') ? 2.8 : 2;
  line(NW.map(v => v[0]), p.nu, isAct('Cs') ? 3.2 : bw); line(NW.map((v,q) => v[0]*(1-Math.exp(-YPS[q]/26))**2), p.w, 1.6, true); line(NW.map(v => v[1]), p.tau, bw); line(NW.map(v => v[2]), p.c, bw);
  const sl = [slope(NW, 0), slope(NW, 1), slope(NW, 2)], yr = 0;
  const f1 = v => fx(Math.abs(v) < .05 ? 0 : v, 1); label(c, 'slope at the wall:', x0+150, y1-40, p.mut, F10);
  [['Smagorinsky', p.nu], ['Vreman', p.tau], ['WALE', p.c]].forEach(([nm, col], k) => label(c, `${nm} ∝ y⁺^${f1(sl[k])}`, x0+150, y1-26+k*12, col, F10));
  $('bcap').textContent = `${BNAMES[bCase]}: ${[['Smagorinsky', r.smag], ['Vreman', r.vrem], ['WALE', r.wale]].filter(v => v[1] === 0).map(v => v[0]).join(' and ') || 'no model'} ${[r.smag, r.vrem, r.wale].filter(v => v === 0).length === 1 ? 'is' : 'are'} exactly off here. Near the wall the true turbulent stress falls like y³: measured slopes ${sl.map(s => fx(Math.abs(s) < .05 ? 0 : s, 1)).join(', ')} (Smagorinsky, Vreman, WALE).`;
}

// ===== C: the near-wall region on a coarse grid, the matching point and the log law through it =====
const CCv = hidpi($('wmviz')); let cJ = 0, cRe = 2000, cClock = 0, cLast = null, cHold = -1e9, cAv = [], cIts = [], ghostsC = [];
const DYW = 1/12;
function cellAvg(j, Re){ const M = 600; let s = 0;
  if (j === 0){ for (let q=0;q<M;q++){ const t = (q+.5)/M, y = DYW*t**4; s += spald(y*Re)*4*t**3/M; } return s; }
  for (let q=0;q<M;q++) s += spald((j + (q+.5)/M)*DYW*Re)/M; return s; }
function cUpdate(){ cAv = [...Array(6)].map((_,j) => cellAvg(j, cRe)); cIts = newtonIts(cAv[cJ], (cJ+.5)*DYW, 1/cRe, 0.6, 8);
  const q = cIts[cIts.length-1], h = (cJ+.5)*DYW, ord = ['1st','2nd','3rd','4th','5th','6th'][cJ];
  $('chwmv').textContent = ord; $('crev').textContent = Math.round(cRe).toLocaleString('en-US');
  $('ccap').textContent = `h_wm = ${fx(h, 3)}δ (${ord} cell centre, h⁺ = ${Math.round(h*cRe)}): the LES cell value is ${fx(cAv[cJ], 2)} vs the law of the wall's ${fx(spald(h*cRe), 2)} at that height → u_τ ${q >= 1 ? '+' : '−'}${fx(Math.abs(q-1)*100, 1)}%, τ_w ${q*q >= 1 ? '+' : '−'}${fx(Math.abs(q*q-1)*100, 1)}%. ` +
    (Math.abs(q-1) > 0.01 ? 'The first cell averages over the steep near-wall profile: one computable piece of the log-layer mismatch.' : 'A few cells up, the cell value is a faithful sample: the mismatch is gone.'); }
cUpdate();
$('chwm').oninput = e => { ghostsC = [{ j: cJ, q: cIts[cIts.length-1] }, ...ghostsC.filter(g => g.j !== cJ)].slice(0, 3); cJ = +e.target.value; cHold = now(); cClock = 0; cUpdate(); if (reduce) drawC(0); };
$('cre').oninput = e => { cRe = Math.pow(10, +e.target.value); ghostsC = []; cHold = now(); cUpdate(); if (reduce) drawC(0); };
function drawC(t){
  const dt = cLast === null ? 0 : Math.min(100, t - cLast); cLast = t; if (!reduce) cClock += dt;
  const c = CCv, W = c.W, p = P(), h = (cJ+.5)*DYW, q = cIts[cIts.length-1], Umax = logLaw(.5*cRe) + 2, wmU = y => { const yp = y*q*cRe; return q*(yp < 11 ? yp : logLaw(yp)); };
  c.clearRect(0,0,W,c.H);
  // left: physical space, y up to 0.5δ, the six cells of a WMLES grid
  const X = u => 40 + u/Umax*160, Y = y => 330 - y/.5*300;
  label(c, 'near-wall region', 20, 18, p.ink, FT); label(c, 'u/u_τ →', X(Umax), 18, p.mut, F10, 'right');
  c.strokeStyle = p.rule; c.lineWidth = 1; for (let j=0;j<=6;j++){ c.beginPath(); c.moveTo(X(0), Y(j*DYW)); c.lineTo(X(Umax), Y(j*DYW)); c.stroke(); }
  c.beginPath(); c.moveTo(X(0), Y(.5)); c.lineTo(X(0), Y(0)); c.lineTo(X(Umax), Y(0)); c.stroke(); for (let k=0;k<8;k++){ c.beginPath(); c.moveTo(X(0)+k*20, Y(0)+2); c.lineTo(X(0)+k*20-7, Y(0)+9); c.stroke(); }
  label(c, 'wall', X(0)-4, Y(0)+4, p.mut, F10, 'right'); label(c, '0.5δ', X(0)-4, Y(.5)+4, p.mut, F10, 'right'); 
  for (let j=0;j<6;j++){ c.fillStyle = p.u; c.globalAlpha = j === cJ || isAct('upar') && j === cJ ? .45 : .2; c.fillRect(X(0), Y((j+1)*DYW)+1, X(cAv[j])-X(0), Y(j*DYW)-Y((j+1)*DYW)-2); c.globalAlpha = 1; c.fillRect(X(cAv[j])-1.5, Y((j+1)*DYW)+1, 3, Y(j*DYW)-Y((j+1)*DYW)-2); }
  c.beginPath(); for (let k=0;k<=200;k++){ const y = .5*(k/200)**3; k ? c.lineTo(X(spald(y*cRe)), Y(y)) : c.moveTo(X(0), Y(0)); } c.strokeStyle = p.f; c.lineWidth = 1.8; c.stroke();
  c.beginPath(); for (let k=0;k<=80;k++){ const y = h*(k/80)**3; k ? c.lineTo(X(wmU(y)), Y(y)) : c.moveTo(X(0), Y(0)); } c.setLineDash([5,4]); c.strokeStyle = p.c; c.lineWidth = 2; c.stroke(); c.setLineDash([]);
  if (isAct('hwm')){ c.setLineDash([3,3]); c.strokeStyle = p.cs; c.beginPath(); c.moveTo(X(0), Y(h)); c.lineTo(X(Umax), Y(h)); c.stroke(); c.setLineDash([]); }
  ghostsC.forEach(g => { c.strokeStyle = p.cs; c.globalAlpha = .4; c.lineWidth = 1.5; c.beginPath(); c.arc(X(cAv[g.j]), Y((g.j+.5)*DYW), 4, 0, 7); c.stroke(); c.globalAlpha = 1; });
  const pulse = reduce ? 0 : .5 + .5*Math.sin(t/300); c.fillStyle = p.cs; c.beginPath(); c.arc(X(cAv[cJ]), Y(h), isAct('hwm','upar') ? 7 : 5 + pulse, 0, 7); c.fill();
  label(c, 'h_wm', X(cAv[cJ]) - 10, Y(h) - 9, p.cs, FB, 'right');
  const twL = 70*q*q; arrow(c, X(0)+3, Y(0)-7, X(0)+3+twL, Y(0)-7, p.c, isAct('tw','W','utau') ? 4 : 3); c.fillStyle = p.ink; c.fillRect(X(0)+3+70, Y(0)-13, 1.5, 12);
  label(c, `τ_w = ${fx(q*q, 3)} (true value 1 = tick)`, X(0)-30, Y(0)+22, p.c, F10);
  // right top: wall units, semi-log
  const lx0 = 240, lx1 = 446, ly0 = 34, ly1 = 196, lmax = Math.log10(.5*cRe), LX = yp => lx0 + Math.log10(Math.max(yp, 1))/lmax*(lx1-lx0), LY = u => ly1 - u/Umax*(ly1-ly0);
  label(c, 'same, in wall units', lx0, 18, p.ink, FT);
  c.fillStyle = p.nu; c.globalAlpha = isAct('nu','yp') ? .18 : .08; c.fillRect(LX(1), ly0, LX(5)-LX(1), ly1-ly0); c.globalAlpha = 1; label(c, 'sublayer', LX(1)+2, ly0+10, p.nu, F9);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(lx0, ly0); c.lineTo(lx0, ly1); c.lineTo(lx1, ly1); c.stroke();
  for (let e=0;e<=lmax;e++) label(c, e < 3 ? String(10**e) : `10${'⁰¹²³⁴⁵'[e]}`, LX(10**e), ly1+12, isAct('yp','Re') ? p.ink : p.mut, F9, 'center'); label(c, 'y⁺', lx1, ly1+24, isAct('yp') ? p.ink : p.mut, F10, 'right');
  c.beginPath(); for (let k=0;k<=60;k++){ const yp = Math.pow(10, lmax*k/60); k ? c.lineTo(LX(yp), LY(spald(yp))) : c.moveTo(LX(yp), LY(spald(yp))); } c.strokeStyle = p.f; c.lineWidth = 1.8; c.stroke();
  c.beginPath(); for (let k=0;k<=40;k++){ const yp = 11*Math.pow(.5*cRe/11, k/40); k ? c.lineTo(LX(yp), LY(logLaw(yp))) : c.moveTo(LX(yp), LY(logLaw(yp))); } c.setLineDash([2,3]); c.strokeStyle = isAct('kap','Bc') ? p.ink : p.w; c.lineWidth = isAct('kap','Bc') ? 2 : 1.2; c.stroke(); c.setLineDash([]);
  if (isAct('kap','Bc')) label(c, 'log law: slope 1/κ = 2.44 per e, B = 5.2', lx0+4, ly0+24, p.ink, F9);
  c.beginPath(); for (let k=0;k<=40;k++){ const yp = 30*Math.pow(.5*cRe/30, k/40), u = q*logLaw(yp*q); k ? c.lineTo(LX(yp), LY(u)) : c.moveTo(LX(yp), LY(u)); } c.setLineDash([5,4]); c.strokeStyle = p.c; c.lineWidth = 1.8; c.stroke(); c.setLineDash([]);
  for (let j=0;j<6;j++){ c.fillStyle = p.u; c.beginPath(); c.arc(LX((j+.5)*DYW*cRe), LY(cAv[j]), 3.2, 0, 7); c.fill(); }
  c.strokeStyle = p.cs; c.lineWidth = 2.2; c.beginPath(); c.arc(LX(h*cRe), LY(cAv[cJ]), 6.5, 0, 7); c.stroke();
  if (Math.abs(q-1) > .01) label(c, 'shifted log law', lx1, LY(q*logLaw(.5*cRe*q))+18, p.c, F9, 'right');
  // right bottom: Newton on f(u_τ) = 0, animated
  const nx0 = 250, nx1 = 440, ny0 = 250, ny1 = 338, U = cAv[cJ], nu = 1/cRe, f = qq => qq*(Math.log(h*qq/nu)/KAP + BLOG) - U, qa = .4, qb = 1.5, fa = f(qa), fb = f(qb), NX_ = qq => nx0 + (qq-qa)/(qb-qa)*(nx1-nx0), NY_ = v => ny1 - (v-fa)/(fb-fa)*(ny1-ny0);
  const on = isAct('W','utau'); label(c, 'Newton: f(u_τ) = 0', nx0, ny0-10, on ? p.c : p.ink, FB);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(nx0, NY_(0)); c.lineTo(nx1, NY_(0)); c.stroke();
  c.beginPath(); for (let k=0;k<=50;k++){ const qq = qa + (qb-qa)*k/50; k ? c.lineTo(NX_(qq), NY_(f(qq))) : c.moveTo(NX_(qq), NY_(f(qq))); } c.strokeStyle = p.c; c.lineWidth = on ? 2.6 : 1.8; c.stroke();
  const nIt = reduce ? cIts.length-1 : Math.min(cIts.length-1, Math.floor((cClock % 5000)/650));
  for (let k=0;k<nIt;k++){ const a = cIts[k], b = cIts[k+1]; if (a < qa || a > qb) continue; c.strokeStyle = p.eq; c.setLineDash([3,3]); c.lineWidth = 1.2; c.beginPath(); c.moveTo(NX_(a), NY_(f(a))); c.lineTo(NX_(clamp(b, qa, qb)), NY_(0)); c.stroke(); c.setLineDash([]); c.fillStyle = p.eq; c.beginPath(); c.arc(NX_(a), NY_(f(a)), 3, 0, 7); c.fill(); }
  c.fillStyle = p.ink; c.beginPath(); c.arc(NX_(clamp(cIts[nIt], qa, qb)), NY_(0), 4, 0, 7); c.fill(); label(c, `u_τ = ${fx(cIts[nIt], 4)}`, nx1, ny0-10, p.c, F10, 'right');
  // bottom: the numbers
  let px = 14, py = 372; px = pill(c, px, py, `h_wm = ${fx(h, 3)}δ`, p.cs); px = pill(c, px, py, `h⁺ = ${Math.round(h*cRe)}`, p.w); pill(c, px, py, `u_τ ${q >= 1 ? '+' : '−'}${fx(Math.abs(q-1)*100, 1)}%`, Math.abs(q-1) > .01 ? p.nu : p.c);
  py = 400; px = 14; px = pill(c, px, py, `first cell Δy⁺ = ${Math.round(DYW*cRe)}`, p.w); pill(c, px, py, `wall-resolved needs Δy⁺ ≈ 1: ${Math.round(DYW*cRe)}× thinner`, p.mut);
  label(c, 'κ = 0.41, B = 5.2 · true profile: Spalding\'s law of the wall', 14, 440, p.mut, F10);
}

// ===== Build: the 3D channel =====
const S = Channel({ jh: 2 }); let running = false, ghostsS = [], runLeft = 0;
const SC = hidpi($('sim')), VS = { th: -0.62, ph: 0.42, s: 58, ox: 212, oy: 212 }; orbit($('sim'), VS, () => { if (!running || reduce) drawSim(); });
const SB = surf(S.NX, S.NZ), SK = surf(S.NX, S.NY), SL = surf(S.NZ, S.NY);
const ORD = ['1st','2nd','3rd','4th'];
function simLabels(){ const h = (S.jh+.5)*S.dy; $('hwmv').textContent = `${fx(h, 3)}δ (${ORD[S.jh]} cell)`; $('hwmn').textContent = `h⁺ = ${Math.round(h*S.retau)} · ${S.jh === 0 ? 'first cell: expect the log-layer mismatch' : S.jh === 1 ? 'second cell: mostly fixed' : `${S.jh+1} cells up: in the trustworthy part of the LES (Kawai & Larsson)`}`; }
function keepGhost(lab){ const m = S.meanAvg(); if (m && S.nAcc() > 200) ghostsS = [{ m: Float64Array.from(m), lab }, ...ghostsS].slice(0, 3); }
const settingLab = () => `${ORD[S.jh]} cell, ${S.model === 'vreman' ? 'Vreman' : 'Smag.'}`;
$('hwm').oninput = e => { const v = +e.target.value; if (v === S.jh) return; keepGhost(settingLab()); S.jh = v; S.resetStats(); simLabels(); drawSim(); };
[['mv','vreman'],['ms','smag']].forEach(([id, md]) => $(id).onclick = () => { if (S.model === md) return; keepGhost(settingLab()); S.model = md; S.resetStats(); $('mv').classList.toggle('pri', md === 'vreman'); $('ms').classList.toggle('pri', md === 'smag'); drawSim(); });
[['r2',2000],['r5',5200],['r20',20000]].forEach(([id, re]) => $(id).onclick = () => { if (S.retau === re) return; S.retau = re; ghostsS = []; S.init(); ['r2','r5','r20'].forEach(k => $(k).classList.toggle('pri', k === id)); simLabels(); drawSim(); });
$('run').onclick = () => { if (!running) return; runLeft = S.t + 1; if (reduce) chunk(); };
function chunk(){ const t0 = now(); let k = 0; while (S.t < runLeft && now() - t0 < 30 && k++ < 40) S.stage(); drawSim(); if (S.t < runLeft) setTimeout(chunk, 0); }
simLabels();
function drawSim(){
  const c = SC, W = c.W, H = c.H, p = P(), cs = cols(p), { NX, NY, NZ, NP, dy } = S, hx = S.LX/2, hy = 1, hz = S.LZ/2;
  VS.th = clamp(VS.th, -1.2, -0.25); VS.ph = clamp(VS.ph, .15, .9);
  const Pp = (x,y,z) => proj(VS, x, y, z), jh = S.jh, yp = -hy + (jh+.5)*dy;
  c.clearRect(0,0,W,H);
  // back wall z = 0: streamwise velocity u (x–y plane); side x = 0: u (z–y plane); plane at h_wm: u − its plane mean (streaks)
  const um = Math.max(25, deanUb(S.retau)*1.25);
  for (let r=0;r<NY;r++) for (let i=0;i<NX;i++) put(SK, i, r, seqc(cs, S.uc[i + NP*(NY-1-r)]/um));
  for (let r=0;r<NY;r++) for (let k=0;k<NZ;k++) put(SL, k, r, seqc(cs, S.uc[NX*k + NP*(NY-1-r)]/um));
  const mj = S.mean[jh]; for (let k=0;k<NZ;k++) for (let i=0;i<NX;i++) put(SB, i, k, divc(cs, (S.uc[i + NX*k + NP*jh] - mj)/4));
  face(c, SK, Pp(-hx,hy,-hz), Pp(hx,hy,-hz), Pp(-hx,-hy,-hz)); face(c, SL, Pp(-hx,hy,-hz), Pp(-hx,hy,hz), Pp(-hx,-hy,-hz));
  face(c, SB, Pp(-hx,yp,-hz), Pp(hx,yp,-hz), Pp(-hx,yp,hz), .9);
  // wall-model shear stress on the bottom wall
  for (let k=1;k<NZ;k+=4) for (let i=1;i<NX;i+=4){ const pI = i + NX*k, tx = S.twx[0][pI], tz = S.twz[0][pI];
    const x = -hx + (i+.5)*S.dx, z = -hz + (k+.5)*S.dz, a = Pp(x, -hy, z), b = Pp(x + tx*.22, -hy, z + tz*.22); arrow(c, a[0], a[1], b[0], b[1], p.c, 1.6); }
  box(c, VS, hx, hy, hz, p.mut, 1.1);
  const w0 = Pp(-hx, -hy, hz), w1 = Pp(hx, -hy, hz); c.strokeStyle = p.ink; c.lineWidth = 2.4; c.beginPath(); c.moveTo(w0[0], w0[1]); c.lineTo(w1[0], w1[1]); c.stroke();
  const f0 = Pp(-hx-.7, 0, 0), f1 = Pp(-hx-.15, 0, 0); arrow(c, f0[0], f0[1], f1[0], f1[1], p.ink, 2); label(c, 'flow', f0[0]-6, f0[1]-8, p.mut, F10, 'center');
  label(c, `plane at h_wm: streaks (u − ū), ±4 u_τ`, 16, 20, p.ink, F11); label(c, `walls: streamwise u, 0–${Math.round(um)} u_τ · arrows: τ_w from W`, 16, 36, p.mut, F10);
  label(c, `${NX}×${NY}×${NZ} cells · box π × 2 × π/2 (δ)`, 16, H-34, p.mut, F10);
  // right: running mean profile against the log law (y/δ on a log axis)
  const x0 = 470, x1 = 746, y0 = 26, y1 = 182, Umax = deanUb(S.retau)*1.3, lY = y => x0 + Math.log(y/.02)/Math.log(50)*(x1-x0), lU = u => y1 - u/Umax*(y1-y0);
  label(c, 'mean profile vs log law', x0, 16, p.ink, FT);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x0, y1); c.lineTo(x1, y1); c.stroke();
  [.02,.05,.1,.2,.5,1].forEach(y => label(c, String(y), lY(y), y1+12, p.mut, F9, 'center')); label(c, 'y/δ', x1, y1+24, p.mut, F10, 'right');
  [0,10,20,30].filter(u => u < Umax).forEach(u => label(c, String(u), x0-4, lU(u)+4, p.mut, F9, 'right'));
  c.beginPath(); for (let k=0;k<=40;k++){ const y = .02*Math.pow(50, k/40); k ? c.lineTo(lY(y), lU(logLaw(y*S.retau))) : c.moveTo(lY(y), lU(logLaw(y*S.retau))); } c.setLineDash([4,3]); c.strokeStyle = p.ink; c.lineWidth = 1.4; c.stroke(); c.setLineDash([]);
  const half = m => [...Array(NY/2)].map((_,j) => [(j+.5)*dy, .5*(m[j] + m[NY-1-j])]);
  ghostsS.forEach((g,j) => { c.beginPath(); half(g.m).forEach(([y,u],k) => k ? c.lineTo(lY(y), lU(u)) : c.moveTo(lY(y), lU(u))); c.strokeStyle = p.w; c.globalAlpha = .55 - .12*j; c.lineWidth = 1.4; c.stroke(); c.globalAlpha = 1;
    const e = half(g.m)[NY/2-1]; label(c, g.lab, lY(e[0])-2, lU(e[1]) + 12 + 10*j, p.w, F9, 'right'); });
  c.beginPath(); half(S.mean).forEach(([y,u],k) => k ? c.lineTo(lY(y), lU(u)) : c.moveTo(lY(y), lU(u))); c.strokeStyle = p.u; c.globalAlpha = .35; c.lineWidth = 1; c.stroke(); c.globalAlpha = 1;
  const ma = S.meanAvg(); if (ma) half(ma).forEach(([y,u]) => { c.fillStyle = p.u; c.beginPath(); c.arc(lY(y), lU(u), 3.2, 0, 7); c.fill(); });
  const hh = (S.jh+.5)*dy; c.strokeStyle = p.cs; c.setLineDash([3,3]); c.beginPath(); c.moveTo(lY(hh), y0); c.lineTo(lY(hh), y1); c.stroke(); c.setLineDash([]); label(c, 'h_wm', lY(hh)+3, y0+10, p.cs, F9);
  label(c, ma ? `● mean of ${S.nAcc()} steps` : '● collecting (starts 1 δ/u_τ after a change)', x1-4, y1-24, p.u, F10, 'right'); label(c, '┄ log law', x1-4, y1-10, p.ink, F10, 'right');
  // τ_w from the wall model over time; the driving pressure gradient is 1, so its long-time mean must be 1
  const ty0 = 236, ty1 = 334, hs = S.twHist, tEnd = S.t, tA = tEnd - 8, TX = tt => x0 + (tt - tA)/8*(x1-x0), TY = v => ty1 - clamp(v/2, 0, 1)*(ty1-ty0);
  label(c, 'τ_w from the wall model (mean over both walls)', x0, ty0-10, p.ink, FT);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, ty0); c.lineTo(x0, ty1); c.lineTo(x1, ty1); c.stroke();
  c.setLineDash([4,3]); c.strokeStyle = p.ink; c.beginPath(); c.moveTo(x0, TY(1)); c.lineTo(x1, TY(1)); c.stroke(); c.setLineDash([]); label(c, '1 = pressure gradient', x1, TY(1)-5, p.mut, F9, 'right');
  label(c, '2', x0-4, ty0+4, p.mut, F9, 'right'); label(c, '0', x0-4, ty1+4, p.mut, F9, 'right'); label(c, 't u_τ/δ (last 8)', x1, ty1+14, p.mut, F9, 'right');
  c.beginPath(); let st = false; for (const [tt, v] of hs){ if (tt < tA) continue; st ? c.lineTo(TX(tt), TY(v)) : c.moveTo(TX(tt), TY(v)); st = true; } c.strokeStyle = p.c; c.lineWidth = 1.6; c.stroke();
  let twm = 0, nn = 0; for (const [tt, v] of hs) if (tt > S.tAcc0 + 1){ twm += v; nn++; }
  // the numbers
  const ub = S.ub(), dean = deanUb(S.retau), inDean = 2*dean*S.retau <= 6.5e5, ubm = ma ? ma.reduce((a,b) => a+b, 0)/NY : ub;
  let px = 470, py = 362; px = pill(c, px, py, `Re_τ ${S.retau}`, p.w); px = pill(c, px, py, `t = ${fx(S.t, 1)} δ/u_τ`, p.w); pill(c, px, py, `${fx(S.tStep || 0, 1)} ms/step`, p.mut);
  py = 390; px = 470; px = pill(c, px, py, `U_b⁺ ${fx(ubm, 2)}`, p.u); pill(c, px, py, inDean ? `Dean ${fx(dean, 2)} (${ubm >= dean ? '+' : '−'}${fx(Math.abs(ubm/dean-1)*100, 1)}%)` : `log law only (Re_b beyond Dean's fit)`, inDean && Math.abs(ubm/dean-1) > .025 ? p.nu : p.c);
  px = 16; py = H-12; px = pill(c, px, py, `max|∇·u| ${S.divMax().toExponential(0)}`, p.rho); pill(c, px, py, nn ? `mean τ_w ${fx(twm/nn, 3)}` : 'mean τ_w …', p.c);
  $('simcap').textContent = !running ? 'Order the steps above to start the solver.' : `${settingLab()}: U_b⁺ ${ma ? 'averaged over ' + S.nAcc() + ' steps' : '(instantaneous)'} = ${fx(ubm, 2)}${inDean ? `, Dean's correlation ${fx(dean, 2)}` : ''}. ${S.jh === 0 ? 'With the first cell the profile sits above the log law: the log-layer mismatch (measured here ~+5% with Vreman, ~+10% with Smagorinsky).' : 'Matching a few cells up keeps the profile on the log law (measured here within ~1% of Dean).'} Reduced model: small periodic box, ~12 cells per δ, honest but coarse.`;
}

// ===== Parallelize: pencil transposes for the FFT Poisson solve; cost against Reynolds number =====
const PCv = hidpi($('pencil')), PSTG = [['FFT along x', 'x', 0], ['Transpose x → z', 'z', 1], ['FFT along z', 'z', 0], ['Transpose z → y', 'y', 1], ['Tridiagonal solve along y', 'y', 0], ['Transpose back, inverse FFTs', 'x', 1]];
const DESC = { x: 'x-pencils: each processor owns whole lines along x', z: 'z-pencils: whole lines along z', y: 'y-pencils: whole lines along y (wall to wall)' };
let pNext = 0, pDec = 'x', pFrom = 'x', pT0 = -1e9, pKind = 0;
const owner = (d, v) => d === 'x' ? (v[1]>=2)*2 + (v[2]>=2) : d === 'z' ? (v[0]>=2)*2 + (v[1]>=2) : (v[0]>=2)*2 + (v[2]>=2);
const pst = $('pstages'); pst.innerHTML = PSTG.map(([nm],k) => `<button class="b" data-s="${k}">${k+1} · ${nm}</button>`).join('');
pst.onclick = e => { const b = e.target.closest('[data-s]'); if (!b) return; const s = +b.dataset.s, fb = $('pfb');
  if (pNext >= PSTG.length){ fb.className = 'fb good'; fb.textContent = '✓ Already done. Each pressure solve repeats this every Runge–Kutta stage.'; return; }
  if (s !== pNext){ fb.className = 'fb bad'; fb.textContent = `Not yet: the data are in ${pDec}-pencils, so next comes “${PSTG[pNext][0]}”.`; return; }
  pFrom = pDec; pDec = PSTG[s][1]; pKind = PSTG[s][2]; pT0 = now(); pNext++; b.classList.add('pri');
  if (pNext === PSTG.length){ fb.className = 'fb good'; fb.textContent = '✓ One pressure solve: 4 transposes (2 there, 2 back). In each, every processor sends ¾ of its data to the others: all-to-all traffic that, not arithmetic, limits how far FFT solvers scale.'; K.done('parallel'); }
  else { fb.className = 'fb'; fb.textContent = pKind ? 'All-to-all: each processor keeps ¼ of its data and swaps the rest.' : 'Local: every processor works on its own whole lines; no messages.'; }
  if (reduce) drawPencil(now() + 5000); };
function drawPencil(t){ const c = PCv, p = P(), V = { th: -0.62, ph: 0.45, s: 26, ox: 160, oy: 120 }, rc = [p.f, p.eq, p.c, p.tau].map(hex), a = clamp((t - pT0)/1200, 0, 1);
  c.clearRect(0,0,c.W,c.H); const vox = [];
  for (let k=0;k<4;k++) for (let j=0;j<4;j++) for (let i=0;i<4;i++){ const P3 = proj(V, (i-1.5)*1.25, (j-1.5)*1.25, (k-1.5)*1.25); vox.push({ v: [i,j,k], P3 }); }
  vox.sort((x,y) => x.P3[2] - y.P3[2]).forEach(({ v, P3 }) => { const wv = clamp(a*1.8 - (v[0]+v[1]+v[2])/9*.8, 0, 1), c0 = rc[owner(pFrom, v)], c1 = rc[owner(pDec, v)], cc = c0.map((x,q) => Math.round(x + (c1[q]-x)*wv));
    const sweep = !pKind && a < 1 && v[{ x: 0, y: 1, z: 2 }[pDec]] === Math.floor(a*4); c.fillStyle = `rgb(${cc.join(',')})`; c.globalAlpha = sweep ? 1 : .82; rr(c, P3[0]-9, P3[1]-9, 18, 18, 4); c.fill(); c.globalAlpha = 1;
    if (sweep){ c.strokeStyle = p.ink; c.lineWidth = 2; c.stroke(); } });
  triad(c, V, 28, 226, p); label(c, DESC[pDec], 160, 16, p.ink, F10, 'center'); label(c, '4 processors = 4 colours', 312, 250, p.mut, F9, 'right'); }
const COv = hidpi($('cost'));
function drawCost(){ const c = COv, p = P(), lr = +$('pre').value, r = Math.pow(10, lr - 6), rows = [['wall-modelled LES', 1, p.c], ['wall-resolved LES', 13/7, p.u], ['DNS', 37/14, p.nu]], X = v => 150 + v/12*390;
  $('prev').textContent = `10^${lr.toFixed(1)}`; c.clearRect(0,0,c.W,c.H);
  label(c, `grid growth from Re_Lx = 10⁶ to 10^${lr.toFixed(1)}`, 10, 18, p.ink, FT);
  rows.forEach(([nm, ex_, col], k) => { const y = 36 + k*42, g = Math.pow(r, ex_), lg = Math.log10(g); label(c, nm, 10, y+17, col, F11); c.fillStyle = col; rr(c, 150, y, Math.max(3, X(lg)-150), 24, 5); c.fill();
    label(c, `×${g < 1e4 ? Math.round(g).toLocaleString('en-US') : g.toExponential(1)}`, Math.max(3, X(lg)-150) + 156, y+17, col, FB); });
  label(c, '10× Re → ×10 (WMLES), ×72 (wall-resolved), ×437 (DNS)', 10, 180, p.mut, F10); }
$('pre').oninput = drawCost;
function wmShare(){ let sh = S.tTot > 0 ? S.tWall/S.tTot : 0; if (!sh){ const T = Channel({ jh: 2 }); for (let k=0;k<3;k++) T.step(); sh = T.tWall/T.tTot; } $('wmshare').textContent = sh > 0 && sh < 1 ? `about ${fx(100*sh, 1)}% (measured)` : 'a few per cent'; }

let openBlk = '0';
function drawLearn(t){ if (reduce || openBlk === '0') drawOps(t); if (reduce || openBlk === 'A') drawA(t); if (reduce || openBlk === 'B') drawB(t); if (reduce || openBlk === 'C') drawC(t); }
drawOps(0); drawA(0); drawB(0); drawC(0); drawSim(); drawCost();
return {
  frame(t, stp){
    if (stp === 0) drawLearn(t);
    if (stp === 1 && running){ const t0 = now(); let k = 0; do { S.stage(); k++; } while (k < 12 && (now() - t0 + (S.tStage || 2) < 8 || (runLeft > S.t && now() - t0 < 30))); drawSim(); }
    if (stp === 2) drawPencil(t); },
  onStep(stp){ if (stp === 1) drawSim(); if (stp === 2){ wmShare(); drawPencil(now()); drawCost(); } },
  onBlock(k){ openBlk = k; if (k === '0') drawOps(0); },
  buildReset(){ running = false; runLeft = 0; ghostsS = []; S.init(); drawSim(); },
  buildStart(){ running = true; drawSim(); if (reduce){ runLeft = S.t + 1; chunk(); } }
};
 }
});
})();
