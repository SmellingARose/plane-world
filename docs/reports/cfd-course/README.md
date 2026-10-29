# CFD solver course

An interactive course on eight CFD methods. Each method has five steps: **Learn** (the maths), **Build** (order the steps of one update, then a real solver runs in the browser), **Parallelize** (how it maps to GPUs/clusters), **Quiz**, **Unlock** (its row of the comparison). The full comparison opens when all eight are complete.

- `framework.js`: shell, step navigation, symbol inspector, accordion blocks, quizzes, animation loop, drawing kit.
- `framework.css`: all styles and colour tokens (light and dark).
- `methods/<id>.js`: one module per method. `methods/lbm.js` is the **reference implementation**: match its depth and polish.
- `shell.html` + `build.py`: `python3 build.py` writes the single self-contained page `../cfd-course.html`; `python3 build.py <id>` writes `build-<id>.html` with just that method.
- `tools/check.mjs`: `node tools/check.mjs methods/<id>.js` checks a module (structure, symbols, ids, quizzes, MathML). It must pass with no ERROR lines.

Method ids, in home-grid order: `potential`, `rans`, `urans`, `ddes`, `wmles`, `wrles`, `dns`, `lbm`.

## Module spec

```js
CFD.register({
  id: 'rans', name: 'Steady RANS', sub: 'averaged equations',
  lede: 'One sentence under "1 · Learn the maths".',
  uncoloured: ['grp'],            // term keys used on grouping <mrow>s that should stay ink (optional)
  blocks: [ { key: '0', title: 'The objects', note: 'what goes in, what comes out', html: '…' },
            { key: 'A', … }, { key: 'B', … }, { key: 'C', … } ],
  checks: { '0': [Q, …], A: [Q, …], B: [Q, …], C: [Q, …] },   // ≥ 4 each
  quiz: [Q, …],                                               // ≥ 6
  build: { intro, html, steps: ['first', 'second', …], hint, success },
  parallel: { html },
  unlock: 'What this method\'s comparison row now shows.',
  sources: [['Title, author, year', 'https://…'], …],
  terms: { key: { sym: '<mi>ν</mi>', name: 'Viscosity', def: 'one or two plain sentences', space: '<mi>ν</mi><mo>∈</mo>…', col: '--c-nu', op: 'S' } },
  ops: { S: { html(K){…}, bind(root, K){…}, draw(root, K){…} } },   // or set this.ops inside mount (lbm does)
  bench(){ /* optional: build and step the Build solver headless, return ms per step */ },
  mount(root, K){ …; return { frame(now, step){}, onStep(step){}, buildReset(){}, buildStart(){}, onBlock(key){} }; }
});
```

- `Q` is `[question, [options…], correctIndex, whyItsRight]`.
- The framework wraps each block in the click-to-open accordion and appends its check; do not add those yourself.
- Every `id`/`for` in module HTML starts with `<id>-`; inside `mount` use `K.$('name')` for `#<id>-name`.
- `K` gives: `$`, `q`, `qa`, `root`, `reduce`, `P()` (palette: `ink mut rule panel bg acc accSoft warm ok f eq c tau u rho w cs nu`), `css`, `hex`, `hidpi(canvas)` (draw in logical units from `data-w`/`data-h`), `arrow`, `rr`, `pill`, `label`, `ease`, `lerp`, `clamp`, `proj(V,x,y,z)` (3D orthographic → `[sx, sy, depth]`), `box`, `triad`, `orbit(canvas, V)`, `MONO`, `MATH`, `isAct(...keys)`, `act()`, `setAct`, `pin(key)`, `done('parallel')`, `redraw()`, `mkQuiz`.
- `frame(now, step)` is called every animation frame while the method is open; `step` is the visible pane (0 Learn … 4 Unlock). Keep each call under ~9 ms: give solvers a time budget (`do step(); while (performance.now() - t0 < 9)`).
- The Build ordering game is the framework's; `buildReset()` is called on open and on "Reset order", `buildStart()` when the order is right.
- The Parallelize pane must contain an interaction that calls `K.done('parallel')` when completed.
- With `prefers-reduced-motion`, nothing animates on its own; draw a static frame and redraw on input (`if (K.reduce) …`).

### Markup conventions (copy them from lbm.js)

- Equation: `<div class="eqhero"><math display="block">…</math></div>`. Tag every symbol with `data-t="key"`; the framework colours it with the term's `col` and links hover/tap across equation, chips and canvas.
- Operator labels under equations: `<munder><munder><mrow>…</mrow><mo stretchy="true">⏟</mo></munder><mtext data-t="S" class="opl">S: what it does</mtext></munder>`.
- Symbol inspector: `<aside class="insp" data-terms="a,b,c"></aside>` (chips + one definition card + "Lives in" + the operator's how-it-works panel).
- Two-column block body: `<div class="bb"><figure class="viz"><canvas data-w data-h>…</figure><aside class="insp" …></aside></div>`.
- "Every index" table: `.idx` with `.ir` rows (symbol, range, meaning), each row `data-t` of that index.
- Dimension cards: `.dims` > `.dim`.
- Going deeper: `<details class="deep"><summary>Going a bit deeper <span class="note">· N steps</span></summary><div class="dstep"><span class="k">1</span><div class="dm"><math display="block">…</math></div><p>…</p></div>…</details>`.
- How-it-works panels (inside `ops[...].html`): `.hm` formula box, `.eterms` term table with `.tb` colour swatches, `.eex` example buttons, a canvas, `.ecalc` worked numbers.
- Sliders: `.ctl` (label · range · output) or `.ctl3` grid; legends `.lg`; wide canvases inside `<div class="scrollx">` so phones scroll instead of shrinking.

## Style guide (the owner's feedback, all of it applies to every method)

1. **Visuals connected to the equations.** Every block has a real animation whose parts light up when the matching symbol is hovered or tapped (`K.isAct(key)` inside the drawing code).
2. **Every term defined**, with a plain one-line definition and **"Lives in"**: the set it belongs to, and for maps their input and output spaces (pure maths: is it a number, a vector in ℝ³, a field, an operator?).
3. **Index (tensor) notation in 3D**: i, j over axes x, y, z, Einstein summation, and an **"Every index" table that explains every index including t**. Everything is 3D, including the maths.
4. **Block 0 "The objects"**: what the state is (its shape and dimension), what goes in and out of one step, the operators of the method as maps between spaces, and an animated, step-by-step **operator walkthrough** on concrete numbers (like lbm's: play/pause + step buttons, a caption per step with an everyday analogy).
5. **Every operator explains itself**: hovering/clicking it opens its own how-it-works panel (formula with coloured terms, what each term does, a worked example with real numbers you can change, a small visual). One panel per operator, never one shared section.
6. **Operators named under the equations** (underbraces), colour-coded to match.
7. **A bit more maths**: each block has a short collapsible "Going a bit deeper" (2–3 steps: where it comes from, the key derivation step, what is assumed or dropped).
8. **Checks after every block** (≥ 4: recall plus conceptual "what would happen if…" questions) and a final quiz (≥ 6, conceptual).
9. **Sliders must visibly do something at once** (freeze/hold the animation at the moment that shows the effect, keep "ghost" curves of earlier settings, name the regime).
10. **Real computation, not fakes.** The Build solver is a real 3D (or honestly reduced, clearly labelled) solver of that method running live; numbers in worked examples are computed, not typed.
11. **No overlapping maths**: MathML only (no LaTeX), no scripts on bold letters, no `(ℝⁿ)^Λ` style notation; write shapes like ℝ^{N×3}.
12. **Organised and concise**: click-to-open blocks, collapsible extras, visuals over text, short sentences, plain words.
13. **Looks good at desktop and phone width**, light and dark (use only the palette tokens).
14. **Research-backed**: constants and claims from the literature (cite in `sources`); no invented numbers.
