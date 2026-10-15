// Wave director: called ~10×/s with elapsed seconds while "AI waves" is on.
GW.onRestart = function() { GW.wave = 1; GW.waveT = 50; GW.spawnBase('colony'); };

GW.director = function(dt) {
  GW.waveT = GW.waveT - dt;
  if (GW.waveT > 0) return;
  var w = GW.wave + 1; GW.wave = w; GW.waveT = 45;
  var list = ['colony'];
  if (w >= 2 && w % 2 === 0) list.push('hive');
  if (w >= 3 && w % 2 === 1) list.push('factory');
  if (w >= 4 && w % 3 === 1) list.push('spire');
  if (w >= 5 && w % 4 === 1) list.push('hatchery');
  if (w >= 7 && w % 5 === 2) list.push('mother');
  list.forEach(function(t) { GW.spawnBase(t); });
  GW.toast('Wave ' + w + ': ' + list.join(', ') + ' detected');
};
