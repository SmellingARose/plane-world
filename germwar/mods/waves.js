// Wave director: decides when and where enemy bases appear. Hot-reloadable.
(() => {
const { rand } = GW;
GW.waveLen = 45;

GW.spawnBase = (type, minR=700, maxR=1050) => {
  const hq = GW.ents.find(e => e.type === 'hq') || { pos:{ x:0, z:0 } };
  for (let tries=0; tries<30; tries++){
    const a = rand(0, Math.PI*2), r = rand(minR, maxR);
    let x = hq.pos.x + Math.cos(a)*r, z = hq.pos.z + Math.sin(a)*r;
    const d = Math.hypot(x, z); if (d > 1800){ x *= 1800/d; z *= 1800/d; }
    if (GW.heightAt(x, z) < -6) continue;                                   // not in a pool
    if (GW.ents.some(e => GW.def(e).cat === 'base' && GW.flat(e.pos, { x, z }) < 150)) continue;
    return GW.spawn(type, { x, z });
  }
};

GW.hooks.onRestart = () => { GW.wave = 1; GW.waveT = 50; GW.spawnBase('colony'); };

GW.director = dt => {
  if (GW.atk && !GW.atk.aiWaves) return;            // attacker player can switch the AI off
  if ((GW.waveT -= dt) > 0) return;
  const w = ++GW.wave; GW.waveT = GW.waveLen;
  const spawned = ['colony'];
  if (w >= 3 && w % 2 === 1 && GW.types.factory) spawned.push('factory');
  if (w >= 5 && w % 4 === 1 && GW.types.hatchery) spawned.push('hatchery');
  if (w >= 2 && w % 2 === 0) spawned.push('hive');
  if (w >= 4 && w % 3 === 1) spawned.push('spire');
  if (w >= 7 && w % 5 === 2) spawned.push('mother');
  for (const t of spawned) GW.spawnBase(t);
  GW.toast(`Wave ${w}: ${spawned.map(t => GW.types[t].label).join(', ')} detected`);
};
})();
