// Lattice Boltzmann (D3Q19, BGK): the reference method module. See ../README.md for the spec.
CFD.register(Object.assign({
 "id": "lbm",
 "name": "Lattice Boltzmann",
 "sub": "stream and collide",
 "lede": "Each cell of a 3D grid stores 19 numbers. Every step they <strong>collide</strong>, then <strong>stream</strong>.",
 "uncoloured": [
  "coll"
 ],
 "blocks": [
  {
   "key": "0",
   "title": "The objects",
   "note": "what goes in, what comes out",
   "html": "<div class=\"eqhero\">\n          <math display=\"block\"><mrow data-t=\"fi\"><msubsup><mi>f</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"ix\">x</mi><mi data-t=\"iy\">y</mi><mi data-t=\"iz\">z</mi></mrow><mi data-t=\"t\">t</mi></msubsup></mrow><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>19</mn><mo>×</mo><msub data-t=\"N\"><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub data-t=\"N\"><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub data-t=\"N\"><mi>N</mi><mi>z</mi></msub></mrow></msup><mspace width=\"2em\"/><msup><mi>f</mi><mrow><mi data-t=\"t\">t</mi><mo>+</mo><mrow data-t=\"dt\"><mi>Δ</mi><mi>t</mi></mrow></mrow></msup><mo>=</mo><mi data-t=\"S\">S</mi><mo>(</mo><mi data-t=\"C\">C</mi><mo>(</mo><msup><mi>f</mi><mi data-t=\"t\">t</mi></msup><mo>)</mo><mo>)</mo></math>\n        </div>\n        <div class=\"idx\"><span class=\"eyebrow\">Every index</span><div class=\"ir\" data-t=\"i\"><span class=\"is\"><math><mi>i</mi></math></span><span class=\"rg\"><math><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mn>18</mn></math></span><span class=\"im\">Direction: 0 = rest, 1–6 = faces, 7–18 = edges of the cell.</span></div><div class=\"ir\" data-t=\"ix\"><span class=\"is\"><math><mi>x</mi></math></span><span class=\"rg\"><math><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>x</mi></msub><mo>−</mo><mn>1</mn></math></span><span class=\"im\">Cell column (along the flow).</span></div><div class=\"ir\" data-t=\"iy\"><span class=\"is\"><math><mi>y</mi></math></span><span class=\"rg\"><math><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>−</mo><mn>1</mn></math></span><span class=\"im\">Cell row (up).</span></div><div class=\"ir\" data-t=\"iz\"><span class=\"is\"><math><mi>z</mi></math></span><span class=\"rg\"><math><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>−</mo><mn>1</mn></math></span><span class=\"im\">Cell layer (across).</span></div><div class=\"ir\" data-t=\"t\"><span class=\"is\"><math><mi>t</mi></math></span><span class=\"rg\"><math><mn>0</mn><mo>,</mo><mi>Δ</mi><mi>t</mi><mo>,</mo><mn>2</mn><mi>Δ</mi><mi>t</mi><mo>,</mo><mo>…</mo></math></span><span class=\"im\">Time level. Written up top (fᵗ) it is a label, not a power.</span></div><div class=\"ir\" data-t=\"alpha\"><span class=\"is\"><math><mi>α</mi><mo>,</mo><mi>β</mi></math></span><span class=\"rg\"><math><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi></math></span><span class=\"im\">Axis of a vector (c<sub>iα</sub>, u<sub>α</sub>). Appears twice in a term → summed: c<sub>iα</sub>u<sub>α</sub> = c<sub>ix</sub>u<sub>x</sub> + c<sub>iy</sub>u<sub>y</sub> + c<sub>iz</sub>u<sub>z</sub>.</span></div><div class=\"ir\" data-t=\"a\"><span class=\"is\"><math><mi>a</mi></math></span><span class=\"rg\"><math><mn>0</mn><mo>,</mo><mn>1</mn><mo>,</mo><mn>2</mn><mo>,</mo><mn>3</mn></math></span><span class=\"im\">Moment: 0 = density ρ, 1–3 = momentum ρu<sub>x</sub>, ρu<sub>y</sub>, ρu<sub>z</sub>.</span></div></div>\n        <div class=\"dims\">\n          <div class=\"dim\"><b>Fix i, x, y, z</b><math><msub><mi>f</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"ix\">x</mi><mi data-t=\"iy\">y</mi><mi data-t=\"iz\">z</mi></mrow></msub><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub></math><span>one number, not a vector</span></div>\n          <div class=\"dim\"><b>Fix x, y, z</b><math><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub><mo>∈</mo><msup><mi>ℝ</mi><mn>19</mn></msup></math><span>one cell: 19 numbers, index i free</span></div>\n          <div class=\"dim\"><b>Nothing fixed (the state)</b><math><msub><mi>f</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"ix\">x</mi><mi data-t=\"iy\">y</mi><mi data-t=\"iz\">z</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>19</mn><mo>×</mo><msub data-t=\"N\"><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub data-t=\"N\"><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub data-t=\"N\"><mi>N</mi><mi>z</mi></msub></mrow></msup></math><span>a 4-index array; 80 × 40 × 40 grid → 2 432 000 numbers</span></div>\n        </div>\n        <span class=\"eyebrow\">What the operators do, one cell at a time</span>\n        <figure class=\"viz\"><div class=\"scrollx\"><canvas id=\"lbm-opviz\" data-w=\"880\" data-h=\"340\" aria-label=\"Animated walkthrough: the 19 numbers of a cell are totalled by M, rebuilt by E, blended by 1/tau, then shifted by S\"></canvas></div>\n          <div class=\"opctl\"><button class=\"b\" id=\"lbm-opplay\">Pause</button><div id=\"lbm-opsteps\" class=\"btns\"></div></div>\n          <p class=\"opcap\" id=\"lbm-opcap\"></p></figure>\n        <aside class=\"insp\" data-terms=\"Mm,m,E,C,S,N\"></aside>\n        \n        <details class=\"deep\"><summary>Going a bit deeper <span class=\"note\">· 3 steps</span></summary><div class=\"dstep\"><span class=\"k\">M</span><div class=\"dm\"><math display=\"block\"><mrow><mo>[</mo><mtable><mtr><mtd><mi data-t=\"rho\">ρ</mi></mtd></mtr><mtr><mtd><mrow data-t=\"u\"><mi data-t=\"rho\">ρ</mi><msub><mi>u</mi><mi data-t=\"alpha\">x</mi></msub></mrow></mtd></mtr><mtr><mtd><mrow data-t=\"u\"><mi data-t=\"rho\">ρ</mi><msub><mi>u</mi><mi data-t=\"alpha\">y</mi></msub></mrow></mtd></mtr><mtr><mtd><mrow data-t=\"u\"><mi data-t=\"rho\">ρ</mi><msub><mi>u</mi><mi data-t=\"alpha\">z</mi></msub></mrow></mtd></mtr></mtable><mo>]</mo></mrow><mo>=</mo><mrow><mo>[</mo><mtable><mtr><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd></mtr><mtr><mtd><mn>0</mn></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd></mtr><mtr><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>1</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd></mtr><mtr><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>0</mn></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>1</mn></mtd><mtd><mn>1</mn></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mrow><mo>−</mo><mn>1</mn></mrow></mtd><mtd><mn>1</mn></mtd></mtr></mtable><mo>]</mo></mrow><mrow><mo>[</mo><mtable><mtr><mtd><msub><mi>f</mi><mn>0</mn></msub></mtd></mtr><mtr><mtd><mo>⋮</mo></mtd></mtr><mtr><mtd><msub><mi>f</mi><mn>18</mn></msub></mtd></mtr></mtable><mo>]</mo></mrow><mspace width=\"1em\"/><mo>⇔</mo><mspace width=\"1em\"/><msub data-t=\"m\"><mi>m</mi><mi data-t=\"a\">a</mi></msub><mo>=</mo><mrow data-t=\"sum\"><munder><mo>∑</mo><mi>i</mi></munder></mrow><msub data-t=\"Mm\"><mi>M</mi><mrow><mi data-t=\"a\">a</mi><mi data-t=\"i\">i</mi></mrow></msub><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow></math></div><p>The moments as a matrix: one row per moment (density, then x-, y- and z-momentum), one column per direction i. Row 0 is all ones; rows 1–3 are the x, y and z components of 𝐜ᵢ.</p></div><div class=\"dstep\"><span class=\"k\">C</span><div class=\"dm\"><math display=\"block\"><mrow data-t=\"coll\"><msubsup><mi>f</mi><mi data-t=\"i\">i</mi><mo>⋆</mo></msubsup></mrow><mo>=</mo><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mo>−</mo><mfrac data-t=\"tau\"><mn>1</mn><mi>τ</mi></mfrac><mo>(</mo><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mo>−</mo><mrow data-t=\"feq\"><msubsup><mi>f</mi><mi data-t=\"i\">i</mi><mtext>eq</mtext></msubsup><mo>(</mo><msub data-t=\"m\"><mi>m</mi><mi data-t=\"a\">a</mi></msub><mo>)</mo></mrow><mo>)</mo></math></div><p>Collision is local: each cell uses only its own 19 numbers. It is nonlinear, because the equilibrium is quadratic in the velocity u<sub>α</sub> = m<sub>α</sub>/m<sub>0</sub>.</p></div><div class=\"dstep\"><span class=\"k\">S</span><div class=\"dm\"><math display=\"block\"><msubsup><mi>f</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"ix\">x</mi><mi data-t=\"iy\">y</mi><mi data-t=\"iz\">z</mi></mrow><mrow><mi data-t=\"t\">t</mi><mo>+</mo><mrow data-t=\"dt\"><mi>Δ</mi><mi>t</mi></mrow></mrow></msubsup><mo>=</mo><msubsup><mi>f</mi><mrow><mi data-t=\"i\">i</mi><mo>,</mo><mi data-t=\"ix\">x</mi><mo>−</mo><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">x</mi></mrow></msub><mo>,</mo><mi data-t=\"iy\">y</mi><mo>−</mo><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">y</mi></mrow></msub><mo>,</mo><mi data-t=\"iz\">z</mi><mo>−</mo><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">z</mi></mrow></msub></mrow><mrow><mo>⋆</mo><mi data-t=\"t\">t</mi></mrow></msubsup></math></div><p>Streaming only shifts the x, y, z indices by 𝐜ᵢ: no arithmetic. As a matrix it would be 2 432 000 × 2 432 000 with a single 1 per row, which is why codes store the shift, not the matrix.</p></div></details>"
  },
  {
   "key": "A",
   "title": "Update rule",
   "note": "collide, then stream",
   "html": "<div class=\"eqhero\"><math display=\"block\"><munder><munder><mrow><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mo>(</mo><mrow data-t=\"xc\"><mi data-t=\"x\">𝐱</mi><mo>+</mo><mrow data-t=\"ci\"><msub><mi>𝐜</mi><mi>i</mi></msub></mrow><mrow data-t=\"dt\"><mi>Δ</mi><mi>t</mi></mrow></mrow><mo>,</mo><mrow data-t=\"dt\"><mi>t</mi><mo>+</mo><mi>Δ</mi><mi>t</mi></mrow><mo>)</mo></mrow><mo stretchy=\"true\">⏟</mo></munder><mtext data-t=\"S\" class=\"opl\">S: lands at the neighbour</mtext></munder><mo>=</mo><munder><munder><mrow><mrow data-t=\"fi\"><msub><mi>f</mi><mi>i</mi></msub></mrow><mo>(</mo><mi data-t=\"x\">𝐱</mi><mo>,</mo><mi data-t=\"t\">t</mi><mo>)</mo><mo>−</mo><mrow data-t=\"coll\"><mfrac data-t=\"tau\"><mn>1</mn><mi>τ</mi></mfrac><mo>(</mo><mrow data-t=\"fi\"><msub><mi>f</mi><mi>i</mi></msub></mrow><mo>−</mo><mrow data-t=\"feq\"><msubsup><mi>f</mi><mi>i</mi><mtext>eq</mtext></msubsup></mrow><mo>)</mo></mrow></mrow><mo stretchy=\"true\">⏟</mo></munder><mtext data-t=\"C\" class=\"opl\">C: collision, gives fᵢ*</mtext></munder></math></div>\n        <div class=\"bb\">\n          <figure class=\"viz\">\n            <canvas id=\"lbm-cellviz\" data-w=\"460\" data-h=\"430\" aria-label=\"One 3D cell's 19 populations colliding toward equilibrium, then streaming to the 18 neighbours; drag to rotate\"></canvas>\n            <div class=\"lg\"><span style=\"color:var(--c-f)\"><i class=\"ln\"></i>population <math><msub><mi>f</mi><mi>i</mi></msub></math></span><span style=\"color:var(--c-eq)\"><i class=\"ln dash\"></i>equilibrium <math><msubsup><mi>f</mi><mi>i</mi><mtext>eq</mtext></msubsup></math></span><span style=\"color:var(--c-c)\"><i class=\"ln\"></i>stream along <math><msub><mi>𝐜</mi><mi>i</mi></msub></math></span><span class=\"note\">drag to rotate</span></div>\n            <div class=\"ctl\"><label for=\"lbm-ltau\" class=\"sym\" style=\"color:var(--c-tau)\">τ</label><input type=\"range\" id=\"lbm-ltau\" min=\"0.55\" max=\"3\" step=\"0.01\" value=\"1.5\"><output id=\"lbm-ltauv\">1.50</output></div>\n          </figure>\n          <aside class=\"insp\" data-terms=\"S,C,fi,feq,coll,tau,ci,xc,x,i,t,dt,grad\"></aside>\n        </div>\n<details class=\"deep\"><summary>Going a bit deeper <span class=\"note\">· 2 steps</span></summary><div class=\"dstep\"><span class=\"k\">1</span><div class=\"dm\"><math display=\"block\"><mrow data-t=\"fi\"><msubsup><mi>f</mi><mi data-t=\"i\">i</mi><mtext>new</mtext></msubsup></mrow><mo>=</mo><mo>(</mo><mn>1</mn><mo>−</mo><mfrac data-t=\"tau\"><mn>1</mn><mi>τ</mi></mfrac><mo>)</mo><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mo>+</mo><mfrac data-t=\"tau\"><mn>1</mn><mi>τ</mi></mfrac><mrow data-t=\"feq\"><msubsup><mi>f</mi><mi data-t=\"i\">i</mi><mtext>eq</mtext></msubsup></mrow></math></div><p>Collision rearranged: a weighted average of where the cell is and where it wants to be. τ = 1 jumps straight to equilibrium; τ &lt; 1 overshoots it.</p></div><div class=\"dstep\"><span class=\"k\">2</span><div class=\"dm\"><math display=\"block\"><mrow data-t=\"grad\"><msub><mo>∂</mo><mi>t</mi></msub></mrow><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mo>+</mo><mrow data-t=\"cia\"><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">α</mi></mrow></msub></mrow><mrow data-t=\"grad\"><msub><mo>∂</mo><mi data-t=\"alpha\">α</mi></msub></mrow><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mo>=</mo><mo>−</mo><mfrac><mn>1</mn><mi data-t=\"tau\">τ</mi></mfrac><mo>(</mo><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mo>−</mo><mrow data-t=\"feq\"><msubsup><mi>f</mi><mi data-t=\"i\">i</mi><mtext>eq</mtext></msubsup></mrow><mo>)</mo></math></div><p>Where it comes from: the Boltzmann–BGK equation with only 9 velocities. Following population i along 𝐜ᵢ for one step Δt turns the left side into “arrive at the neighbour”: the update rule.</p></div></details>"
  },
  {
   "key": "B",
   "title": "Equilibrium",
   "note": "what the cell relaxes toward",
   "html": "<div class=\"eqhero\">\n          <math display=\"block\"><mrow data-t=\"feq\"><msubsup><mi>f</mi><mi data-t=\"i\">i</mi><mtext>eq</mtext></msubsup></mrow><mo>=</mo><munder><munder><mrow><msub data-t=\"w\"><mi>w</mi><mi data-t=\"i\">i</mi></msub><mi data-t=\"rho\">ρ</mi><mo>[</mo><mn>1</mn><mo>+</mo><mfrac><mrow><mrow data-t=\"cia\"><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">α</mi></mrow></msub></mrow><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">α</mi></msub></mrow></mrow><msubsup data-t=\"cs\"><mi>c</mi><mi>s</mi><mn>2</mn></msubsup></mfrac><mo>+</mo><mfrac><msup><mrow><mo>(</mo><mrow data-t=\"cia\"><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">α</mi></mrow></msub></mrow><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">α</mi></msub></mrow><mo>)</mo></mrow><mn>2</mn></msup><mrow><mn>2</mn><msubsup data-t=\"cs\"><mi>c</mi><mi>s</mi><mn>4</mn></msubsup></mrow></mfrac><mo>−</mo><mfrac><mrow><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">α</mi></msub></mrow><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">α</mi></msub></mrow></mrow><mrow><mn>2</mn><msubsup data-t=\"cs\"><mi>c</mi><mi>s</mi><mn>2</mn></msubsup></mrow></mfrac><mo>]</mo></mrow><mo stretchy=\"true\">⏟</mo></munder><mtext data-t=\"E\" class=\"opl\">E: builds 19 values from ρ and u</mtext></munder></math>\n          <math display=\"block\" class=\"sm\"><mi data-t=\"rho\">ρ</mi><mo>=</mo><munder><munder><mrow><mrow data-t=\"sum\"><munder><mo>∑</mo><mi>i</mi></munder></mrow><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow></mrow><mo stretchy=\"true\">⏟</mo></munder><mtext data-t=\"Mm\" class=\"opl\">M row 0</mtext></munder><mspace width=\"2em\"/><mi data-t=\"rho\">ρ</mi><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">α</mi></msub></mrow><mo>=</mo><munder><munder><mrow><mrow data-t=\"sum\"><munder><mo>∑</mo><mi>i</mi></munder></mrow><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mrow data-t=\"cia\"><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">α</mi></mrow></msub></mrow></mrow><mo stretchy=\"true\">⏟</mo></munder><mtext data-t=\"Mm\" class=\"opl\">M rows 1–3</mtext></munder></math>\n        </div>\n        <div class=\"bb\">\n          <figure class=\"viz\">\n            <canvas id=\"lbm-eqviz\" data-w=\"460\" data-h=\"300\" aria-label=\"The 19 equilibrium populations in 3D for the velocity set by the sliders; drag to rotate\"></canvas>\n            <div class=\"ctl3\"><label for=\"lbm-ux\" class=\"sym\" style=\"color:var(--c-u)\">u<sub>x</sub></label><input type=\"range\" id=\"lbm-ux\" min=\"-0.3\" max=\"0.3\" step=\"0.01\" value=\"0.12\"><output id=\"lbm-uxv\">0.12</output><label for=\"lbm-uy\" class=\"sym\" style=\"color:var(--c-u)\">u<sub>y</sub></label><input type=\"range\" id=\"lbm-uy\" min=\"-0.3\" max=\"0.3\" step=\"0.01\" value=\"0.05\"><output id=\"lbm-uyv\">0.05</output><label for=\"lbm-uz\" class=\"sym\" style=\"color:var(--c-u)\">u<sub>z</sub></label><input type=\"range\" id=\"lbm-uz\" min=\"-0.3\" max=\"0.3\" step=\"0.01\" value=\"0.03\"><output id=\"lbm-uzv\">0.03</output><span class=\"note\" style=\"grid-column:1/-1\">drag the picture to rotate</span></div>\n          </figure>\n          <aside class=\"insp\" data-terms=\"E,Mm,feq,w,rho,u,cia,alpha,cs,sum,delta,p\"></aside>\n        </div>\n<details class=\"deep\"><summary>Going a bit deeper <span class=\"note\">· 3 steps</span></summary><div class=\"dstep\"><span class=\"k\">1</span><div class=\"dm\"><math display=\"block\"><mrow data-t=\"sum\"><munder><mo>∑</mo><mi>i</mi></munder></mrow><mrow data-t=\"feq\"><msubsup><mi>f</mi><mi data-t=\"i\">i</mi><mtext>eq</mtext></msubsup></mrow><mo>=</mo><mi data-t=\"rho\">ρ</mi><mo>,</mo><mspace width=\"1em\"/><mrow data-t=\"sum\"><munder><mo>∑</mo><mi>i</mi></munder></mrow><mrow data-t=\"feq\"><msubsup><mi>f</mi><mi data-t=\"i\">i</mi><mtext>eq</mtext></msubsup></mrow><mrow data-t=\"cia\"><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">α</mi></mrow></msub></mrow><mo>=</mo><mi data-t=\"rho\">ρ</mi><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">α</mi></msub></mrow></math></div><p>Equilibrium has the same mass and momentum as the populations it replaces, so collision conserves both. Only the shape of the distribution changes.</p></div><div class=\"dstep\"><span class=\"k\">2</span><div class=\"dm\"><math display=\"block\"><mrow data-t=\"sum\"><munder><mo>∑</mo><mi>i</mi></munder></mrow><msub data-t=\"w\"><mi>w</mi><mi data-t=\"i\">i</mi></msub><mrow data-t=\"cia\"><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">α</mi></mrow></msub></mrow><mrow data-t=\"cia\"><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">β</mi></mrow></msub></mrow><mo>=</mo><msubsup data-t=\"cs\"><mi>c</mi><mi>s</mi><mn>2</mn></msubsup><msub data-t=\"delta\"><mi>δ</mi><mrow><mi data-t=\"alpha\">α</mi><mi data-t=\"alpha\">β</mi></mrow></msub></math></div><p>How the weights are chosen: the 9 velocities must spread like a Gaussian with variance cₛ² = ⅓, the same along x, y and z and with no coupling between axes (δ<sub>αβ</sub>). That forces 1/3, 1/18, 1/36.</p></div><div class=\"dstep\"><span class=\"k\">3</span><div class=\"dm\"><math display=\"block\"><mrow data-t=\"sum\"><munder><mo>∑</mo><mi>i</mi></munder></mrow><mrow data-t=\"feq\"><msubsup><mi>f</mi><mi data-t=\"i\">i</mi><mtext>eq</mtext></msubsup></mrow><mrow data-t=\"cia\"><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">α</mi></mrow></msub></mrow><mrow data-t=\"cia\"><msub><mi>c</mi><mrow><mi data-t=\"i\">i</mi><mi data-t=\"alpha\">β</mi></mrow></msub></mrow><mo>=</mo><mi data-t=\"p\">p</mi><msub data-t=\"delta\"><mi>δ</mi><mrow><mi data-t=\"alpha\">α</mi><mi data-t=\"alpha\">β</mi></mrow></msub><mo>+</mo><mi data-t=\"rho\">ρ</mi><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">α</mi></msub></mrow><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">β</mi></msub></mrow><mo>,</mo><mspace width=\"1em\"/><mi data-t=\"p\">p</mi><mo>=</mo><mi data-t=\"rho\">ρ</mi><msubsup data-t=\"cs\"><mi>c</mi><mi>s</mi><mn>2</mn></msubsup></math></div><p>The momentum flux of equilibrium is pressure plus convection: exactly the inviscid (Euler) part of Navier–Stokes. Pressure comes free, with no pressure equation to solve.</p></div></details>"
  },
  {
   "key": "C",
   "title": "Viscosity",
   "note": "the one physical knob",
   "html": "<div class=\"eqhero\"><math display=\"block\"><mi data-t=\"nu\">ν</mi><mo>=</mo><mo>(</mo><munder><munder><mrow><msubsup data-t=\"cs\"><mi>c</mi><mi>s</mi><mn>2</mn></msubsup><mi data-t=\"tau\">τ</mi></mrow><mo stretchy=\"true\">⏟</mo></munder><mtext data-t=\"C\" class=\"opl\">from collision C</mtext></munder><mo>−</mo><munder><munder><mrow><msubsup data-t=\"cs\"><mi>c</mi><mi>s</mi><mn>2</mn></msubsup><mfrac data-t=\"half\"><mn>1</mn><mn>2</mn></mfrac></mrow><mo stretchy=\"true\">⏟</mo></munder><mtext data-t=\"S\" class=\"opl\">removed by streaming S</mtext></munder><mo>)</mo><mrow data-t=\"dt\"><mi>Δ</mi><mi>t</mi></mrow><mspace width=\"1.5em\"/><msubsup data-t=\"cs\"><mi>c</mi><mi>s</mi><mn>2</mn></msubsup><mo>=</mo><mfrac><mn>1</mn><mn>3</mn></mfrac></math></div>\n        <div class=\"bb\">\n          <figure class=\"viz\">\n            <div class=\"scrollx\"><canvas id=\"lbm-nuviz\" data-w=\"560\" data-h=\"250\" aria-label=\"Viscosity versus tau, and a real lattice Boltzmann shear wave decaying at that viscosity\"></canvas></div>\n            <div class=\"ctl\"><label for=\"lbm-ntau\" class=\"sym\" style=\"color:var(--c-tau)\">τ</label><input type=\"range\" id=\"lbm-ntau\" min=\"0.51\" max=\"2\" step=\"0.01\" value=\"0.8\"><output id=\"lbm-ntauv\">0.80</output></div>\n            <div class=\"note\" id=\"lbm-nucap\">&nbsp;</div>\n          </figure>\n          <aside class=\"insp\" data-terms=\"nu,tau,half,cs,dt,D,p,grad,alpha\"></aside>\n        </div>\n<details class=\"deep\"><summary>Going a bit deeper <span class=\"note\">· 2 steps</span></summary><div class=\"dstep\"><span class=\"k\">1</span><div class=\"dm\"><math display=\"block\"><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mo>(</mo><mi data-t=\"x\">𝐱</mi><mo>+</mo><mrow data-t=\"ci\"><msub><mi>𝐜</mi><mi>i</mi></msub></mrow><mrow data-t=\"dt\"><mi>Δ</mi><mi>t</mi></mrow><mo>,</mo><mi>t</mi><mo>+</mo><mrow data-t=\"dt\"><mi>Δ</mi><mi>t</mi></mrow><mo>)</mo><mo>≈</mo><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mo>+</mo><mrow data-t=\"dt\"><mi>Δ</mi><mi>t</mi></mrow><msub data-t=\"D\"><mi>D</mi><mi data-t=\"i\">i</mi></msub><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow><mo>+</mo><mfrac data-t=\"half\"><mn>1</mn><mn>2</mn></mfrac><msup><mrow data-t=\"dt\"><mi>Δ</mi><mi>t</mi></mrow><mn>2</mn></msup><msubsup data-t=\"D\"><mi>D</mi><mi data-t=\"i\">i</mi><mn>2</mn></msubsup><mrow data-t=\"fi\"><msub><mi>f</mi><mi data-t=\"i\">i</mi></msub></mrow></math></div><p>Taylor-expand streaming, with Dᵢ = ∂ₜ + c<sub>iα</sub>∂<sub>α</sub>. The ½Δt² term is error from taking whole steps: it behaves like an extra, negative diffusion.</p></div><div class=\"dstep\"><span class=\"k\">2</span><div class=\"dm\"><math display=\"block\"><mrow data-t=\"grad\"><msub><mo>∂</mo><mi>t</mi></msub></mrow><mo>(</mo><mi data-t=\"rho\">ρ</mi><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">α</mi></msub></mrow><mo>)</mo><mo>+</mo><mrow data-t=\"grad\"><msub><mo>∂</mo><mi data-t=\"alpha\">β</mi></msub></mrow><mo>(</mo><mi data-t=\"rho\">ρ</mi><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">α</mi></msub></mrow><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">β</mi></msub></mrow><mo>)</mo><mo>=</mo><mo>−</mo><mrow data-t=\"grad\"><msub><mo>∂</mo><mi data-t=\"alpha\">α</mi></msub></mrow><mi data-t=\"p\">p</mi><mo>+</mo><mrow data-t=\"grad\"><msub><mo>∂</mo><mi data-t=\"alpha\">β</mi></msub></mrow><mo>[</mo><mi data-t=\"rho\">ρ</mi><mi data-t=\"nu\">ν</mi><mo>(</mo><mrow data-t=\"grad\"><msub><mo>∂</mo><mi data-t=\"alpha\">β</mi></msub></mrow><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">α</mi></msub></mrow><mo>+</mo><mrow data-t=\"grad\"><msub><mo>∂</mo><mi data-t=\"alpha\">α</mi></msub></mrow><mrow data-t=\"u\"><msub><mi>u</mi><mi data-t=\"alpha\">β</mi></msub></mrow><mo>)</mo><mo>]</mo></math></div><p>Chapman–Enskog expansion: collide + stream reproduce Navier–Stokes. Collision contributes cₛ²τ of viscosity; the streaming error from step 1 removes cₛ²·½. Hence ν = cₛ²(τ − ½)Δt.</p></div></details>"
  }
 ],
 "checks": {
  "0": [
   [
    "At one cell and one time, what is fᵢ?",
    [
     "A vector in ℝ³",
     "A single non-negative number",
     "A vector in ℝ¹⁹"
    ],
    1,
    "fᵢ is one number; the 19 of them together form the cell's vector in ℝ¹⁹."
   ],
   [
    "Which map couples neighbouring cells?",
    [
     "Collision C",
     "Streaming S",
     "The moment map M"
    ],
    1,
    "C is local to each cell; only S moves numbers between cells."
   ],
   [
    "Why does streaming need no arithmetic?",
    [
     "It averages each cell with its neighbours",
     "It only copies each value to one neighbour: a pure reshuffle",
     "It recomputes the equilibrium"
    ],
    1,
    "S is a permutation: every number is moved, none is changed. All the arithmetic lives in collision."
   ],
   [
    "You double the grid resolution along x, y and z. How much bigger is the state?",
    [
     "2×",
     "8×",
     "19×"
    ],
    1,
    "The state has Nₓ·N_y·N_z cells × 19 values; doubling each of the three sizes gives 2³ = 8× as many numbers (and about 16× the work, because Δt halves too)."
   ],
   [
    "Which of S and C would you have to change to model a curved wall more accurately?",
    [
     "C, the collision",
     "S near the wall: how values bounce back at the boundary",
     "Neither"
    ],
    1,
    "Walls act during streaming: bounce-back decides what a cell pulls from a solid neighbour. Interpolated bounce-back schemes improve curved walls."
   ]
  ],
  "A": [
   [
    "With τ = 1, what is fᵢ right after collision?",
    [
     "Exactly fᵢᵉq",
     "Unchanged",
     "Halfway to fᵢᵉq"
    ],
    0,
    "1/τ = 1 closes the whole gap: fᵢ_new = fᵢᵉq."
   ],
   [
    "During streaming, where does population i go?",
    [
     "To every neighbour",
     "To the one neighbour 𝐱 + 𝐜ᵢΔt",
     "It stays in the cell"
    ],
    1,
    "Each population moves along its own lattice velocity, one cell per step."
   ],
   [
    "With collision but no streaming, what happens?",
    [
     "Each cell settles to its own equilibrium and nothing ever moves between cells",
     "The flow still moves, only slower",
     "The fluid becomes unstable"
    ],
    0,
    "Collision is local. Without S no information crosses a cell boundary, so there is no flow."
   ],
   [
    "Why is collision called “relaxation”?",
    [
     "Like a stretched spring settling, each population drifts toward equilibrium at rate 1/τ",
     "It lowers the pressure",
     "It removes energy at walls"
    ],
    0,
    "BGK: the gap to equilibrium shrinks by the factor (1 − 1/τ) every step."
   ],
   [
    "You set τ = 0.6. Roughly what fraction of the gap to equilibrium is left after one collision?",
    [
     "40%",
     "−67% (it overshoots past equilibrium)",
     "100%"
    ],
    1,
    "fᵢ_new − fᵢᵉq = (1 − 1/τ)(fᵢ − fᵢᵉq) = (1 − 1.67)(…) = −0.67(…): it overshoots, which lowers viscosity."
   ]
  ],
  "B": [
   [
    "Why does collision never change ρ or 𝐮?",
    [
     "Because τ is large",
     "fᵉq is built from the cell's own ρ and 𝐮, so its sums match",
     "The weights sum to 1"
    ],
    1,
    "Σfᵉq = ρ and Σfᵉq𝐜ᵢ = ρ𝐮: mass and momentum are conserved."
   ],
   [
    "Flow points right (+x). Which equilibrium population grows most?",
    [
     "→ (direction 1)",
     "← (direction 2)",
     "The rest population"
    ],
    0,
    "𝐜₁·𝐮 is largest and positive, so the first-order term boosts it most."
   ],
   [
    "The fluid in a cell is at rest (𝐮 = 0). What is fᵢᵉq?",
    [
     "Zero in every direction",
     "wᵢρ: each direction gets its fixed share",
     "ρ/19 in every direction"
    ],
    1,
    "With 𝐮 = 0 every term in the bracket except 1 vanishes, so fᵢᵉq = wᵢρ."
   ],
   [
    "Why does the recipe E need the −3/2 u² term?",
    [
     "So the 19 values still add up to exactly ρ",
     "To add viscosity",
     "To make it faster to compute"
    ],
    0,
    "The tilt and the (c·u)² term would otherwise change the total; −3/2 u² takes the same fraction back from every direction."
   ],
   [
    "Why does D3Q19 skip the 8 corner directions?",
    [
     "Corners would move faster than the speed of sound",
     "19 directions already spread evenly enough to reproduce Navier–Stokes; corners mainly add memory",
     "Corners point into walls"
    ],
    1,
    "The weights only need Σwᵢcᵢαcᵢβ = cₛ²δαβ (and a fourth-order version). D3Q27 adds the corners for extra stability in turbulent flow, at more cost."
   ]
  ],
  "C": [
   [
    "Doubling (τ − ½) does what to ν?",
    [
     "Halves it",
     "Doubles it",
     "Nothing"
    ],
    1,
    "ν is linear in (τ − ½), with slope cₛ²Δt = ⅓."
   ],
   [
    "Where does the −½ come from?",
    [
     "A safety margin for stability",
     "Streaming's own numerical diffusion, found by Taylor expansion",
     "Converting units"
    ],
    1,
    "The ½Δt²Dᵢ² term of streaming acts like negative diffusion and is subtracted from cₛ²τ."
   ],
   [
    "Which τ would represent honey rather than water, on the same grid?",
    [
     "A larger τ",
     "τ close to ½",
     "τ makes no difference"
    ],
    0,
    "ν = cₛ²(τ − ½): larger τ means higher viscosity, so the shear wave dies faster."
   ],
   [
    "To reach a higher Reynolds number on the same grid, you would…",
    [
     "Raise τ",
     "Lower τ toward ½, at the cost of stability",
     "Add more directions"
    ],
    1,
    "Re = UL/ν. Lowering τ lowers ν, until the simple collision becomes unstable; then you need a finer grid or a better collision model."
   ],
   [
    "Which grid change halves the viscosity in lattice units at fixed τ?",
    [
     "None: ν in lattice units is set by τ alone",
     "Doubling the cell count",
     "Halving Δt"
    ],
    0,
    "ν_lattice = cₛ²(τ − ½). Physical viscosity = ν_lattice·Δx²/Δt, so the grid and time step set the conversion, not the lattice value."
   ]
  ]
 },
 "quiz": [
  [
   "What does τ control?",
   [
    "The grid spacing",
    "The fluid's viscosity",
    "The inflow speed"
   ],
   1,
   "ν = c_s²(τ − ½)Δt: τ sets viscosity, and so the Reynolds number."
  ],
  [
   "Why does LBM suit GPUs so well?",
   [
    "It uses fewer cells than other methods",
    "Collision is local and streaming touches only neighbours, with no global pressure solve",
    "It runs in double precision"
   ],
   1,
   "Every cell updates independently, so thousands of threads run without waiting on each other."
  ],
  [
   "What happens as τ approaches ½?",
   [
    "Viscosity goes to zero and the scheme becomes unstable",
    "The flow becomes supersonic",
    "Nothing changes"
   ],
   0,
   "Lower viscosity means higher Reynolds number, until the simple collision model can no longer stay stable."
  ],
  [
   "Why is standard LBM limited to about Mach 0.3?",
   [
    "The lattice is too coarse",
    "Its equilibrium is a low-velocity expansion, so errors grow with Mach²",
    "GPUs can't represent fast flow"
   ],
   1,
   "The truncated Maxwell–Boltzmann equilibrium is only accurate for small u/c_s."
  ],
  [
   "What limits a GPU lattice Boltzmann solver most?",
   [
    "The arithmetic of collision",
    "Memory traffic: 19 values read and written per cell per step",
    "Solving the pressure equation"
   ],
   1,
   "Each update does little maths per byte moved, so memory bandwidth sets the speed; that is why layout (structure of arrays) matters."
  ],
  [
   "Why does LBM need no separate pressure equation?",
   [
    "Pressure is read straight from density: p = ρcₛ²",
    "It ignores pressure",
    "Pressure is computed on the CPU"
   ],
   0,
   "In the lattice gas, pressure is proportional to density, so it comes free with the moments."
  ],
  [
   "Why is LBM attractive for complex geometries like a full aircraft?",
   [
    "Cells are cubes, so meshing is just marking which cells are solid",
    "It needs no grid",
    "It is exact at walls"
   ],
   0,
   "A Cartesian lattice avoids body-fitted meshing; the cost is staircase walls, which need fine cells or interpolated bounce-back."
  ]
 ],
 "build": {
  "intro": "Put the steps of one LBM update in order. When it's right, your 3D solver runs below; you see a slice through its middle.",
  "html": "<div class=\"scrollx\"><canvas class=\"sim\" id=\"lbm-sim\" data-w=\"720\" data-h=\"290\" aria-label=\"Your 3D lattice Boltzmann solver: flow past a sphere, mid-plane slice\"></canvas></div>\n      <div class=\"row\"><label for=\"lbm-tau\">τ = <span id=\"lbm-tauv\">0.520</span></label><input type=\"range\" id=\"lbm-tau\" min=\"0.505\" max=\"1.0\" step=\"0.001\" value=\"0.52\"><span class=\"note\" id=\"lbm-nuv\"></span></div>\n      ",
  "steps": [
   "Compute ρ and u from the 19 values",
   "Compute equilibrium f_eq",
   "Collide: relax toward f_eq",
   "Stream: move values to neighbours",
   "Bounce back at the solid wall"
  ],
  "hint": "You need ρ and u before the equilibrium, and the wall acts on values after they stream.",
  "success": "Your 3D solver is running (the colour is spin about z in the middle slice). A sphere's wake stays steady up to Re ≈ 210 and sheds vortices above ≈ 270."
 },
 "parallel": {
  "html": "<div class=\"par\">\n        <div class=\"stack\">\n          <p><strong>Collide</strong> uses only the cell's own 19 numbers, so every cell is independent: one GPU thread per cell.</p>\n          <p><strong>Stream</strong> reads from the 18 neighbours (faces and edges of the cell; D3Q19 skips the 8 corners). \"Pull\" (each cell reads its incoming values) means no two threads write to the same place, so no locks.</p>\n          <p><strong>No global solve:</strong> unlike Navier–Stokes solvers, there is no pressure equation coupling the whole grid, so it scales almost perfectly.</p>\n        </div>\n        <canvas id=\"lbm-threads\" data-w=\"320\" data-h=\"230\" style=\"width:100%;max-width:320px;border-radius:8px;background:var(--bg)\" aria-label=\"Grid of cells, each a GPU thread; highlighted neighbours read during streaming\"></canvas>\n      </div>\n      <h3 style=\"font-size:16px\">Memory layout: the main optimization</h3>\n      <p>The solver is limited by memory bandwidth, not maths. Each cell moves 19 values in and 19 out per step. How they sit in memory decides whether neighbouring threads read neighbouring addresses (coalesced = fast).</p>\n      <div class=\"btns\"><button class=\"b\" id=\"lbm-aos\">Array of structures</button><button class=\"b\" id=\"lbm-soa\">Structure of arrays</button></div>\n      <div class=\"mem\" id=\"lbm-mem\" aria-label=\"Memory addresses read by 16 threads\"></div>\n      <div class=\"fb\" id=\"lbm-memfb\"></div>\n      <details><summary>Further optimizations</summary><p>Fuse collide and stream into one kernel (one read, one write per value). In-place \"esoteric pull\" streaming halves memory. Store values in 16-bit floats, compute in 32-bit. Typical GPU throughput: billions of cell updates per second.</p></details>\n      "
 },
 "unlock": "The Lattice Boltzmann row of the comparison is now visible. Complete the other seven methods to open the full page.",
 "terms": {
  "fi": {
   "sym": "<msub><mi>f</mi><mi>i</mi></msub>",
   "name": "Population",
   "def": "How much fluid in the cell moves in direction i. A count, not a speed.",
   "space": "<msub><mi>f</mi><mi>i</mi></msub><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>≥</mo><mn>0</mn></mrow></msub><mo>,</mo><mspace width=\".6em\"/><msub><mi>f</mi><mrow><mi>i</mi><mi>x</mi><mi>y</mi><mi>z</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>19</mn><mo>×</mo><msub><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub><mi>N</mi><mi>z</mi></msub></mrow></msup>",
   "col": "--c-f"
  },
  "i": {
   "sym": "<mi>i</mi>",
   "name": "Direction index",
   "def": "0 = at rest, 1–6 = the 6 face neighbours, 7–18 = the 12 edge neighbours.",
   "space": "<mi>i</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><mn>18</mn><mo>}</mo>",
   "col": "--c-f"
  },
  "x": {
   "sym": "<mi>𝐱</mi>",
   "name": "Cell position",
   "def": "Where the cell sits in the 3D grid: 𝐱 = (x, y, z).",
   "space": "<mi>𝐱</mi><mo>=</mo><mo>(</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>)</mo><mo>∈</mo><msup><mi>ℤ</mi><mn>3</mn></msup>",
   "col": "--ink"
  },
  "ci": {
   "sym": "<msub><mi>𝐜</mi><mi>i</mi></msub>",
   "name": "Lattice velocity",
   "def": "One of 19 fixed 3D vectors: (0,0,0), six like (±1,0,0), twelve like (±1,±1,0). Exactly one cell per step.",
   "space": "<msub><mi>𝐜</mi><mi>i</mi></msub><mo>∈</mo><msup><mrow><mo>{</mo><mo>−</mo><mn>1</mn><mo>,</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>}</mo></mrow><mn>3</mn></msup><mo>,</mo><mspace width=\".5em\"/><msup><mrow><mo>|</mo><msub><mi>𝐜</mi><mi>i</mi></msub><mo>|</mo></mrow><mn>2</mn></msup><mo>≤</mo><mn>2</mn>",
   "col": "--c-c"
  },
  "t": {
   "sym": "<mi>t</mi>",
   "name": "Time level",
   "def": "Which step: 0, Δt, 2Δt, … As a superscript (fᵗ) it labels the time; it is not a power.",
   "space": "<mi>t</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mi>Δ</mi><mi>t</mi><mo>,</mo><mn>2</mn><mi>Δ</mi><mi>t</mi><mo>,</mo><mo>…</mo><mo>}</mo>",
   "col": "--c-w"
  },
  "dt": {
   "sym": "<mi>Δ</mi><mi>t</mi>",
   "name": "Time step",
   "def": "One update. In lattice units Δt = 1 and the cell size Δx = 1.",
   "space": "<mi>Δ</mi><mi>t</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub><mo>,</mo><mspace width=\"0.5em\"/><mtext>lattice units: </mtext><mi>Δ</mi><mi>t</mi><mo>=</mo><mn>1</mn>",
   "col": "--c-w"
  },
  "xc": {
   "sym": "<mi>𝐱</mi><mo>+</mo><msub><mi>𝐜</mi><mi>i</mi></msub><mi>Δ</mi><mi>t</mi>",
   "name": "Neighbour",
   "def": "Where population i lands after one step.",
   "space": "<mi>𝐱</mi><mo>+</mo><msub><mi>𝐜</mi><mi>i</mi></msub><mi>Δ</mi><mi>t</mi><mo>∈</mo><mi>Λ</mi><mspace width=\"0.5em\"/><mtext>(wraps around)</mtext>",
   "col": "--c-c"
  },
  "coll": {
   "sym": "<mfrac><mn>1</mn><mi>τ</mi></mfrac><mo>(</mo><msub><mi>f</mi><mi>i</mi></msub><mo>−</mo><msubsup><mi>f</mi><mi>i</mi><mtext>eq</mtext></msubsup><mo>)</mo>",
   "name": "Collision (BGK)",
   "def": "Closes a fraction 1/τ of the gap between each population and its equilibrium.",
   "space": "<mi>Ω</mi><mo>:</mo><msup><mi>ℝ</mi><mn>19</mn></msup><mo>→</mo><msup><mi>ℝ</mi><mn>19</mn></msup><mo>,</mo><mspace width=\".5em\"/><mtext>per cell, nonlinear</mtext>",
   "col": "--c-eq",
   "op": "C"
  },
  "tau": {
   "sym": "<mi>τ</mi>",
   "name": "Relaxation time",
   "def": "Steps to relax toward equilibrium. τ = 1 lands on it; τ < 1 overshoots.",
   "space": "<mi>τ</mi><mo>∈</mo><mo>(</mo><mfrac><mn>1</mn><mn>2</mn></mfrac><mo>,</mo><mi>∞</mi><mo>)</mo><mo>⊂</mo><mi>ℝ</mi>",
   "col": "--c-tau"
  },
  "feq": {
   "sym": "<msubsup><mi>f</mi><mi>i</mi><mtext>eq</mtext></msubsup>",
   "name": "Equilibrium",
   "def": "The populations a fluid with this cell's ρ and 𝐮 settles to.",
   "space": "<mi>E</mi><mo>:</mo><msub><mi>m</mi><mi>a</mi></msub><mo>∈</mo><msup><mi>ℝ</mi><mn>4</mn></msup><mo>↦</mo><msubsup><mi>f</mi><mi>i</mi><mtext>eq</mtext></msubsup><mo>∈</mo><msup><mi>ℝ</mi><mn>19</mn></msup>",
   "col": "--c-eq"
  },
  "w": {
   "sym": "<msub><mi>w</mi><mi>i</mi></msub>",
   "name": "Weight",
   "def": "Equilibrium of still fluid: 1/3 at rest, 1/18 faces, 1/36 edges. Sum = 1.",
   "space": "<msub><mi>w</mi><mi>i</mi></msub><mo>∈</mo><mo>{</mo><mfrac><mn>1</mn><mn>3</mn></mfrac><mo>,</mo><mfrac><mn>1</mn><mn>18</mn></mfrac><mo>,</mo><mfrac><mn>1</mn><mn>36</mn></mfrac><mo>}</mo><mo>,</mo><mspace width=\".5em\"/><mo>∑</mo><msub><mi>w</mi><mi>i</mi></msub><mo>=</mo><mn>1</mn>",
   "col": "--c-w"
  },
  "rho": {
   "sym": "<mi>ρ</mi>",
   "name": "Density",
   "def": "The sum of the cell's 19 populations.",
   "space": "<mi>ρ</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>",
   "col": "--c-rho"
  },
  "u": {
   "sym": "<msub><mi>u</mi><mi>α</mi></msub>",
   "name": "Velocity",
   "def": "Component α of the fluid velocity: momentum ρu_α divided by ρ. u_αu_α = u_x² + u_y² + u_z².",
   "space": "<msub><mi>u</mi><mi>α</mi></msub><mo>∈</mo><mi>ℝ</mi><mo>,</mo><mspace width=\".5em\"/><mi>α</mi><mo>∈</mo><mo>{</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>}</mo>",
   "col": "--c-u"
  },
  "cs": {
   "sym": "<msub><mi>c</mi><mi>s</mi></msub>",
   "name": "Speed of sound",
   "def": "1/√3 cells per step. Mach number = |𝐮| / cₛ.",
   "space": "<msub><mi>c</mi><mi>s</mi></msub><mo>=</mo><mfrac><mn>1</mn><msqrt><mn>3</mn></msqrt></mfrac><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub><mspace width=\"0.5em\"/><mtext>(constant)</mtext>",
   "col": "--c-cs"
  },
  "sum": {
   "sym": "<munder><mo>∑</mo><mi>i</mi></munder>",
   "name": "Sum over directions",
   "def": "Adds all 19 directions. Taking such sums is applying the moment matrix M_ai (block 0).",
   "space": "<msub><mi>M</mi><mrow><mi>a</mi><mi>i</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>4</mn><mo>×</mo><mn>19</mn></mrow></msup><mo>,</mo><mspace width=\".5em\"/><msub><mi>m</mi><mi>a</mi></msub><mo>=</mo><munder><mo>∑</mo><mi>i</mi></munder><msub><mi>M</mi><mrow><mi>a</mi><mi>i</mi></mrow></msub><msub><mi>f</mi><mi>i</mi></msub>",
   "col": "--ink",
   "op": "M"
  },
  "nu": {
   "sym": "<mi>ν</mi>",
   "name": "Viscosity",
   "def": "How fast velocity differences smear out (cells²/step). Re = UL/ν.",
   "space": "<mi>ν</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>",
   "col": "--c-nu"
  },
  "half": {
   "sym": "<mfrac><mn>1</mn><mn>2</mn></mfrac>",
   "name": "Streaming correction",
   "def": "Streaming itself adds numerical diffusion; at τ = ½ viscosity is zero.",
   "space": "<mfrac><mn>1</mn><mn>2</mn></mfrac><mo>∈</mo><mi>ℚ</mi><mspace width=\"0.5em\"/><mtext>(constant)</mtext>",
   "col": "--c-tau"
  },
  "grad": {
   "sym": "<msub><mo>∂</mo><mi>α</mi></msub>",
   "name": "Partial derivative",
   "def": "Rate of change along axis α; ∂ₜ is the same in time.",
   "space": "<mrow><msub><mo>∂</mo><mi>α</mi></msub><mo>:</mo><mtext>field on the grid → field on the grid</mtext></mrow>",
   "col": "--ink"
  },
  "D": {
   "sym": "<msub><mi>D</mi><mi>i</mi></msub>",
   "name": "Derivative along 𝐜ᵢ",
   "def": "Dᵢ = ∂ₜ + c_iα∂_α: the change seen while travelling with population i.",
   "space": "<mrow><msub><mi>D</mi><mi>i</mi></msub><mo>=</mo><msub><mo>∂</mo><mi>t</mi></msub><mo>+</mo><msub><mi>c</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><msub><mo>∂</mo><mi>α</mi></msub><mspace width=\".5em\"/><mtext>(linear operator)</mtext></mrow>",
   "col": "--c-c"
  },
  "p": {
   "sym": "<mi>p</mi>",
   "name": "Pressure",
   "def": "p = ρcₛ²: the lattice gas law. Pressure is just density times a constant.",
   "space": "<mi>p</mi><mo>∈</mo><msub><mi>ℝ</mi><mrow><mo>&gt;</mo><mn>0</mn></mrow></msub>",
   "col": "--c-rho"
  },
  "delta": {
   "sym": "<msub><mi>δ</mi><mrow><mi>α</mi><mi>β</mi></mrow></msub>",
   "name": "Kronecker delta",
   "def": "1 if α = β, else 0: the 3×3 identity matrix written with indices.",
   "space": "<msub><mi>δ</mi><mrow><mi>α</mi><mi>β</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>3</mn><mo>×</mo><mn>3</mn></mrow></msup>",
   "col": "--c-w"
  },
  "alpha": {
   "sym": "<mrow><mi>α</mi><mo>,</mo><mi>β</mi></mrow>",
   "name": "Axis index",
   "def": "x, y or z. Repeated twice in a term means sum over all three (Einstein convention).",
   "space": "<mi>α</mi><mo>,</mo><mi>β</mi><mo>∈</mo><mo>{</mo><mi>x</mi><mo>,</mo><mi>y</mi><mo>,</mo><mi>z</mi><mo>}</mo>",
   "col": "--ink"
  },
  "cia": {
   "sym": "<msub><mi>c</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub>",
   "name": "Lattice velocity component",
   "def": "Component α of lattice velocity i: −1, 0 or 1. c_iαu_α = how far direction i points along the flow.",
   "space": "<msub><mi>c</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub><mo>∈</mo><mo>{</mo><mo>−</mo><mn>1</mn><mo>,</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>}</mo><mo>,</mo><mspace width=\".5em\"/><mtext>a 19 × 3 integer table</mtext>",
   "col": "--c-c"
  },
  "ix": {
   "sym": "<mi>x</mi>",
   "name": "Cell column",
   "def": "Which column of the grid, 0 … Nₓ−1. As a subscript of f it picks the cell.",
   "space": "<mi>x</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>x</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>",
   "col": "--ink"
  },
  "iy": {
   "sym": "<mi>y</mi>",
   "name": "Cell row",
   "def": "Which row of the grid, 0 … N_y−1.",
   "space": "<mi>y</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>",
   "col": "--ink"
  },
  "N": {
   "sym": "<msub><mi>N</mi><mi>x</mi></msub><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub>",
   "name": "Grid size",
   "def": "Cells along x, y and z (80 × 40 × 40 in the Build step).",
   "space": "<msub><mi>N</mi><mi>x</mi></msub><mo>,</mo><msub><mi>N</mi><mi>y</mi></msub><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>∈</mo><mi>ℕ</mi>",
   "col": "--ink"
  },
  "S": {
   "sym": "<mi>S</mi>",
   "name": "Streaming map",
   "def": "Slides every number one cell along its own direction. Nothing is added or multiplied: like shifting an image by one pixel. The only step that connects neighbouring cells.",
   "space": "<mi>S</mi><mo>:</mo><msup><mi>ℝ</mi><mrow><mn>19</mn><mo>×</mo><msub><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub><mi>N</mi><mi>z</mi></msub></mrow></msup><mo>→</mo><msup><mi>ℝ</mi><mrow><mn>19</mn><mo>×</mo><msub><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub><mi>N</mi><mi>z</mi></msub></mrow></msup><mo>,</mo><mspace width=\".5em\"/><mtext>linear</mtext>",
   "col": "--c-c",
   "op": "S"
  },
  "C": {
   "sym": "<mi>C</mi>",
   "name": "Collision map",
   "def": "Inside each cell: total up (M), build the calm-fluid target (E), move part way to it (1/τ). Every cell on its own, like a filter applied to each pixel separately.",
   "space": "<mi>C</mi><mo>:</mo><msup><mi>ℝ</mi><mrow><mn>19</mn><mo>×</mo><msub><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub><mi>N</mi><mi>z</mi></msub></mrow></msup><mo>→</mo><msup><mi>ℝ</mi><mrow><mn>19</mn><mo>×</mo><msub><mi>N</mi><mi>x</mi></msub><mo>×</mo><msub><mi>N</mi><mi>y</mi></msub><mo>×</mo><msub><mi>N</mi><mi>z</mi></msub></mrow></msup><mo>,</mo><mspace width=\".5em\"/><mtext>cell by cell</mtext>",
   "col": "--c-tau",
   "op": "C"
  },
  "Mm": {
   "sym": "<msub><mi>M</mi><mrow><mi>a</mi><mi>i</mi></mrow></msub>",
   "name": "Moment matrix",
   "def": "Turns 19 numbers into 4 totals. Row 0 adds everything (density); rows 1–3 add what moves +x, +y, +z and subtract what moves the other way (momentum). Like totalling a receipt.",
   "space": "<msub><mi>M</mi><mrow><mi>a</mi><mi>i</mi></mrow></msub><mo>∈</mo><msup><mi>ℝ</mi><mrow><mn>4</mn><mo>×</mo><mn>19</mn></mrow></msup>",
   "col": "--c-rho",
   "op": "M"
  },
  "m": {
   "sym": "<msub><mi>m</mi><mi>a</mi></msub>",
   "name": "Moments",
   "def": "The cell's 4 totals: density ρ and momentum ρuₓ, ρu_y, ρu_z.",
   "space": "<msub><mi>m</mi><mi>a</mi></msub><mo>∈</mo><msup><mi>ℝ</mi><mn>4</mn></msup>",
   "col": "--c-rho",
   "op": "M"
  },
  "E": {
   "sym": "<mi>E</mi>",
   "name": "Equilibrium map",
   "def": "A recipe: from the 4 totals, build the 19 numbers a calm fluid with that density and velocity would have.",
   "space": "<mi>E</mi><mo>:</mo><msup><mi>ℝ</mi><mn>4</mn></msup><mo>→</mo><msup><mi>ℝ</mi><mn>19</mn></msup><mo>,</mo><mspace width=\".5em\"/><mtext>nonlinear</mtext>",
   "col": "--c-eq",
   "op": "E"
  },
  "iz": {
   "sym": "<mi>z</mi>",
   "name": "Cell layer",
   "def": "Which layer of the grid, 0 … N_z−1.",
   "space": "<mi>z</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mo>…</mo><mo>,</mo><msub><mi>N</mi><mi>z</mi></msub><mo>−</mo><mn>1</mn><mo>}</mo>",
   "col": "--ink"
  },
  "a": {
   "sym": "<mi>a</mi>",
   "name": "Moment index",
   "def": "0 = density ρ, 1–3 = momentum ρuₓ, ρu_y, ρu_z.",
   "space": "<mi>a</mi><mo>∈</mo><mo>{</mo><mn>0</mn><mo>,</mo><mn>1</mn><mo>,</mo><mn>2</mn><mo>,</mo><mn>3</mn><mo>}</mo>",
   "col": "--c-rho"
  }
 }
}, {
mount(root, K){
const {$, css, reduce, MONO, MATH, P, hex, hidpi, arrow, rr, pill, label, ease, lerp, proj, box, orbit, isAct} = K;
const triad = K.triad;
// D3Q19 lattice: 1 rest, 6 face neighbours, 12 edge neighbours (the 8 corners are left out)
const C3 = [[0,0,0],[1,0,0],[-1,0,0],[0,1,0],[0,-1,0],[0,0,1],[0,0,-1],[1,1,0],[-1,-1,0],[1,-1,0],[-1,1,0],[1,0,1],[-1,0,-1],[1,0,-1],[-1,0,1],[0,1,1],[0,-1,-1],[0,1,-1],[0,-1,1]];
const Q = 19, cx = C3.map(c => c[0]), cy = C3.map(c => c[1]), cz = C3.map(c => c[2]);
const w = C3.map((c,i) => i === 0 ? 1/3 : Math.abs(c[0])+Math.abs(c[1])+Math.abs(c[2]) === 1 ? 1/18 : 1/36);
const opp = C3.map(c => C3.findIndex(d => d[0] === -c[0] && d[1] === -c[1] && d[2] === -c[2]));
function feq(i, r, ux, uy, uz){ const cu = 3*(cx[i]*ux+cy[i]*uy+cz[i]*uz); return w[i]*r*(1+cu+0.5*cu*cu-1.5*(ux*ux+uy*uy+uz*uz)); }

// BUILD: real 3D flow past a sphere. Structure-of-arrays storage, collide fused with pull streaming.
const NX = 80, NY = 40, NZ = 40, N = NX*NY*NZ, RS = 5, XC = 20, U0 = 0.08;
let f, f2, solid, src, running = false, tau = 0.52, simN = 0;
function initSim(){
  f = new Float32Array(Q*N); f2 = new Float32Array(Q*N); solid = new Uint8Array(N); src = new Int32Array(Q*N);
  for (let z=0;z<NZ;z++) for (let y=0;y<NY;y++) for (let x=0;x<NX;x++){ const k = (z*NY+y)*NX+x;
    if ((x-XC)**2+(y-NY/2+0.5)**2+(z-NZ/2+0.5)**2 < RS*RS) solid[k] = 1; for (let i=0;i<Q;i++) f[i*N+k] = w[i]; }
  // where each population is pulled from; -1 means that neighbour is solid, so it bounces back
  for (let z=0;z<NZ;z++) for (let y=0;y<NY;y++) for (let x=0;x<NX;x++){ const k = (z*NY+y)*NX+x;
    for (let i=0;i<Q;i++){ const sx = Math.min(NX-1, Math.max(0, x-cx[i])), sy = (y-cy[i]+NY)%NY, sz = (z-cz[i]+NZ)%NZ, ks = (sz*NY+sy)*NX+sx;
      src[i*N+k] = solid[ks] ? -1 : ks; } }
  simN = 0;
}
const fl = new Float64Array(Q);
function stepSim(){
  const Uin = U0*(simN < 400 ? 0.5-0.5*Math.cos(Math.PI*simN/400) : 1), kick = simN > 400 && simN < 500 ? 0.004 : 0; simN++;
  for (let k=0;k<N;k++){ if (solid[k]) continue;
    let r=0, u=0, v=0, s=0;
    for (let i=0;i<Q;i++){ const sI = src[i*N+k], val = sI < 0 ? f[opp[i]*N+k] : f[i*N+sI]; fl[i] = val; r += val; u += val*cx[i]; v += val*cy[i]; s += val*cz[i]; }
    u /= r; v /= r; s /= r;
    if (k % NX === 0) { r = 1; u = Uin; v = kick; s = 0; }
    const uu = 1.5*(u*u+v*v+s*s);
    for (let i=0;i<Q;i++){ const cu = 3*(cx[i]*u+cy[i]*v+cz[i]*s); f2[i*N+k] = fl[i] + (w[i]*r*(1+cu+0.5*cu*cu-uu) - fl[i])/tau; }
  }
  [f,f2] = [f2,f];
  for (let k=NX-1;k<N;k+=NX) for (let i=0;i<Q;i++) f[i*N+k] = f[i*N+k-1];
  if (!(f[N*3+N/2] === f[N*3+N/2])) initSim();
}
const SC = hidpi($('sim')), img = new ImageData(NX, NY), off = document.createElement('canvas'); off.width=NX; off.height=NY;
const UX = new Float32Array(NX*NY), UY = new Float32Array(NX*NY);
function drawSim(){
  const p = P(), a = hex(p.acc), b = hex(p.warm), bg = hex(p.bg), z0 = NZ>>1, SW = 560, SH = 280;
  for (let y=0;y<NY;y++) for (let x=0;x<NX;x++){ const k = (z0*NY+y)*NX+x, j = y*NX+x; let r=0,u=0,v=0;
    for (let i=0;i<Q;i++){ const t = f[i*N+k]; r += t; u += t*cx[i]; v += t*cy[i]; } UX[j] = u/r; UY[j] = v/r; }
  for (let y=0;y<NY;y++) for (let x=0;x<NX;x++){ const j = y*NX+x, o = ((NY-1-y)*NX+x)*4;
    const xl = Math.max(0,x-1), xr = Math.min(NX-1,x+1), yu = (y+1)%NY, yd = (y-1+NY)%NY;
    const vort = (UY[y*NX+xr]-UY[y*NX+xl]) - (UX[yu*NX+x]-UX[yd*NX+x]);
    const s = Math.tanh(vort*40), c = s>0?a:b, t = Math.abs(s)**0.8, sp = Math.min(1, Math.hypot(UX[j],UY[j])/(1.6*U0));
    for (let q=0;q<3;q++){ const base = bg[q]*(1-0.10*sp); img.data[o+q] = base+(c[q]-base)*t; } img.data[o+3] = 255; }
  off.getContext('2d').putImageData(img,0,0);
  SC.clearRect(0,0,SC.W,SC.H); SC.imageSmoothingEnabled = true; SC.imageSmoothingQuality = 'high'; SC.drawImage(off,0,0,SW,SH);
  SC.fillStyle = p.ink; SC.beginPath(); SC.arc((XC+0.5)/NX*SW, SH/2, RS/NX*SW, 0, 7); SC.fill();
  // inset: where the slice sits in the 3D box
  const V = {th:-0.75, ph:0.42, s:62, ox:642, oy:150}, B = (x,y,z) => proj(V, x, y, z), hx = 1, hy = .5, hz = .5;
  const q = [[-hx,-hy,0],[hx,-hy,0],[hx,hy,0],[-hx,hy,0]].map(v => B(...v));
  SC.fillStyle = p.acc; SC.globalAlpha = .18; SC.beginPath(); q.forEach(([x,y],i) => i ? SC.lineTo(x,y) : SC.moveTo(x,y)); SC.closePath(); SC.fill(); SC.globalAlpha = 1;
  SC.strokeStyle = p.acc; SC.lineWidth = 1.4; SC.stroke();
  box(SC, V, hx, hy, hz, p.mut, 1);
  const sc = B(-hx + 2*hx*(XC+.5)/NX, 0, 0); SC.fillStyle = p.ink; SC.beginPath(); SC.arc(sc[0], sc[1], V.s*2*hx*RS/NX, 0, 7); SC.fill();
  const f0 = B(-hx-.35, 0, 0), f1 = B(-hx-.05, 0, 0); arrow(SC, f0[0], f0[1], f1[0], f1[1], p.ink, 2);
  label(SC, 'flow', f0[0]-4, f0[1]+16, p.mut, MONO, 'center');
  label(SC, 'slice shown: z = N_z/2', 640, 254, p.mut, MONO, 'center');
  label(SC, `${NX}×${NY}×${NZ} cells`, 640, 270, p.mut, MONO, 'center'); label(SC, '19 values per cell', 640, 284, p.mut, MONO, 'center');
}
const tauIn=$('tau');
function tauText(){ tau=+tauIn.value; $('tauv').textContent=tau.toFixed(3); const nu=(tau-0.5)/3, Re = U0*2*RS/nu;
  $('nuv').textContent=`ν = ${nu.toFixed(4)} · Re ≈ ${Math.round(Re)} · ${Re < 210 ? 'steady wake: a still vortex ring behind the sphere' : Re < 270 ? 'steady but lopsided wake' : 'vortex shedding (hairpin vortices)'}${tau<0.51?' · too close to ½ for this grid: may go unstable':''}`; }
tauIn.oninput=tauText; tauText();

const moments = g => { let r=0,u=0,v=0,s=0; for (let i=0;i<Q;i++){ r+=g[i]; u+=g[i]*cx[i]; v+=g[i]*cy[i]; s+=g[i]*cz[i]; } return [r,u/r,v/r,s/r]; };
const SITES = [-1,0,1].flatMap(a => [-1,0,1].flatMap(b => [-1,0,1].map(d => [a,b,d]))).filter(s => s.some(Boolean));

// 0: what each operator does to one cell's numbers, step by step
const CO = hidpi($('opviz')), OPT = 1.5;
const OPS = [
 ['fᵢ', 'Start: one cell holds 19 numbers fᵢ, one bar each: how much fluid moves in each of the 19 directions.'],
 ['M', 'M adds them up into 4 totals. ρ counts all fluid (density). ρuₓ adds what moves +x and subtracts what moves −x; the same for y and z (momentum). Like totalling a receipt: many items in, a few sums out.'],
 ['E', 'E is a recipe: from those 4 totals it builds the 19 numbers a calm fluid with that density and velocity would have. Few numbers in, many out. Click E (the button above the picture, or the symbol) to see how it works.'],
 ['1/τ', 'Blend: each fᵢ moves part of the way (1/τ) toward its calm value. Steps M → E → blend together are collision C. Every cell does this on its own, like a filter applied to each pixel separately.'],
 ['S', 'S (streaming) slides every number one cell along its own direction. Nothing is added or multiplied: like shifting an image by one pixel. It is the only step that connects neighbouring cells.']];
let opStage = 0, opT = 0, opPlay = !reduce, opLast = null;
const opF = (() => { let s = 7; const rnd = () => (s = (s*16807) % 2147483647) / 2147483647; return C3.map((_,i) => feq(i,1,0.1,0.05,0.03) * (i ? 1 + 0.8*(rnd()-.5) : 1)); })();
const opM = moments(opF), opE = C3.map((_,i) => feq(i, opM[0], opM[1], opM[2], opM[3])), opS = opF.map((g,i) => g + (opE[i]-g)/OPT);
const opBtns = $('opsteps');
opBtns.innerHTML = OPS.map(([n],k) => `<button class="b opb" data-k="${k}">${k+1} · ${n}</button>`).join('');
opBtns.onclick = e => { const b = e.target.closest('.opb'); if (!b) return; opStage = +b.dataset.k; opT = 0; opCap(); K.pin([null,'Mm','E','C','S'][opStage]); if (reduce) drawOps(0); };
$('opplay').onclick = e => { opPlay = !opPlay; e.target.textContent = opPlay ? 'Pause' : 'Play'; };
function opCap(){ $('opcap').textContent = OPS[opStage][1]; opBtns.querySelectorAll('.opb').forEach((b,k) => b.classList.toggle('pri', k === opStage)); }
opCap();
function drawOps(now){
  const dt = opLast === null ? 0 : Math.min(100, now - opLast); opLast = now;
  opT = Math.min(opPlay ? 99 : 3.6, opT + dt/1000); if (opPlay && opT > 3.6) { opT = 0; opStage = (opStage+1) % OPS.length; opCap(); }
  const c = CO, W = c.W, H = c.H, p = P(), e = reduce ? 1 : ease(opT/2.2), top = 46, base = 190, un = 52;
  c.clearRect(0,0,W,H);
  const cols = { f: 16, m: 258, q: 438, s: 680 }, bw = 7.2, gp = 2.4, bx = (x0,i) => x0 + i*(bw+gp) + bw/2;
  const groupCol = i => i === 0 ? p.ink : i < 7 ? p.f : p.c;
  const bars = (x0, vals, col, alpha, title, sub) => {
    label(c, title, x0, 22, alpha > .5 ? p.ink : p.mut, MATH); label(c, sub, x0, 36, p.mut, '10px "IBM Plex Mono", monospace');
    c.globalAlpha = alpha; vals.forEach((v,i) => { const h = Math.min(140, v/w[i]*un); c.fillStyle = typeof col === 'function' ? col(i) : col; rr(c, x0+i*(bw+gp), base-h, bw, h, 2); c.fill(); }); c.globalAlpha = 1;
    c.setLineDash([3,3]); c.strokeStyle = p.w; c.lineWidth = 1; c.beginPath(); c.moveTo(x0-3, base-un); c.lineTo(x0+Q*(bw+gp), base-un); c.stroke(); c.setLineDash([]); };
  // the four columns of numbers
  bars(cols.f, opF, p.f, 1, 'fᵢ  · 19 numbers', 'bar = fᵢ ÷ wᵢ');
  const mOn = opStage >= 1, qOn = opStage >= 2, sOn = opStage >= 3;
  // moments: density on its own scale, momentum ×8 around a zero line
  { const x0 = cols.m, mv = [opM[0], opM[0]*opM[1], opM[0]*opM[2], opM[0]*opM[3]], nm = ['ρ','ρuₓ','ρu_y','ρu_z'], k = opStage === 1 ? e : mOn ? 1 : 0;
    label(c, 'm_a  · 4 totals', x0, 22, mOn ? p.ink : p.mut, MATH); label(c, 'momentum ×8', x0, 36, p.mut, '10px "IBM Plex Mono", monospace');
    c.globalAlpha = mOn ? 1 : .25;
    mv.forEach((v,a) => { const x = x0 + a*30, h = a ? v*8*un*k : v*un*k, col = a ? p.u : p.rho; c.fillStyle = col; rr(c, x, h >= 0 ? base-h : base, 20, Math.abs(h), 3); c.fill();
      label(c, nm[a], x+10, base+16, col, '11px "IBM Plex Mono", monospace', 'center'); });
    c.globalAlpha = 1; }
  bars(cols.q, qOn ? opE.map(v => opStage === 2 ? v*e : v) : opE, p.eq, qOn ? 1 : .25, 'fᵢᵉq  · 19 numbers', 'calm-fluid values');
  const star = opF.map((g,i) => opStage === 3 ? lerp(g, opS[i], e) : sOn ? opS[i] : g);
  bars(cols.s, star, p.tau, sOn ? 1 : .25, 'fᵢ⋆  · 19 numbers', `after collision, τ = ${OPT}`);
  if (opStage === 3) opE.forEach((v,i) => { const x = cols.s + i*(bw+gp), h = Math.min(140, v/w[i]*un); c.fillStyle = p.eq; c.fillRect(x-1, base-h-1, bw+2, 2.5); });
  // operator arrows between the columns
  [[cols.f+Q*(bw+gp)+6, cols.m-14, 'M', '4×19 matrix', 1], [cols.m+124, cols.q-12, 'E', 'recipe', 2], [cols.q+Q*(bw+gp)+6, cols.s-10, '1/τ', 'blend', 3]].forEach(([a,b,n,s,k]) => {
    const on = opStage === k, y = 110; arrow(c, a, y, b, y, on ? p.ink : p.rule, on ? 2.6 : 1.6);
    label(c, n, (a+b)/2, y-10, on ? p.ink : p.mut, MATH, 'center'); label(c, s, (a+b)/2, y+18, on ? p.ink : p.mut, '10px "IBM Plex Mono", monospace', 'center'); });
  // moving dots show where each number goes
  const dot = (x0,y0,x1,y1,col,t) => { const t2 = ease(t); c.fillStyle = col; c.beginPath(); c.arc(lerp(x0,x1,t2), lerp(y0,y1,t2) - Math.sin(Math.PI*t2)*30, 3, 0, 7); c.fill(); };
  if (opStage === 1) for (let i=0;i<Q;i++){ const x0 = bx(cols.f,i), y0 = base - Math.min(140, opF[i]/w[i]*un), t = Math.max(0, Math.min(1, (opT - i*0.04)/1.2));
    dot(x0, y0, cols.m+10, base-un, p.rho, t);
    [cx[i], cy[i], cz[i]].forEach((s,a) => { if (s) dot(x0, y0, cols.m + (a+1)*30 + 10, base-un, s > 0 ? p.c : p.nu, Math.max(0, t - .15)); }); }
  if (opStage === 2) for (let i=0;i<Q;i+=1){ const t = Math.max(0, Math.min(1, (opT - i*0.03)/1.2)); dot(cols.m+55, base-un, bx(cols.q,i), base - Math.min(140, opE[i]/w[i]*un), p.eq, t); }
  if (opStage === 3) for (let i=0;i<Q;i+=2){ const t = Math.max(0, Math.min(1, opT/1.2)); dot(bx(cols.f,i), base-30, bx(cols.s,i), base-30, p.f, t); dot(bx(cols.q,i), base-30, bx(cols.s,i), base-30, p.eq, t); }
  // streaming strip: two of the 19 directions along a row of 9 cells
  { const y0 = 236, n = 9, cw = 86, x0 = (W - n*cw)/2, on = opStage === 4, sh = on ? e : 0, vR = [5,3,7,4,6,2,5,4,3], vL = [2,4,3,6,2,5,3,4,6];
    label(c, 'S on a row of 9 cells (only the → and ← directions drawn; all 19 move the same way)', x0, y0-12, on ? p.ink : p.mut, '11px "IBM Plex Mono", monospace');
    c.globalAlpha = on ? 1 : .35;
    for (let k=0;k<n;k++){ rr(c, x0+k*cw+3, y0, cw-6, 72, 10); c.fillStyle = p.panel; c.fill(); c.strokeStyle = p.rule; c.lineWidth = 1; c.stroke(); }
    c.save(); rr(c, x0, y0, n*cw, 72, 10); c.clip();
    for (let k=-1;k<=n;k++){ const kr = (k+n)%n;
      const xr = x0 + (k + sh)*cw + cw*.5, xl = x0 + (k - sh)*cw + cw*.5;
      arrow(c, xr-22, y0+24, xr-22+vR[kr]*6, y0+24, p.f, 4); arrow(c, xl+22, y0+52, xl+22-vL[kr]*6, y0+52, p.c, 4); }
    c.restore(); c.globalAlpha = 1;
    label(c, '→ values slide one cell right, ← values one cell left; the row wraps around', W/2, y0+92, on ? p.ink : p.mut, '11px "IBM Plex Mono", monospace', 'center'); }
}

// HOW IT WORKS: each operator explains itself, with a worked example on the walkthrough's cell, when it is hovered or clicked
const mt = s => `<div class="hm"><math display="block">${s}</math></div>`, sb = (b,s) => `<msub><mi>${b}</mi>${s}</msub>`, cia = '<msub><mi>c</mi><mrow><mi>i</mi><mi>α</mi></mrow></msub>';
const tc = (col, x) => `<mrow style="color:var(${col})">${x}</mrow>`;
const sw = col => `<i class="tb" style="background:var(${col})"></i>`;
const dirName = i => i === 0 ? 'rest' : [['x',cx[i]],['y',cy[i]],['z',cz[i]]].filter(([,v]) => v).map(([a,v]) => (v > 0 ? '+' : '−') + a).join('');
const howDirs = (st, list, draw) => `<div class="eex"><span>Example, direction</span>${list.map(i => `<button class="b${i === st.i ? ' pri' : ''}" data-i="${i}">${i} · ${dirName(i)}</button>`).join('')}</div>`;
const fq = (v, d=3) => v.toFixed(d), wfrac = v => v === 1/3 ? '1/3' : v === 1/18 ? '1/18' : '1/36';
const HS = {M:{a:1}, E:{i:1}, C:{i:1}, S:{i:7}};
const HOW = {
 M: { html: () => `<span class="eyebrow">How M works</span>
   ${mt(`<msub><mi>m</mi><mi>a</mi></msub><mo>=</mo><munder><mo>∑</mo><mi>i</mi></munder><msub><mi>M</mi><mrow><mi>a</mi><mi>i</mi></mrow></msub><msub><mi>f</mi><mi>i</mi></msub><mo>,</mo><mspace width="1em"/><msub><mi>M</mi><mrow><mn>0</mn><mi>i</mi></mrow></msub><mo>=</mo>${tc('--c-rho','<mn>1</mn>')}<mo>,</mo><mspace width=".6em"/><msub><mi>M</mi><mrow><mi>α</mi><mi>i</mi></mrow></msub><mo>=</mo>${tc('--c-u',cia)}`)}
   <div class="eterms"><span>${sw('--c-rho')}row 0</span><span>Every direction counts +1: the total amount of fluid, density ρ.</span>
     <span>${sw('--c-c')}+1</span><span>Rows 1–3: a direction moving +x (or +y, +z) adds its value…</span>
     <span>${sw('--c-nu')}−1</span><span>…one moving the other way subtracts it, the rest count 0. The net flow is momentum ρu<sub>α</sub>.</span></div>
   <div class="eex"><span>Example, row</span>${['ρ','ρuₓ','ρu_y','ρu_z'].map((n,a) => `<button class="b${a === HS.M.a ? ' pri' : ''}" data-a="${a}">${n}</button>`).join('')}</div>
   <canvas class="hc" data-w="420" data-h="96"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), a = HS.M.a, wt = i => a === 0 ? 1 : [cx,cy,cz][a-1][i], W = c.W, bw = 15, gp = 6, x0 = 16, base = 62;
   c.clearRect(0,0,W,c.H);
   for (let i=0;i<Q;i++){ const s = wt(i), h = Math.min(50, opF[i]/w[i]*24), x = x0+i*(bw+gp);
     c.globalAlpha = s ? 1 : .25; c.fillStyle = p.f; rr(c, x, base-h, bw, h, 2); c.fill(); c.globalAlpha = 1;
     label(c, s > 0 ? '+1' : s < 0 ? '−1' : '0', x+bw/2, base+16, s > 0 ? (a ? p.c : p.rho) : s < 0 ? p.nu : p.mut, '600 10px "IBM Plex Mono", monospace', 'center');
     label(c, String(i), x+bw/2, base+30, p.mut, '9px "IBM Plex Mono", monospace', 'center'); }
   const pos = [], neg = []; for (let i=0;i<Q;i++){ const s = wt(i); if (s > 0) pos.push(i); else if (s < 0) neg.push(i); }
   const S_ = l => l.reduce((t,i) => t+opF[i], 0), nm = ['ρ','ρuₓ','ρu_y','ρu_z'][a];
   root.querySelector('.ecalc').textContent = a === 0 ? `ρ = f₀ + f₁ + … + f₁₈ = ${fq(S_(pos))}` :
     `${nm} = (${pos.map(i => 'f'+i).join(' + ')}) − (${neg.map(i => 'f'+i).join(' + ')}) = ${fq(S_(pos))} − ${fq(S_(neg))} = ${fq(S_(pos)-S_(neg))}`; },
  bind(root){ root.querySelectorAll('[data-a]').forEach(b => b.onclick = () => { HS.M.a = +b.dataset.a; root.querySelectorAll('[data-a]').forEach(x => x.classList.toggle('pri', x === b)); this.draw(root); }); } },
 E: { html: () => `<span class="eyebrow">How E works</span>
   <p>Start from still fluid, where direction i gets the fixed share w<sub>i</sub>ρ, then adjust that share for the flow (c<sub>s</sub>² = ⅓):</p>
   ${mt(`<msubsup><mi>f</mi><mi>i</mi><mtext>eq</mtext></msubsup><mo>=</mo><msub><mi>w</mi><mi>i</mi></msub><mi>ρ</mi><mo>[</mo>${tc('--c-w','<mn>1</mn>')}<mo>+</mo>${tc('--c-c','<mn>3</mn>'+cia+'<msub><mi>u</mi><mi>α</mi></msub>')}<mo>+</mo>${tc('--c-u','<mfrac><mn>9</mn><mn>2</mn></mfrac><msup><mrow><mo>(</mo>'+cia+'<msub><mi>u</mi><mi>α</mi></msub><mo>)</mo></mrow><mn>2</mn></msup>')}<mo>−</mo>${tc('--c-nu','<mfrac><mn>3</mn><mn>2</mn></mfrac><msub><mi>u</mi><mi>α</mi></msub><msub><mi>u</mi><mi>α</mi></msub>')}<mo>]</mo>`)}
   <div class="eterms"><span>${sw('--c-w')}1</span><span>Still fluid: the fixed share wᵢ (1/3 rest, 1/18 faces, 1/36 edges).</span>
     <span>${sw('--c-c')}3c·u</span><span>Tilt: directions with the flow get more, against it less. This puts the momentum in.</span>
     <span>${sw('--c-u')}9/2 (c·u)²</span><span>Fast fluid carries its momentum along: gives the right momentum flux.</span>
     <span>${sw('--c-nu')}−3/2 u²</span><span>Takes the same small fraction back everywhere, so the total stays exactly ρ.</span></div>
   ${howDirs(HS.E, [0,1,2,3,7,8])}<canvas class="hc" data-w="420" data-h="96"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), [r,u,v,s] = opM, i = HS.E.i, cu = cx[i]*u+cy[i]*v+cz[i]*s, uu = u*u+v*v+s*s;
   const terms = [[1,p.w],[3*cu,p.c],[4.5*cu*cu,p.u],[-1.5*uu,p.nu]], tot = terms.reduce((a,b) => a+b[0], 0), x0 = 92, sc = 190;
   c.clearRect(0,0,c.W,c.H); label(c, 'bracket', 6, 30, p.mut, MONO); label(c, 'small ×10', 6, 80, p.mut, MONO);
   let x = x0; terms.forEach(([val,col]) => { const wd = val*sc; c.fillStyle = col; c.globalAlpha = val < 0 ? .6 : 1; rr(c, wd < 0 ? x+wd : x, 16, Math.abs(wd), 22, 3); c.fill(); c.globalAlpha = 1; x += wd; });
   c.strokeStyle = p.ink; c.lineWidth = 2; c.beginPath(); c.moveTo(x0+tot*sc, 10); c.lineTo(x0+tot*sc, 44); c.stroke(); label(c, '= '+fq(tot), x0+tot*sc+6, 31, p.ink, '600 11px "IBM Plex Mono", monospace');
   x = x0; terms.slice(2).forEach(([val,col]) => { const wd = val*sc*10; c.fillStyle = col; c.globalAlpha = val < 0 ? .6 : 1; rr(c, wd < 0 ? x+wd : x, 66, Math.abs(wd), 20, 3); c.fill(); c.globalAlpha = 1; x += wd; });
   root.querySelector('.ecalc').textContent = `i = ${i} (${dirName(i)}): wᵢ = ${wfrac(w[i])}, c·u = ${fq(cu)} → bracket = 1 ${3*cu<0?'−':'+'} ${fq(Math.abs(3*cu))} + ${fq(4.5*cu*cu)} − ${fq(1.5*uu)} = ${fq(tot)} → fᵢᵉq = ${wfrac(w[i])} × ${fq(r)} × ${fq(tot)} = ${fq(w[i]*r*tot,4)}`; } },
 C: { html: () => `<span class="eyebrow">How C works</span>
   <p>Inside each cell: total up with M, build the calm values with E, then blend. The blend, rearranged:</p>
   ${mt(`<msubsup><mi>f</mi><mi>i</mi><mo>*</mo></msubsup><mo>=</mo>${tc('--c-f','<mo>(</mo><mn>1</mn><mo>−</mo><mfrac><mn>1</mn><mi>τ</mi></mfrac><mo>)</mo><msub><mi>f</mi><mi>i</mi></msub>')}<mo>+</mo>${tc('--c-eq','<mfrac><mn>1</mn><mi>τ</mi></mfrac><msubsup><mi>f</mi><mi>i</mi><mtext>eq</mtext></msubsup>')}`)}
   <div class="eterms"><span>${sw('--c-f')}(1 − 1/τ) fᵢ</span><span>Keep part of the old value.</span>
     <span>${sw('--c-eq')}(1/τ) fᵢᵉq</span><span>Take the rest from the calm value. τ = 1 replaces it completely, τ = 2 goes halfway, τ &lt; 1 overshoots.</span></div>
   ${howDirs(HS.C, [0,1,2,3,7])}<canvas class="hc" data-w="420" data-h="70"></canvas><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), i = HS.C.i, f0 = opF[i], fe = opE[i], fs = f0 + (fe-f0)/OPT, lo = Math.min(f0,fe,fs), hi = Math.max(f0,fe,fs), pad = (hi-lo)*.35 || 1e-3;
   const X = v => 20 + (v-(lo-pad))/((hi+pad)-(lo-pad))*(c.W-40), y = 30;
   c.clearRect(0,0,c.W,c.H); c.strokeStyle = p.rule; c.lineWidth = 3; c.lineCap = 'round'; c.beginPath(); c.moveTo(20,y); c.lineTo(c.W-20,y); c.stroke();
   c.strokeStyle = p.tau; c.lineWidth = 6; c.beginPath(); c.moveTo(X(f0),y); c.lineTo(X(fs),y); c.stroke();
   [[f0,p.f,'fᵢ (old)'],[fe,p.eq,'fᵢᵉq'],[fs,p.tau,'fᵢ*']].forEach(([v,col,n],k) => { c.fillStyle = col; c.beginPath(); c.arc(X(v), y, 6, 0, 7); c.fill(); label(c, n, X(v), k === 2 ? y-12 : y+24, col, '600 11px "IBM Plex Mono", monospace', 'center'); });
   root.querySelector('.ecalc').textContent = `i = ${i} (${dirName(i)}), τ = ${OPT}: fᵢ* = (1 − 1/${OPT}) × ${fq(f0,4)} + (1/${OPT}) × ${fq(fe,4)} = ${fq(fs,4)}`; } },
 S: { html: () => `<span class="eyebrow">How S works</span>
   ${mt(`<msub><mrow><mo>(</mo><mi>S</mi><mi>g</mi><mo>)</mo></mrow><mrow><mi>i</mi><mi>x</mi><mi>y</mi><mi>z</mi></mrow></msub><mo>=</mo><msub><mi>g</mi><mrow><mi>i</mi><mo>,</mo>${tc('--c-c','<mi>x</mi><mo>−</mo><msub><mi>c</mi><mrow><mi>i</mi><mi>x</mi></mrow></msub><mo>,</mo><mi>y</mi><mo>−</mo><msub><mi>c</mi><mrow><mi>i</mi><mi>y</mi></mrow></msub><mo>,</mo><mi>z</mi><mo>−</mo><msub><mi>c</mi><mrow><mi>i</mi><mi>z</mi></mrow></msub>')}</mrow></msub>`)}
   <div class="eterms"><span>${sw('--c-c')}x − cᵢ</span><span>Each cell takes population i from the neighbour behind it in direction i (one step back along 𝐜ᵢ).</span>
     <span>${sw('--c-w')}copy</span><span>Values are only moved, never changed: a permutation. This is the only place cells talk to each other.</span></div>
   ${howDirs(HS.S, [1,2,3,7,10,11,15])}<canvas class="hc" data-w="300" data-h="190"></canvas><div class="lg"><span style="color:var(--accent)">● this cell</span><span style="color:var(--c-c)">● where fᵢ comes from</span></div><div class="ecalc"></div>`,
  draw(root){ const c = hidpi(root.querySelector('canvas')), p = P(), i = HS.S.i, V = {th:-0.55, ph:0.4, s:62, ox:140, oy:96};
   c.clearRect(0,0,c.W,c.H);
   SITES.concat([[0,0,0]]).map(st => ({st, P: proj(V, ...st)})).sort((a,b) => a.P[2]-b.P[2]).forEach(({st, P: [X,Y]}) => {
     const me = st.every(v => !v), src = st[0] === -cx[i] && st[1] === -cy[i] && st[2] === -cz[i];
     c.fillStyle = me ? p.acc : src ? p.c : p.rule; c.globalAlpha = me || src ? 1 : .5; c.beginPath(); c.arc(X, Y, me || src ? 7 : 3.5, 0, 7); c.fill(); c.globalAlpha = 1; });
   const A1 = proj(V, -cx[i], -cy[i], -cz[i]), A2 = proj(V, 0, 0, 0); arrow(c, A1[0], A1[1], A2[0]+(A1[0]-A2[0])*.18, A2[1]+(A1[1]-A2[1])*.18, p.c, 2.6);
   triad(c, V, 270, 160, p);
   root.querySelector('.ecalc').textContent = `i = ${i} (${dirName(i)}): 𝐜ᵢ = (${cx[i]}, ${cy[i]}, ${cz[i]}) → cell (x, y, z) receives f${i} from (x${cx[i]>0?'−1':cx[i]<0?'+1':''}, y${cy[i]>0?'−1':cy[i]<0?'+1':''}, z${cz[i]>0?'−1':cz[i]<0?'+1':''}). No arithmetic.`; } },
};
['E','C','S'].forEach(k => HOW[k].bind = function(root){ root.querySelectorAll('[data-i]').forEach(b => b.onclick = () => { HS[k].i = +b.dataset.i; root.querySelectorAll('[data-i]').forEach(x => x.classList.toggle('pri', x === b)); this.draw(root); }); });
// A: one cell collides, then streams to its 18 neighbours
const CA = hidpi($('cellviz')), VA = {th:-0.55, ph:0.38, s:92, ox:230, oy:152};
orbit($('cellviz'), VA);
let ltau = 1.5, cyc = -1, pre, post, eqv, clk = 0, lastNow = null, lastSlide = -1e9;
const ltIn = $('ltau');
ltIn.oninput = () => { ltau = +ltIn.value; $('ltauv').textContent = ltau.toFixed(2); if (pre) post = pre.map((g,i) => g + (eqv[i]-g)/ltau);
  lastSlide = performance.now(); clk = Math.floor(clk/5000)*5000 + 2250; if (reduce) drawLearn(0); };
function newCell(){ pre = []; for (let i=0;i<Q;i++) pre.push(feq(i,1,0.1,0.04,0.03) * (i ? 1 + 0.9*(Math.random()-.5) : 1));
  const [r,u,v,s] = moments(pre); eqv = pre.map((_,i) => feq(i,r,u,v,s)); post = pre.map((g,i) => g + (eqv[i]-g)/ltau); }
function drawCell(now){
  // sliding τ freezes the cycle just after collision, so the change is visible
  const PER = 5000, hold = now - lastSlide < 2200, dt = lastNow === null ? 0 : Math.min(100, now - lastNow); lastNow = now;
  if (!hold) clk += dt; if (!VA.drag && !reduce) VA.th += dt*0.00012;
  const n = Math.floor(clk/PER), s = reduce ? 2.25 : (clk%PER)/1000; if (n !== cyc) { cyc = n; newCell(); }
  const c = CA, W = c.W, H = c.H, p = P(), L = 0.52, P3 = (x,y,z) => proj(VA, x, y, z), [ox, oy] = P3(0,0,0);
  const col = ease((s-.8)/1.4), mv = ease((s-2.4)/1.4);
  c.clearRect(0,0,W,H);
  // the cell itself, and the 26 sites around it: 18 are D3Q19 neighbours, the 8 corners are not used
  // faint lattice lines through the 3×3×3 block, so the sites read as a grid
  c.strokeStyle = p.rule; c.lineWidth = 1; c.globalAlpha = .55; c.beginPath();
  for (const a of [-1,0,1]) for (const b of [-1,0,1]) for (const [u0,u1] of [[[-1,a,b],[1,a,b]],[[a,-1,b],[a,1,b]],[[a,b,-1],[a,b,1]]]) { const A1 = P3(...u0), A2 = P3(...u1); c.moveTo(A1[0],A1[1]); c.lineTo(A2[0],A2[1]); }
  c.stroke(); c.globalAlpha = 1;
  box(c, VA, .5, .5, .5, isAct('x') ? p.ink : p.mut, isAct('x') ? 2.2 : 1.2);
  SITES.forEach(st => { const [X,Y] = P3(...st), corner = st.every(Boolean);
    if (corner) { c.strokeStyle = p.rule; c.lineWidth = 1.2; c.beginPath(); c.arc(X, Y, 3, 0, 7); c.stroke(); return; }
    c.fillStyle = isAct('xc') ? p.c : p.mut; c.globalAlpha = isAct('xc') ? 1 : .55; c.beginPath(); c.arc(X, Y, isAct('xc') ? 5 : 3.5, 0, 7); c.fill(); c.globalAlpha = 1; });
  if (isAct('ci')) for (let i=1;i<Q;i++){ const [X,Y] = P3(cx[i],cy[i],cz[i]); arrow(c, ox, oy, X, Y, p.c, 1.5, true); }
  // equilibrium targets fade out once streaming starts
  const ga = s < 2.4 ? 1 : 1-mv;
  if (ga > 0) { c.globalAlpha = ga*(isAct('feq')?1:.75);
    for (let i=1;i<Q;i++){ const k = eqv[i]/w[i], [X,Y] = P3(cx[i]*L*k, cy[i]*L*k, cz[i]*L*k); arrow(c, ox, oy, X, Y, p.eq, isAct('feq')?2.6:1.7, true); }
    c.globalAlpha = 1; }
  // the gap collision closes
  if (mv === 0 && ((s >= .8 && s < 2.4) || isAct('coll','tau'))) { c.globalAlpha = isAct('coll','tau') ? .45 : .22; c.strokeStyle = p.eq; c.lineWidth = 7; c.lineCap = 'round';
    for (let i=1;i<Q;i++){ const k = (s<.8?pre[i]:lerp(pre[i],post[i],col))/w[i], ke = eqv[i]/w[i], A1 = P3(cx[i]*L*k, cy[i]*L*k, cz[i]*L*k), A2 = P3(cx[i]*L*ke, cy[i]*L*ke, cz[i]*L*ke);
      c.beginPath(); c.moveTo(A1[0],A1[1]); c.lineTo(A2[0],A2[1]); c.stroke(); } c.globalAlpha = 1; }
  // populations, far ones drawn first and fainter
  const hf = isAct('fi','i'), lw = hf ? 3.8 : 2.8, items = [];
  for (let i=1;i<Q;i++){ const k = (s < .8 ? pre[i] : lerp(pre[i], post[i], col))/w[i], b0 = [cx[i]*mv, cy[i]*mv, cz[i]*mv];
    const A1 = P3(...b0), A2 = P3(b0[0]+cx[i]*L*k, b0[1]+cy[i]*L*k, b0[2]+cz[i]*L*k); items.push({i, k, A1, A2, d: A2[2]}); }
  items.sort((a,b) => a.d - b.d);
  items.forEach(({i, k, A1, A2, d}) => { const al = .45 + .55*(d+1.2)/2.4;
    if (mv > 0 && mv < 1) [.1,.2].forEach((dd,j) => { const m = Math.max(0, mv-dd), B1 = P3(cx[i]*m, cy[i]*m, cz[i]*m), B2 = P3(cx[i]*(m+L*k), cy[i]*(m+L*k), cz[i]*(m+L*k)); c.globalAlpha = (.2-.08*j)*al; arrow(c, B1[0], B1[1], B2[0], B2[1], p.f, lw); });
    c.globalAlpha = Math.min(1, al); arrow(c, A1[0], A1[1], A2[0], A2[1], p.f, lw); c.globalAlpha = 1;
    if (isAct('i')) label(c, String(i), A2[0]+(A2[0]-A1[0])*.18, A2[1]+(A2[1]-A1[1])*.18+4, p.f, '600 11px "IBM Plex Mono", monospace', 'center'); });
  const k0 = (s < .8 ? pre[0] : lerp(pre[0], post[0], col))/w[0];
  c.fillStyle = p.f; c.globalAlpha = .22; c.beginPath(); c.arc(ox, oy, 7*k0, 0, 7); c.fill(); c.globalAlpha = 1; c.strokeStyle = p.f; c.lineWidth = hf?2.6:1.8; c.stroke();
  if (isAct('i')) label(c, '0', ox, oy+4, p.f, '600 11px "IBM Plex Mono", monospace', 'center');
  label(c, 'D3Q19: 1 rest + 6 faces + 12 edges', 12, 20, p.mut, MONO); label(c, '○ corners: not used', 12, 36, p.mut, MONO);
  triad(c, VA, 30, 280, p);
  // how far collision moves each population, set by τ
  { const gy = 354, g0 = 70, g1 = W-40, G = v => g0 + v*(g1-g0)/2, fr = 1/ltau, on = isAct('tau','coll') || hold;
    label(c, 'collision moves each fᵢ this far toward equilibrium:', g0, gy-30, on ? p.ink : p.mut, '12px "IBM Plex Sans", sans-serif');
    c.lineCap = 'round'; c.lineWidth = 4; c.strokeStyle = p.rule; c.beginPath(); c.moveTo(G(0), gy); c.lineTo(G(2), gy); c.stroke();
    c.lineWidth = on ? 9 : 7; c.strokeStyle = p.tau; c.beginPath(); c.moveTo(G(0), gy); c.lineTo(G(fr), gy); c.stroke();
    [[0,'before',p.f],[1,'equilibrium',p.eq]].forEach(([v,nm,cl]) => { c.fillStyle = cl; c.fillRect(G(v)-1.5, gy-9, 3, 18); label(c, nm, G(v), gy+22, cl, MONO, 'center'); });
    label(c, `1/τ = ${Math.round(fr*100)}%${fr > 1 ? ' · overshoot' : fr === 1 ? ' · exact' : ''}`, Math.min(Math.max(G(fr), g0+40), g1-40), gy-11, p.tau, '600 12px "IBM Plex Mono", monospace', 'center'); }
  // timeline: collide | stream, from t to t+Δt
  const ty = H-26, tx0 = 44, tx1 = W-44, X = q => tx0 + (tx1-tx0)*Math.min(1, q/3.8);
  c.lineCap = 'round'; c.lineWidth = 6; c.strokeStyle = p.rule; c.beginPath(); c.moveTo(tx0,ty); c.lineTo(tx1,ty); c.stroke();
  [[.8,2.2,p.eq,'collide'],[2.4,3.8,p.c,'stream']].forEach(([a,b,cl,nm]) => { c.strokeStyle = cl; c.globalAlpha = .25; c.beginPath(); c.moveTo(X(a)+3,ty); c.lineTo(X(b)-3,ty); c.stroke();
    if (s > a) { c.globalAlpha = 1; c.beginPath(); c.moveTo(X(a)+3,ty); c.lineTo(Math.max(X(a)+3, X(Math.min(b,s))-3),ty); c.stroke(); }
    c.globalAlpha = 1; label(c, nm, (X(a)+X(b))/2, ty+18, s>=a&&s<b ? cl : p.mut, MONO, 'center'); });
  const tc = isAct('t','dt') ? p.w : p.mut, tf = isAct('t','dt') ? '600 13px "IBM Plex Mono", monospace' : MONO;
  label(c, 't', tx0-14, ty+4, isAct('t')?p.ink:tc, tf, 'center'); label(c, 't+Δt', tx1+20, ty+4, isAct('dt')?p.ink:tc, tf, 'center');
  c.fillStyle = p.ink; c.beginPath(); c.arc(X(s), ty, 5, 0, 7); c.fill();
}

// B: equilibrium in 3D; sliders set u_x, u_y, u_z, drag to orbit
const CB = hidpi($('eqviz')), VB = {th:-0.6, ph:0.35, s:80, ox:122, oy:138}; let U = [0.12, 0.05, 0.03], lastB = null;
orbit($('eqviz'), VB);
['ux','uy','uz'].forEach((id,j) => { const el = $(id); el.oninput = () => { U[j] = +el.value; $(id+'v').textContent = (+el.value).toFixed(2); if (reduce) drawLearn(0); }; });
function drawEq(now){
  if (lastB !== null && !VB.drag && !reduce) VB.th += Math.min(100, now-lastB)*0.0001; lastB = now;
  const c = CB, W = c.W, H = c.H, L = 0.45, US = 150/VB.s, p = P(), cs = 1/Math.sqrt(3), [u,v,s] = U, fe = [...Array(Q)].map((_,i) => feq(i,1,u,v,s));
  const P3 = (x,y,z) => proj(VB, x, y, z), [ox, oy] = P3(0,0,0);
  c.clearRect(0,0,W,H);
  c.setLineDash([4,5]); c.strokeStyle = p.cs; c.globalAlpha = isAct('cs') ? 1 : .55; c.lineWidth = isAct('cs') ? 2.2 : 1.4; c.beginPath(); c.arc(ox, oy, cs*150, 0, 7); c.stroke();
  c.globalAlpha = 1; c.setLineDash([]); label(c, 'Mach 1', ox, oy-cs*150-7, p.cs, MONO, 'center');
  c.strokeStyle = p.w; c.lineWidth = isAct('w') ? 2.4 : 1.2; c.globalAlpha = isAct('w') ? 1 : .55; c.beginPath(); c.arc(ox, oy, L*VB.s, 0, 7); c.stroke(); c.globalAlpha = 1;
  const items = [];
  for (let i=1;i<Q;i++){ const k = fe[i]/w[i], e = P3(cx[i]*L*k, cy[i]*L*k, cz[i]*L*k); items.push({i, e, d: e[2], cu: cx[i]*u+cy[i]*v+cz[i]*s}); }
  items.sort((a,b) => a.d - b.d).forEach(({i, e, d, cu}) => { c.globalAlpha = Math.min(1, .45 + .55*(d+1)/2); arrow(c, ox, oy, e[0], e[1], p.eq, isAct('feq') ? 3.4 : 2.5); c.globalAlpha = 1;
    if (isAct('cia')) label(c, (cu>=0?'+':'−')+Math.abs(cu).toFixed(2), e[0]+(e[0]-ox)*.2, e[1]+(e[1]-oy)*.2+4, p.c, '600 10px "IBM Plex Mono", monospace', 'center'); });
  c.fillStyle = p.eq; c.globalAlpha = .2; c.beginPath(); c.arc(ox, oy, 8*fe[0]/w[0], 0, 7); c.fill(); c.globalAlpha = 1; c.strokeStyle = p.eq; c.lineWidth = 2; c.stroke();
  const ue = P3(u*US, v*US, s*US); arrow(c, ox, oy, ue[0], ue[1], p.u, isAct('u') ? 5 : 3.6); label(c, '𝐮', ue[0]+10, ue[1]-8, p.u, MATH);
  triad(c, VB, 26, 238, p);
  // bars: f_eq / w_i, so still fluid sits on the weight line
  const x0 = 262, bw = 7.6, gp = 2.6, base = 206, un = 58, xe = x0 + Q*(bw+gp) - gp;
  label(c, 'equilibrium ÷ weight', x0, 22, p.mut, MONO);
  if (isAct('rho','sum')) { c.strokeStyle = p.rho; c.lineWidth = 1.6; rr(c, x0-6, 32, xe-x0+12, base-26, 8); c.stroke(); label(c, isAct('sum') ? '∑ over i' : 'ρ = ∑ fᵢ', xe-2, 48, p.rho, MONO, 'right'); }
  for (let i=0;i<Q;i++){ const x = x0+i*(bw+gp), h = Math.min(170, fe[i]/w[i]*un);
    const g = c.createLinearGradient(0, base-h, 0, base); g.addColorStop(0, p.eq); g.addColorStop(1, p.eq+'55'); c.fillStyle = g; rr(c, x, base-h, bw, h, 3); c.fill(); }
  c.setLineDash([4,4]); c.strokeStyle = p.w; c.lineWidth = isAct('w') ? 2.4 : 1.4; c.beginPath(); c.moveTo(x0-6, base-un); c.lineTo(xe+2, base-un); c.stroke(); c.setLineDash([]);
  label(c, 'wᵢρ', x0-10, base-un+4, p.w, MONO, 'right');
  [[0,0,'rest'],[1,6,'6 faces'],[7,18,'12 edges']].forEach(([a,b,nm]) => { const xa = x0+a*(bw+gp), xb = x0+b*(bw+gp)+bw;
    c.strokeStyle = isAct('i') ? p.f : p.mut; c.lineWidth = 1; c.beginPath(); c.moveTo(xa, base+6); c.lineTo(xa, base+10); c.lineTo(xb, base+10); c.lineTo(xb, base+6); c.stroke();
    label(c, nm, a === 0 ? xa : (xa+xb)/2, a === 0 ? base+36 : base+24, isAct('i') ? p.f : p.mut, '10px "IBM Plex Mono", monospace', 'center'); });
  const [r, mu, mvv, mw] = moments(fe), ma = Math.hypot(u,v,s)/cs;
  let px = 14; const py = H-16;
  px = pill(c, px, py, `ρ = ${r.toFixed(3)}`, p.rho);
  px = pill(c, px, py, `𝐮 = (${mu.toFixed(2)}, ${mvv.toFixed(2)}, ${mw.toFixed(2)})`, p.u);
  pill(c, px, py, `Mach ${ma.toFixed(2)}${ma > .3 ? ' · too fast' : ''}`, ma > .3 ? p.nu : p.cs);
}

// C: viscosity, checked against a real D3Q19 shear wave (one column of cells, periodic)
const CC = hidpi($('nuviz')), NYw = 32, A = 0.04, kw = 2*Math.PI/NYw;
let ntau = 0.8, fw, fw2, nstep = 0, hist = [], fr = 0, ghosts = [], tauStart = 0.8; const TFIX = 2000;
const ntIn = $('ntau');
function waveInit(){ fw = new Float64Array(NYw*Q); fw2 = new Float64Array(NYw*Q); nstep = 0; hist = [[0,1]]; for (let y=0;y<NYw;y++) for (let i=0;i<Q;i++) fw[y*Q+i] = feq(i,1,A*Math.sin(kw*(y+.5)),0,0); }
ntIn.oninput = () => { ntau = +ntIn.value; $('ntauv').textContent = ntau.toFixed(2); waveInit(); if (reduce) drawLearn(0); }; waveInit();
ntIn.addEventListener('pointerdown', () => tauStart = ntau);
ntIn.addEventListener('change', () => { if (tauStart !== ntau) { ghosts = [tauStart, ...ghosts.filter(g => g !== tauStart && g !== ntau)].slice(0,3); } tauStart = ntau; });
function waveStep(){
  for (let y=0;y<NYw;y++){ const g = fw.subarray(y*Q, y*Q+Q), [r,u,v,s] = moments(g); for (let i=0;i<Q;i++) g[i] += (feq(i,r,u,v,s)-g[i])/ntau; }
  for (let y=0;y<NYw;y++) for (let i=0;i<Q;i++) fw2[y*Q+i] = fw[((y-cy[i]+NYw)%NYw)*Q+i];
  [fw,fw2] = [fw2,fw]; nstep++;
}
function drawNu(){
  const c = CC, W = c.W, H = c.H, p = P(), nu = (ntau-.5)/3, rate = nu*kw*kw, Tm = Math.log(1/0.08)/rate;
  if (!reduce) for (let n=0;n<10;n++) waveStep();
  let meas = 0; const prof = []; for (let y=0;y<NYw;y++){ const [, u] = moments(fw.subarray(y*Q,y*Q+Q)); prof.push(u); meas = Math.max(meas, Math.abs(u)); }
  if (++fr % 3 === 0) hist.push([nstep, meas/A]);
  const amp = Math.exp(-rate*nstep);
  c.clearRect(0,0,W,H);
  const top = 40, bot = 204;
  // panel 1: ν(τ)
  { const x0 = 40, x1 = 182, X = t => x0+(t-.5)/1.5*(x1-x0), Y = n => bot-n/.5*(bot-top);
    label(c, 'ν(τ)', x0, 22, p.ink, '600 12px "IBM Plex Sans", sans-serif');
    c.fillStyle = p.nu; c.globalAlpha = isAct('half') ? .22 : .1; c.fillRect(X(.5), top, X(.56)-X(.5), bot-top); c.globalAlpha = 1;
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, top-6); c.lineTo(x0, bot); c.lineTo(x1+6, bot); c.stroke();
    [[.5,'½'],[1,'1'],[1.5,'1.5'],[2,'2']].forEach(([t,s]) => label(c, s, X(t), bot+15, t===.5 && isAct('half') ? p.tau : p.mut, MONO, 'center'));
    [[0,'0'],[.25,'.25'],[.5,'.5']].forEach(([n,s]) => label(c, s, x0-6, Y(n)+4, p.mut, MONO, 'right'));
    label(c, 'τ', x1+18, bot+5, p.tau, MATH, 'center'); label(c, 'unstable', X(.5)+4, top+10, p.nu, '10px "IBM Plex Mono", monospace');
    c.strokeStyle = p.nu; c.lineWidth = isAct('nu','cs') ? 4 : 2.6; c.lineCap = 'round'; c.beginPath(); c.moveTo(X(.5), Y(0)); c.lineTo(X(2), Y(.5)); c.stroke();
    label(c, 'slope cₛ² = ⅓', X(1.62), Y(.22), isAct('cs') ? p.cs : p.mut, isAct('cs') ? '600 11px "IBM Plex Mono", monospace' : MONO, 'center');
    c.setLineDash([2,3]); c.strokeStyle = p.tau; c.lineWidth = 1.2; c.beginPath(); c.moveTo(X(ntau), bot); c.lineTo(X(ntau), Y(nu)); c.lineTo(x0, Y(nu)); c.stroke(); c.setLineDash([]);
    c.fillStyle = p.tau; c.strokeStyle = p.panel; c.lineWidth = 2.5; c.beginPath(); c.arc(X(ntau), Y(nu), isAct('tau') ? 8 : 6, 0, 7); c.fill(); c.stroke(); }
  // panel 2: velocity profile, LBM vs exact
  { const ax = 300, sx = 52/A, rh = (bot-top)/NYw, Yy = y => top+(y+.5)*rh;
    label(c, 'velocity profile', ax, 22, p.ink, '600 12px "IBM Plex Sans", sans-serif', 'center');
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(ax, top-6); c.lineTo(ax, bot+6); c.stroke();
    c.beginPath(); c.moveTo(ax, Yy(0)); prof.forEach((u,y) => c.lineTo(ax+u*sx, Yy(y))); c.lineTo(ax, Yy(NYw-1)); c.closePath();
    c.fillStyle = p.u; c.globalAlpha = .2; c.fill(); c.globalAlpha = 1;
    c.beginPath(); prof.forEach((u,y) => y ? c.lineTo(ax+u*sx, Yy(y)) : c.moveTo(ax+u*sx, Yy(y))); c.strokeStyle = p.u; c.lineWidth = 2.4; c.stroke();
    for (let y=1;y<NYw;y+=3) arrow(c, ax, Yy(y), ax+prof[y]*sx, Yy(y), p.u, 1.4);
    c.setLineDash([5,4]); c.beginPath(); for (let y=0;y<NYw;y++){ const xx = ax+A*amp*Math.sin(kw*(y+.5))*sx; y ? c.lineTo(xx, Yy(y)) : c.moveTo(xx, Yy(y)); }
    c.strokeStyle = p.nu; c.lineWidth = isAct('nu') ? 2.6 : 1.6; c.stroke(); c.setLineDash([]); }
  // panel 3: amplitude over time
  { const x0 = 404, x1 = 548, X = n => x0+(x1-x0)*Math.min(1, n/TFIX), Y = a => bot-a*(bot-top);
    label(c, 'amplitude', (x0+x1)/2, 22, p.ink, '600 12px "IBM Plex Sans", sans-serif', 'center');
    c.strokeStyle = p.rule; c.lineWidth = 1; c.beginPath(); c.moveTo(x0, top-6); c.lineTo(x0, bot); c.lineTo(x1, bot); c.stroke();
    label(c, '1', x0-6, Y(1)+4, p.mut, MONO, 'right'); label(c, '0', x0-6, bot+4, p.mut, MONO, 'right'); label(c, `${TFIX} steps`, x1, bot+15, p.mut, MONO, 'right');
    ghosts.forEach((g,j) => { const r2 = (g-.5)/3*kw*kw; c.beginPath(); for (let q=0;q<=40;q++){ const n = TFIX*q/40; q ? c.lineTo(X(n), Y(Math.exp(-r2*n))) : c.moveTo(X(n), Y(1)); }
      c.globalAlpha = .45-.12*j; c.strokeStyle = p.tau; c.lineWidth = 1.4; c.stroke(); const ye = Y(Math.exp(-r2*TFIX)); label(c, 'τ '+g.toFixed(2), x1-2, Math.min(bot-4, ye-4), p.tau, '10px "IBM Plex Mono", monospace', 'right'); c.globalAlpha = 1; });
    c.beginPath(); for (let q=0;q<=40;q++){ const n = TFIX*q/40; q ? c.lineTo(X(n), Y(Math.exp(-rate*n))) : c.moveTo(X(n), Y(1)); }
    c.setLineDash([5,4]); c.strokeStyle = p.nu; c.lineWidth = isAct('nu') ? 2.6 : 1.6; c.stroke(); c.setLineDash([]);
    c.fillStyle = p.u; hist.forEach(([n,a]) => { c.beginPath(); c.arc(X(n), Y(a), 2.6, 0, 7); c.fill(); }); }
  label(c, '● LBM', 404, H-10, p.u, MONO); label(c, '┄ exact', 456, H-10, p.nu, MONO); if (ghosts.length) label(c, '— earlier τ', 300, H-10, p.tau, MONO, 'center');
  $('nucap').textContent = `ν = ${nu.toFixed(3)} · step ${nstep} · amplitude: LBM ${(meas/A*100).toFixed(1)}% vs exact Navier–Stokes ${(amp*100).toFixed(1)}%`;
  if (nstep >= TFIX) waveInit();
}
function drawLearn(now){ drawOps(now); drawCell(reduce ? 1700 : now); drawEq(now); drawNu(); }
drawLearn(1700);

// PARALLEL: threads + memory layout
const TH = hidpi($('threads'));
function drawThreads(){
  const x = TH, p = P(), V = {th:-0.6, ph:0.45, s:58, ox:160, oy:92}; x.clearRect(0,0,x.W,x.H);
  const cells = [-1,0,1].flatMap(a => [-1,0,1].flatMap(b => [-1,0,1].map(d => [a,b,d]))).map(c => ({c, P: proj(V, ...c)})).sort((a,b) => a.P[2]-b.P[2]);
  cells.forEach(({c, P: [X,Y]}) => { const n = Math.abs(c[0])+Math.abs(c[1])+Math.abs(c[2]);
    x.fillStyle = n === 0 ? p.acc : n < 3 ? p.accSoft : p.panel; x.strokeStyle = n === 0 ? p.acc : n < 3 ? p.acc : p.rule; x.lineWidth = 1.2;
    rr(x, X-11, Y-11, 22, 22, 5); x.fill(); x.stroke(); });
  label(x, 'dark: 1 thread = 1 cell', 10, x.H-38, p.mut, MONO); label(x, 'light: the 18 cells it reads', 10, x.H-24, p.mut, MONO); label(x, 'white: 8 corners, not read', 10, x.H-10, p.mut, MONO);
}
const mem=$('mem');
function showMem(layout){
  mem.innerHTML=''; const fb=$('memfb');
  for (let k=0;k<32;k++){ const i=document.createElement('i'); let hit;
    if (layout==='aos') hit = k%19===1; else hit = k<16;
    i.style.background = hit ? css('--accent') : css('--rule'); mem.appendChild(i); }
  if (layout==='aos'){ fb.className='fb bad'; fb.textContent='16 threads read direction 1: addresses 19 apart, so each read pulls a separate memory line. Slow.'; }
  else { fb.className='fb good'; fb.textContent='✓ 16 threads read direction 1 from 16 consecutive addresses: one coalesced read. This is what fast GPU LBM codes use.'; K.done('parallel'); }
}
$('aos').onclick=()=>showMem('aos'); $('soa').onclick=()=>showMem('soa');


this.ops = { M: HOW.M, E: HOW.E, C: HOW.C, S: HOW.S };
drawLearn(1700);
return {
  frame(now, stp){ if (running && stp === 1) { const t0 = performance.now(); do stepSim(); while (performance.now()-t0 < 9); drawSim(); } if (stp === 0) drawLearn(now); },
  onStep(stp){ if (stp === 2) drawThreads(); },
  buildReset(){ running = false; initSim(); drawSim(); },
  buildStart(){ running = true; },
};
}
}));
