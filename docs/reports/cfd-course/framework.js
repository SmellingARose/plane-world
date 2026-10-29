// CFD course framework: the home grid, the five-step course shell, the symbol inspector,
// the accordion of Learn blocks, the quizzes and the animation loop. Each method is a module
// that calls CFD.register(spec); see README.md for the spec.
const CFD = (() => {
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const MONO = '500 11px "IBM Plex Mono", monospace', MATH = 'italic 600 15px "STIX Two Math","Cambria Math","Times New Roman",serif';
const ORDER = ['potential', 'rans', 'urans', 'ddes', 'wmles', 'wrles', 'dns', 'lbm'];
const specs = {}, apis = {}, done = {};
let cur = null;

// ---- drawing kit shared by every method ----
function hidpi(cv){ const w=+cv.dataset.w, h=+cv.dataset.h, d=Math.min(3, window.devicePixelRatio||1); cv.width=w*d; cv.height=h*d; cv.style.aspectRatio=w+'/'+h; const c=cv.getContext('2d'); c.setTransform(d,0,0,d,0,0); c.W=w; c.H=h; return c; }
const P = () => { const g = css; return {ink:g('--ink'),mut:g('--muted'),rule:g('--rule'),panel:g('--panel'),bg:g('--bg'),acc:g('--accent'),accSoft:g('--accent-soft'),warm:g('--warm'),ok:g('--ok'),
  f:g('--c-f'),eq:g('--c-eq'),c:g('--c-c'),tau:g('--c-tau'),u:g('--c-u'),rho:g('--c-rho'),w:g('--c-w'),cs:g('--c-cs'),nu:g('--c-nu')}; };
function hex(c){ c=c.replace('#',''); if(c.length===3) c=c.split('').map(x=>x+x).join(''); return [parseInt(c.slice(0,2),16),parseInt(c.slice(2,4),16),parseInt(c.slice(4,6),16)]; }
function arrow(c, x0, y0, x1, y1, col, lw, dash){
  const dx=x1-x0, dy=y1-y0, L=Math.hypot(dx,dy); if (L < 1.5) return;
  const ux=dx/L, uy=dy/L, h=Math.min(L*.55, 5+lw*1.9), hw=h*.6;
  c.strokeStyle=col; c.fillStyle=col; c.lineWidth=lw; c.lineCap='round'; c.lineJoin='round'; c.setLineDash(dash ? [lw*1.4, lw*2.2] : []);
  c.beginPath(); c.moveTo(x0,y0); c.lineTo(x1-ux*h*.7, y1-uy*h*.7); c.stroke(); c.setLineDash([]);
  c.beginPath(); c.moveTo(x1,y1); c.lineTo(x1-ux*h-uy*hw, y1-uy*h+ux*hw); c.lineTo(x1-ux*h*.72, y1-uy*h*.72); c.lineTo(x1-ux*h+uy*hw, y1-uy*h-ux*hw); c.closePath(); c.fill();
}
function rr(c, x, y, w_, h, r){ c.beginPath(); if (c.roundRect) c.roundRect(x,y,w_,h,r); else c.rect(x,y,w_,h); }
function pill(c, x, y, txt, col, font){ c.font = font || MONO; const tw = c.measureText(txt).width; c.globalAlpha=.13; c.fillStyle=col; rr(c, x, y-13, tw+16, 22, 11); c.fill(); c.globalAlpha=1; c.fillStyle=col; c.fillText(txt, x+8, y+2); return x+tw+24; }
function label(c, txt, x, y, col, font, align){ c.font = font || MONO; c.fillStyle = col; c.textAlign = align || 'left'; c.fillText(txt, x, y); c.textAlign = 'left'; }
const ease = s => s<0?0:s>1?1:s*s*(3-2*s), lerp = (a,b,s) => a+(b-a)*s, clamp = (v,a,b) => Math.max(a, Math.min(b, v));
// orthographic 3D view: yaw th about the vertical axis, pitch ph toward the viewer; returns screen x, y and depth
function proj(V, x, y, z){ const ct=Math.cos(V.th), st=Math.sin(V.th), cp=Math.cos(V.ph), sp=Math.sin(V.ph);
  const X = x*ct + z*st, Z = -x*st + z*ct; return [V.ox + V.s*X, V.oy - V.s*(y*cp - Z*sp), y*sp + Z*cp]; }
// the 12 edges of an axis-aligned box centred on the origin
function box(c, V, hx, hy, hz, col, lw){ const P3 = [-1,1].flatMap(a => [-1,1].flatMap(b => [-1,1].map(d => [a,b,d])));
  c.strokeStyle = col; c.lineWidth = lw; c.beginPath();
  P3.forEach(a => P3.forEach(b => { if (a < b && Math.abs(a[0]-b[0])+Math.abs(a[1]-b[1])+Math.abs(a[2]-b[2]) === 2) { const A1 = proj(V, a[0]*hx, a[1]*hy, a[2]*hz), A2 = proj(V, b[0]*hx, b[1]*hy, b[2]*hz); c.moveTo(A1[0],A1[1]); c.lineTo(A2[0],A2[1]); } }));
  c.stroke(); }
// drag a 3D view to orbit it; V.drag is true while dragging
function orbit(cv, V, onChange){ let last = null;
  cv.addEventListener('pointerdown', e => { last = [e.clientX, e.clientY]; V.drag = true; cv.setPointerCapture(e.pointerId); cv.style.cursor = 'grabbing'; });
  cv.addEventListener('pointermove', e => { if (!last) return; V.th += (e.clientX-last[0])*0.012; V.ph = clamp(V.ph + (e.clientY-last[1])*0.012, -1.2, 1.2); last = [e.clientX, e.clientY]; if (onChange) onChange(); });
  const up = () => { last = null; V.drag = false; cv.style.cursor = 'grab'; }; cv.addEventListener('pointerup', up); cv.addEventListener('pointercancel', up); cv.style.cursor = 'grab'; cv.style.touchAction = 'none'; }

// ---- quizzes ----
function mkQuiz(el, qs, onRight){ const got = new Set();
  qs.forEach(([q,opts,ans,why],qi) => { const d=document.createElement('div'); d.className='q'; d.innerHTML=`<strong>${qi+1}. ${q}</strong>`;
    const fb=document.createElement('div'); fb.className='fb';
    opts.forEach((o,oi) => { const b=document.createElement('button'); b.className='b opt'; b.textContent=o;
      b.onclick=()=>{ d.querySelectorAll('.opt').forEach(x=>x.classList.remove('wrong')); if(oi===ans){ b.classList.add('right'); fb.className='fb good'; fb.textContent='✓ '+why; got.add(qi); } else { b.classList.add('wrong'); fb.className='fb bad'; fb.textContent='✕ Try again.'; }
        onRight(got.size === qs.length); }; d.appendChild(b); });
    d.appendChild(fb); el.appendChild(d); }); }

// ---- the course shell for one method ----
const STEPS = ['Learn','Build','Parallelize','Quiz','Unlock'];
function shell(s){
  const blocks = s.blocks.map(b => `<section class="blk closed" data-b="${b.key}">
    <header class="bh" role="button" tabindex="0" aria-expanded="false"><span class="bn">${b.key}</span><div><h4>${b.title}</h4><span class="note">${b.note || ''}</span></div><span class="bst"></span><span class="chev">▾</span></header>
    <div class="bbody">${b.html}<div class="bq" data-q="${b.key}"><span class="eyebrow">Check · ${b.key}</span></div></div></section>`).join('\n');
  const keys = s.blocks.map(b => b.key).join(', ');
  return `<div class="btns" style="margin-top:22px"><button class="b" data-back>← All methods</button></div>
  <h2>${s.name}</h2><div class="steps"></div>
  <div class="pane" data-step="0"><h3>1 · Learn the maths</h3><p class="lede">${s.lede} <span class="note">Tap any symbol.</span></p>
    ${blocks}
    <div class="btns"><button class="b pri" data-next data-gate="learn" disabled>Next → Build</button><span class="note" data-fb="learn">Answer the checks in ${keys} to continue.</span></div></div>
  <div class="pane" data-step="1" hidden><h3>2 · Build it</h3><p>${s.build.intro}</p>
    <div class="pool"></div><div class="slots" aria-label="Your order"></div><div class="fb" data-fb="build"></div>
    ${s.build.html}
    <div class="btns"><button class="b" data-reset>Reset order</button><button class="b pri" data-next data-gate="build" disabled>Next → Parallelize</button></div></div>
  <div class="pane" data-step="2" hidden><h3>3 · Run it in parallel</h3>${s.parallel.html}
    <div class="btns"><button class="b pri" data-next data-gate="parallel" disabled>Next → Quiz</button></div></div>
  <div class="pane" data-step="3" hidden><h3>4 · Quiz</h3><div class="quiz"></div>
    <div class="btns"><button class="b pri" data-next data-gate="quiz" disabled>Finish</button></div></div>
  <div class="pane" data-step="4" hidden><div class="unlock"><span class="big">Unlocked</span><p>${s.unlock}</p></div>
    <div class="all-done" hidden></div>${(s.sources||[]).length ? `<details class="srcs"><summary>Sources</summary><ul>${s.sources.map(([n,u]) => `<li><a href="${u}" target="_blank" rel="noopener">${n}</a></li>`).join('')}</ul></details>` : ''}<div class="btns"><button class="b pri" data-back>Back to methods</button></div></div>`;
}

function mount(id){
  let api = {};
  const s = specs[id], root = document.createElement('section'); root.className = 'course'; root.dataset.m = id; root.hidden = true;
  root.innerHTML = shell(s); document.getElementById('courses').appendChild(root);
  const $ = k => root.querySelector('#' + id + '-' + k), q = sel => root.querySelector(sel), qa = sel => [...root.querySelectorAll(sel)];
  const st = { step: 0, act: undefined, pinned: null, gates: {} };
  const T = s.terms, col = k => T[k] ? `var(${T[k].col})` : 'var(--ink)';
  const gate = (g, ok) => { st.gates[g] = ok; const b = q(`[data-gate="${g}"]`); if (b) b.disabled = !ok; };

  // colour every tagged symbol; the collision-style group keys listed in s.uncoloured stay ink
  qa('math [data-t]').forEach(e => { const k = e.dataset.t; if (!T[k]) console.warn(`${id}: no term "${k}"`); else if (!(s.uncoloured || []).includes(k)) e.style.color = col(k); });
  // symbol inspectors: chips, one definition card, where the object lives, and how an operator works
  const insp = qa('.insp');
  insp.forEach(a => { a.ks = a.dataset.terms.split(',').filter(k => T[k] || console.warn(`${id}: no term "${k}"`));
    a.innerHTML = `<div class="chips">${a.ks.map(k => `<button class="chip" data-t="${k}" style="--tc:${col(k)}" aria-label="${T[k].name}"><math>${T[k].sym}</math></button>`).join('')}</div><div class="def"><span class="ds"></span><div><b></b><p></p></div><div class="sp"></div><div class="how"></div></div>`; });
  function showHow(d, on){ const hw = d.querySelector('.how'), opk = on && T[on].op, op = opk && s.ops && s.ops[opk];
    if (!op) { hw.innerHTML = ''; hw.dataset.op = ''; return; }
    if (hw.dataset.op !== opk) { hw.dataset.op = opk; hw.innerHTML = op.html(K) + '<span class="note hn"></span>'; if (op.bind) op.bind(hw, K); op.draw(hw, K); }
    hw.querySelector('.hn').textContent = st.pinned === on ? 'Pinned: click the symbol again to close.' : 'Click the symbol to keep this open.'; }
  function setAct(k){
    if (k === st.act) return; st.act = k;
    qa('.hl').forEach(e => e.classList.remove('hl')); if (k) qa(`[data-t="${k}"]`).forEach(e => e.classList.add('hl'));
    insp.forEach(a => { const on = a.ks.includes(k) ? k : null, d = a.querySelector('.def');
      d.classList.toggle('empty', !on); d.style.setProperty('--tc', on ? col(on) : 'var(--rule)');
      d.querySelector('.ds').innerHTML = on ? `<math>${T[on].sym}</math>` : '?'; d.querySelector('b').textContent = on ? T[on].name : 'Tap a symbol';
      d.querySelector('p').textContent = on ? T[on].def : 'In the equation or above. It lights up in the animation too.';
      d.querySelector('.sp').innerHTML = on && T[on].space ? `<span class="eyebrow">Lives in</span><math>${T[on].space}</math>` : ''; showHow(d, on); });
    if (reduce && api.frame) api.frame(0, st.step);
  }
  const pin = k => { st.pinned = k; st.act = undefined; setAct(k); };
  const lp = q('[data-step="0"]');
  lp.addEventListener('mouseover', e => { if (e.target.closest('.def')) return; const t = e.target.closest('[data-t]'); setAct(t ? t.dataset.t : st.pinned); });
  lp.addEventListener('mouseleave', () => setAct(st.pinned));
  lp.addEventListener('click', e => { const t = e.target.closest('[data-t]'); if (!t || e.target.closest('.def .how')) return; pin(st.pinned === t.dataset.t ? null : t.dataset.t); });

  // Learn: accordion blocks, each closed by its check; passing one opens the next
  const blks = qa('.blk[data-b]'), bdone = {};
  function openBlk(el, scroll){ blks.forEach(b => { const on = b === el; b.classList.toggle('closed', !on); b.querySelector('.bh').setAttribute('aria-expanded', on); }); if (scroll) el.scrollIntoView({behavior: 'smooth', block: 'start'}); if (api.onBlock) api.onBlock(el.dataset.b); }
  blks.forEach(b => { const h = b.querySelector('.bh'); h.onclick = () => b.classList.contains('closed') ? openBlk(b, false) : (b.classList.add('closed'), h.setAttribute('aria-expanded', false));
    h.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); h.onclick(); } }; });
  qa('.bq').forEach(el => mkQuiz(el, s.checks[el.dataset.q] || [], ok => { const k = el.dataset.q, blk = el.closest('.blk'), was = bdone[k]; bdone[k] = ok; el.classList.toggle('done', ok);
    blk.classList.toggle('passed', ok); blk.querySelector('.bst').textContent = ok ? '✓ passed' : '';
    if (ok && !was) { const nx = blks[blks.indexOf(blk)+1]; if (nx) setTimeout(() => openBlk(nx, true), 900); }
    const keys = s.blocks.map(b => b.key), all = keys.every(k => bdone[k]); gate('learn', all);
    q('[data-fb="learn"]').textContent = all ? '✓ All checks passed.' : `Checks passed: ${keys.filter(k => bdone[k]).join(', ') || 'none'}`; }));

  // Build: put the steps of one update in order, then the method's solver runs
  let order = [];
  function initBuild(){ order = []; const pool = q('.pool'); pool.innerHTML = ''; q('.slots').innerHTML = ''; const fb = q('[data-fb="build"]'); fb.textContent = ''; fb.className = 'fb'; gate('build', false);
    [...s.build.steps].sort(() => Math.random() - .5).forEach(t => { const b = document.createElement('button'); b.className = 'chipb'; b.textContent = t; b.onclick = () => pick(b, t); pool.appendChild(b); });
    if (api.buildReset) api.buildReset(); }
  function pick(b, t){ order.push(t); q('.slots').appendChild(b); b.onclick = null;
    if (order.length < s.build.steps.length) return;
    const ok = order.every((t,i) => t === s.build.steps[i]), fb = q('[data-fb="build"]');
    if (ok) { fb.className = 'fb good'; fb.textContent = '✓ ' + s.build.success; gate('build', true); if (api.buildStart) api.buildStart(); }
    else { fb.className = 'fb bad'; fb.textContent = '✕ Not quite. ' + s.build.hint; } }
  q('[data-reset]').onclick = initBuild;

  // Quiz and step navigation
  mkQuiz(q('.quiz'), s.quiz, ok => gate('quiz', ok));
  function render(){
    const bar = q('.steps'); bar.innerHTML = '';
    STEPS.forEach((n,i) => { const d = document.createElement('div'); d.className = 'st' + (i < st.step ? ' ok' : i === st.step ? ' cur' : ''); d.innerHTML = `<b>${i < st.step ? '✓' : i+1}</b><span>${n}</span>`;
      // testing: every tab is clickable, so sections can be visited without passing the checks
      d.onclick = () => go(i); bar.appendChild(d); });
    qa('.pane').forEach(p => p.hidden = +p.dataset.step !== st.step);
    if (api.onStep) api.onStep(st.step);
  }
  function go(i){ st.step = i; if (i === 4) { done[id] = true; allDone(); } render(); window.scrollTo({top: q('.steps').offsetTop - 20}); }
  qa('[data-next]').forEach(b => b.onclick = () => go(st.step + 1));
  qa('[data-back]').forEach(b => b.onclick = home);

  const K = { id, root, $, q, qa, s, T, reduce, MONO, MATH, css, P, hex, hidpi, arrow, rr, pill, label, ease, lerp, clamp, proj, box, triad: (c, V, x, y, p) => triad(c, V, x, y, p, K), orbit, mkQuiz,
    act: () => st.act, isAct: (...k) => k.includes(st.act), setAct, pin, pinned: () => st.pinned, step: () => st.step,
    done: g => gate(g, true), redraw: () => { if (reduce && api.frame) api.frame(0, st.step); } };
  api = s.mount(root, K) || {};
  apis[id] = Object.assign(api, { open(){ st.step = 0; render(); initBuild(); openBlk(blks[0], false); pin(null); } });
}
// a small x, y, z triad so the orientation is always readable
function triad(c, V, x, y, p, K){ const W = {...V, ox: x, oy: y, s: 22}, on = K && K.isAct('alpha','ix','iy','iz');
  [['x',1,0,0],['y',0,1,0],['z',0,0,1]].forEach(([n,a,b,d]) => { const e = proj(W, a, b, d); arrow(c, x, y, e[0], e[1], on ? p.ink : p.mut, 1.4); label(c, n, x+(e[0]-x)*1.6, y+(e[1]-y)*1.6+5, on ? p.ink : p.mut, MATH, 'center'); }); }

// ---- home grid ----
const LOCK = '<svg class="lk" viewBox="0 0 16 16" aria-hidden="true"><rect x="3" y="7" width="10" height="7" rx="1.5"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2" fill="none"/></svg>';
function home(){
  const g = document.getElementById('methods'); g.innerHTML = '';
  ORDER.forEach(id => { const s = specs[id], b = document.createElement('button');
    if (!s) { b.className = 'm lock'; b.disabled = true; b.innerHTML = `<span class="n">${LOCK}${id}</span><span class="s">not built yet</span>`; g.appendChild(b); return; }
    b.className = 'm open' + (done[id] ? ' done' : '');
    b.innerHTML = `<span class="n">${s.name}</span><span class="s">${s.sub}</span><span class="s">${done[id] ? '✓ complete · row unlocked' : '<span class="go">Start →</span>'}</span>`;
    b.onclick = () => openCourse(id); g.appendChild(b); });
  const n = ORDER.filter(id => done[id]).length;
  document.getElementById('progress').textContent = `${n} of ${ORDER.length} complete. The full comparison opens when every method is complete.`;
  document.getElementById('home').hidden = false; document.querySelectorAll('.course').forEach(c => c.hidden = true); cur = null;
}
function openCourse(id){ if (!apis[id]) mount(id); document.getElementById('home').hidden = true; document.querySelectorAll('.course').forEach(c => c.hidden = c.dataset.m !== id); cur = id; apis[id].open(); window.scrollTo(0,0); }
function allDone(){ const n = ORDER.filter(id => done[id]).length;
  document.querySelectorAll('.all-done').forEach(e => { e.hidden = false; e.innerHTML = n === ORDER.length ? '<div class="unlock"><span class="big">All 8</span><p>Every method is complete: the full comparison is open.</p></div>' : `<p class="note">${n} of ${ORDER.length} methods complete.</p>`; }); }

function loop(now){ if (!document.hidden && cur && apis[cur] && apis[cur].frame) apis[cur].frame(now, apis[cur] && document.querySelector(`.course[data-m="${cur}"] .pane:not([hidden])`) ? +document.querySelector(`.course[data-m="${cur}"] .pane:not([hidden])`).dataset.step : 0); requestAnimationFrame(loop); }
if (!reduce) requestAnimationFrame(loop);

return { register(spec){ specs[spec.id] = spec; }, start(){ home(); }, specs };
})();
