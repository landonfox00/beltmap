# Copyright (C) 2026 Landon Fox
#
# This work may be distributed and/or modified under the conditions of the
# LaTeX Project Public License, either version 1.3c of this license or (at your
# option) any later version. The latest version of this license is in
#   https://www.latex-project.org/lppl.txt
# and version 1.3c or later is part of all distributions of LaTeX version
# 2008 or later.
#
# This work has the LPPL maintenance status `maintained'.
# The Current Maintainer of this work is Landon Fox.
#
# This work consists of the files beltmap.sty, tikzlibrarybeltmap.code.tex,
# beltmap.lua, beltmap-net.lua, beltmap_export.py, beltmap-doc.tex, and the
# files in examples/.

"""Export one beltmap picture as PNG, SVG or an animated GIF, for posting outside LaTeX.

    python beltmap_export.py LAYOUT [--keys "mix=bands, theme=dark, labels"]
                             [--png out.png] [--dpi 220] [--svg out.svg]
                             [--gif out.gif] [--fps 5] [--hold 2.5]

LAYOUT is any file \\beltlayout reads: Factorio-SAT tiles (.json), search records (.jsonl),
or a blueprint string or book (.txt).  --keys are beltmap keys, as in \\beltlayout[...].
At least one of --png, --svg, --gif.  The GIF shows the inputs' colors flowing through the
layout step by step (\\beltanimation); it implies mix=blend unless --keys sets mix.

Needs LuaLaTeX, Poppler's pdftoppm (PNG, GIF) and pdftocairo (SVG), and Pillow (GIF).  Works in a temporary
folder; nothing but the outputs is written.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd, cwd, env=None):
	r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, errors='replace')
	if r.returncode != 0:
		sys.stderr.write(r.stdout[-3000:] + r.stderr[-2000:])
		raise SystemExit('failed: ' + ' '.join(cmd[:2]))
	return r


def compile_tex(body, tmp, opts):
	tex = os.path.join(tmp, 'pic.tex')
	with open(tex, 'w', encoding='utf-8') as f:
		f.write('\\documentclass[%s]{standalone}\n\\usepackage{beltmap}\n\\begin{document}\n%s\n\\end{document}\n' % (opts, body))
	env = dict(os.environ)
	# beltmap.sty and the TikZ library through TEXINPUTS, beltmap.lua through LUAINPUTS.
	for var in ('TEXINPUTS', 'LUAINPUTS'):
		env[var] = HERE + os.pathsep + env.get(var, '')
	run(['lualatex', '-interaction=nonstopmode', '-halt-on-error', 'pic.tex'], tmp, env)
	return os.path.join(tmp, 'pic.pdf')


def main():
	ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
	ap.add_argument('layout')
	ap.add_argument('--keys', default='')
	ap.add_argument('--png')
	ap.add_argument('--dpi', type=int, default=220)
	ap.add_argument('--svg')
	ap.add_argument('--gif')
	ap.add_argument('--fps', type=float, default=5)
	ap.add_argument('--hold', type=float, default=2.5, help='seconds the last frame stays')
	a = ap.parse_args()
	if not (a.png or a.svg or a.gif):
		ap.error('give --png, --svg or --gif')
	layout = os.path.abspath(a.layout).replace('\\', '/')
	tmp = tempfile.mkdtemp(prefix='beltmap-')
	try:
		if a.png or a.svg:
			pdf = compile_tex('\\beltlayout[%s]{%s}' % (a.keys, layout), tmp, 'border=4pt')
			if a.png:
				run(['pdftoppm', '-r', str(a.dpi), '-png', '-singlefile', pdf, os.path.join(tmp, 'pic')], tmp)
				shutil.copyfile(os.path.join(tmp, 'pic.png'), a.png)
				print('wrote', a.png)
			if a.svg:
				# Poppler's cairo backend: text as paths, so the SVG shows the same anywhere.
				run(['pdftocairo', '-svg', pdf, os.path.abspath(a.svg)], tmp)
				print('wrote', a.svg)
		if a.gif:
			from PIL import Image
			tmp2 = os.path.join(tmp, 'anim')
			os.makedirs(tmp2)
			keys = a.keys if 'mix' in a.keys else ('mix, ' + a.keys)
			pdf = compile_tex('\\beltanimation[%s]{%s}' % (keys, layout), tmp2, 'border=4pt, tikz')
			run(['pdftoppm', '-r', str(a.dpi), '-png', pdf, os.path.join(tmp2, 'f')], tmp2)
			names = sorted(n for n in os.listdir(tmp2) if n.startswith('f') and n.endswith('.png'))
			frames = [Image.open(os.path.join(tmp2, n)).convert('RGB') for n in names]
			size = frames[0].size
			frames = [f if f.size == size else f.resize(size) for f in frames]
			step = int(1000 / a.fps)
			durations = [step] * (len(frames) - 1) + [int(1000 * a.hold)]
			frames[0].save(a.gif, save_all=True, append_images=frames[1:], duration=durations, loop=0, optimize=True)
			print('wrote', a.gif, '(%d frames)' % len(frames))
	finally:
		shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
	main()
