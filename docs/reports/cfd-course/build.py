"""Assemble the course into one self-contained page: docs/reports/cfd-course.html.
Usage: python3 build.py            (all modules in methods/)
       python3 build.py lbm rans   (only these, for testing)"""
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
order = ['potential', 'rans', 'urans', 'ddes', 'wmles', 'wrles', 'dns', 'lbm']
pick = sys.argv[1:] or order
mods = [m for m in order if m in pick and os.path.exists(f'{here}/methods/{m}.js')]
js = open(f'{here}/framework.js').read() + ''.join(f'\n// ===== {m} =====\n(() => {{\n' + open(f'{here}/methods/{m}.js').read() + '\n})();\n' for m in mods)
page = open(f'{here}/shell.html').read().replace('/*CSS*/', open(f'{here}/framework.css').read()).replace('/*JS*/', js)
out = os.path.join(here, '..', 'cfd-course.html') if not sys.argv[1:] else os.path.join(here, f'build-{"-".join(mods)}.html')
open(out, 'w').write(page)
print(out, len(page), 'bytes,', ', '.join(mods))
