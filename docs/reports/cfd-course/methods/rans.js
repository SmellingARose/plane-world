// Steady RANS (Reynolds-averaged Navier–Stokes) with Menter's SST k-ω model. See ../README.md for the spec.
(() => {
// ---------- the solver: fully developed turbulent channel flow, a 1D reduction of the 3D RANS equations ----------
// Outer units: half-height δ = 1, friction velocity u_τ = 1, so ν = 1/Re_τ and the driving pressure gradient −dp̄/dx = 1.
// Wall at y = 0, centreline (symmetry) at y = 1. Unknowns per node: ū (= ū_x), k, ω. Segregated pseudo-time iterations,
// each equation implicit (tridiagonal), destruction terms linearised implicitly (Patankar).
const SST = { bs: 0.09, a1: 0.31, k1: 0.85, w1: 0.5, b1: 0.075, g1: 5/9, k2: 1.0, w2: 0.856, b2: 0.0828, g2: 0.44 }; // Menter, Kuntz & Langtry 2003
const KW88 = { sk: 0.5, sw: 0.5, b: 0.075, g: 5/9 };                                                                   // Wilcox 1988
const KAPPA = 0.41, BLOG = 5.2, BUILD_CFL = 1000;
function Channel(re, model, NN, crude){
  const N = NN || 120, G = 3.3, nu = 1/re, C = SST;
  const F = () => new Float64Array(N+1);
  const y = F(), U = F(), k = F(), w = F(), nt = F(), F1 = F(), S = F(), Pk = F(), sk = F(), sw = F(), bt = F(), gm = F(), cd = F();
  for (let j=0;j<=N;j++) y[j] = 1 - Math.tanh(G*(1-j/N))/Math.tanh(G);   // tanh stretching: fine at the wall, coarse at the centre
  const a = F(), b = F(), c = F(), d = F(), cp = F(), dp = F(), wo = F();
  const wWall = 60*nu/(C.b1*y[1]*y[1]);                                  // Menter 1994: ω_wall = 10 · 6ν/(β₁ Δy₁²)
  const hist = [];
  // initial guess: a parabola for ū, k = u_τ², and ω from a mixing length (ν_t ≈ κy(1 − y/2)), capped by its near-wall value;
  // the crude guess (k = 0.5, ω = 20 everywhere) is used in block C, so the budget visibly evolves
  function init(){ for (let j=0;j<=N;j++){ const yy = y[j]; U[j] = 12*yy*(2-yy); k[j] = j ? (crude ? 0.5 : 1) : 0; w[j] = j ? (crude ? 20 : Math.max(1/(KAPPA*yy*(1-0.5*yy)), 6*nu/(C.b1*yy*yy))) : wWall; nt[j] = 0; F1[j] = 1; } hist.length = 0; it = 0; }
  // one implicit pseudo-time step of 0 = d/dy(Γ dφ/dy) + src − sp·φ; returns the scaled residual before the step
  function solve(phi, gam, src, sp, phi0, cfl){
    let r2 = 0;
    for (let j=1;j<=N;j++){
      const hm = y[j]-y[j-1], gmf = 0.5*(gam(j)+gam(j-1)); let aW, aE, D;
      if (j < N){ const hp = y[j+1]-y[j]; D = 0.5*(hp+hm); aW = gmf/(hm*D); aE = 0.5*(gam(j)+gam(j+1))/(hp*D); }
      else { D = hm; aW = 2*gmf/(hm*hm); aE = 0; }                      // symmetry: ghost node φ_{N+1} = φ_{N−1}
      const s = src(j), p = sp(j), aP0 = aW+aE+p;
      const R = aW*phi[j-1] + (j<N ? aE*phi[j+1] : 0) - aP0*phi[j] + s;
      r2 += (R/(aP0*Math.abs(phi[j]) + Math.abs(s) + 1e-30))**2;
      const idt = gam(j)/(cfl*D*D);                                      // local pseudo-time step Δτ = CFL·Δy²/Γ
      a[j] = -aW; b[j] = aP0 + idt; c[j] = -aE; d[j] = s + idt*phi[j];
    }
    d[1] -= a[1]*phi0; a[1] = 0;
    cp[1] = c[1]/b[1]; dp[1] = d[1]/b[1];
    for (let j=2;j<=N;j++){ const m = b[j]-a[j]*cp[j-1]; cp[j] = c[j]/m; dp[j] = (d[j]-a[j]*dp[j-1])/m; }
    phi[N] = dp[N]; for (let j=N-1;j>=1;j--) phi[j] = dp[j]-cp[j]*phi[j+1]; phi[0] = phi0;
    return Math.sqrt(r2/N);
  }
  const ddy = (f, j) => j === 0 ? (f[1]-f[0])/(y[1]-y[0]) : j === N ? 0 : (f[j+1]-f[j-1])/(y[j+1]-y[j-1]);
  let it = 0;
  const res = { U: 1, k: 1, w: 1 };
  const gU = j => nu+nt[j], gk = j => nu+sk[j]*nt[j], gw = j => nu+sw[j]*nt[j];
  function step(cfl){
    // 1. strain rate and blending functions from the current state
    for (let j=0;j<=N;j++) S[j] = Math.abs(ddy(U,j));
    // 2. eddy viscosity
    for (let j=1;j<=N;j++){
      const kk = Math.max(k[j],1e-14), ww = w[j], dd = y[j];
      if (model === 'sst'){
        const dk = ddy(k,j), dw = ddy(w,j), CDkw = Math.max(2*C.w2/ww*dk*dw, 1e-10);
        const ar1 = Math.min(Math.max(Math.sqrt(kk)/(C.bs*ww*dd), 500*nu/(dd*dd*ww)), 4*C.w2*kk/(CDkw*dd*dd));
        const f1 = Math.tanh(ar1**4), ar2 = Math.max(2*Math.sqrt(kk)/(C.bs*ww*dd), 500*nu/(dd*dd*ww)), f2 = Math.tanh(ar2*ar2);
        F1[j] = f1; nt[j] = C.a1*kk/Math.max(C.a1*ww, S[j]*f2);
        sk[j] = f1*C.k1+(1-f1)*C.k2; sw[j] = f1*C.w1+(1-f1)*C.w2; bt[j] = f1*C.b1+(1-f1)*C.b2; gm[j] = f1*C.g1+(1-f1)*C.g2;
        cd[j] = 2*(1-f1)*C.w2/ww*dk*dw;
      } else if (model === 'kw'){ F1[j] = 1; nt[j] = kk/ww; sk[j] = KW88.sk; sw[j] = KW88.sw; bt[j] = KW88.b; gm[j] = KW88.g; cd[j] = 0; }
      else nt[j] = 0;
    }
    nt[0] = 0; sk[0] = sk[1]; sw[0] = sw[1]; F1[0] = 1;
    // 3. momentum: 0 = 1 + d/dy[(ν+ν_t) dū/dy]
    res.U = solve(U, gU, () => 1, () => 0, 0, cfl);
    if (model === 'lam'){ res.k = res.w = 0; it++; hist.push(res.U); return res.U; }
    // 4. turbulence: k, then ω, with production from the new strain
    for (let j=0;j<=N;j++) S[j] = Math.abs(ddy(U,j));
    for (let j=1;j<=N;j++){ const p = nt[j]*S[j]*S[j]; Pk[j] = model === 'sst' ? Math.min(p, 10*C.bs*k[j]*w[j]) : p; }
    res.k = solve(k, gk, j => Pk[j], j => C.bs*w[j], 0, cfl);
    for (let j=1;j<=N;j++) if (k[j] < 1e-14) k[j] = 1e-14;
    wo.set(w);
    res.w = solve(w, gw, j => (nt[j] > 1e-30 ? gm[j]*Pk[j]/nt[j] : gm[j]*S[j]*S[j]) + bt[j]*wo[j]*wo[j] + Math.max(cd[j],0),
                         j => 2*bt[j]*wo[j] + Math.max(-cd[j],0)/wo[j], wWall, cfl);
    for (let j=1;j<=N;j++) if (!(w[j] > 1e-8)) w[j] = 1e-8;
    // 5. residual
    it++; const r = Math.max(res.U, res.k, res.w); hist.push(r); return r;
  }
  // the k budget in wall units: production, destruction, diffusion
  function budget(){ const P = F(), D = F(), Df = F();
    for (let j=1;j<N;j++){ const hm = y[j]-y[j-1], hp = y[j+1]-y[j], DD = 0.5*(hp+hm);
      Df[j] = (0.5*(gk(j)+gk(j+1))*(k[j+1]-k[j])/hp - 0.5*(gk(j)+gk(j-1))*(k[j]-k[j-1])/hm)/DD/re;
      P[j] = Pk[j]/re; D[j] = C.bs*k[j]*w[j]/re; }
    return { P, D, Df }; }
  function metrics(){
    let Ub = 0; for (let j=1;j<=N;j++) Ub += 0.5*(U[j]+U[j-1])*(y[j]-y[j-1]);
    const Reb = 2*Ub*re, Cf = 2/(Ub*Ub), Cfd = 0.073*Math.pow(Reb, -0.25);   // Dean 1978
    let dev = 0, nd = 0; for (let j=1;j<=N;j++){ const yp = y[j]*re; if (yp >= 30 && yp <= 0.2*re){ dev = Math.max(dev, Math.abs(U[j] - (Math.log(yp)/KAPPA + BLOG))); nd++; } }
    return { Ub, Reb, Cf, Cfd, dev: nd ? dev : NaN, Uc: U[N], y1p: y[1]*re };
  }
  init();
  return { y, U, k, w, nt, F1, S, Pk, sk, sw, bt, gm, hist, res, step, init, budget, metrics, N, re, model, get it(){ return it; } };
}
// values of a converged solution at a given y⁺, in wall units
function wallAt(ch, yp){ const re = ch.re, yy = yp/re; let j = 1; while (j < ch.N && ch.y[j] < yy) j++;
  const t = Math.max(0, Math.min(1, (yy-ch.y[j-1])/(ch.y[j]-ch.y[j-1]))), L = A => A[j-1] + t*(A[j]-A[j-1]);
  return { U: L(ch.U), k: L(ch.k), om: L(ch.w)/re, nt: L(ch.nt)*re, S: L(ch.S)/re, F1: L(ch.F1), P: L(ch.Pk)/re, bt: L(ch.bt), gm: L(ch.gm) }; }
function rng(seed){ let s = seed % 2147483647 || 7; const r = () => (s = (s*16807) % 2147483647) / 2147483647; for (let i=0;i<20;i++) r(); return r; }   // Park–Miller; the first draws of a small seed are tiny, so skip them
const gauss = r => Math.sqrt(-2*Math.log(r()+1e-12))*Math.cos(2*Math.PI*r());

// ---------- MathML helpers ----------
const T = (k, x) => `<mrow data-t="${k}">${x}</mrow>`;
const I_ = c => `<mi data-t="ij">${c}</mi>`;
const bar = s => `<mover accent="true"><mi>${s}</mi><mo>¯</mo></mover>`;
const ub = c => T('ub', `<msub>${bar('u')}${I_(c)}</msub>`);
const ui = c => T('u', `<msub><mi>u</mi>${I_(c)}</msub>`);
const up = c => T('up', `<msubsup><mi>u</mi>${I_(c)}<mo>′</mo></msubsup>`);
const rs = (a,b) => T('Rs', `<mo>⟨</mo>${up(a)}${up(b)}<mo>⟩</mo>`);
const Sb = (a,b) => T('S', `<msub>${bar('S')}<mrow>${I_(a)}${I_(b)}</mrow></msub>`);
const S2 = T('S', `<msup>${bar('S')}<mn>2</mn></msup>`);
const nut = T('nut', '<msub><mi>ν</mi><mi>t</mi></msub>');
const kk = '<mi data-t="k">k</mi>', om = '<mi data-t="om">ω</mi>', nu = '<mi data-t="nu">ν</mi>', rho = '<mi data-t="rho">ρ</mi>';
const dl = (a,b) => T('dl', `<msub><mi>δ</mi><mrow>${I_(a)}${I_(b)}</mrow></msub>`);
const dd = c => T('grad', `<msub><mo>∂</mo>${I_(c)}</msub>`);
const pb = T('p', bar('p'));
const fr = (a,b) => `<mfrac><mrow>${a}</mrow><mrow>${b}</mrow></mfrac>`;
const UB = (x, k, lab) => `<munder><munder><mrow>${x}</mrow><mo stretchy="true">⏟</mo></munder><mtext data-t="${k}" class="opl">${lab}</mtext></munder>`;
const nI = '<mi data-t="n">n</mi>';
const q = sup => T('q', sup ? `<msup><mi>q</mi>${sup}</msup>` : '<mi>q</mi>');
const Nxyz = ['x','y','z'].map(a => T('N', `<msub><mi>N</mi><mi>${a}</mi></msub>`)).join('<mo>×</mo>');
const R6 = `<msup><mi>ℝ</mi><mrow><mn>6</mn><mo>×</mo>${Nxyz}</mrow></msup>`;
const qa = T('q', `<msub><mi>q</mi><mrow><mi data-t="a">a</mi><mi data-t="ix">x</mi><mi data-t="iy">y</mi><mi data-t="iz">z</mi></mrow></msub>`);
const half = fr('<mn>1</mn>','<mn>2</mn>'), twoThirds = fr('<mn>2</mn>','<mn>3</mn>');
const bs = T('bs', '<msup><mi>β</mi><mo>*</mo></msup>'), beta = '<mi data-t="beta">β</mi>', gam = '<mi data-t="gam">γ</mi>';
const sig = s => T('sig', `<msub><mi>σ</mi><mi>${s}</mi></msub>`);
const Pk = T('Pk', '<msub><mover accent="true"><mi>P</mi><mo>~</mo></mover><mi>k</mi></msub>');
const RR = T('R', '<mi>R</mi>'), JJ = '<mi data-t="J">J</mi>', DQ = T('dq', '<mi>Δ</mi><mi>q</mi>'), DT = T('dtau', '<mi>Δ</mi><mi>τ</mi>');
const Rm = (r, c) => `<msup><mi>ℝ</mi><mrow><mn>${r}</mn><mo>×</mo><mn>${c}</mn></mrow></msup>`;
const Rsym = '<msubsup><mi>ℝ</mi><mtext>sym</mtext><mrow><mn>3</mn><mo>×</mo><mn>3</mn></mrow></msubsup>';
const R6N = '<msup><mi>ℝ</mi><mrow><mn>6</mn><mi>N</mi></mrow></msup>';
const ir = (k, s, rg, txt) => `<div class="ir" data-t="${k}"><span class="is"><math>${s}</math></span><span class="rg"><math>${rg}</math></span><span class="im">${txt}</span></div>`;
const deep = steps => `<details class="deep"><summary>Going a bit deeper <span class="note">· ${steps.length} steps</span></summary>${steps.map(([k, m, p]) => `<div class="dstep"><span class="k">${k}</span><div class="dm"><math display="block">${m}</math></div><p>${p}</p></div>`).join('')}</details>`;
const ctl = (id, sym, col, min, max, stp, val, out) => `<div class="ctl"><label for="rans-${id}" class="sym" style="color:var(${col})">${sym}</label><input type="range" id="rans-${id}" min="${min}" max="${max}" step="${stp}" value="${val}" style="accent-color:var(${col})"><output id="rans-${id}v">${out}</output></div>`;

// ---------- block HTML ----------
const B0 = `<div class="eqhero">
  <math display="block">${qa}<mo>∈</mo>${R6}<mspace width="2em"/>${RR}<mo>(</mo>${q()}<mo>)</mo><mo>=</mo><mn>0</mn></math>
  <math display="block" class="sm">${q(`<mrow>${nI}<mo>+</mo><mn>1</mn></mrow>`)}<mo>=</mo><mi data-t="I">I</mi><mo>(</mo>${q(nI)}<mo>)</mo><mo>,</mo><mspace width="1em"/><mi>n</mi><mo>=</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>,</mo><mn>2</mn><mo>,</mo><mo>…</mo><mspace width="1em"/><mtext>until</mtext><mspace width=".4em"/><mo>‖</mo>${RR}<mo>‖</mo><mo>&lt;</mo><msup><mn>10</mn><mrow><mo>−</mo><mn>9</mn></mrow></msup></math>
</div>
<div class="idx"><span class="eyebrow">Every index</span>
  ${ir('ij', '<mi>i</mi><mo>,</mo><mi>j</mi>', '<mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi>', 'Axis of a vector or tensor (ū<sub>i</sub>, S̄<sub>ij</sub>). Repeated in one term → summed over x, y, z: ∂<sub>j</sub>ū<sub>j</sub> = ∂<sub>x</sub>ū<sub>x</sub> + ∂<sub>y</sub>ū<sub>y</sub> + ∂<sub>z</sub>ū<sub>z</sub>.')}
  ${ir('a', '<mi>a</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mn>5</mn>', 'Which unknown: 0–2 = ū<sub>x</sub>, ū<sub>y</sub>, ū<sub>z</sub>; 3 = p̄; 4 = k; 5 = ω.')}
  ${ir('ix', '<mi>x</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>x</mi></msub><mo>−</mo><mn>1</mn>', 'Cell column (along the flow).')}
  ${ir('iy', '<mi>y</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>−</mo><mn>1</mn>', 'Cell row (away from the wall).')}
  ${ir('iz', '<mi>z</mi>', '<mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>−</mo><mn>1</mn>', 'Cell layer (across the span).')}
  ${ir('t', '<mi>t</mi>', '<mn>0</mn><mo>≤</mo><mi>t</mi><mo>≤</mo><mi>T</mi>', 'Physical time. It lives only inside the average ⟨·⟩ and is gone afterwards: the steady state has <em>no</em> t. (The t in ν<sub>t</sub> means “turbulent”, not time.)')}
  ${ir('s', '<mi>s</mi>', '<mn>1</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>s</mi></msub>', 'Sample number when the time average is taken from N<sub>s</sub> readings.')}
  ${ir('n', '<mi>n</mi>', '<mn>0</mn><mo>,</mo><mn>1</mn><mo>,</mo><mn>2</mn><mo>,</mo><mo>…</mo>', 'Iteration (pseudo-time level). Written up top (qⁿ) it is a label, not a power. The states in between mean nothing; only the converged one does.')}
</div>
<div class="dims">
  <div class="dim"><b>Fix a, x, y, z</b><math>${qa}<mo>∈</mo><mi>ℝ</mi></math><span>one number, e.g. ū<sub>x</sub> in one cell</span></div>
  <div class="dim"><b>Fix x, y, z</b><math>${T('q', `<msub><mi>q</mi><mi data-t="a">a</mi></msub>`)}<mo>∈</mo><msup><mi>ℝ</mi><mn>6</mn></msup></math><span>one cell: ū<sub>x</sub>, ū<sub>y</sub>, ū<sub>z</sub>, p̄, k, ω</span></div>
  <div class="dim"><b>Nothing fixed (the state)</b><math>${qa}<mo>∈</mo>${R6}</math><span>a 4-index array, no time index: 10⁶ cells → 6 × 10⁶ numbers</span></div>
  <div class="dim"><b>Never stored</b><math>${rs('i','j')}<mo>∈</mo>${Rsym}</math><span>6 numbers per cell that the model must supply</span></div>
</div>
<span class="eyebrow">The four operators, as maps</span>
<div class="dims">
  <div class="dim"><b><span style="color:var(--c-rho)">A</span> · average</b><math><mi data-t="A">A</mi><mo>:</mo>${ui('i')}<mo>(</mo><mi>𝐱</mi><mo>,</mo><mi data-t="t">t</mi><mo>)</mo><mo>↦</mo>${ub('i')}<mo>(</mo><mi>𝐱</mi><mo>)</mo></math><span>field over space and time → field over space; linear</span></div>
  <div class="dim"><b><span style="color:var(--c-c)">B</span> · closure</b><math><mi data-t="B">B</mi><mo>:</mo>${Rsym}<mo>×</mo><mi>ℝ</mi><mo>×</mo><mi>ℝ</mi><mo>→</mo>${Rsym}</math><span>(S̄<sub>ij</sub>, k, ν<sub>t</sub>) → Reynolds stress, cell by cell</span></div>
  <div class="dim"><b><span style="color:var(--c-cs)">M</span> · model sources</b><math><mi data-t="M">M</mi><mo>:</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>→</mo><msup><mi>ℝ</mi><mn>2</mn></msup></math><span>(k, ω, S̄) → net sources of k and ω; nonlinear, per cell</span></div>
  <div class="dim"><b><span style="color:var(--c-u)">I</span> · steady iteration</b><math><mi data-t="I">I</mi><mo>:</mo>${R6N}<mo>→</mo>${R6N}</math><span>qⁿ → qⁿ⁺¹ by solving JΔq = −R; global (N = N<sub>x</sub>N<sub>y</sub>N<sub>z</sub>)</span></div>
</div>
<span class="eyebrow">What the operators do, on one point of a channel</span>
<figure class="viz"><div class="scrollx"><canvas id="rans-opviz" data-w="880" data-h="350" aria-label="Animated walkthrough: a velocity signal is averaged by A, its fluctuations give Reynolds stresses, B models them, M gives the k sources, and I iterates the channel solver to convergence"></canvas></div>
  <div class="opctl"><button class="b" id="rans-opplay">Pause</button><div id="rans-opsteps" class="btns"></div></div>
  <p class="opcap" id="rans-opcap"></p></figure>
<aside class="insp" data-terms="q,a,A,Rs,B,M,I,R,N"></aside>
${deep([
 ['1', `<mtext>unknowns:</mtext><mspace width=".4em"/>${ub('i')}<mo>,</mo>${pb}<mspace width=".3em"/><mo>(</mo><mn>4</mn><mo>)</mo><mo>+</mo>${rs('i','j')}<mspace width=".3em"/><mo>(</mo><mn>6</mn><mo>)</mo><mspace width="1em"/><mo>&gt;</mo><mspace width="1em"/><mtext>equations:</mtext><mspace width=".4em"/><mn>1</mn><mo>+</mo><mn>3</mn>`, 'The closure problem in one line. Continuity and three momentum equations give 4 equations; averaging adds 6 unknown Reynolds stresses. The model closes the count: B writes the 6 stresses with one ν<sub>t</sub>, and two transport equations (k, ω) supply ν<sub>t</sub>. That is why the state has 6 entries per cell.'],
 ['2', `${RR}<mo>:</mo>${R6N}<mo>→</mo>${R6N}<mo>,</mo><mspace width="1em"/>${JJ}<mo>=</mo>${fr(`<mo>∂</mo>${RR}`, `<mo>∂</mo>${q()}`)}<mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>6</mn><mi>N</mi><mo>×</mo><mn>6</mn><mi>N</mi></mrow></msup>`, 'Steady RANS is one huge nonlinear system: the residual R has one entry per unknown. Its Jacobian J is sparse: each cell couples only to its 6 face neighbours, so a row has about 7 blocks of 6 × 6 non-zeros.'],
 ['3', `<mo>(</mo>${fr('<mi>V</mi>', DT)}<mo>+</mo>${JJ}<mo>)</mo>${DQ}<mo>=</mo><mo>−</mo>${RR}<mo>(</mo>${q(nI)}<mo>)</mo>`, 'Pseudo-time stepping: march a fake time τ until nothing changes. Δτ → ∞ is Newton’s method (fast near the answer, fragile far from it); a small Δτ is safe but slow. Only the end point matters, so Δτ can differ from cell to cell.']
])}`;

const BA = `<div class="eqhero">
  <math display="block">${ui('i')}<mo>=</mo>${ub('i')}<mo>+</mo>${up('i')}<mo>,</mo><mspace width="1.5em"/>${ub('i')}<mo>=</mo>${UB(`<mo>⟨</mo>${ui('i')}<mo>⟩</mo><mo>=</mo>${fr('<mn>1</mn>','<mi data-t="T">T</mi>')}<msubsup><mo>∫</mo><mn>0</mn><mi data-t="T">T</mi></msubsup>${ui('i')}<mspace width=".2em"/><mi>d</mi><mi data-t="t">t</mi>`, 'A', 'A: average over time')}</math>
  <math display="block">${dd('j')}<mo stretchy="false">(</mo>${ub('i')}${ub('j')}<mo stretchy="false">)</mo><mo>=</mo><mo>−</mo>${fr('<mn>1</mn>', rho)}${dd('i')}${pb}<mo>+</mo>${dd('j')}<mo stretchy="false">(</mo><mn>2</mn>${nu}${Sb('i','j')}${UB(`<mo>−</mo>${rs('i','j')}`, 'Rs', 'Reynolds stress')}<mo stretchy="false">)</mo></math>
  <math display="block" class="sm">${dd('i')}${ub('i')}<mo>=</mo><mn>0</mn><mspace width="1.5em"/><mtext>(mean continuity: 4 equations, 4 + 6 unknowns)</mtext></math>
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="rans-avgviz" data-w="460" data-h="480" aria-label="A turbulent channel: the instantaneous velocity profile jitters around the mean; a probe's signal, its running mean, and the scatter of its fluctuations u' against v'; drag the channel to rotate"></canvas>
    <div class="lg"><span style="color:var(--c-f)"><i class="ln"></i>instantaneous <math><msub><mi>u</mi><mi>x</mi></msub></math></span><span style="color:var(--c-rho)"><i class="ln dash"></i>mean <math><msub>${bar('u')}<mi>x</mi></msub></math></span><span style="color:var(--c-u)"><i class="ln"></i>fluctuation <math><msubsup><mi>u</mi><mi>x</mi><mo>′</mo></msubsup></math></span><span class="note">drag to rotate</span></div>
    ${ctl('win', '<i>N<sub>s</sub></i>', '--c-rho', 1, 3.6, 0.01, 2.6, '400')}
    ${ctl('yp', '<i>y</i>⁺', '--c-f', 20, 400, 1, 50, '50')}
    <div class="note" id="rans-avgcap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="A,u,ub,up,Rs,T,t,s,k,p,rho,nu,S,grad,ij"></aside>
</div>
${deep([
 ['1', `<mo>⟨</mo>${ub('i')}<mo>⟩</mo><mo>=</mo>${ub('i')}<mo>,</mo><mspace width=".8em"/><mo>⟨</mo>${up('i')}<mo>⟩</mo><mo>=</mo><mn>0</mn><mo>,</mo><mspace width=".8em"/><mo>⟨</mo>${dd('j')}${ui('i')}<mo>⟩</mo><mo>=</mo>${dd('j')}${ub('i')}`, 'The rules: the average of a mean is itself, fluctuations average to zero, and averaging commutes with derivatives (it is linear). So every linear term of Navier–Stokes just gets a bar.'],
 ['2', `<mo>⟨</mo>${ui('i')}${ui('j')}<mo>⟩</mo><mo>=</mo>${ub('i')}${ub('j')}<mo>+</mo><munder><munder><mrow><mo>⟨</mo>${ub('i')}${up('j')}<mo>⟩</mo><mo>+</mo><mo>⟨</mo>${up('i')}${ub('j')}<mo>⟩</mo></mrow><mo stretchy="true">⏟</mo></munder><mtext>= 0</mtext></munder><mo>+</mo>${rs('i','j')}`, 'The key step: convection u<sub>j</sub>∂<sub>j</sub>u<sub>i</sub> = ∂<sub>j</sub>(u<sub>i</sub>u<sub>j</sub>) is a product. The cross terms vanish, but the product of two fluctuations does not: that is the Reynolds stress, and it is the only new term.'],
 ['3', `${kk}<mo>=</mo>${half}${rs('i','i')}<mo>,</mo><mspace width="1em"/><msub><mo>∂</mo><mi data-t="t">t</mi></msub>${ub('i')}<mo>=</mo><mn>0</mn>`, 'What is thrown away: every unsteady motion, large or small. Its energy survives only as one number k per point (½ the trace of the stress), and its effect on the mean flow only through the model. Steady RANS even drops ∂<sub>t</sub>ū<sub>i</sub>: it assumes the averaged flow does not change.']
])}`;

const BB = `<div class="eqhero">
  <math display="block">${UB(`<mo>−</mo>${rs('i','j')}<mo>=</mo><mn>2</mn>${nut}${Sb('i','j')}<mo>−</mo>${twoThirds}${kk}${dl('i','j')}`, 'B', 'B: closure, stress from strain')}</math>
  <math display="block" class="sm">${Sb('i','j')}<mo>=</mo>${half}<mo>(</mo>${dd('j')}${ub('i')}<mo>+</mo>${dd('i')}${ub('j')}<mo>)</mo><mo>,</mo><mspace width="1.2em"/>${nut}<mo>=</mo>${fr(`<mi data-t="a1">a</mi><mn>₁</mn>${kk}`, `<mo>max</mo><mo>(</mo><mi data-t="a1">a</mi><mn>₁</mn>${om}<mo>,</mo><mspace width=".2em"/>${T('S', bar('S'))}<msub><mi data-t="F1">F</mi><mn>2</mn></msub><mo>)</mo>`)}<mspace width=".6em"/><mtext>(SST)</mtext></math>
</div>
<div class="bb">
  <figure class="viz">
    <canvas id="rans-bousviz" data-w="460" data-h="440" aria-label="A fluid cube deformed by the mean flow, with the model's stress on its faces, and the measured versus modelled Reynolds stress matrices; drag to rotate"></canvas>
    <div class="lg"><span style="color:var(--c-c)"><i class="ln"></i><math><mn>2</mn><msub><mi>ν</mi><mi>t</mi></msub><msub><mover accent="true"><mi>S</mi><mo>¯</mo></mover><mrow><mi>i</mi><mi>j</mi></mrow></msub><msub><mi>n</mi><mi>j</mi></msub></math> on a face</span><span style="color:var(--c-cs)"><i class="ln"></i><math><mo>−</mo><mfrac><mn>2</mn><mn>3</mn></mfrac><mi>k</mi><msub><mi>n</mi><mi>i</mi></msub></math> (isotropic)</span><span style="color:var(--c-eq)"><i class="ln dash"></i>stretch axes of S̄</span></div>
    <div class="btns" id="rans-flows"><button class="b pri" data-f="0">Shear (channel)</button><button class="b" data-f="1">Plane strain</button><button class="b" data-f="2">Rotation</button></div>
    ${ctl('gr', 'G', '--c-eq', 0, 0.15, 0.001, 0.049, '0.049')}
    ${ctl('nt', 'ν<sub>t</sub>/ν', '--c-c', 0, 60, 0.1, 18, '18.0')}
    <div class="note" id="rans-bcap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="B,Rs,S,nut,k,dl,om,a1,F1,ub,grad,ij"></aside>
</div>
${deep([
 ['1', `<msub><mi>σ</mi><mrow>${I_('i')}${I_('j')}</mrow></msub><mo>=</mo><mo>−</mo>${pb}${dl('i','j')}<mo>+</mo><mn>2</mn>${rho}${nu}${Sb('i','j')}<mspace width="1em"/><mo>⟶</mo><mspace width="1em"/><mo>−</mo>${rho}${rs('i','j')}<mo>≈</mo><mn>2</mn>${rho}${nut}${Sb('i','j')}<mo>−</mo>${twoThirds}${rho}${kk}${dl('i','j')}`, 'Where it comes from (Boussinesq, 1877): molecules carry momentum between layers and give the viscous stress 2ρνS̄<sub>ij</sub>. Eddies carry momentum too, so treat them as giant molecules with an eddy viscosity ν<sub>t</sub>. Unlike ν, ν<sub>t</sub> belongs to the flow, not the fluid.'],
 ['2', `<mo>−</mo>${rs('i','i')}<mo>=</mo><mn>2</mn>${nut}<munder><munder>${Sb('i','i')}<mo stretchy="true">⏟</mo></munder><mrow><mo>=</mo>${dd('i')}${ub('i')}<mo>=</mo><mn>0</mn></mrow></munder><mo>−</mo>${twoThirds}${kk}<munder><munder>${dl('i','i')}<mo stretchy="true">⏟</mo></munder><mn>3</mn></munder><mspace width="1em"/><mo>⇒</mo><mspace width="1em"/><mo>−</mo><mn>2</mn>${kk}<mo>=</mo><mo>−</mo><mn>2</mn>${kk}<mspace width=".4em"/><mo>✓</mo>`, 'Why the −⅔kδ<sub>ij</sub>: take the trace (set i = j, sum). The left side is −2k by definition of k. The strain term vanishes because the mean flow is incompressible, so without −⅔kδ<sub>ij</sub> the model would say k = 0.'],
 ['3', `${rs('i','j')}<mo>−</mo>${twoThirds}${kk}${dl('i','j')}<mo>∥</mo>${Sb('i','j')}`, 'What is assumed: the stress anisotropy is parallel to the strain, with one scalar ν<sub>t</sub>. Real turbulence remembers its history and feels rotation and curvature, so the model misses unequal normal stresses (and with them the secondary flow in a square duct) and over-produces k where flow hits a body. SST’s limiter and production cap patch the worst of it.']
])}`;

const BC = `<div class="eqhero">
  <math display="block">${ub('j')}${dd('j')}${kk}<mo>=</mo>${UB(`${Pk}<mo>−</mo>${T('Dk', `${bs}${kk}${om}`)}`, 'M', 'M: sources')}<mo>+</mo>${UB(T('Dif', `${dd('j')}<mo>[</mo><mo>(</mo>${nu}<mo>+</mo>${sig('k')}${nut}<mo>)</mo>${dd('j')}${kk}<mo>]</mo>`), 'Dif', 'diffusion')}</math>
  <math display="block" class="sm">${ub('j')}${dd('j')}${om}<mo>=</mo>${T('Pk', `${gam}${fr(Pk, nut)}`)}<mo>−</mo>${T('Dk', `${beta}<msup>${om}<mn>2</mn></msup>`)}<mo>+</mo>${T('Dif', `${dd('j')}<mo>[</mo><mo>(</mo>${nu}<mo>+</mo>${sig('ω')}${nut}<mo>)</mo>${dd('j')}${om}<mo>]</mo>`)}<mo>+</mo>${T('cd', `<mn>2</mn><mo>(</mo><mn>1</mn><mo>−</mo><msub><mi data-t="F1">F</mi><mn>1</mn></msub><mo>)</mo>${fr(`<msub><mi>σ</mi><mrow><mi>ω</mi><mn>2</mn></mrow></msub>`, om)}${dd('j')}${kk}${dd('j')}${om}`)}</math>
  <math display="block" class="sm">${Pk}<mo>=</mo><mo>min</mo><mo stretchy="false">(</mo>${nut}${S2}<mo>,</mo><mspace width=".2em"/><mn>10</mn>${bs}${kk}${om}<mo stretchy="false">)</mo><mspace width="2em"/>${UB(`${JJ}${DQ}<mo>=</mo><mo>−</mo>${RR}<mo>(</mo>${q(nI)}<mo>)</mo><mo>,</mo><mspace width=".5em"/>${q(`<mrow>${nI}<mo>+</mo><mn>1</mn></mrow>`)}<mo>=</mo>${q(nI)}<mo>+</mo>${DQ}`, 'I', 'I: one steady iteration')}</math>
</div>
<div class="bb">
  <figure class="viz">
    <div class="scrollx"><canvas id="rans-modviz" data-w="560" data-h="300" aria-label="The k budget across a channel at Re_tau 550 as the SST solver iterates, and the residual falling with each iteration"></canvas></div>
    <div class="btns" id="rans-mods"><button class="b pri" data-m="sst">SST (Menter 2003)</button><button class="b" data-m="kw">k-ω (Wilcox 1988)</button></div>
    ${ctl('cfl', 'CFL', '--c-u', 0.5, 4.7, 0.01, 3, '1000')}
    <div class="note" id="rans-modcap">&nbsp;</div>
  </figure>
  <aside class="insp" data-terms="M,Pk,Dk,Dif,k,om,bs,beta,gam,sig,F1,cd,I,R,J,dq,dtau,n"></aside>
</div>
${deep([
 ['1', `${Pk}<mo>≈</mo><mo>−</mo>${rs('i','j')}${dd('j')}${ub('i')}<mo>=</mo>${nut}${S2}<mo>,</mo><mspace width="1em"/><mi>ε</mi><mo>=</mo>${nu}<mo>⟨</mo>${dd('j')}${up('i')}${dd('j')}${up('i')}<mo>⟩</mo><mo>≈</mo>${bs}${kk}${om}`, 'Where the k equation comes from: multiply the fluctuation momentum equation by u′<sub>i</sub> and average. Production is exact once the stresses are known (Boussinesq makes it ν<sub>t</sub>S̄²). The dissipation ε and the transport terms are not, and are modelled: ε = β*kω, transport as gradient diffusion.'],
 ['2', `${kk}<mo>=</mo>${fr('<msubsup><mi>u</mi><mi>τ</mi><mn>2</mn></msubsup>', `<msqrt>${bs}</msqrt>`)}<mo>,</mo><mspace width=".6em"/>${om}<mo>=</mo>${fr('<msub><mi>u</mi><mi>τ</mi></msub>', `<msqrt>${bs}</msqrt><mi>κ</mi><mi>y</mi>`)}<mspace width="1em"/><mo>⇒</mo><mspace width="1em"/>${gam}<mo>=</mo>${fr(beta, bs)}<mo>−</mo>${fr(`${sig('ω')}<msup><mi>κ</mi><mn>2</mn></msup>`, `<msqrt>${bs}</msqrt>`)}<mo>=</mo><mn>0.553</mn>`, 'How the constants are chosen: in the log layer production balances destruction. Putting the log-law profile into the ω equation ties γ to the others: with β = 0.075, σ<sub>ω</sub> = 0.5, β* = 0.09 and κ = 0.41 it gives 0.553, which Wilcox and Menter round to 5/9. β* = 0.09 itself is −⟨u′v′⟩/k ≈ 0.3, squared.'],
 ['3', `<mo>(</mo>${fr('<mi>V</mi>', DT)}<mo>+</mo>${JJ}<mo>)</mo>${DQ}<mo>=</mo><mo>−</mo>${RR}<mspace width="1em"/><mo>→</mo><mspace width="1em"/><mtext>SIMPLE: </mtext><msubsup>${bar('u')}<mi>i</mi><mo>*</mo></msubsup><mo>,</mo><mspace width=".3em"/><msup><mi>p</mi><mo>′</mo></msup><mo>,</mo><mspace width=".3em"/><mtext>correct</mtext><mo>,</mo><mspace width=".3em"/>${kk}<mo>,</mo><mspace width=".3em"/>${om}`, 'Production codes rarely form the full J. SIMPLE (Patankar & Spalding, 1972) solves the equations one after another: predict ū* with the old pressure, solve a Poisson equation for a pressure correction p′ that restores ∂<sub>i</sub>ū<sub>i</sub> = 0 in every cell, correct, then update k and ω, all under-relaxed. Coupled (Newton–Krylov) solvers form J and converge in fewer, costlier iterations.']
])}`;

CFD.register({
 id: 'rans', name: 'Steady RANS', sub: 'averaged equations',
 lede: 'Average the turbulence away, model what it did to the mean flow with <strong>k</strong> and <strong>ω</strong>, then iterate one steady field until the equations hold everywhere.',
 blocks: [
  { key: '0', title: 'The objects', note: 'what goes in, what comes out', html: B0 },
  { key: 'A', title: 'Reynolds averaging', note: 'split, average, and six unknowns appear', html: BA },
  { key: 'B', title: 'Closure', note: 'the Boussinesq hypothesis: stress from strain', html: BB },
  { key: 'C', title: 'Model and steady solve', note: 'k and ω, then iterate to R = 0', html: BC }
 ],
 checks: {
  '0': [
   ['How many unknowns does steady RANS with a k-ω model store per cell?', ['3', '6', '19'], 1, 'ū_x, ū_y, ū_z, p̄, k and ω: 6 numbers per cell.'],
   ['Where is the time index t in the steady RANS state?', ['It is a seventh variable', 'Gone: averaging removed it, the answer is one steady field', 'It became the iteration index n'], 1, 't only appears inside the average ⟨·⟩. The steady solution q has no time index at all.'],
   ['What does the iteration index n count?', ['Physical time steps', 'Repeats of the update until the residual is tiny; the in-between states mean nothing', 'Grid cells'], 1, 'n labels pseudo-time levels. Only the converged qⁿ is physical.'],
   ['Which operator couples every cell to every other cell?', ['The closure map B', 'The model sources M', 'The steady iteration I, through its linear solve'], 2, 'B and M act cell by cell. I solves JΔq = −R, where J links neighbours and the solve spreads that across the whole mesh.'],
   ['You refine the mesh 2× along x, y and z. How many unknowns now?', ['2×', '6×', '8×'], 2, '2³ = 8× as many cells, each still with 6 unknowns. There is no time axis to refine.']
  ],
  A: [
   ['What is ⟨u′ᵢ⟩?', ['0, by definition', 'k', 'ūᵢ'], 0, 'u′ᵢ = uᵢ − ūᵢ, and averaging that gives ūᵢ − ūᵢ = 0.'],
   ['Why does averaging the momentum equation create a new term?', ['The pressure term is nonlinear', 'Convection is a product: ⟨uᵢuⱼ⟩ = ūᵢūⱼ + ⟨u′ᵢu′ⱼ⟩', 'Viscosity changes with time'], 1, 'Linear terms just get a bar; the quadratic convection term leaves the correlation ⟨u′ᵢu′ⱼ⟩ behind.'],
   ['Near a wall, gusts of fast fluid (u′ > 0) mostly move toward the wall (v′ < 0). What sign has ⟨u′v′⟩?', ['Positive', 'Negative', 'Zero'], 1, 'Sweeps (u′ > 0, v′ < 0) and ejections (u′ < 0, v′ > 0) dominate, so the product is mostly negative: the scatter tilts down.'],
   ['You average over a window shorter than the life of the big eddies. What happens?', ['The mean still wanders and the Reynolds stresses are noisy', 'Nothing; any window works', 'The flow becomes laminar'], 0, 'The error of a time average falls like 1/√(number of independent samples). Too short a window leaves the mean wandering, as the N_s slider shows.'],
   ['How many independent Reynolds stresses are there at one point?', ['3', '6', '9'], 1, '⟨u′ᵢu′ⱼ⟩ is a symmetric 3 × 3 matrix: 3 diagonal + 3 off-diagonal values.']
  ],
  B: [
   ['What does the Boussinesq hypothesis assume?', ['The Reynolds stress follows the mean strain rate through one scalar ν_t', 'Turbulence is isotropic everywhere', 'ν_t equals ν'], 0, 'Stress anisotropy ∝ strain, like a viscous fluid with an extra, flow-dependent viscosity.'],
   ['Why is the −⅔kδᵢⱼ term needed?', ['Without it the trace would give k = 0, because S̄ᵢᵢ = 0', 'It adds the pressure', 'Only for numerical stability'], 0, 'The trace of −⟨u′ᵢu′ⱼ⟩ is −2k; the strain term has zero trace in incompressible flow, so −⅔k·3 = −2k must come from somewhere.'],
   ['Pure rotation: S̄ᵢⱼ = 0. What shear stress does the model predict?', ['None: only ⅔k on the diagonal', 'A large one', 'One that grows with the rotation rate'], 0, 'The model only sees strain. Rotation, which real turbulence does feel, is invisible to it (try the Rotation button).'],
   ['In the log layer, what does the model get wrong?', ['The sign of the shear stress', 'The normal stresses: it gives ⟨u′²⟩ = ⟨v′²⟩ = ⟨w′²⟩, while measured ⟨u′²⟩ ≈ 3 ⟨v′²⟩', 'The mean flow direction'], 1, 'The diagonal of 2ν_tS̄ᵢⱼ is zero in simple shear, so all three normal stresses come out as ⅔k.'],
   ['What does SST’s ν_t = a₁k / max(a₁ω, S̄F₂) do?', ['Caps −⟨u′v′⟩ at a₁k (Bradshaw: ≈ 0.3k), which improves separation prediction', 'Makes ν_t negative', 'Turns turbulence off near walls'], 0, 'When strain is large the denominator becomes S̄F₂, so ν_tS̄ ≤ a₁k: shear stress can no longer outrun the turbulent energy.']
  ],
  C: [
   ['In the log layer, production and destruction of k are…', ['About equal (local equilibrium)', 'Production ≫ destruction', 'Both zero'], 0, 'P ≈ ε is the log-layer balance the constants are calibrated on: watch the green and red curves overlap.'],
   ['Which equation does the steady solver try to satisfy?', ['R(q) = 0', '∂ₜq = 1', 'Δq = q'], 0, 'Steady state means every residual vanishes; the iteration stops when ‖R‖ is tiny.'],
   ['You make the pseudo-time step Δτ huge. What happens?', ['The damping disappears: each step becomes a Newton-type step, fast near the answer, but no longer protected from a poor start', 'It becomes a physical time step', 'The answer changes'], 0, 'Push the CFL slider right: iterations drop, then stop improving past CFL ≈ 10³, because this solver updates ū, k, ω one after another. A fully coupled Newton solve converges faster near the answer but can diverge from a poor start. The converged answer never depends on Δτ.'],
   ['Right at the wall, which term balances the destruction of k?', ['Production', 'Viscous diffusion', 'Pressure'], 1, 'At the wall there is no turbulent shear stress, so production is 0; molecular diffusion carries k down to the wall where it is destroyed.'],
   ['What does SIMPLE’s pressure-correction step enforce?', ['Mass conservation (∂ᵢūᵢ = 0) in every cell', 'Energy conservation', 'k ≥ 0'], 0, 'p′ is chosen so the corrected face velocities carry no net mass into any cell (open the I panel for a worked duct).']
  ]
 },
 quiz: [
  ['What does steady RANS throw away?', ['Only the smallest eddies', 'All unsteadiness, large and small; its effect must be modelled', 'Viscosity'], 1, 'Averaging removes every fluctuation. The model (k, ω, ν_t) is all that is left of the turbulence.'],
  ['Why is RANS so much cheaper than LES or DNS?', ['It resolves only the smooth mean flow: far fewer cells and no time stepping', 'It uses no mesh', 'It skips the pressure'], 0, 'No eddies to resolve and no time history to march through: one steady solve.'],
  ['What is the closure problem?', ['Averaging creates the Reynolds stresses: more unknowns than equations', 'The mesh does not close at walls', 'Pressure has no equation'], 0, '4 equations, 4 + 6 unknowns. A model must supply the 6 stresses.'],
  ['Why does a steady RANS solver scale worse on clusters than LBM?', ['Its implicit solve couples all cells: halo exchanges every Krylov iteration plus global reductions for dot products and residuals', 'It uses more memory per cell', 'It cannot run on GPUs'], 0, 'Every Krylov iteration needs neighbour data and a global sum; LBM needs neither a global solve nor reductions.'],
  ['A cylinder sheds vortices. What does steady RANS give?', ['At best a time-averaged wake; often it will not converge, because the flow is not steady', 'The shedding frequency', 'The exact unsteady wake'], 0, 'Steady RANS assumes ∂ₜū = 0. Unsteady RANS (next method) keeps the time derivative.'],
  ['The Build solver works on y only. Why is that honest?', ['Fully developed channel flow is the same at every x and z, so the 3D RANS equations reduce exactly to ODEs in y', 'Because the flow is laminar', 'Because 1D runs faster'], 0, 'Homogeneity in x and z (and time) makes every x- and z-derivative of a mean vanish: this is exactly how turbulence models are calibrated.'],
  ['SST blends two models. What does it use near walls?', ['k-ω (β₁ = 0.075, σ_k1 = 0.85)', 'k-ε', 'No model'], 0, 'F₁ → 1 near walls (k-ω, good in the sublayer) and → 0 outside (k-ε, insensitive to free-stream ω).']
 ],
 build: {
  intro: 'Put the steps of one steady iteration in order. When it is right, your RANS solver runs below on a turbulent channel.',
  html: `<div class="scrollx"><canvas class="sim" id="rans-sim" data-w="760" data-h="330" aria-label="Your steady RANS solver: a 3D channel with the extruded mean velocity profile, u-plus against y-plus with the log law, and the residual per iteration; drag the channel to rotate"></canvas></div>
  <div class="row"><label for="rans-re">Re<sub>τ</sub> = <span id="rans-rev">550</span></label><input type="range" id="rans-re" min="0" max="5" step="1" value="2"><span class="btns" id="rans-bm"><button class="b pri" data-m="sst">SST</button><button class="b" data-m="kw">k-ω 1988</button><button class="b" data-m="lam">no model (ν<sub>t</sub> = 0)</button></span></div>
  <div class="note" id="rans-simcap">&nbsp;</div>
  <p class="note">An honest 1D reduction: in fully developed channel flow every mean quantity is the same at every x and z, so the 3D RANS equations collapse to ODEs in y. Wall at y = 0, symmetry at the centre, 120 points packed toward the wall (first point below y⁺ = 1), outer units u<sub>τ</sub> = δ = 1. Re<sub>τ</sub> values are those of the DNS of Moser, Kim &amp; Mansour (1999) and Lee &amp; Moser (2015).</p>`,
  steps: [
   'Strain rate S̄ and blending F₁, F₂ from the current ū, k, ω',
   'Eddy viscosity ν_t = a₁k / max(a₁ω, S̄F₂)',
   'Momentum: solve for ū with ν + ν_t',
   'Turbulence: solve k, then ω, with the new production',
   'Residual ‖R(q)‖: stop when it is tiny'
  ],
  hint: 'ν_t needs the strain and the blending; momentum needs ν_t; the model’s production needs the new ū; the convergence test comes last.',
  success: 'Your steady RANS solver is iterating. In 3D a pressure-correction step would sit between momentum and turbulence (SIMPLE); in a fully developed channel the pressure gradient is the fixed driving force, so it drops out.'
 },
 parallel: { html: `<div class="par">
  <div class="stack">
   <p><strong>Implicit and nonlinear.</strong> Each iteration solves J Δq = −R: a sparse system with 6 unknowns per cell, coupled to its 6 face neighbours. It is solved by a Krylov method (GMRES, BiCGStab) with an algebraic multigrid (AMG) or ILU preconditioner.</p>
   <p><strong>Domain decomposition.</strong> The mesh is cut into P parts, one per core or GPU. Each part keeps a one-cell <em>halo</em> copy of its neighbours’ edge cells and exchanges it before every matrix–vector product.</p>
   <p><strong>Global reductions.</strong> Every Krylov iteration needs dot products, and every outer iteration a residual norm: sums over <em>all</em> cells, so every rank waits for every other (an all-reduce, about log₂P network hops).</p>
  </div>
  <canvas id="rans-part" data-w="340" data-h="270" style="width:100%;max-width:340px;border-radius:8px;background:var(--bg)" aria-label="A cubic mesh cut into P parts; one part and its halo of ghost cells are highlighted"></canvas>
 </div>
 <h3 style="font-size:16px">Cut the mesh: halo against interior</h3>
 <p>Split a cube of cells into P parts and watch the surface-to-volume ratio: compute shrinks like 1/P, but halos shrink slower and the all-reduce gets <em>longer</em>. Find where communication costs more than computing.</p>
 <div class="ctl"><label for="rans-P">P</label><input type="range" id="rans-P" min="0" max="15" step="1" value="3"><output id="rans-Pv">8</output></div>
 <div class="ctl"><label for="rans-mesh">mesh</label><input type="range" id="rans-mesh" min="0" max="3" step="1" value="1"><output id="rans-meshv">64³</output></div>
 <div class="scrollx"><canvas id="rans-ptime" data-w="680" data-h="170" style="width:100%;border-radius:8px;background:var(--bg)" aria-label="Time per Krylov iteration split into compute, halo exchange and all-reduce, and the strong-scaling curve"></canvas></div>
 <div class="fb" id="rans-pfb"></div>
 <p class="note">Cost model (assumed, typical orders of magnitude): 0.5 µs of compute per cell per Krylov iteration, 2 µs latency per message or reduction hop, 10 GB/s links, 6 unknowns × 8 bytes per halo cell, 2 global reductions per iteration.</p>
 <details><summary>Further: why multigrid gets hard in parallel</summary><p>AMG builds ever coarser grids; on the coarse levels each rank owns only a handful of cells, so the levels become pure communication. Codes agglomerate coarse levels onto fewer ranks or switch to a direct solve there. Steady solvers also need many outer iterations, each with its own residual all-reduce; GPU implementations (e.g. matrix-free Newton–Krylov) cut memory traffic but keep the same global sums.</p></details>` },
 unlock: 'The Steady RANS row of the comparison is now visible: the cheapest workhorse for attached, steady flows, whose accuracy is set by its turbulence model. Complete the other methods to open the full page.',
 sources: [
  ['Reynolds, O. (1895). On the dynamical theory of incompressible viscous fluids and the determination of the criterion. Phil. Trans. R. Soc. A 186', 'https://doi.org/10.1098/rsta.1895.0004'],
  ['Schmitt, F. G. (2007). About Boussinesq’s turbulent viscosity hypothesis: historical remarks and a direct evaluation of its validity. C. R. Mécanique 335', 'https://doi.org/10.1016/j.crme.2007.08.004'],
  ['Wilcox, D. C. (1988). Reassessment of the scale-determining equation for advanced turbulence models. AIAA J. 26(11)', 'https://doi.org/10.2514/3.10041'],
  ['Menter, F. R. (1994). Two-equation eddy-viscosity turbulence models for engineering applications. AIAA J. 32(8)', 'https://doi.org/10.2514/3.12149'],
  ['Menter, Kuntz & Langtry (2003). Ten years of industrial experience with the SST turbulence model; constants as listed by the NASA Turbulence Modeling Resource', 'https://turbmodels.larc.nasa.gov/sst.html'],
  ['Bradshaw, Ferriss & Atwell (1967). Calculation of boundary-layer development using the turbulent energy equation. J. Fluid Mech. 28 (a₁ ≈ 0.3)', 'https://doi.org/10.1017/S0022112067001326'],
  ['Pope, S. B. (2000). Turbulent Flows. Cambridge University Press (Reynolds averaging, log law κ = 0.41, B = 5.2)', 'https://doi.org/10.1017/CBO9780511840531'],
  ['Moser, Kim & Mansour (1999). Direct numerical simulation of turbulent channel flow up to Re_τ = 590. Phys. Fluids 11', 'https://doi.org/10.1063/1.869966'],
  ['Lee & Moser (2015). Direct numerical simulation of turbulent channel flow up to Re_τ ≈ 5200. J. Fluid Mech. 774', 'https://doi.org/10.1017/jfm.2015.268'],
  ['Dean, R. B. (1978). Reynolds number dependence of skin friction and other bulk flow variables in two-dimensional rectangular duct flow. J. Fluids Eng. 100', 'https://doi.org/10.1115/1.3448633'],
  ['Patankar & Spalding (1972). A calculation procedure for heat, mass and momentum transfer in three-dimensional parabolic flows (SIMPLE). Int. J. Heat Mass Transfer 15', 'https://doi.org/10.1016/0017-9310(72)90054-3'],
  ['Gropp, Kaushik, Keyes & Smith (2001). High-performance parallel implicit CFD. Parallel Computing 27', 'https://doi.org/10.1016/S0167-8191(00)00075-2'],
  ['Henson & Yang (2002). BoomerAMG: a parallel algebraic multigrid solver and preconditioner. Appl. Numer. Math. 41', 'https://doi.org/10.1016/S0168-9274(01)00115-5']
 ],
 terms: {
  q: { sym: '<mi>q</mi>', name: 'State', def: 'Everything stored per cell: mean velocity ū_x, ū_y, ū_z, mean pressure p̄, and the model’s k and ω. No time index: the answer is one steady field.', space: `<msub><mi>q</mi><mrow><mi>a</mi><mi>x</mi><mi>y</mi><mi>z</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>6</mn><mo>×</mo><msub><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub><mi>N</mi><mi>z</mi></msub></mrow></msup>`, col: '--c-f', op: 'I' },
  a: { sym: '<mi>a</mi>', name: 'Variable index', def: 'Which of the 6 unknowns: 0–2 = ū_x, ū_y, ū_z; 3 = p̄; 4 = k; 5 = ω.', space: '<mi>a</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mn>5</mn><mo>}</mo>', col: '--c-f' },
  ix: { sym: '<mi>x</mi>', name: 'Cell column', def: 'Which column of the mesh, 0 … Nₓ−1. As a subscript of q it picks the cell.', space: '<mi>x</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>x</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>', col: '--ink' },
  iy: { sym: '<mi>y</mi>', name: 'Cell row', def: 'Which row, 0 … N_y−1 (away from the wall in the channel).', space: '<mi>y</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>', col: '--ink' },
  iz: { sym: '<mi>z</mi>', name: 'Cell layer', def: 'Which layer, 0 … N_z−1 (across the span).', space: '<mi>z</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>', col: '--ink' },
  N: { sym: '<msub><mi>N</mi><mi>x</mi></msub><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub>', name: 'Mesh size', def: 'Cells along x, y and z. RANS meshes are coarse away from walls (the mean flow is smooth) and very fine next to them.', space: '<msub><mi>N</mi><mi>x</mi></msub><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>∈</mo><mi>ℕ</mi>', col: '--ink' },
  t: { sym: '<mi>t</mi>', name: 'Physical time', def: 'Real time. It lives only inside the average and disappears: the steady RANS state has no t. (The t in ν_t means turbulent.)', space: '<mi>t</mi><mo>∈</mo><mo>[</mo><mn>0</mn><mo>,</mo><mi>T</mi><mo>]</mo><mo>⊂</mo><mi>ℝ</mi>', col: '--c-w' },
  T: { sym: '<mi>T</mi>', name: 'Averaging window', def: 'How long the average runs. It must be much longer than the slowest eddy, or the mean keeps wandering.', space: '<mi>T</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--c-w', op: 'A' },
  s: { sym: '<mi>s</mi>', name: 'Sample index', def: 'Numbers the N_s readings a discrete time average adds up.', space: '<mi>s</mi><mo>∈</mo><mo>{</mo><mn>1</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>s</mi></msub><mo>}</mo>', col: '--c-w', op: 'A' },
  n: { sym: '<mi>n</mi>', name: 'Iteration index', def: 'Counts steady iterations 0, 1, 2, … It is not time: the states on the way mean nothing, only the converged one. As a superscript (qⁿ) it is a label, not a power.', space: '<mi>n</mi><mo>∈</mo><mi>ℕ</mi>', col: '--c-w', op: 'I' },
  ij: { sym: '<mrow><mi>i</mi><mo>,</mo><mi>j</mi></mrow>', name: 'Axis indices', def: 'x, y or z. An index repeated in one term is summed over all three (Einstein convention).', space: '<mi>i</mi><mo>,</mo><mi>j</mi><mo>∈</mo><mo>{</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>}</mo>', col: '--ink' },
  u: { sym: '<msub><mi>u</mi><mi>i</mi></msub>', name: 'Instantaneous velocity', def: 'What a probe measures at one instant. In turbulence it jumps around by tens of percent.', space: '<msub><mi>u</mi><mi>i</mi></msub><mo>(</mo><mi>𝐱</mi><mo>,</mo><mi>t</mi><mo>)</mo><mo>∈</mo><mi>ℝ</mi><mo>,</mo><mspace width=".5em"/><mi>u</mi><mo>:</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>×</mo><mi>ℝ</mi><mo>→</mo><msup><mi>ℝ</mi><mn>3</mn></msup>', col: '--c-f' },
  ub: { sym: `<msub>${bar('u')}<mi>i</mi></msub>`, name: 'Mean velocity', def: 'The time average of uᵢ: smooth and steady. This is what RANS solves for.', space: `<msub>${bar('u')}<mi>i</mi></msub><mo>(</mo><mi>𝐱</mi><mo>)</mo><mo>∈</mo><mi>ℝ</mi><mo>,</mo><mspace width=".5em"/>${bar('u')}<mo>:</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>→</mo><msup><mi>ℝ</mi><mn>3</mn></msup>`, col: '--c-rho', op: 'A' },
  up: { sym: '<msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup>', name: 'Fluctuation', def: 'u′ᵢ = uᵢ − ūᵢ: the part averaging throws away. It averages to zero, but its products do not.', space: '<msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup><mo>(</mo><mi>𝐱</mi><mo>,</mo><mi>t</mi><mo>)</mo><mo>∈</mo><mi>ℝ</mi><mo>,</mo><mspace width=".5em"/><mo>⟨</mo><msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup><mo>⟩</mo><mo>=</mo><mn>0</mn>', col: '--c-u', op: 'A' },
  Rs: { sym: '<mo>⟨</mo><msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup><msubsup><mi>u</mi><mi>j</mi><mo>′</mo></msubsup><mo>⟩</mo>', name: 'Reynolds stress', def: 'Averages of products of fluctuations: 6 numbers per point. −ρ⟨u′ᵢu′ⱼ⟩ acts on the mean flow like an extra stress, and nobody knows it: the closure problem.', space: `<mo>⟨</mo><msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup><msubsup><mi>u</mi><mi>j</mi><mo>′</mo></msubsup><mo>⟩</mo><mo>∈</mo>${Rsym}<mspace width=".5em"/><mtext>per point</mtext>`, col: '--c-nu', op: 'B' },
  A: { sym: '<mi>A</mi>', name: 'Averaging operator', def: 'Takes a field over space and time and returns its time average, a field over space only. Like a daily mean temperature: the weather’s ups and downs vanish. Linear, and it commutes with derivatives.', space: '<mi>A</mi><mo>:</mo><mo>(</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>×</mo><mi>ℝ</mi><mo>→</mo><mi>ℝ</mi><mo>)</mo><mo>→</mo><mo>(</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>→</mo><mi>ℝ</mi><mo>)</mo><mo>,</mo><mspace width=".5em"/><mtext>linear</mtext>', col: '--c-rho', op: 'A' },
  p: { sym: bar('p'), name: 'Mean pressure', def: 'The time-averaged pressure. Its gradient pushes the mean flow; in the channel −∂ₓp̄ is the fixed driving force.', space: `${bar('p')}<mo>(</mo><mi>𝐱</mi><mo>)</mo><mo>∈</mo><mi>ℝ</mi>`, col: '--c-w' },
  rho: { sym: '<mi>ρ</mi>', name: 'Density', def: 'Constant here (incompressible flow).', space: '<mi>ρ</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub><mspace width=".5em"/><mtext>(constant)</mtext>', col: '--c-w' },
  nu: { sym: '<mi>ν</mi>', name: 'Kinematic viscosity', def: 'A property of the fluid (air ≈ 1.5 × 10⁻⁵ m²/s). It sets the thin viscous layer next to the wall.', space: '<mi>ν</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--c-w' },
  grad: { sym: '<msub><mo>∂</mo><mi>j</mi></msub>', name: 'Partial derivative', def: 'Rate of change along axis j.', space: '<msub><mo>∂</mo><mi>j</mi></msub><mo>:</mo><mtext>field → field, linear</mtext>', col: '--ink' },
  S: { sym: `<msub>${bar('S')}<mrow><mi>i</mi><mi>j</mi></mrow></msub>`, name: 'Mean strain rate', def: 'How fast the mean flow stretches and shears a fluid element: the symmetric half of ∂ⱼūᵢ. Its size is S̄ = √(2S̄ᵢⱼS̄ᵢⱼ).', space: `<msub>${bar('S')}<mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo>${Rsym}<mo>,</mo><mspace width=".5em"/><msub>${bar('S')}<mrow><mi>i</mi><mi>i</mi></mrow></msub><mo>=</mo><mn>0</mn>`, col: '--c-eq', op: 'B' },
  nut: { sym: '<msub><mi>ν</mi><mi>t</mi></msub>', name: 'Eddy viscosity', def: 'How strongly the eddies mix momentum, written as an extra viscosity. A property of the flow, not the fluid: often 100–1000 × ν away from walls.', space: '<msub><mi>ν</mi><mi>t</mi></msub><mo>(</mo><mi>𝐱</mi><mo>)</mo><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>', col: '--c-c', op: 'B' },
  k: { sym: '<mi>k</mi>', name: 'Turbulent kinetic energy', def: 'k = ½⟨u′ᵢu′ᵢ⟩: the energy per unit mass hidden in the fluctuations. Carried by its own transport equation.', space: '<mi>k</mi><mo>(</mo><mi>𝐱</mi><mo>)</mo><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>', col: '--c-cs', op: 'M' },
  om: { sym: '<mi>ω</mi>', name: 'Specific dissipation rate', def: 'ω = ε/(β*k): how fast eddies lose their energy, in 1/time. √k/ω is the size of the energetic eddies.', space: '<mi>ω</mi><mo>(</mo><mi>𝐱</mi><mo>)</mo><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--c-tau', op: 'M' },
  dl: { sym: '<msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>', name: 'Kronecker delta', def: '1 if i = j, else 0: the 3 × 3 identity in index notation. δᵢᵢ = 3.', space: `<msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>∈</mo>${Rm(3,3)}`, col: '--c-w' },
  B: { sym: '<mi>B</mi>', name: 'Boussinesq closure map', def: 'Turns the mean strain, with k and ν_t, into the six Reynolds stresses: eddies treated like extra-sticky molecules. Linear in S̄, applied cell by cell.', space: `<mi>B</mi><mo>:</mo>${Rsym}<mo>×</mo><mi>ℝ</mi><mo>×</mo><mi>ℝ</mi><mo>→</mo>${Rsym}`, col: '--c-c', op: 'B' },
  a1: { sym: '<msub><mi>a</mi><mn>1</mn></msub>', name: 'Bradshaw constant', def: 'a₁ = 0.31. Caps the shear stress at a₁k, from Bradshaw’s observation that −⟨u′v′⟩ ≈ 0.3k in boundary layers. The heart of SST.', space: '<msub><mi>a</mi><mn>1</mn></msub><mo>=</mo><mn>0.31</mn>', col: '--c-c', op: 'B' },
  F1: { sym: '<msub><mi>F</mi><mn>1</mn></msub><mo>,</mo><msub><mi>F</mi><mn>2</mn></msub>', name: 'Blending functions', def: 'F₁ is 1 near walls (k-ω constants) and 0 far away (k-ε constants). F₂ turns the ν_t limiter on inside boundary layers. Both depend on wall distance, k and ω.', space: '<msub><mi>F</mi><mn>1</mn></msub><mo>,</mo><msub><mi>F</mi><mn>2</mn></msub><mo>:</mo><mo>(</mo><mi>d</mi><mo>,</mo><mi>k</mi><mo>,</mo><mi>ω</mi><mo>)</mo><mo>→</mo><mo>[</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>]</mo>', col: '--c-w', op: 'M' },
  M: { sym: '<mi>M</mi>', name: 'Model source map', def: 'Per cell: from k, ω and the mean strain, how much k and ω are made and destroyed. Like a bank balance: income (production) against spending (destruction). Nonlinear.', space: '<mi>M</mi><mo>:</mo><mo>(</mo><mi>k</mi><mo>,</mo><mi>ω</mi><mo>,</mo><mover accent="true"><mi>S</mi><mo>¯</mo></mover><mo>)</mo><mo>∈</mo><msup><mi>ℝ</mi><mn>3</mn></msup><mo>→</mo><msup><mi>ℝ</mi><mn>2</mn></msup>', col: '--c-cs', op: 'M' },
  Pk: { sym: '<msub><mover accent="true"><mi>P</mi><mo>~</mo></mover><mi>k</mi></msub>', name: 'Production', def: 'Energy the mean shear feeds into the eddies, ν_tS̄². SST caps it at 10β*kω so it cannot run away where flow hits a body.', space: '<msub><mover accent="true"><mi>P</mi><mo>~</mo></mover><mi>k</mi></msub><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>', col: '--c-c', op: 'M' },
  Dk: { sym: '<msup><mi>β</mi><mo>*</mo></msup><mi>k</mi><mi>ω</mi>', name: 'Destruction', def: 'Energy the smallest eddies turn into heat (the dissipation ε = β*kω); in the ω equation βω² plays the same role.', space: '<msup><mi>β</mi><mo>*</mo></msup><mi>k</mi><mi>ω</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub>', col: '--c-nu', op: 'M' },
  Dif: { sym: '<msub><mo>∂</mo><mi>j</mi></msub><mo>[</mo><mo>(</mo><mi>ν</mi><mo>+</mo><mi>σ</mi><msub><mi>ν</mi><mi>t</mi></msub><mo>)</mo><msub><mo>∂</mo><mi>j</mi></msub><mo>·</mo><mo>]</mo>', name: 'Diffusion', def: 'Spreads k and ω from where they are made to where they are not: molecular ν plus eddy mixing σν_t. It is what carries k down to the wall.', space: '<mtext>field → field, linear in </mtext><mi>k</mi><mtext> (or </mtext><mi>ω</mi><mtext>)</mtext>', col: '--c-f' },
  bs: { sym: '<msup><mi>β</mi><mo>*</mo></msup>', name: 'β*', def: 'β* = 0.09: sets ε = β*kω. Its square root (0.3) is the log-layer ratio −⟨u′v′⟩/k.', space: '<msup><mi>β</mi><mo>*</mo></msup><mo>=</mo><mn>0.09</mn>', col: '--c-nu', op: 'M' },
  beta: { sym: '<mi>β</mi>', name: 'β', def: 'Destruction coefficient of ω: β₁ = 0.075 near walls, β₂ = 0.0828 outside, blended with F₁.', space: '<mi>β</mi><mo>=</mo><msub><mi>F</mi><mn>1</mn></msub><mo>·</mo><mn>0.075</mn><mo>+</mo><mo>(</mo><mn>1</mn><mo>−</mo><msub><mi>F</mi><mn>1</mn></msub><mo>)</mo><mo>·</mo><mn>0.0828</mn>', col: '--c-nu', op: 'M' },
  gam: { sym: '<mi>γ</mi>', name: 'γ', def: 'Production coefficient of ω: γ₁ = 5/9 near walls, γ₂ = 0.44 outside. Tied to the others by the log law.', space: '<mi>γ</mi><mo>=</mo><msub><mi>F</mi><mn>1</mn></msub><mo>·</mo><mfrac><mn>5</mn><mn>9</mn></mfrac><mo>+</mo><mo>(</mo><mn>1</mn><mo>−</mo><msub><mi>F</mi><mn>1</mn></msub><mo>)</mo><mo>·</mo><mn>0.44</mn>', col: '--c-c', op: 'M' },
  sig: { sym: '<msub><mi>σ</mi><mi>k</mi></msub><mo>,</mo><msub><mi>σ</mi><mi>ω</mi></msub>', name: 'Diffusion coefficients', def: 'How strongly eddies spread k and ω: σ_k = 0.85 → 1.0 and σ_ω = 0.5 → 0.856 from wall to free stream (SST).', space: '<msub><mi>σ</mi><mi>k</mi></msub><mo>,</mo><msub><mi>σ</mi><mi>ω</mi></msub><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--c-f' },
  cd: { sym: '<mi>C</mi><msub><mi>D</mi><mrow><mi>k</mi><mi>ω</mi></mrow></msub>', name: 'Cross diffusion', def: 'The extra term that turns k-ω into k-ε away from walls, where (1 − F₁) → 1. It removes k-ω’s sensitivity to the free-stream ω.', space: '<mi>C</mi><msub><mi>D</mi><mrow><mi>k</mi><mi>ω</mi></mrow></msub><mo>∈</mo><mi>ℝ</mi>', col: '--c-w', op: 'M' },
  I: { sym: '<mi>I</mi>', name: 'Steady iteration map', def: 'One update of everything: measure the residual, solve the linearised system for a correction, add it. Repeat until R ≈ 0. Like tuning a guitar: pluck, adjust, pluck again.', space: `<mi>I</mi><mo>:</mo>${R6N}<mo>→</mo>${R6N}<mo>,</mo><mspace width=".5em"/><mi>N</mi><mo>=</mo><msub><mi>N</mi><mi>x</mi></msub><msub><mi>N</mi><mi>y</mi></msub><msub><mi>N</mi><mi>z</mi></msub>`, col: '--c-u', op: 'I' },
  R: { sym: '<mi>R</mi>', name: 'Residual', def: 'How badly the current state breaks the steady equations, cell by cell. Zero means solved.', space: `<mi>R</mi><mo>:</mo>${R6N}<mo>→</mo>${R6N}<mo>,</mo><mspace width=".5em"/><mtext>nonlinear</mtext>`, col: '--c-nu', op: 'I' },
  J: { sym: '<mi>J</mi>', name: 'Jacobian', def: 'J = ∂R/∂q: how each residual reacts to each unknown. Sparse: a cell couples only to its face neighbours.', space: '<mi>J</mi><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>6</mn><mi>N</mi><mo>×</mo><mn>6</mn><mi>N</mi></mrow></msup><mo>,</mo><mspace width=".5em"/><mtext>sparse</mtext>', col: '--c-tau', op: 'I' },
  dq: { sym: '<mi>Δ</mi><mi>q</mi>', name: 'Correction', def: 'What one iteration adds to the state.', space: `<mi>Δ</mi><mi>q</mi><mo>∈</mo>${R6N}`, col: '--c-f', op: 'I' },
  dtau: { sym: '<mi>Δ</mi><mi>τ</mi>', name: 'Pseudo-time step', def: 'A fake time step that damps each correction. Small: safe but slow. Δτ → ∞: Newton’s method. Usually set per cell through a CFL number.', space: '<mi>Δ</mi><mi>τ</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>', col: '--c-w', op: 'I' }
 },
 bench(){
  const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now()), out = [];
  for (const re of [550, 5200]) {
   { const w = Channel(re, 'sst'); for (let i=0;i<30;i++) w.step(BUILD_CFL); }   // warm-up (JIT)
   const ch = Channel(re, 'sst'); let n = 0; const t0 = now(); while (n < 3000 && ch.step(BUILD_CFL) > 1e-9) n++; const t1 = now(); const m = ch.metrics();
   out.push(`Re_τ=${re}: ${n} iterations, ${((t1-t0)/n).toFixed(3)} ms/iteration (${(t1-t0).toFixed(0)} ms total, ${BUILD_PER_FRAME} per frame), C_f ${(100*(m.Cf/m.Cfd-1)).toFixed(1)}% vs Dean, max |u⁺ − log law| ${m.dev.toFixed(2)} for 30 ≤ y⁺ ≤ 0.2Re_τ`);
  }
  return out.join(' | ');
 },
 mount(root, K){ return mountRans.call(this, root, K); }
});

const BUILD_PER_FRAME = 1;
const REs = [180, 395, 550, 1000, 2000, 5200];

// ---------- everything that draws ----------
function mountRans(root, K){
const {$, reduce, MONO, MATH, P, hidpi, arrow, rr, pill, label, ease, lerp, clamp, proj, orbit, isAct} = K;
const triad = K.triad;
const F10 = '10px "IBM Plex Mono", monospace', F11 = '11px "IBM Plex Mono", monospace', B11 = '600 11px "IBM Plex Mono", monospace', B12 = '600 12px "IBM Plex Mono", monospace', SANS = '600 12px "IBM Plex Sans", sans-serif';
const vis = cv => cv.offsetParent !== null;
const fx = (v, d=2) => (v < 0 ? '−' : '') + Math.abs(v).toFixed(d);
const SUP = {'-':'⁻','0':'⁰','1':'¹','2':'²','3':'³','4':'⁴','5':'⁵','6':'⁶','7':'⁷','8':'⁸','9':'⁹'};
const sci = (v, d=1) => { if (!(v > 0)) return '0'; const e = Math.floor(Math.log10(v)); return `${(v/10**e).toFixed(d)}×10${String(e).split('').map(c => SUP[c]).join('')}`; };
const line = (c, pts, col, lw, dash) => { c.strokeStyle = col; c.lineWidth = lw; c.setLineDash(dash || []); c.beginPath(); pts.forEach(([x,y],i) => i ? c.lineTo(x,y) : c.moveTo(x,y)); c.stroke(); c.setLineDash([]); };
const P3 = (V, x, y, z) => proj(V, x, y, z);
function boxAt(c, V, x0, x1, y0, y1, z0, z1, col, lw, dash){ const pts = [x0,x1].flatMap(x => [y0,y1].flatMap(y => [z0,z1].map(z => [x,y,z])));
  c.strokeStyle = col; c.lineWidth = lw; c.setLineDash(dash || []); c.beginPath();
  pts.forEach((a,i) => pts.forEach((b,j) => { if (i < j && (a[0]!==b[0]) + (a[1]!==b[1]) + (a[2]!==b[2]) === 1) { const A1 = P3(V, ...a), A2 = P3(V, ...b); c.moveTo(A1[0],A1[1]); c.lineTo(A2[0],A2[1]); } }));
  c.stroke(); c.setLineDash([]); }
function quad(c, V, pts, fill, alpha){ c.globalAlpha = alpha; c.fillStyle = fill; c.beginPath(); pts.forEach((p3,i) => { const [x,y] = P3(V, ...p3); i ? c.lineTo(x,y) : c.moveTo(x,y); }); c.closePath(); c.fill(); c.globalAlpha = 1; }

// ---- the reference solution: SST at Re_τ = 550, converged once at mount ----
const RE0 = 550, base = Channel(RE0, 'sst');
for (let i=0;i<800;i++) if (base.step(BUILD_CFL) < 1e-11) break;
const baseHist = base.hist.slice(), baseB = base.budget();
// synthetic turbulence with channel-like statistics: k, −⟨u′v′⟩ and ū from the SST solution, k split 55/20/25 % into
// ⟨u′²⟩, ⟨v′²⟩, ⟨w′²⟩ as DNS shows in the log layer (Moser, Kim & Mansour 1999); a first-order random process in time
const SHARE = [0.55, 0.20, 0.25];
function statsAt(yp){ const w = wallAt(base, yp), k2 = 2*w.k; return { U: w.U, su: Math.sqrt(k2*SHARE[0]), sv: Math.sqrt(k2*SHARE[1]), sw: Math.sqrt(k2*SHARE[2]), uv: -w.nt*w.S, w }; }
function makeSig(seed, st, ph){ const r = rng(seed), g = () => gauss(r); let a = g(), b = g(), c = g(); const qq = Math.sqrt(1-ph*ph);
  return () => { a = ph*a+qq*g(); b = ph*b+qq*g(); c = ph*c+qq*g(); const rh = clamp(st.uv/(st.su*st.sv), -0.9, 0.9);
    return [st.U + st.su*(rh*a + Math.sqrt(1-rh*rh)*b), st.sv*a, st.sw*c]; }; }
function covOf(X, n0, n1){ const n = n1-n0, m = [0,0,0], C = [[0,0,0],[0,0,0],[0,0,0]];
  for (let s=n0;s<n1;s++) for (let i=0;i<3;i++) m[i] += X[i][s]/n;
  for (let s=n0;s<n1;s++) for (let i=0;i<3;i++) for (let j=0;j<3;j++) C[i][j] += (X[i][s]-m[i])*(X[j][s]-m[j])/n;
  return { m, C, k: 0.5*(C[0][0]+C[1][1]+C[2][2]) }; }
// the walkthrough's probe: y⁺ = 50, 4000 samples (400 drawn)
const YP0 = 50, ST0 = statsAt(YP0), NS0 = 4000, W0 = [[],[],[]];
{ const g = makeSig(11, ST0, 0.75); for (let s=0;s<NS0;s++){ const v = g(); for (let i=0;i<3;i++) W0[i].push(v[i]); } }
const S0 = covOf(W0, 0, NS0), w50 = ST0.w;
const modM = (k, nt, G) => [[2/3*k, -nt*G, 0], [-nt*G, 2/3*k, 0], [0, 0, 2/3*k]];   // ⟨u′ᵢu′ⱼ⟩ = ⅔kδᵢⱼ − 2ν_tS̄ᵢⱼ in simple shear

function drawMat(c, x0, y0, cs, M, p, opt){
  const sc = opt.scale || Math.max(...M.flat().map(Math.abs)), nm = ['x','y','z'];
  for (let i=0;i<3;i++) for (let j=0;j<3;j++){ const v = M[i][j], on = opt.hi ? opt.hi(i,j) : true, x = x0+j*cs, y = y0+i*cs;
    c.globalAlpha = (opt.alpha ?? 1) * (on ? 1 : .35); c.fillStyle = v >= 0 ? opt.pos : opt.neg; c.globalAlpha *= .1 + .5*Math.min(1, Math.abs(v)/sc); rr(c, x+1, y+1, cs-2, cs-2, 5); c.fill();
    c.globalAlpha = (opt.alpha ?? 1) * (on ? 1 : .45); label(c, fx(v, Math.abs(v) < 10 ? 2 : 1), x+cs/2, y+cs/2+4, p.ink, cs > 40 ? B11 : '600 10px "IBM Plex Mono", monospace', 'center'); c.globalAlpha = 1; }
  c.globalAlpha = opt.alpha ?? 1;
  for (let i=0;i<3;i++){ label(c, nm[i], x0-7, y0+i*cs+cs/2+4, p.mut, MATH, 'center'); label(c, nm[i], x0+i*cs+cs/2, y0-5, p.mut, MATH, 'center'); }
  c.globalAlpha = 1; }

// ================= 0: operator walkthrough =================
const CO = hidpi($('opviz'));
const OPS = [
 ['u(t)', 'Start: a probe 50 wall units above a channel wall records the velocity (u, v, w) 4000 times (400 drawn). Turbulence makes it jump around, like a wind gauge on a gusty day. (A synthetic signal with the statistics of the SST solution and DNS-like component shares.)'],
 ['A', 'A averages each component over time: thousands of readings become 3 numbers ūᵢ. The leftovers u′ = u − ū average to exactly zero. Like a daily mean temperature: the weather’s ups and downs vanish from the number.'],
 ['⟨u′u′⟩', 'Products of fluctuations do not average to zero. Gusts that push forward (u′ > 0) tend to push toward the wall (v′ < 0), so ⟨u′v′⟩ < 0. These 6 averages (a symmetric 3 × 3 matrix) are the Reynolds stresses: new unknowns, the closure problem.'],
 ['B', 'B builds them from the mean flow alone: ⅔k on the diagonal minus 2ν_t times the mean strain. The shear stress comes out close; the three normal stresses are forced to be equal, which the data contradict. A model, not a law.'],
 ['M', 'M feeds the model: production ν_tS̄² (energy taken from the mean shear) against destruction β*kω (energy turned into heat). At y⁺ = 50 they nearly cancel: the log-layer balance. Like income and spending of a bank account.'],
 ['I', 'I repeats the whole update until nothing changes. This is the real channel solver of the Build step: the residual ‖R(q)‖ falls by 10 orders of magnitude. Like tuning a guitar: pluck, adjust, pluck again.']];
let opStage = 0, opT = 0, opPlay = !reduce, opLast = null;
const opBtns = $('opsteps');
opBtns.innerHTML = OPS.map(([n],k) => `<button class="b opb" data-k="${k}">${k+1} · ${n}</button>`).join('');
opBtns.onclick = e => { const b = e.target.closest('.opb'); if (!b) return; opStage = +b.dataset.k; opT = 0; opCap(); K.pin([null,'A','Rs','B','M','I'][opStage]); if (reduce) drawOps(0); };
$('opplay').onclick = e => { opPlay = !opPlay; e.target.textContent = opPlay ? 'Pause' : 'Play'; };
function opCap(){ $('opcap').textContent = OPS[opStage][1]; opBtns.querySelectorAll('.opb').forEach((b,k) => b.classList.toggle('pri', k === opStage)); }
opCap();
const ntSST50 = w50.nt, Gp50 = w50.S, model50 = modM(S0.k, ntSST50, Gp50);
function drawOps(now){
  const dt = opLast === null ? 0 : Math.min(100, now - opLast); opLast = now;
  opT = Math.min(opPlay ? 99 : 3.6, opT + dt/1000); if (opPlay && opT > 3.8) { opT = 0; opStage = (opStage+1) % OPS.length; opCap(); }
  const c = CO, W = c.W, H = c.H, p = P(), e = reduce ? 1 : ease(opT/2.2), st = opStage;
  c.clearRect(0,0,W,H);
  const on = k => st === k, dim = k => st >= k ? 1 : .22, hd = (t, x, y, k) => label(c, t, x, y, on(k) ? p.ink : st >= k ? p.mut : p.rule, SANS);
  // --- signal strips ---
  const sx0 = 22, sx1 = 330, NSH = 400, X = s => sx0 + (sx1-sx0)*s/NSH, rows = [['u', 0, p.f, 52], ['v', 1, p.c, 100], ['w', 2, p.tau, 146]];
  hd('probe signal · y⁺ = 50 · Re_τ = 550', sx0, 18, 0);
  const shown = st === 0 ? Math.max(2, Math.floor(NSH*e)) : NSH;
  rows.forEach(([nm, i, col, yc]) => { const sd = Math.sqrt(S0.C[i][i]), Y = v => yc - (v - S0.m[i])/sd*6.5;
    label(c, nm, sx0-12, yc+4, col, MATH, 'center');
    if (st >= 1) { c.globalAlpha = (st === 1 ? e : 1)*.35; c.fillStyle = p.u; c.beginPath(); c.moveTo(X(0), Y(S0.m[i])); for (let s=0;s<NSH;s++) c.lineTo(X(s), Y(W0[i][s])); c.lineTo(X(NSH-1), Y(S0.m[i])); c.closePath(); c.fill(); c.globalAlpha = 1; }
    const pts = []; for (let s=0;s<shown;s++) pts.push([X(s), Y(W0[i][s])]); line(c, pts, col, 1.1);
    if (st >= 1) { const xe = st === 1 ? lerp(sx0, sx1, e) : sx1; line(c, [[sx0, Y(S0.m[i])], [xe, Y(S0.m[i])]], p.rho, 2, [6,4]); } });
  label(c, `samples s = 1 … 400 shown (statistics use all ${NS0})`, sx0, 180, p.mut, F10);
  // --- A: the mean ---
  const ar = (x0, x1, y, nm, sub, k) => { const a = on(k); arrow(c, x0, y, x1, y, a ? p.ink : st >= k ? p.mut : p.rule, a ? 2.6 : 1.6); label(c, nm, (x0+x1)/2, y-9, a ? p.ink : p.mut, MATH, 'center'); if (sub) label(c, sub, (x0+x1)/2, y+16, a ? p.ink : p.mut, F10, 'center'); };
  ar(338, 380, 88, 'A', 'average', 1);
  { const x0 = 392; hd('ūᵢ · 3 numbers', x0, 18, 1); c.globalAlpha = dim(1);
    ['ū_x','ū_y','ū_z'].forEach((nm, i) => { const v = S0.m[i] * (st === 1 ? e : 1), y = 44 + i*42, w = Math.abs(v)/S0.m[0]*92;
      c.fillStyle = p.rho; rr(c, x0+34, y-9, Math.max(2, w), 16, 3); c.fill(); label(c, nm, x0, y+4, p.rho, F11); label(c, fx(v), x0+40+Math.max(2,w), y+4, p.ink, B11); });
    label(c, 'u′ = u − ū averages to 0', x0, 168, p.mut, F10); c.globalAlpha = 1; }
  // --- Reynolds stresses ---
  ar(530, 566, 88, '⟨u′u′⟩', '', 2);
  { const x0 = 586, y0 = 40, cs = 34; hd('⟨u′ᵢu′ⱼ⟩ · 6 unknowns', x0-12, 18, 2);
    const M = S0.C.map(r => r.map(v => v*(st === 2 ? e : 1)));
    drawMat(c, x0, y0, cs, st >= 2 ? M : S0.C, p, { pos: p.nu, neg: p.f, scale: S0.C[0][0], alpha: dim(2), hi: (i,j) => st !== 2 || (i+j === 1) || isAct('Rs') });
    c.globalAlpha = dim(2); label(c, `k = ½ trace = ${S0.k.toFixed(2)}`, x0, y0+3*cs+18, p.cs, B11); c.globalAlpha = 1;
    // scatter u′ v′
    const qx = 815, qy = 92, R = 46; c.globalAlpha = dim(2); c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(qx-R, qy); c.lineTo(qx+R, qy); c.moveTo(qx, qy-R); c.lineTo(qx, qy+R); c.stroke();
    label(c, 'u′', qx+R+2, qy+4, p.mut, F10); label(c, 'v′', qx+3, qy-R+4, p.mut, F10);
    const nsc = st === 2 ? Math.floor(300*e) : 300;
    c.fillStyle = p.u; for (let s=0;s<nsc;s++){ const a = (W0[0][s]-S0.m[0])/Math.sqrt(S0.C[0][0])*15, b = (W0[1][s]-S0.m[1])/Math.sqrt(S0.C[1][1])*15; if (Math.abs(a) < R && Math.abs(b) < R) c.fillRect(qx+a-1, qy-b-1, 2, 2); }
    label(c, 'sweeps & ejections', qx, qy+R+14, p.mut, F10, 'center'); c.globalAlpha = 1; }
  // --- bottom row: B, M, I ---
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(14, 192); c.lineTo(W-14, 192); c.stroke();
  { const x0 = 76, y0 = 230, cs = 34; label(c, 'B', 22, 280, on(3) ? p.ink : p.mut, MATH); arrow(c, 34, 276, 56, 276, on(3) ? p.ink : p.rule, on(3) ? 2.4 : 1.4);
    hd('model: ⅔kδᵢⱼ − 2ν_tS̄ᵢⱼ', 60, 206, 3);
    const M = model50.map(r => r.map(v => v*(st === 3 ? e : 1)));
    drawMat(c, x0, y0, cs, st >= 3 ? M : model50, p, { pos: p.nu, neg: p.f, scale: S0.C[0][0], alpha: dim(3), hi: (i,j) => !(st >= 3 && isAct('k')) || i === j });
    c.globalAlpha = dim(3);
    label(c, `ν_t/ν = ${ntSST50.toFixed(1)}, dū/dy = ${Gp50.toFixed(3)}`, 60, 344, p.mut, F10);
    if (st >= 3) { const dx = 190; label(c, 'model vs data', dx, 236, p.ink, B11);
      [['shear u′v′', model50[0][1], S0.C[0][1]], ['u′²', model50[0][0], S0.C[0][0]], ['v′²', model50[1][1], S0.C[1][1]], ['w′²', model50[2][2], S0.C[2][2]]].forEach(([nm, mv, dv], r) => {
        const yy = 256 + r*20, ok = Math.abs(mv-dv) < 0.25*Math.abs(dv); label(c, `${nm}: ${fx(mv)} vs ${fx(dv)}`, dx, yy, ok ? p.ok : p.warm, F10); }); }
    c.globalAlpha = 1; }
  { const x0 = 380, base = 320; label(c, 'M', 350, 280, on(4) ? p.ink : p.mut, MATH); arrow(c, 362, 276, 376, 276, on(4) ? p.ink : p.rule, on(4) ? 2.4 : 1.4);
    hd('k sources at y⁺ = 50 (SST)', x0, 206, 4); c.globalAlpha = dim(4);
    const Pv = w50.P, Dv = SST.bs*w50.k*w50.om, sc = 92/Math.max(Pv, Dv), g = st === 4 ? e : 1;
    [['P̃_k = ν_tS̄²', Pv, p.c], ['β*kω', Dv, p.nu]].forEach(([nm, v, col], i) => { const x = x0 + 18 + i*90, h = v*sc*g; c.fillStyle = col; rr(c, x, base-h, 40, h, 3); c.fill();
      label(c, nm, x+20, base+14, col, F10, 'center'); label(c, v.toFixed(4), x+20, base-h-6, p.ink, B11, 'center'); });
    label(c, `net ${fx(Pv-Dv, 4)}: almost balanced`, x0, 344, p.mut, F10); c.globalAlpha = 1; }
  { const x0 = 600, x1 = 860, y0 = 222, y1 = 318; label(c, 'I', 566, 280, on(5) ? p.ink : p.mut, MATH); arrow(c, 576, 276, 592, 276, on(5) ? p.ink : p.rule, on(5) ? 2.4 : 1.4);
    hd('‖R(qⁿ)‖ · real channel solve', x0, 206, 5); c.globalAlpha = dim(5);
    const n = baseHist.length, Xn = i => x0 + (x1-x0)*i/(n-1), Yr = r => y0 + (y1-y0)*clamp((0 - Math.log10(r))/11, 0, 1);
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0-4); c.lineTo(x0, y1); c.lineTo(x1, y1); c.stroke();
    label(c, '1', x0-4, y0+4, p.mut, F10, 'right'); label(c, '10⁻¹¹', x0-4, y1+3, p.mut, F10, 'right');
    const shownN = st === 5 ? Math.max(2, Math.floor(n*e)) : n, pts = []; for (let i=0;i<shownN;i++) pts.push([Xn(i), Yr(baseHist[i])]);
    line(c, pts, p.u, 2);
    label(c, `iteration n = ${shownN} of ${n}`, x0, 344, p.mut, F10); c.globalAlpha = 1; }
}

// ================= HOW IT WORKS panels =================
const mt = s => `<div class="hm"><math display="block">${s}</math></div>`, tc = (col, x) => `<mrow style="color:var(${col})">${x}</mrow>`, sw = col => `<i class="tb" style="background:var(${col})"></i>`;
const eex = (lab, attr, list, cur) => `<div class="eex"><span>${lab}</span>${list.map(([v,n]) => `<button class="b${v === cur ? ' pri' : ''}" data-${attr}="${v}">${n}</button>`).join('')}</div>`;
const bindEx = (root, attr, set, redraw) => root.querySelectorAll(`[data-${attr}]`).forEach(b => b.onclick = () => { set(b.dataset[attr]); root.querySelectorAll(`[data-${attr}]`).forEach(x => x.classList.toggle('pri', x === b)); redraw(); });
const HS = { A: { q: 'uv', n: 100 }, B: { f: 0 }, M: { y: 50 }, I: { g: 0 } };
const HOW = {
 A: { html: () => `<span class="eyebrow">How A works</span>
   <p>Add up many readings s = 1 … N<sub>s</sub> of the same point and divide (a time average):</p>
   ${mt(`<mo>⟨</mo><mi>φ</mi><mo>⟩</mo><mo>=</mo><mfrac><mn>1</mn><mi>T</mi></mfrac><msubsup><mo>∫</mo><mn>0</mn><mi>T</mi></msubsup><mi>φ</mi><mspace width=".2em"/><mi>d</mi><mi>t</mi><mo>≈</mo>${tc('--c-rho', '<mfrac><mn>1</mn><msub><mi>N</mi><mi>s</mi></msub></mfrac><munder><mo>∑</mo><mi>s</mi></munder><msup><mi>φ</mi><mrow><mo>(</mo><mi>s</mi><mo>)</mo></mrow></msup>')}<mo>,</mo><mspace width="1em"/>${tc('--c-u', '<msup><mi>u</mi><mo>′</mo></msup><mo>=</mo><mi>u</mi><mo>−</mo><mo>⟨</mo><mi>u</mi><mo>⟩</mo>')}<mo>,</mo><mspace width="1em"/>${tc('--c-nu', '<mo>⟨</mo><msup><mi>u</mi><mo>′</mo></msup><msup><mi>v</mi><mo>′</mo></msup><mo>⟩</mo>')}`)}
   <div class="eterms"><span>${sw('--c-rho')}mean</span><span>Sum ÷ count: one number per component. More samples → steadier answer (error ∝ 1/√N<sub>s</sub>).</span>
     <span>${sw('--c-u')}u′</span><span>What is left after subtracting the mean. Its own average is 0 by construction.</span>
     <span>${sw('--c-nu')}⟨u′v′⟩</span><span>Average of a product of fluctuations: not 0. These six numbers are the Reynolds stresses.</span></div>
   ${eex('Quantity', 'q', [['u','u'],['v','v'],['uv','u′v′'],['k','k']], HS.A.q)}${eex('Samples N<sub>s</sub>', 'n', [[10,'10'],[100,'100'],[1000,'1000'],[4000,'4000']], HS.A.n)}
   <canvas class="hc" data-w="420" data-h="104"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), n = +HS.A.n, qk = HS.A.q, S = covOf(W0, 0, n);
   const val = s => { const a = W0[0][s]-S.m[0], b = W0[1][s]-S.m[1], d = W0[2][s]-S.m[2]; return qk === 'u' ? W0[0][s] : qk === 'v' ? W0[1][s] : qk === 'uv' ? a*b : 0.5*(a*a+b*b+d*d); };
   const vals = []; for (let s=0;s<n;s++) vals.push(val(s));
   const mean = vals.reduce((x,y) => x+y, 0)/n, sd = Math.sqrt(vals.reduce((x,y) => x+(y-mean)**2, 0)/n);
   const all = qk === 'u' ? S0.m[0] : qk === 'v' ? S0.m[1] : qk === 'uv' ? S0.C[0][1] : S0.k;
   const lo = Math.min(mean - 2.5*sd, all), hi = Math.max(mean + 2.5*sd, all), Y = v => 90 - (v-lo)/(hi-lo)*80;
   c.clearRect(0,0,c.W,c.H); const show = Math.min(n, 400);
   c.fillStyle = qk === 'uv' ? p.nu : qk === 'k' ? p.cs : p.f; c.globalAlpha = .55;
   for (let s=0;s<show;s++){ c.beginPath(); c.arc(12 + 396*s/Math.max(1,show-1), Y(vals[s]), show > 100 ? 1.4 : 2.4, 0, 7); c.fill(); } c.globalAlpha = 1;
   line(c, [[8, Y(all)], [412, Y(all)]], p.mut, 1, [2,3]);
   line(c, [[8, Y(mean)], [412, Y(mean)]], p.rho, 2.4);
   label(c, `mean of ${n}`, 410, Y(mean)-5, p.rho, B11, 'right'); label(c, `all ${NS0}`, 410, Y(all)+12, p.mut, F10, 'right');
   const nm = { u: 'ū', v: 'v̄', uv: '⟨u′v′⟩', k: 'k = ½⟨u′ᵢu′ᵢ⟩' }[qk], f3 = vals.slice(0,3).map(v => fx(v)).join(' + ');
   root.querySelector('.ecalc').textContent = `${nm} ≈ (1/${n})(${f3} + …) = ${fx(mean)}   (all ${NS0} samples: ${fx(all)}; with ${n} the scatter of the mean is ≈ ±${(sd/Math.sqrt(n/7)).toFixed(2)})`; },
  bind(root){ bindEx(root, 'q', v => HS.A.q = v, () => this.draw(root)); bindEx(root, 'n', v => HS.A.n = +v, () => this.draw(root)); } },
 B: { html: () => `<span class="eyebrow">How B works</span>
   <p>Read the mean strain off the velocity gradient, then turn it into a stress with one number ν<sub>t</sub>:</p>
   ${mt(`<mo>⟨</mo><msubsup><mi>u</mi><mi>i</mi><mo>′</mo></msubsup><msubsup><mi>u</mi><mi>j</mi><mo>′</mo></msubsup><mo>⟩</mo><mo>=</mo>${tc('--c-cs', '<mfrac><mn>2</mn><mn>3</mn></mfrac><mi>k</mi><msub><mi>δ</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub>')}<mo>−</mo>${tc('--c-c', `<mn>2</mn><msub><mi>ν</mi><mi>t</mi></msub><msub>${bar('S')}<mrow><mi>i</mi><mi>j</mi></mrow></msub>`)}<mo>,</mo><mspace width="1em"/>${tc('--c-eq', `<msub>${bar('S')}<mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>=</mo><mfrac><mn>1</mn><mn>2</mn></mfrac><mo>(</mo><msub><mi>G</mi><mrow><mi>i</mi><mi>j</mi></mrow></msub><mo>+</mo><msub><mi>G</mi><mrow><mi>j</mi><mi>i</mi></mrow></msub><mo>)</mo>`)}`)}
   <div class="eterms"><span>${sw('--c-eq')}S̄ᵢⱼ</span><span>Symmetric half of the gradient Gᵢⱼ = ∂ⱼūᵢ. Rotation (the other half) is thrown away.</span>
     <span>${sw('--c-c')}2ν<sub>t</sub>S̄ᵢⱼ</span><span>The deviatoric part: eddies resist being strained, like a thick liquid.</span>
     <span>${sw('--c-cs')}⅔kδᵢⱼ</span><span>The isotropic part: k shared equally over x, y, z, like a pressure.</span></div>
   ${eex('Mean flow', 'f', [[0,'shear (y⁺ = 50)'],[1,'plane strain'],[2,'rotation']], HS.B.f)}
   <canvas class="hc" data-w="420" data-h="144"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), f = +HS.B.f, g = Gp50, nt = ntSST50, k = S0.k;
   const G = f === 0 ? [[0,g,0],[0,0,0],[0,0,0]] : f === 1 ? [[g/2,0,0],[0,-g/2,0],[0,0,0]] : [[0,-g/2,0],[g/2,0,0],[0,0,0]];
   const S = G.map((r,i) => r.map((v,j) => 0.5*(G[i][j]+G[j][i]))), M = S.map((r,i) => r.map((v,j) => (i === j ? 2/3*k : 0) - 2*nt*v));
   c.clearRect(0,0,c.W,c.H); label(c, 'S̄ᵢⱼ (×100)', 20, 14, p.eq, B11); label(c, '⟨u′ᵢu′ⱼ⟩ model', 262, 14, p.c, B11);
   drawMat(c, 30, 34, 34, S.map(r => r.map(v => v*100)), p, { pos: p.eq, neg: p.f, scale: 5 }); drawMat(c, 290, 34, 34, M, p, { pos: p.nu, neg: p.f, scale: 2.5 });
   arrow(c, 150, 85, 262, 85, p.c, 2); label(c, 'B', 206, 77, p.c, MATH, 'center');
   root.querySelector('.ecalc').textContent = `k = ${k.toFixed(2)}, ν_t/ν = ${nt.toFixed(1)}, rate ${g.toFixed(4)}: ⟨u′v′⟩ = −2 × ${nt.toFixed(1)} × ${S[0][1].toFixed(4)} = ${fx(M[0][1])};  ⟨u′u′⟩ = ⅔ × ${k.toFixed(2)} − 2 × ${nt.toFixed(1)} × ${fx(S[0][0],4)} = ${fx(M[0][0])}${f === 2 ? '  · rotation has no strain: no shear stress at all' : ''}`; },
  bind(root){ bindEx(root, 'f', v => HS.B.f = +v, () => this.draw(root)); } },
 M: { html: () => `<span class="eyebrow">How M works</span>
   <p>In each cell, compare what is made with what is destroyed (SST, wall units):</p>
   ${mt(`<msub><mi>s</mi><mi>k</mi></msub><mo>=</mo>${tc('--c-c', `<mo>min</mo><mo>(</mo><msub><mi>ν</mi><mi>t</mi></msub><msup>${bar('S')}<mn>2</mn></msup><mo>,</mo><mn>10</mn><msup><mi>β</mi><mo>*</mo></msup><mi>k</mi><mi>ω</mi><mo>)</mo>`)}<mo>−</mo>${tc('--c-nu', '<msup><mi>β</mi><mo>*</mo></msup><mi>k</mi><mi>ω</mi>')}<mo>,</mo><mspace width="1em"/><msub><mi>s</mi><mi>ω</mi></msub><mo>=</mo>${tc('--c-c', `<mi>γ</mi><msup>${bar('S')}<mn>2</mn></msup>`)}<mo>−</mo>${tc('--c-nu', '<mi>β</mi><msup><mi>ω</mi><mn>2</mn></msup>')}`)}
   <div class="eterms"><span>${sw('--c-c')}production</span><span>Mean shear feeds the eddies. Capped at 10β*kω (stagnation points).</span>
     <span>${sw('--c-nu')}destruction</span><span>The smallest eddies turn k into heat; βω² keeps ω from growing without bound.</span></div>
   ${eex('Example, y⁺ =', 'y', [[2,'2'],[12,'12'],[50,'50'],[200,'200']], HS.M.y)}
   <canvas class="hc" data-w="420" data-h="100"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), yp = +HS.M.y, w = wallAt(base, yp);
   const Pr = Math.min(w.nt*w.S*w.S, 10*SST.bs*w.k*w.om), Dk = SST.bs*w.k*w.om, Pw = w.gm*w.S*w.S, Dw = w.bt*w.om*w.om;
   c.clearRect(0,0,c.W,c.H);
   [[['k', Pr, Dk], 4], [['ω', Pw, Dw], 214]].forEach(([[nm, a, b], x0]) => { const sc = 80/Math.max(a, b, 1e-12);
     label(c, `${nm} equation`, x0, 14, p.ink, B11);
     [[a, p.c, 'make'], [b, p.nu, 'destroy']].forEach(([v, col, t], i) => { const y = 30 + i*28; c.fillStyle = col; rr(c, x0+46, y, Math.max(2, v*sc), 18, 3); c.fill(); label(c, t, x0, y+13, col, F10); label(c, sci(v, 2), x0+51+Math.max(2, v*sc), y+13, p.ink, F10); });
     label(c, `net ${a >= b ? 'gain' : 'loss'} ${Math.round(100*Math.abs(a-b)/Math.max(a,b))} %`, x0, 94, p.mut, F10); });
   root.querySelector('.ecalc').textContent = `y⁺ = ${yp}: k = ${w.k.toFixed(3)}, ω = ${sci(w.om, 2)}, ν_t/ν = ${w.nt.toFixed(2)}, S̄ = ${w.S.toFixed(4)}, F₁ = ${w.F1.toFixed(2)} → P̃_k = ${sci(Pr, 2)}, β*kω = ${sci(Dk, 2)}. ${yp < 5 ? 'Next to the wall production is tiny: diffusion brings k in.' : yp < 30 ? 'Buffer layer: production beats destruction; diffusion carries the surplus away.' : 'Log layer: made ≈ destroyed.'}`; },
  bind(root){ bindEx(root, 'y', v => HS.M.y = +v, () => this.draw(root)); } },
 I: { html: () => `<span class="eyebrow">How I works</span>
   <p>One SIMPLE iteration: predict the velocity with the old pressure, then fix the pressure so no cell gains or loses mass. A worked duct of 4 cells:</p>
   ${mt(`<msub><mi>u</mi><mi>f</mi></msub><mo>=</mo>${tc('--c-f', '<msubsup><mi>u</mi><mi>f</mi><mo>*</mo></msubsup>')}<mo>+</mo>${tc('--c-u', '<mi>d</mi><mo>(</mo><msubsup><mi>p</mi><mi>L</mi><mo>′</mo></msubsup><mo>−</mo><msubsup><mi>p</mi><mi>R</mi><mo>′</mo></msubsup><mo>)</mo>')}<mo>,</mo><mspace width="1em"/>${tc('--c-nu', '<munder><mo>∑</mo><mtext>faces</mtext></munder><msub><mi>A</mi><mi>f</mi></msub><msub><mi>u</mi><mi>f</mi></msub><mo>=</mo><mn>0</mn>')}`)}
   <div class="eterms"><span>${sw('--c-f')}u*</span><span>Momentum predictor: velocities from the old pressure. They do not conserve mass.</span>
     <span>${sw('--c-u')}d·Δp′</span><span>Correction: a higher p′ on the left pushes extra fluid right (d = 0.5 here).</span>
     <span>${sw('--c-nu')}continuity</span><span>One equation per cell for p′ (a 1D Poisson problem): flux in = flux out.</span></div>
   ${eex('Predicted u*', 'g', [[0,'guess 1'],[1,'guess 2 (ignores the throat)']], HS.I.g)}
   <canvas class="hc" data-w="420" data-h="142"></canvas><div class="ecalc"></div>
   <p class="note">Newton view: all of this approximates J Δq = −R. In the Build channel v̄ = 0 and the pressure gradient is the given driving force, so the correction is not needed there.</p>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), A = [1, 0.8, 0.6, 0.8, 1], d = 0.5;
   const us = HS.I.g == 1 ? [1, 1, 1, 1, 1] : [1, 1.15, 1.5, 1.2, 1.05];
   const m = [0,1,2,3].map(cI => A[cI+1]*us[cI+1] - A[cI]*us[cI]);
   // tridiagonal for p′: d(A_{c+1} + A_c[c>0]) p′_c − dA_{c+1} p′_{c+1} − dA_c p′_{c−1} = −m_c   (p′ beyond the outlet = 0)
   const aa = [], bb = [], cc = [], rr_ = []; for (let cI=0;cI<4;cI++){ aa.push(cI > 0 ? -d*A[cI] : 0); bb.push(d*(A[cI+1] + (cI > 0 ? A[cI] : 0))); cc.push(cI < 3 ? -d*A[cI+1] : 0); rr_.push(-m[cI]); }
   for (let i=1;i<4;i++){ const f = aa[i]/bb[i-1]; bb[i] -= f*cc[i-1]; rr_[i] -= f*rr_[i-1]; }
   const pp = [0,0,0,0]; pp[3] = rr_[3]/bb[3]; for (let i=2;i>=0;i--) pp[i] = (rr_[i]-cc[i]*pp[i+1])/bb[i];
   const uc = us.map((u, f) => f === 0 ? u : u + d*(pp[f-1] - (f < 4 ? pp[f] : 0)));
   c.clearRect(0,0,c.W,c.H); const x0 = 30, fw = 90, yc = 52, H0 = 34;
   c.fillStyle = p.accSoft; c.beginPath(); A.forEach((a,f) => c.lineTo(x0+f*fw, yc-a*H0)); [...A].reverse().forEach((a,f) => c.lineTo(x0+(4-f)*fw, yc+a*H0)); c.closePath(); c.fill();
   c.strokeStyle = p.mut; c.lineWidth = 1.2; c.stroke();
   A.forEach((a,f) => { const x = x0+f*fw; line(c, [[x, yc-a*H0], [x, yc+a*H0]], p.rule, 1, [3,3]);
     arrow(c, x-14, yc-8, x-14+us[f]*26, yc-8, p.f, 1.8, true); arrow(c, x-14, yc+8, x-14+uc[f]*26, yc+8, p.u, 2.2); });
   line(c, [[x0, 112], [x0+4*fw, 112]], p.rule, 1); pp.forEach((v,i) => { const x = x0+(i+.5)*fw, h = v*36; c.fillStyle = p.c; c.globalAlpha = .7; rr(c, x-8, h >= 0 ? 112-h : 112, 16, Math.max(1, Math.abs(h)), 2); c.fill(); c.globalAlpha = 1; label(c, 'p′' + '₀₁₂₃'[i] + ' = ' + fx(v), x, 134, p.c, F10, 'center'); });
   label(c, '┄ u*', 6, 12, p.f, F10); label(c, '— corrected u', 50, 12, p.u, F10);
   root.querySelector('.ecalc').textContent = `mass imbalance A·u* per cell: ${m.map(v => fx(v,3)).join(', ')} → solve 4 equations for p′ = ${pp.map(v => fx(v,3)).join(', ')} → corrected fluxes A·u = ${uc.map((u,f) => (A[f]*u).toFixed(3)).join(', ')}: equal, so every cell conserves mass.`; },
  bind(root){ bindEx(root, 'g', v => HS.I.g = +v, () => this.draw(root)); } }
};

// ================= A: averaging in a channel =================
const CA = hidpi($('avgviz')), VA = {th:-0.62, ph:0.3, s:100, ox:240, oy:160};
orbit($('avgviz'), VA);
const NB = 4000, NYH = 26; let ring = [new Float64Array(NB), new Float64Array(NB), new Float64Array(NB)], rh = 0, sigA, stA;
let win = 400, ypA = 50, ghostWin = null, winStart = 400, lastA = null, fluct = new Float64Array(NYH), fnoise = rng(5);
const YH = [...Array(NYH)].map((_,i) => Math.pow(10, Math.log10(1) + i/(NYH-1)*Math.log10(RE0)));
const YHS = YH.map(yp => statsAt(yp));
function resetSig(){ stA = statsAt(ypA); sigA = makeSig(23 + ypA, stA, 0.75); for (let s=0;s<NB;s++){ const v = sigA(); ring[0][s] = v[0]; ring[1][s] = v[1]; ring[2][s] = v[2]; } rh = 0; }
resetSig();
const yDisp = yp => Math.log10(Math.max(1, yp))/Math.log10(RE0);
const winIn = $('win'), ypIn = $('yp');
winIn.addEventListener('pointerdown', () => winStart = win);
winIn.oninput = () => { win = Math.round(Math.pow(10, +winIn.value)); $('winv').textContent = win; if (reduce) drawAvg(0); };
winIn.addEventListener('change', () => { if (winStart !== win) ghostWin = winStart; });
ypIn.oninput = () => { ypA = +ypIn.value; $('ypv').textContent = ypA; resetSig(); if (reduce) drawAvg(0); };
const at = (i, back) => ring[i][(rh - 1 - back + 2*NB) % NB];
function movAvg(i, W, n){ // running mean over the last W samples, at each of the last n samples
  const out = new Float64Array(n); let s = 0; for (let b=n-1; b<n-1+W; b++) s += at(i, b);
  for (let t=n-1; t>=0; t--){ out[n-1-t] = s/W; if (t > 0){ s += at(i, t-1) - at(i, t-1+W); } }
  return out; }
function drawAvg(now){
  const dt = lastA === null ? 16 : Math.min(100, now - lastA); lastA = now;
  if (!reduce) { for (let n=0;n<2;n++){ const v = sigA(); ring[0][rh] = v[0]; ring[1][rh] = v[1]; ring[2][rh] = v[2]; rh = (rh+1) % NB; }
    for (let j=0;j<NYH;j++) fluct[j] = 0.8*fluct[j] + 0.6*gauss(fnoise);
    if (!VA.drag) VA.th += dt*0.00008; }
  if (!vis(CA.canvas)) return;
  const c = CA, W = c.W, p = P(); c.clearRect(0,0,W,c.H);
  // --- 3D half channel; wall-normal axis on a log scale y⁺ = 1 … 550 ---
  const hx = 1.25, hz = 0.55, Um = YHS[NYH-1].U, Xu = u => -hx + 0.15 + (2*hx-0.3)*u/(Um*1.15);
  quad(c, VA, [[-hx,0,-hz],[hx,0,-hz],[hx,0,hz],[-hx,0,hz]], p.mut, .16);
  boxAt(c, VA, -hx, hx, 0, 1, -hz, hz, p.rule, 1);
  quad(c, VA, [[-hx,1,-hz],[hx,1,-hz],[hx,1,hz],[-hx,1,hz]], p.rule, .08);
  if (isAct('nu')) quad(c, VA, [[-hx,0,0],[hx,0,0],[hx,yDisp(5),0],[-hx,yDisp(5),0]], p.w, .25);
  // smooth the per-height noise so the instantaneous profile looks like eddies, not static
  const sm = [...fluct].map((v,j,a) => (a[Math.max(0,j-1)] + 2*v + a[Math.min(NYH-1,j+1)])/4);
  const meanP = YH.map((yp,j) => P3(VA, Xu(YHS[j].U), yDisp(yp), 0)), instP = YH.map((yp,j) => P3(VA, Xu(YHS[j].U + YHS[j].su*sm[j]*0.9), yDisp(yp), 0));
  const w0 = P3(VA, Xu(0), 0, 0);
  if (isAct('up','A','Rs')) { c.globalAlpha = .3; c.fillStyle = p.u; c.beginPath(); meanP.forEach(([x,y],i) => i ? c.lineTo(x,y) : c.moveTo(x,y)); [...instP].reverse().forEach(([x,y]) => c.lineTo(x,y)); c.closePath(); c.fill(); c.globalAlpha = 1; }
  for (let j=2;j<NYH;j+=3){ const b = P3(VA, Xu(0), yDisp(YH[j]), 0); arrow(c, b[0], b[1], instP[j][0], instP[j][1], p.f, isAct('u') ? 2 : 1.2); }
  line(c, [w0, ...instP.map(q => [q[0], q[1]])], p.f, isAct('u') ? 3 : 2);
  line(c, [w0, ...meanP.map(q => [q[0], q[1]])], p.rho, isAct('ub','A') ? 3.4 : 2.2, [6,4]);
  { const pr = P3(VA, Xu(stA.U), yDisp(ypA), 0); c.fillStyle = p.ink; c.beginPath(); c.arc(pr[0], pr[1], 5, 0, 7); c.fill(); label(c, `probe y⁺ = ${ypA}`, pr[0]+9, pr[1]-6, p.ink, B11); }
  if (isAct('p','grad')) { const a1 = P3(VA, -hx+0.1, 0.8, -hz), a2 = P3(VA, -hx+0.75, 0.8, -hz); arrow(c, a1[0], a1[1], a2[0], a2[1], p.w, 2.6); label(c, '−∂ₓp̄ drives the flow', a2[0]+6, a2[1]+4, p.w, F10); }
  { const L1 = P3(VA, -hx, 0, hz), L2 = P3(VA, hx, 1, -hz); label(c, 'wall', L1[0]-4, L1[1]+4, p.mut, F10, 'right'); label(c, 'centre', L2[0]+6, L2[1]+4, p.mut, F10); }
  label(c, 'half channel, Re_τ = 550 · height on a log scale', 12, 16, p.mut, F10);
  triad(c, VA, 28, 120, p);
  // --- probe signal and running mean ---
  const tx0 = 34, tx1 = W-14, ty0 = 206, ty1 = 296, NT = 240, sd = stA.su, Yt = v => (ty0+ty1)/2 - (v - stA.U)/(3*sd)*(ty1-ty0)/2, Xt = i => tx0 + (tx1-tx0)*i/(NT-1);
  const ut = []; for (let i=0;i<NT;i++) ut.push(at(0, NT-1-i));
  const ma = movAvg(0, win, NT), mg = ghostWin ? movAvg(0, ghostWin, NT) : null;
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(tx0, ty0); c.lineTo(tx0, ty1); c.lineTo(tx1, ty1); c.stroke();
  label(c, 'u at the probe', tx0, ty0-6, p.ink, SANS); label(c, isAct('t','T','s') ? 'time t →' : 'time →', tx1, ty1+13, isAct('t','T','s') ? p.ink : p.mut, F10, 'right');
  if (isAct('up','A')) { c.fillStyle = p.u; c.globalAlpha = .3; c.beginPath(); for (let i=0;i<NT;i++) c.lineTo(Xt(i), Yt(ut[i])); for (let i=NT-1;i>=0;i--) c.lineTo(Xt(i), Yt(ma[i])); c.closePath(); c.fill(); c.globalAlpha = 1; }
  line(c, ut.map((v,i) => [Xt(i), Yt(v)]), p.f, isAct('u') ? 1.8 : 1.1);
  if (mg) { c.globalAlpha = .45; line(c, [...mg].map((v,i) => [Xt(i), Yt(v)]), p.rho, 1.4); c.globalAlpha = 1; label(c, `earlier N_s = ${ghostWin}`, tx0+4, ty1-6, p.rho, F10); }
  line(c, [...ma].map((v,i) => [Xt(i), Yt(v)]), p.rho, isAct('ub','A') ? 3.4 : 2.4);
  if (isAct('T','s','A')) { const wpx = Math.min(tx1-tx0, (tx1-tx0)*win/NT); c.strokeStyle = p.w; c.lineWidth = 2; c.beginPath(); c.moveTo(tx1-wpx, ty0+4); c.lineTo(tx1-wpx, ty0); c.lineTo(tx1, ty0); c.lineTo(tx1, ty0+4); c.stroke();
    label(c, win > NT ? `window N_s = ${win} (off the left edge)` : `window N_s = ${win}`, tx1, ty0+16, p.w, F10, 'right'); }
  // --- statistics over the window ---
  const n0 = 0, cov = (() => { const X = [[],[],[]]; for (let b=0;b<win;b++) for (let i=0;i<3;i++) X[i].push(at(i,b)); return covOf(X, n0, win); })();
  { const qx = 104, qy = 392, R = 70; label(c, 'u′ against v′ (window)', 14, 316, p.ink, SANS);
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(qx-R, qy); c.lineTo(qx+R, qy); c.moveTo(qx, qy-R); c.lineTo(qx, qy+R); c.stroke();
    if (isAct('Rs')) { c.fillStyle = p.nu; c.globalAlpha = .08; c.fillRect(qx-R, qy-R, R, R); c.fillRect(qx, qy, R, R); c.globalAlpha = 1; }
    label(c, 'ejections', qx-R+2, qy-R+10, p.mut, F10); label(c, 'sweeps', qx+R-2, qy+R-4, p.mut, F10, 'right');
    const sc = R/(3*stA.su), ns = Math.min(win, 900); c.fillStyle = p.u;
    for (let b=0;b<ns;b++){ const a = (at(0,b)-cov.m[0])*sc, d = (at(1,b)-cov.m[1])*sc; if (Math.abs(a) < R && Math.abs(d) < R) c.fillRect(qx+a-1, qy-d-1, 2, 2); }
    const sl = cov.C[0][1]/cov.C[0][0]; line(c, [[qx-R, qy+sl*R], [qx+R, qy-sl*R]], p.nu, isAct('Rs') ? 2.6 : 1.6);
    label(c, 'u′', qx+R+4, qy+4, p.mut, F10); label(c, 'v′', qx+4, qy-R-2, p.mut, F10); }
  { const x0 = 262, y0 = 340, cs = 38; label(c, '⟨u′ᵢu′ⱼ⟩ over the window', 236, 316, p.ink, SANS);
    drawMat(c, x0, y0, cs, cov.C, p, { pos: p.nu, neg: p.f, scale: 2*stA.su*stA.su, hi: (i,j) => !isAct('k') || i === j });
    label(c, `k = ${cov.k.toFixed(2)}`, x0, y0+3*cs+16, p.cs, B11); }
  const err = Math.abs(cov.C[0][1]/stA.uv - 1), regime = win < 60 ? 'too short: the mean still wanders' : win < 600 ? 'rough: stresses within ~' + Math.round(100*Math.max(err, 1/Math.sqrt(win/7))) + ' %' : 'long enough: the statistics have settled';
  $('avgcap').textContent = `N_s = ${win}: ū = ${cov.m[0].toFixed(2)}, ⟨u′v′⟩ = ${fx(cov.C[0][1])} (model input ${fx(stA.uv)}) · ${regime}`;
}

// ================= B: Boussinesq on a fluid cube =================
const CB = hidpi($('bousviz')), VB = {th:-0.55, ph:0.36, s:62, ox:150, oy:132};
orbit($('bousviz'), VB);
let flow = 0, Gr = 0.049, NtB = 18, clkB = 0, lastB = null, ghostB = null, slideB = -1e9;
const grIn = $('gr'), ntIn = $('nt');
// start the sliders at the SST solution at y⁺ = 50, so the model matrix matches the probe of block 0
Gr = +Gp50.toFixed(3); NtB = +ntSST50.toFixed(1); grIn.value = Gr; ntIn.value = NtB; $('grv').textContent = Gr.toFixed(3); $('ntv').textContent = NtB.toFixed(1);
const keepB = () => { ghostB = { Gr, NtB, flow }; };
grIn.addEventListener('pointerdown', keepB); ntIn.addEventListener('pointerdown', keepB);
grIn.oninput = () => { Gr = +grIn.value; $('grv').textContent = Gr.toFixed(3); slideB = performance.now(); if (reduce) drawBous(0); };
ntIn.oninput = () => { NtB = +ntIn.value; $('ntv').textContent = NtB.toFixed(1); slideB = performance.now(); if (reduce) drawBous(0); };
$('flows').onclick = e => { const b = e.target.closest('[data-f]'); if (!b) return; keepB(); flow = +b.dataset.f; $('flows').querySelectorAll('[data-f]').forEach(x => x.classList.toggle('pri', x === b)); if (reduce) drawBous(0); };
const gradOf = (f, g) => f === 0 ? [[0,g,0],[0,0,0],[0,0,0]] : f === 1 ? [[g/2,0,0],[0,-g/2,0],[0,0,0]] : [[0,-g/2,0],[g/2,0,0],[0,0,0]];
const symOf = G => G.map((r,i) => r.map((v,j) => 0.5*(G[i][j]+G[j][i])));
function drawBous(now){
  const dt = lastB === null ? 16 : Math.min(100, now - lastB); lastB = now;
  if (!reduce) { if (now - slideB > 1600) clkB += dt; if (!VB.drag) VB.th += dt*0.00007; }
  if (!vis(CB.canvas)) return;
  const c = CB, W = c.W, p = P(); c.clearRect(0,0,W,c.H);
  const k = S0.k, G = gradOf(flow, Gr), S = symOf(G), tau = S.map((r,i) => r.map((v,j) => 2*NtB*v - (i === j ? 2/3*k : 0)));   // −⟨u′ᵢu′ⱼ⟩
  // deformation over one cycle: x′ = exp(sG)x, amplitude normalised so it is always visible; speed grows with G
  const sphase = reduce ? 0.6 : 0.5 - 0.5*Math.cos(clkB*0.0012*(0.4 + 6*Gr)), amp = 0.6*sphase, gn = Math.max(1e-9, Gr);
  const def = v => { const [x,y,z] = v, a = amp;
    if (flow === 0) return [x + a*y, y, z];
    if (flow === 1) return [x*Math.exp(a/2), y*Math.exp(-a/2), z];
    const th = a; return [x*Math.cos(th) - y*Math.sin(th), x*Math.sin(th) + y*Math.cos(th), z]; };
  const h = 0.8, corners = [-1,1].flatMap(a => [-1,1].flatMap(b => [-1,1].map(d => [a*h,b*h,d*h])));
  // faces: +x, +y, +z (front), with fills
  const faces = [[[1,-1,-1],[1,1,-1],[1,1,1],[1,-1,1]], [[-1,1,-1],[1,1,-1],[1,1,1],[-1,1,1]], [[-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]]];
  c.globalAlpha = .1; faces.forEach(fc => { c.fillStyle = p.f; c.beginPath(); fc.forEach((q,i) => { const [x,y] = P3(VB, ...def(q.map(v => v*h))); i ? c.lineTo(x,y) : c.moveTo(x,y); }); c.closePath(); c.fill(); }); c.globalAlpha = 1;
  c.strokeStyle = p.f; c.lineWidth = isAct('ub') ? 2.4 : 1.4; c.beginPath();
  corners.forEach((a,i) => corners.forEach((b,j) => { if (i < j && (a[0]!==b[0]) + (a[1]!==b[1]) + (a[2]!==b[2]) === 1) { const A1 = P3(VB, ...def(a)), A2 = P3(VB, ...def(b)); c.moveTo(A1[0],A1[1]); c.lineTo(A2[0],A2[1]); } })); c.stroke();
  boxAt(c, VB, -h, h, -h, h, -h, h, p.rule, 1, [3,3]);
  // stretch axes of S̄ (principal directions in the x-y plane)
  if (flow !== 2 && Gr > 0) { const ang = flow === 0 ? Math.PI/4 : 0, L = 1.35, on = isAct('S');
    [[ang, 1], [ang + Math.PI/2, -1]].forEach(([a, sgn]) => { const e1 = P3(VB, L*Math.cos(a), L*Math.sin(a), 0), e2 = P3(VB, -L*Math.cos(a), -L*Math.sin(a), 0), o = P3(VB, 0,0,0);
      c.globalAlpha = on ? 1 : .7; line(c, [e2.slice(0,2), e1.slice(0,2)], p.eq, on ? 2.4 : 1.4, [5,4]);
      if (sgn > 0) { arrow(c, o[0]+(e1[0]-o[0])*.7, o[1]+(e1[1]-o[1])*.7, e1[0], e1[1], p.eq, 2); arrow(c, o[0]+(e2[0]-o[0])*.7, o[1]+(e2[1]-o[1])*.7, e2[0], e2[1], p.eq, 2); }
      else { arrow(c, e1[0], e1[1], o[0]+(e1[0]-o[0])*.7, o[1]+(e1[1]-o[1])*.7, p.eq, 2); arrow(c, e2[0], e2[1], o[0]+(e2[0]-o[0])*.7, o[1]+(e2[1]-o[1])*.7, p.eq, 2); }
      c.globalAlpha = 1; }); }
  // tractions on the +x and +y faces: t_i = τ_ij n_j, split into the deviatoric (2ν_tS̄) and isotropic (−⅔k) parts
  const AS = 0.45, faceT = (nrm, tg) => { const cen = def(nrm.map(v => v*h)), o = P3(VB, ...cen);
    const dev = [0,1,2].map(i => 2*NtB*S[i].reduce((s,v,j) => s + v*nrm[j], 0)), iso = nrm.map(v => -2/3*k*v);
    const e1 = P3(VB, cen[0]+dev[0]*AS, cen[1]+dev[1]*AS, cen[2]+dev[2]*AS), e2 = P3(VB, cen[0]+iso[0]*AS, cen[1]+iso[1]*AS, cen[2]+iso[2]*AS);
    if (ghostB && (ghostB.Gr !== Gr || ghostB.NtB !== NtB || ghostB.flow !== flow)) { const Sg = symOf(gradOf(ghostB.flow, ghostB.Gr)), dg = [0,1,2].map(i => 2*ghostB.NtB*Sg[i].reduce((s,v,j) => s + v*nrm[j], 0)), eg = P3(VB, cen[0]+dg[0]*AS, cen[1]+dg[1]*AS, cen[2]+dg[2]*AS);
      c.globalAlpha = .3; arrow(c, o[0], o[1], eg[0], eg[1], p.c, 2.4); c.globalAlpha = 1; }
    arrow(c, e2[0]+(o[0]-e2[0])*0, e2[1], o[0], o[1], p.cs, isAct('k','dl') ? 3.2 : 2);
    arrow(c, o[0], o[1], e1[0], e1[1], p.c, isAct('nut','B','Rs') ? 4 : 2.8);
    label(c, tg, e1[0]+6, e1[1]-4, p.c, B11); };
  faceT([1,0,0], 'on +x face'); faceT([0,1,0], 'on +y face');
  triad(c, VB, 30, 236, p);
  label(c, ['simple shear ū_x = G·y', 'plane strain ū_x = Gx/2, ū_y = −Gy/2', 'rotation ū_x = −Gy/2, ū_y = Gx/2'][flow], 12, 16, p.ink, SANS);
  // matrices: data-like (from the block-0 samples) and the model
  const M = tau.map(r => r.map(v => -v)), y0 = 300, cs = 36;
  label(c, flow === 0 ? 'data-like ⟨u′ᵢu′ⱼ⟩ (y⁺ = 50)' : 'no data shown for this flow', 18, 266, p.ink, SANS);
  if (flow === 0) drawMat(c, 34, y0, cs, S0.C, p, { pos: p.nu, neg: p.f, scale: S0.C[0][0] });
  label(c, 'Boussinesq ⅔kδᵢⱼ − 2ν_tS̄ᵢⱼ', 248, 266, p.ink, SANS);
  drawMat(c, 270, y0, cs, M, p, { pos: p.nu, neg: p.f, scale: S0.C[0][0], hi: (i,j) => isAct('k','dl') ? i === j : isAct('nut','S') ? i !== j || flow === 1 : true });
  const shear = -M[0][1], rg = flow === 2 ? 'pure rotation: S̄ = 0, so the model sees no shear stress, whatever the spin' : flow === 1 ? 'plane strain: normal stresses split ⅔k ∓ ν_tG; this is where eddy-viscosity models over-produce k' : NtB*Gr > 1.15*a1k() ? `ν_tG = ${(NtB*Gr).toFixed(2)} > a₁k = ${a1k().toFixed(2)}: SST’s limiter would cap ν_t here` : `shear stress ${shear.toFixed(2)} vs data ${(-S0.C[0][1]).toFixed(2)}; normal stresses all ${(2/3*k).toFixed(2)} vs data ${S0.C[0][0].toFixed(2)}, ${S0.C[1][1].toFixed(2)}, ${S0.C[2][2].toFixed(2)}`;
  $('bcap').textContent = `G = ${Gr.toFixed(3)}, ν_t/ν = ${NtB.toFixed(1)}, k = ${k.toFixed(2)} (wall units) · ${rg}`;
}
const a1k = () => SST.a1*S0.k;

// ================= C: k budget while the solver iterates =================
const CC = hidpi($('modviz'));
let modelC = 'sst', cflC = 1000, chC = Channel(RE0, modelC, 0, true), holdC = 0, ghostsC = [], lastC = null;
function restartC(keep){ if (keep && chC.hist.length > 3) ghostsC = [{ h: chC.hist.slice(), cfl: chC.cfl0, m: chC.model }, ...ghostsC].slice(0, 3); chC = Channel(RE0, modelC, 0, true); chC.cfl0 = cflC; holdC = 0; }
chC.cfl0 = cflC;
const cflIn = $('cfl');
cflIn.oninput = () => { cflC = Math.round(Math.pow(10, +cflIn.value)); $('cflv').textContent = cflC; restartC(true); if (reduce) { runC(400); drawMod(0); } };
$('mods').onclick = e => { const b = e.target.closest('[data-m]'); if (!b) return; modelC = b.dataset.m; $('mods').querySelectorAll('[data-m]').forEach(x => x.classList.toggle('pri', x === b)); restartC(true); if (reduce) { runC(400); drawMod(0); } };
function runC(n){ for (let i=0;i<n;i++){ const r = chC.step(cflC); if (!(r > 1e-9) || chC.it >= 3000) break; } }
function drawMod(now){
  const dt = lastC === null ? 16 : Math.min(100, now - lastC); lastC = now;
  if (!vis(CC.canvas)) return;
  const r = chC.hist.length ? chC.hist[chC.hist.length-1] : 1, done = !(r > 1e-9) || chC.it >= 3000;
  if (!reduce) { if (!done) runC(cflC < 100 ? 12 : 3); else if ((holdC += dt) > 2600) restartC(false); }
  const c = CC, W = c.W, H = c.H, p = P(); c.clearRect(0,0,W,H);
  // left: k budget against log y⁺
  const x0 = 46, x1 = 300, y0 = 30, y1 = 250, Xl = yp => x0 + (x1-x0)*Math.log10(Math.max(1, yp))/Math.log10(RE0), Yb = v => (y0+y1)/2 - v/0.3*(y1-y0)/2;
  label(c, 'k budget (wall units)', x0, 18, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, y0); c.lineTo(x0, y1); c.moveTo(x0, Yb(0)); c.lineTo(x1, Yb(0)); c.stroke();
  [1, 10, 100, 550].forEach(v => label(c, String(v), Xl(v), y1+14, p.mut, F10, 'center')); label(c, 'y⁺', x1+24, y1+14, p.mut, MATH, 'center');
  [[0.3,'0.3'],[0,'0'],[-0.3,'−0.3']].forEach(([v,s]) => label(c, s, x0-5, Yb(v)+4, p.mut, F10, 'right'));
  const bd = chC.budget(), N = chC.N, ys = [...chC.y].map(y => y*RE0);
  const curve = (arr, col, k, sgn) => { const pts = []; for (let j=1;j<N;j++) if (ys[j] >= 1) pts.push([Xl(ys[j]), Yb(sgn*arr[j])]); line(c, pts, col, isAct(k) ? 3.2 : 2); };
  // the converged answer as a faint guide
  c.globalAlpha = .22; [[baseB.P, p.c, 1], [baseB.D, p.nu, -1], [baseB.Df, p.f, 1]].forEach(([a, col, s]) => { const pts = []; for (let j=1;j<N;j++) if (ys[j] >= 1) pts.push([Xl(ys[j]), Yb(s*a[j])]); line(c, pts, col, 4); }); c.globalAlpha = 1;
  curve(bd.P, p.c, 'Pk', 1); curve(bd.D, p.nu, 'Dk', -1); curve(bd.Df, p.f, 'Dif', 1);
  if (isAct('F1','cd','sig','beta','gam')) { const pts = []; for (let j=1;j<=N;j++) if (ys[j] >= 1) pts.push([Xl(ys[j]), Yb(0.3*chC.F1[j]) ]); line(c, pts, p.w, 2, [5,3]); label(c, 'F₁ (×0.3)', x1-4, Yb(0.3)-6, p.w, F10, 'right'); }
  if (isAct('k','om','nut')) { const key = isAct('k') ? 'k' : isAct('om') ? 'om' : 'nut', arr = key === 'k' ? chC.k : key === 'om' ? chC.w : chC.nt, col = key === 'k' ? p.cs : key === 'om' ? p.tau : p.c;
    let mx = 0; for (let j=1;j<=N;j++) if (ys[j] >= 1) mx = Math.max(mx, arr[j]); const pts = []; for (let j=1;j<=N;j++) if (ys[j] >= 1) pts.push([Xl(ys[j]), Yb(0.28*arr[j]/mx)]);
    line(c, pts, col, 2.4, [2,2]); label(c, `${key === 'k' ? 'k' : key === 'om' ? 'ω' : 'ν_t'} (scaled)`, x0+6, y0+10, col, F10); }
  label(c, 'production', Xl(12), Yb(0.27), p.c, B11, 'center'); label(c, '− destruction', Xl(40), Yb(-0.22), p.nu, B11, 'center'); label(c, 'diffusion', Xl(2.5), Yb(0.2), p.f, B11, 'center');
  // right: residual against iteration
  const rx0 = 350, rx1 = W-14, ry0 = 30, ry1 = 250, nmax = Math.max(300, chC.it, ...ghostsC.map(g => Math.min(g.h.length, 3000))), Xr = i => rx0 + (rx1-rx0)*i/nmax, Yr = v => ry0 + (ry1-ry0)*clamp(-Math.log10(Math.max(v,1e-12))/11, 0, 1);
  label(c, '‖R(qⁿ)‖', rx0, 18, isAct('R','I','n','dtau','J','dq') ? p.ink : p.mut, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(rx0, ry0); c.lineTo(rx0, ry1); c.lineTo(rx1, ry1); c.stroke();
  [[1,'1'],[1e-5,'10⁻⁵'],[1e-10,'10⁻¹⁰']].forEach(([v,s]) => label(c, s, rx0-4, Yr(v)+4, p.mut, F10, 'right'));
  label(c, `iteration n → ${nmax}`, rx1, ry1+14, isAct('n') ? p.ink : p.mut, F10, 'right');
  ghostsC.forEach((g,i) => { c.globalAlpha = .45 - .12*i; line(c, g.h.map((v,j) => [Xr(j), Yr(v)]), p.u, 1.4); const L = g.h.length-1; label(c, `CFL ${g.cfl}${g.m !== modelC ? ' · ' + (g.m === 'sst' ? 'SST' : 'k-ω') : ''}`, Math.min(rx1-2, Xr(L)), Yr(g.h[L])-5, p.u, F10, 'right'); c.globalAlpha = 1; });
  line(c, chC.hist.map((v,j) => [Xr(j), Yr(v)]), p.u, isAct('I','R','dtau') ? 3 : 2.2);
  const rg = cflC < 100 ? 'small Δτ: every step is heavily damped, so convergence is slow' : cflC < 1000 ? 'larger Δτ: fewer iterations' : 'Δτ no longer limits: solving ū, k, ω one after another does; only a coupled Newton solve would go faster';
  const st = done ? (r <= 1e-9 ? `converged in ${chC.it} iterations` : `stopped at the ${chC.it}-iteration cap, residual ${sci(r)}`) : `iteration ${chC.it}, residual ${sci(r)}`;
  $('modcap').textContent = `${modelC === 'sst' ? 'SST' : 'k-ω 1988'}, Re_τ = 550, CFL ${cflC} (Δτ = CFL·Δy²/(ν+σν_t)) · ${st} · ${rg}`;
}

// ================= BUILD: the channel solver =================
const SCV = hidpi($('sim')), VS = {th:-0.5, ph:0.3, s:74, ox:150, oy:168};
orbit($('sim'), VS);
let reI = 2, modelB = 'sst', chB = Channel(REs[reI], modelB), running = false, ghostsB = [], lastS = null;
const reIn = $('re');
function restartB(){ if (chB.it > 5) ghostsB = [{ U: chB.U.slice(), y: chB.y.slice(), re: chB.re, m: chB.model }, ...ghostsB].slice(0, 2); chB = Channel(REs[reI], modelB); if (reduce && running) { runB(3000); drawSim(0); } }
reIn.oninput = () => { reI = +reIn.value; $('rev').textContent = REs[reI]; restartB(); if (reduce) drawSim(0); };
$('bm').onclick = e => { const b = e.target.closest('[data-m]'); if (!b) return; modelB = b.dataset.m; $('bm').querySelectorAll('[data-m]').forEach(x => x.classList.toggle('pri', x === b)); restartB(); if (reduce) drawSim(0); };
function runB(n){ for (let i=0;i<n;i++){ const r = chB.step(BUILD_CFL); if (!(r > 1e-9) || chB.it >= 3000) return true; } return false; }
const conv = ch => { const r = ch.hist.length ? ch.hist[ch.hist.length-1] : 1; return !(r > 1e-9) || ch.it >= 3000; };
const mName = m => m === 'sst' ? 'SST' : m === 'kw' ? 'k-ω 1988' : 'no model';
function drawSim(now){
  const dt = lastS === null ? 16 : Math.min(100, now - lastS); lastS = now; if (!VS.drag && !reduce) VS.th += dt*0.00006;
  const c = SCV, W = c.W, H = c.H, p = P(), re = chB.re, N = chB.N; c.clearRect(0,0,W,H);
  // --- 3D channel: both walls, the profile extruded across z ---
  const hx = 1.25, hy = 0.8, hz = 0.85, Um = Math.max(1, ...chB.U), Xu = u => -hx + 0.1 + (2*hx - 0.35)*Math.min(1.2, u/Um);
  quad(c, VS, [[-hx,-hy,-hz],[hx,-hy,-hz],[hx,-hy,hz],[-hx,-hy,hz]], p.mut, .18); quad(c, VS, [[-hx,hy,-hz],[hx,hy,-hz],[hx,hy,hz],[-hx,hy,hz]], p.mut, .1);
  boxAt(c, VS, -hx, hx, -hy, hy, -hz, hz, p.rule, 1);
  const prof = []; for (let j=0;j<=N;j++) prof.push([chB.U[j], -hy + hy*chB.y[j]]); for (let j=N-1;j>=0;j--) prof.push([chB.U[j], hy - hy*chB.y[j]]);
  const zs = [-hz, -hz/2, 0, hz/2, hz];
  for (let s=0;s<zs.length-1;s++){ c.globalAlpha = .1; c.fillStyle = p.acc; c.beginPath(); prof.forEach(([u,y],i) => { const [X,Y] = P3(VS, Xu(u), y, zs[s]); i ? c.lineTo(X,Y) : c.moveTo(X,Y); }); [...prof].reverse().forEach(([u,y]) => { const [X,Y] = P3(VS, Xu(u), y, zs[s+1]); c.lineTo(X,Y); }); c.closePath(); c.fill(); c.globalAlpha = 1; }
  zs.forEach((z, s) => { line(c, prof.map(([u,y]) => P3(VS, Xu(u), y, z).slice(0,2)), p.acc, s === 2 ? 2.4 : 1.2);
    if (s === 2) for (let q=1;q<=9;q++){ const yy = -hy + 2*hy*q/10, yo = Math.abs(yy)/hy, j = Math.min(N, Math.max(0, chB.y.findIndex(v => v >= 1 - yo))), b0 = P3(VS, Xu(0), yy, z), e0 = P3(VS, Xu(chB.U[j]), yy, z); arrow(c, b0[0], b0[1], e0[0], e0[1], p.acc, 1.4); } });
  { const a = P3(VS, -hx, hy, hz), b = P3(VS, hx, -hy, -hz); label(c, 'wall', a[0]-4, a[1]-6, p.mut, F10, 'right'); label(c, 'wall', b[0]+4, b[1]+12, p.mut, F10); }
  label(c, '1D reduction of 3D RANS', 12, 16, p.ink, SANS); label(c, 'ū(y) is the same at every x and z', 12, 31, p.mut, F10);
  triad(c, VS, 30, 300, p);
  // --- u⁺ against y⁺ with the law of the wall ---
  const px0 = 330, px1 = 560, py0 = 34, py1 = 290, lx0 = Math.log10(0.3), lx1 = Math.log10(5200), Xp = yp => px0 + (px1-px0)*(Math.log10(yp)-lx0)/(lx1-lx0), Yp = u => py1 - (py1-py0)*u/30;
  label(c, 'u⁺ against y⁺', px0, 22, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(px0, py0); c.lineTo(px0, py1); c.lineTo(px1, py1); c.stroke();
  [1, 10, 100, 1000].forEach(v => { label(c, String(v), Xp(v), py1+13, p.mut, F10, 'center'); line(c, [[Xp(v), py1], [Xp(v), py1+3]], p.rule, 1); });
  [0, 10, 20, 30].forEach(v => label(c, String(v), px0-5, Yp(v)+4, p.mut, F10, 'right'));
  const vs = []; for (let i=0;i<=30;i++){ const yp = Math.pow(10, lx0 + i/30*(Math.log10(12)-lx0)); vs.push([Xp(yp), Yp(yp)]); } line(c, vs, p.w, 1.6, [4,3]);
  const ll = []; for (let i=0;i<=30;i++){ const yp = Math.pow(10, Math.log10(8) + i/30*(lx1-Math.log10(8))); ll.push([Xp(yp), Yp(Math.log(yp)/KAPPA + BLOG)]); } line(c, ll, p.w, 1.6, [4,3]);
  label(c, 'u⁺ = y⁺', Xp(1.2), Yp(4.5), p.w, F10); label(c, 'log law κ = 0.41, B = 5.2', Xp(30), Yp(23), p.w, F10, 'center');
  const curveU = (U, y, rre, col, lw, al) => { c.save(); c.beginPath(); c.rect(px0, py0-4, px1-px0+2, py1-py0+4); c.clip(); c.globalAlpha = al; const pts = []; for (let j=1;j<y.length;j++){ const yp = y[j]*rre; if (yp >= 0.3) pts.push([Xp(yp), Yp(U[j])]); } line(c, pts, col, lw); c.restore(); };
  ghostsB.forEach((g,i) => { curveU(g.U, g.y, g.re, p.acc, 1.4, .35 - .12*i); });
  curveU(chB.U, chB.y, re, p.acc, 2.6, 1);
  if (chB.U[N] > 30) label(c, `centre u⁺ = ${chB.U[N].toFixed(0)}: off the chart`, px1, py0+8, p.warm, F10, 'right');
  label(c, `y₁⁺ = ${(chB.y[1]*re).toFixed(2)}`, px1, py1-6, p.mut, F10, 'right');
  // --- residual ---
  const rx0 = 610, rx1 = W-12, ry0 = 34, ry1 = 290, nmax = Math.max(200, chB.it), Xr = i => rx0 + (rx1-rx0)*i/nmax, Yr = v => ry0 + (ry1-ry0)*clamp(-Math.log10(Math.max(v,1e-12))/11, 0, 1);
  label(c, '‖R(qⁿ)‖', rx0, 22, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(rx0, ry0); c.lineTo(rx0, ry1); c.lineTo(rx1, ry1); c.stroke();
  [[1,'1'],[1e-5,'10⁻⁵'],[1e-10,'10⁻¹⁰']].forEach(([v,s]) => label(c, s, rx0-4, Yr(v)+4, p.mut, F10, 'right'));
  label(c, `n → ${nmax}`, rx1, ry1+13, p.mut, F10, 'right');
  line(c, chB.hist.map((v,j) => [Xr(j), Yr(v)]), p.u, 2);
  const m = chB.metrics(), r = chB.hist.length ? chB.hist[chB.hist.length-1] : 1;
  const stt = !running ? 'press the steps into order to start (showing the initial guess)' : conv(chB) ? (r <= 1e-9 ? `converged in ${chB.it} iterations` : `stopped at ${sci(r)}`) : `iteration ${chB.it}, ‖R‖ = ${sci(r)}`;
  const acc = !conv(chB) ? 'accuracy is reported at convergence' : modelB === 'lam' ? `no model: ū_b⁺ = ${m.Ub.toFixed(0)}, C_f = ${sci(m.Cf, 2)} vs Dean ${sci(m.Cfd, 2)} (${(m.Cfd/m.Cf).toFixed(0)}× too little friction): without a closure, RANS returns the laminar solution` :
    `ū_b⁺ = ${m.Ub.toFixed(2)}, centre u⁺ = ${m.Uc.toFixed(2)} · C_f = ${sci(m.Cf, 2)} vs Dean’s correlation ${sci(m.Cfd, 2)} (${fx(100*(m.Cf/m.Cfd-1), 1)} %)${m.dev === m.dev ? ` · max |u⁺ − log law| = ${m.dev.toFixed(2)} for 30 ≤ y⁺ ≤ ${Math.round(0.2*re)}` : ''}`;
  $('simcap').textContent = `${mName(modelB)}, Re_τ = ${re} · ${stt} · ${acc}`;
}

// ================= PARALLEL: partition a cube =================
const PC = hidpi($('part')), PT = hidpi($('ptime')), VP = {th:-0.62, ph:0.42, s:62, ox:170, oy:138};
orbit($('part'), VP, () => drawPart());
const MESH = [32, 64, 128, 256]; let pI = 3, mI = 1, pDone = false;
function split(n, P2){ const d = [n, n, n], cnt = [1, 1, 1]; for (let i=0;i<P2;i++){ let a = d.indexOf(Math.max(...d)); if (d[a] < 2) return null; d[a] /= 2; cnt[a] *= 2; } return { d, cnt }; }
function cost(n, P2){ const s = split(n, P2); if (!s) return null; const [bx,by,bz] = s.d, cells = bx*by*bz, Pn = 2**P2;
  const fa = [by*bz, bx*bz, bx*by], faces = s.cnt.map(c => c >= 3 ? 2 : c === 2 ? 1 : 0), halo = faces.reduce((t,f,a) => t + f*fa[a], 0), msgs = faces.reduce((t,f) => t+f, 0);
  const comp = cells*0.5, hx = msgs*2 + halo*48/1e4, red = Pn > 1 ? 2*Math.ceil(Math.log2(Pn))*2 : 0;
  return { s, cells, halo, msgs, comp, hx, red, tot: comp+hx+red, Pn }; }
const pIn = $('P'), mIn = $('mesh');
pIn.oninput = () => { pI = +pIn.value; drawPar(); }; mIn.oninput = () => { mI = +mIn.value; drawPar(); };
function drawPart(){
  const c = PC, p = P(), n = MESH[mI], cst = cost(n, pI) || cost(n, 3*Math.log2(n)), [Px, Py, Pz] = cst.s.cnt, h = 1;
  c.clearRect(0,0,c.W,c.H);
  const F = (pts, col, a) => quad(c, VP, pts, col, a);
  F([[-h,-h,h],[h,-h,h],[h,h,h],[-h,h,h]], p.f, .06); F([[h,-h,-h],[h,-h,h],[h,h,h],[h,h,-h]], p.f, .1); F([[-h,h,-h],[h,h,-h],[h,h,h],[-h,h,h]], p.f, .14);
  const gl = (a, b, n2) => { if (n2 > 32) return; for (let i=1;i<n2;i++){ const t = -h + 2*h*i/n2; a(t); } };
  c.strokeStyle = p.rule; c.lineWidth = 1; const seg = (u, v) => { const A1 = P3(VP, ...u), A2 = P3(VP, ...v); c.beginPath(); c.moveTo(A1[0],A1[1]); c.lineTo(A2[0],A2[1]); c.stroke(); };
  gl(t => { seg([t,-h,h],[t,h,h]); seg([t,h,-h],[t,h,h]); }, 0, Px); gl(t => { seg([-h,t,h],[h,t,h]); seg([h,t,-h],[h,t,h]); }, 0, Py); gl(t => { seg([h,-h,t],[h,h,t]); seg([-h,h,t],[h,h,t]); }, 0, Pz);
  boxAt(c, VP, -h, h, -h, h, -h, h, p.mut, 1.4);
  // one part (the top front corner region's interior neighbour) and its one-cell halo
  const ix = Math.floor(Px/2), iy = Math.floor(Py/2), iz = Math.floor(Pz/2), dx = 2*h/Px, dy = 2*h/Py, dz = 2*h/Pz, cell = 2*h/n;
  const bx0 = -h + ix*dx, by0 = -h + iy*dy, bz0 = -h + iz*dz;
  if (cst.Pn > 1) boxAt(c, VP, Math.max(-h, bx0-cell), Math.min(h, bx0+dx+cell), Math.max(-h, by0-cell), Math.min(h, by0+dy+cell), Math.max(-h, bz0-cell), Math.min(h, bz0+dz+cell), p.warm, 1.6, [4,3]);
  F([[bx0,by0+dy,bz0],[bx0+dx,by0+dy,bz0],[bx0+dx,by0+dy,bz0+dz],[bx0,by0+dy,bz0+dz]], p.acc, .5); F([[bx0+dx,by0,bz0],[bx0+dx,by0+dy,bz0],[bx0+dx,by0+dy,bz0+dz],[bx0+dx,by0,bz0+dz]], p.acc, .35); F([[bx0,by0,bz0+dz],[bx0+dx,by0,bz0+dz],[bx0+dx,by0+dy,bz0+dz],[bx0,by0+dy,bz0+dz]], p.acc, .25);
  boxAt(c, VP, bx0, bx0+dx, by0, by0+dy, bz0, bz0+dz, p.acc, 2);
  label(c, `${n}³ cells · P = ${cst.Pn} (${Px}×${Py}×${Pz})`, 10, 16, p.ink, B11);
  label(c, '■ one part', 10, c.H-24, p.acc, F10); label(c, '┄ its halo (ghost cells)', 10, c.H-10, p.warm, F10);
  triad(c, VP, c.W-44, c.H-30, p);
}
function drawPar(){
  const n = MESH[mI], maxP = 3*Math.log2(n); if (pI > maxP) { pI = maxP; pIn.value = pI; }
  const cst = cost(n, pI); $('Pv').textContent = cst.Pn; $('meshv').textContent = `${n}³`;
  drawPart();
  const c = PT, p = P(), W = c.W; c.clearRect(0,0,W,c.H);
  // bar: one Krylov iteration
  const bx0 = 14, bx1 = 330, sc = (bx1-bx0)/cst.tot; let x = bx0;
  label(c, 'one Krylov iteration on one rank', bx0, 16, p.ink, SANS);
  [[cst.comp, p.f, 'compute'], [cst.hx, p.c, 'halo'], [cst.red, p.nu, 'all-reduce']].forEach(([v, col, nm]) => { const w = v*sc; c.fillStyle = col; rr(c, x, 30, Math.max(0, w-1), 26, 3); c.fill(); x += w; });
  [[cst.comp, p.f, 'compute'], [cst.hx, p.c, 'halo'], [cst.red, p.nu, 'all-reduce']].forEach(([v, col, nm], i) => label(c, `${nm} ${v < 10 ? v.toFixed(1) : v.toFixed(0)} µs`, bx0 + [0, 100, 210][i], 74, col, F10));
  label(c, `${cst.cells.toLocaleString('en')} owned cells, ${cst.halo.toLocaleString('en')} halo cells (${(100*cst.halo/cst.cells).toFixed(1)} %), ${cst.msgs} messages`, bx0, 96, p.mut, F10);
  const comm = cst.hx + cst.red, ratio = comm/cst.comp;
  label(c, `communication / compute = ${ratio.toFixed(2)}`, bx0, 116, ratio > 1 ? p.warm : p.ink, B11);
  // strong scaling: time per iteration against P
  const sx0 = 400, sx1 = W-14, sy0 = 24, sy1 = 140, all = []; for (let q=0;q<=maxP;q++) all.push(cost(n, q));
  const tmax = all[0].tot, tmin = Math.min(...all.map(a => a.tot), tmax/2**maxP), Xs = q => sx0 + (sx1-sx0)*q/maxP, Ys = t => sy0 + (sy1-sy0)*(Math.log10(tmax) - Math.log10(t))/(Math.log10(tmax) - Math.log10(tmin));
  label(c, 'time per iteration vs P (log–log)', sx0, 16, p.ink, SANS);
  c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(sx0, sy0); c.lineTo(sx0, sy1); c.lineTo(sx1, sy1); c.stroke();
  line(c, [[Xs(0), Ys(tmax)], [Xs(maxP), Ys(tmax/2**maxP)]], p.mut, 1, [3,3]); label(c, 'ideal', Xs(maxP)-4, Ys(tmax/2**maxP)-4, p.mut, F10, 'right');
  line(c, all.map((a,q) => [Xs(q), Ys(a.tot)]), p.f, 2);
  c.fillStyle = ratio > 1 ? p.warm : p.acc; c.beginPath(); c.arc(Xs(pI), Ys(cst.tot), 5, 0, 7); c.fill();
  [0, Math.round(maxP/2), maxP].forEach(q => label(c, q ? '2' + String(q).split('').map(ch => SUP[ch]).join('') : '1', Xs(q), sy1+13, p.mut, F10, 'center')); label(c, 'P', sx1, sy1+13, p.mut, F10, 'right');
  const fb = $('pfb');
  if (ratio > 1) { fb.className = 'fb good'; fb.textContent = `✓ At P = ${cst.Pn} each rank spends more time talking than computing: ${cst.cells} cells per part, but ${cst.msgs} halo messages and ${2*Math.ceil(Math.log2(cst.Pn))} reduction hops per iteration. That is the strong-scaling limit of this ${n}³ mesh; a bigger mesh moves it to larger P.`; if (!pDone) { pDone = true; K.done('parallel'); } }
  else { fb.className = 'fb'; fb.textContent = `Efficiency ${(100*all[0].tot/(cst.tot*cst.Pn)).toFixed(0)} %. Keep adding parts: when does communication cost more than compute?`; }
}

this.ops = { A: HOW.A, B: HOW.B, M: HOW.M, I: HOW.I };
function drawLearn(now){ if (vis(CO.canvas)) drawOps(now); drawAvg(now); drawBous(now); drawMod(now); }
drawOps(1700);
if (reduce) { runC(400); }
return {
  frame(now, stp){
    if (stp === 0) drawLearn(now);
    if (stp === 1) { if (running && !conv(chB)) { const t0 = performance.now(); let n = 0; do { chB.step(BUILD_CFL); n++; } while (n < BUILD_PER_FRAME && !conv(chB) && performance.now()-t0 < 9); } drawSim(now); }
  },
  onStep(stp){ if (stp === 2) drawPar(); if (stp === 1) drawSim(0); if (stp === 0 && reduce) drawLearn(0); },
  onBlock(){ if (reduce) setTimeout(() => drawLearn(0), 0); },
  buildReset(){ running = false; chB = Channel(REs[reI], modelB); ghostsB = []; drawSim(0); },
  buildStart(){ running = true; if (reduce) { runB(3000); drawSim(0); } }
};
}
})();
