// Static checks for a method module: node tools/check.mjs methods/<id>.js
// Loads the module with a stub CFD.register, then checks structure, symbols, ids, quizzes and MathML.
import fs from 'node:fs'; import vm from 'node:vm';
const file = process.argv[2]; if (!file) { console.error('usage: node tools/check.mjs methods/<id>.js'); process.exit(2); }
let spec = null; const ctx = { CFD: { register(s){ spec = s; } }, console, Math, JSON, Object, Array, performance, Float32Array, Float64Array, Int32Array, Uint8Array };
vm.runInNewContext(fs.readFileSync(file, 'utf8'), ctx, { filename: file });
const errs = [], warns = []; const E = m => errs.push(m), W = m => warns.push(m);
if (!spec) { console.error('CFD.register was not called'); process.exit(1); }
const id = spec.id;
for (const k of ['id','name','sub','lede','blocks','checks','quiz','build','parallel','unlock','terms','mount']) if (spec[k] == null) E(`missing field: ${k}`);
const T = spec.terms || {};
for (const [k, t] of Object.entries(T)) { for (const f of ['sym','name','def','col']) if (!t[f]) E(`term ${k}: missing ${f}`); if (!t.space) W(`term ${k}: no "space" (Lives in)`); if (t.col && !/^--(c-(f|eq|c|tau|u|rho|w|cs|nu)|ink)$/.test(t.col)) E(`term ${k}: colour ${t.col} is not a palette token`); }
const html = [...(spec.blocks||[]).map(b => b.html), spec.build?.html || '', spec.parallel?.html || ''].join('\n');
for (const m of html.matchAll(/data-t="([^"]+)"/g)) if (!T[m[1]]) E(`data-t="${m[1]}" has no term`);
for (const m of html.matchAll(/data-terms="([^"]+)"/g)) for (const k of m[1].split(',')) if (!T[k]) E(`inspector term "${k}" has no term`);
for (const m of html.matchAll(/\s(?:id|for)="([^"]+)"/g)) if (!m[1].startsWith(id + '-')) E(`id/for "${m[1]}" must start with "${id}-"`);
const keys = (spec.blocks||[]).map(b => b.key);
if (keys.join() !== '0,A,B,C') W(`blocks are ${keys.join()} (reference uses 0,A,B,C)`);
for (const b of spec.blocks||[]) { if (!b.title || !b.html) E(`block ${b.key}: title/html missing`);
  if (!/class="eqhero"/.test(b.html)) W(`block ${b.key}: no .eqhero equation`); if (!/<canvas/.test(b.html)) W(`block ${b.key}: no canvas visual`);
  if (!/class="insp"/.test(b.html)) W(`block ${b.key}: no symbol inspector (.insp)`); if (b.key !== '0' && !/details class="deep"/.test(b.html)) W(`block ${b.key}: no "Going a bit deeper"`);
  if (!/<munder><munder><mrow>|⏟/.test(b.html) && b.key !== '0') W(`block ${b.key}: no operator underbraces`); }
if (!/class="idx"/.test(html)) W('no "Every index" table (.idx)');
const q1 = (q, where) => { if (!Array.isArray(q) || q.length !== 4) return E(`${where}: question must be [text, options, answerIndex, why]`); const [t,o,a,w] = q; if (!t || !Array.isArray(o) || o.length < 3 || !(a >= 0 && a < o.length) || !w) E(`${where}: bad question "${t}"`); };
for (const k of keys) { const qs = (spec.checks||{})[k] || []; if (qs.length < 4) E(`check ${k}: ${qs.length} questions (need ≥ 4)`); qs.forEach((q,i) => q1(q, `check ${k}#${i+1}`)); }
if ((spec.quiz||[]).length < 6) E(`final quiz: ${(spec.quiz||[]).length} questions (need ≥ 6)`); (spec.quiz||[]).forEach((q,i) => q1(q, `quiz#${i+1}`));
const st = spec.build?.steps || []; if (st.length < 4 || new Set(st).size !== st.length) E('build.steps: need ≥ 4 unique steps'); for (const f of ['intro','html','hint','success']) if (!spec.build?.[f]) E(`build.${f} missing`);
// MathML: balanced tags inside every <math>, and no bold letters carrying scripts (they render badly)
for (const m of html.matchAll(/<math[\s\S]*?<\/math>/g)) { const st2 = []; for (const t of m[0].matchAll(/<(\/?)([a-z]+)[^>]*?(\/?)>/g)) { if (t[3]) continue; if (!t[1]) st2.push(t[2]); else if (st2.pop() !== t[2]) { E(`unbalanced MathML near: ${m[0].slice(0,80)}…`); break; } } }
if (/<msup><mi>𝐟<\/mi>|<msubsup><mi>𝐟<\/mi>/.test(html)) W('bold 𝐟 with a script: overlaps in browsers');
if (/<math[^>]*>(?:(?!<\/math>)[\s\S])*\\[a-z]+/.test(html)) E('LaTeX commands inside MathML');
const size = fs.statSync(file).size; if (size > 220000) W(`module is ${(size/1024)|0} KB`);
if (typeof spec.bench === 'function') { try { const r = spec.bench(); console.log('bench:', r); } catch (e) { E('bench() threw: ' + e.message); } } else W('no bench() for the Build solver');
console.log(`${id}: ${Object.keys(T).length} terms, ${keys.length} blocks, ${Object.values(spec.checks||{}).flat().length} check questions, ${(spec.quiz||[]).length} quiz questions, ${(size/1024)|0} KB`);
warns.forEach(w => console.log('warn:', w)); errs.forEach(e => console.log('ERROR:', e));
process.exit(errs.length ? 1 : 0);
