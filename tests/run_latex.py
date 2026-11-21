"""Compile the test documents in tests/latex and check what each one says about itself.

    python tests/run_latex.py [--verapdf PATH] [--engines lualatex,pdflatex,xelatex] [NAME ...]

Every tests/latex/*.tex starts with lines `% test: key=value`:
    engine=lualatex|pdflatex|xelatex   which engine compiles it
    expect=ok|fail                     whether the run must succeed
    log-contains=TEXT, log-lacks=TEXT  in the log (TeX's line breaks undone first); repeatable
    pdf-images=N, pdf-images>=N        raster images in the PDF (pdfimages -list)
    attachments>=N                     files attached to the PDF (pdfdetach -list)
    file-exists=NAME                   a file the run must write beside the PDF
    fixture=factorio                   a fake Factorio data folder, as \\fixturedata
    no-game=yes                        no data folder anywhere (FACTORIO_DATA cleared)
    pdfua=yes                          PDF/UA-2 by veraPDF, when --verapdf is given
Each document runs in its own folder under tests/tmp/latex, with paths.tex defining \\examples
(the examples folder) and \\fixturedata.  BELTMAP_NO_ICON_SEARCH=1 is set for every run, so no
result depends on a game installed on the machine.  The export script is checked too.

Exit status 0 when every check passes.  A check that needs a missing tool fails, so CI cannot
pass by skipping; --allow-missing-tools turns those into skips for a local run.
"""
import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TMP = os.path.join(HERE, 'tmp', 'latex')


def png(w, h):
	"""A real gray RGBA PNG of w by h pixels, made here so that the repository holds no images."""
	def chunk(typ, data):
		return struct.pack('>I', len(data)) + typ + data + struct.pack('>I', zlib.crc32(typ + data) & 0xffffffff)
	raw = b''.join(b'\0' + b'\x80\x80\x80\xff' * w for _ in range(h))
	return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
		+ chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def make_fixture(base):
	"""A fake game data folder: base with one item, and a mod with another, both 120 by 64."""
	files = {
		'base/prototypes/item.lua': 'data:extend({ { type = "item", name = "widget", icon = "__base__/graphics/icons/widget.png" } })\n',
		'extra/prototypes/item.lua': 'data:extend({ { type = "item", name = "gizmo", icon = "__extra__/graphics/icons/gizmo.png" } })\n',
	}
	for rel, text in files.items():
		p = os.path.join(base, rel)
		os.makedirs(os.path.dirname(p), exist_ok=True)
		with open(p, 'w', encoding='utf-8', newline='\n') as f:
			f.write(text)
	for rel in ('base/graphics/icons/widget.png', 'extra/graphics/icons/gizmo.png'):
		p = os.path.join(base, rel)
		os.makedirs(os.path.dirname(p), exist_ok=True)
		with open(p, 'wb') as f:
			f.write(png(120, 64))


def spec_of(path):
	spec = {'engine': 'lualatex', 'expect': 'ok', 'log-contains': [], 'log-lacks': [], 'file-exists': []}
	for line in open(path, encoding='utf-8'):
		m = re.match(r'%\s*test:\s*([\w-]+)\s*(>=|=)\s*(.*?)\s*$', line)
		if not m:
			continue
		key, op, val = m.group(1), m.group(2), m.group(3)
		if key in ('log-contains', 'log-lacks', 'file-exists'):
			spec[key].append(val)
		elif op == '>=':
			spec[key + '>='] = int(val)
		else:
			spec[key] = val
	return spec


def tool(name):
	return shutil.which(name)


class Run:
	def __init__(self, allow_missing):
		self.fails, self.passes, self.skips = [], 0, 0
		self.allow_missing = allow_missing

	def check(self, name, ok, what):
		if ok:
			self.passes += 1
		else:
			self.fails.append(f'{name}: {what}')
		return ok

	def missing(self, name, what):
		if self.allow_missing:
			self.skips += 1
			print(f'      skip {what}: tool missing')
		else:
			self.fails.append(f'{name}: {what}: tool missing')


def env_for(spec):
	e = dict(os.environ)
	sep = os.pathsep
	# the document's own folder first, then the package at the top of the repository (not
	# recursive: a search of the whole tree would find other tests' files under tests/tmp)
	for var in ('TEXINPUTS', 'LUAINPUTS'):
		e[var] = '.' + sep + ROOT + sep + e.get(var, '')
	e['BELTMAP_NO_ICON_SEARCH'] = '1'
	if spec.get('no-game') == 'yes':
		e.pop('FACTORIO_DATA', None)
	return e


def run_doc(path, run, verapdf, engines):
	name = os.path.splitext(os.path.basename(path))[0]
	spec = spec_of(path)
	if spec['engine'] not in engines:
		print(f'skip  {name} ({spec["engine"]} not selected)')
		run.skips += 1
		return
	if not tool(spec['engine']):
		run.missing(name, spec['engine'])
		return
	work = os.path.join(TMP, name)
	shutil.rmtree(work, ignore_errors=True)
	os.makedirs(work)
	shutil.copy(path, os.path.join(work, name + '.tex'))
	fixture = os.path.join(work, 'factorio-data').replace('\\', '/')
	if spec.get('fixture') == 'factorio':
		make_fixture(fixture)
	with open(os.path.join(work, 'paths.tex'), 'w', encoding='utf-8', newline='\n') as f:
		f.write('\\def\\examples{%s}\n\\def\\fixturedata{%s}\n' % (os.path.join(ROOT, 'examples').replace('\\', '/'), fixture))
	r = subprocess.run([spec['engine'], '-interaction=nonstopmode', '-halt-on-error', name + '.tex'], cwd=work,
		env=env_for(spec), capture_output=True, text=True, errors='replace')
	logp = os.path.join(work, name + '.log')
	log = open(logp, encoding='utf-8', errors='replace').read() if os.path.exists(logp) else ''
	flat = log.replace('\n', '') + r.stdout.replace('\n', '')
	pdf = os.path.join(work, name + '.pdf')
	before = len(run.fails)
	if spec['expect'] == 'ok':
		run.check(name, r.returncode == 0 and os.path.exists(pdf), 'expected the run to succeed (exit %d)' % r.returncode)
	else:
		run.check(name, r.returncode != 0, 'expected the run to fail')
	for t in spec['log-contains']:
		run.check(name, t in flat, 'log lacks: ' + t)
	for t in spec['log-lacks']:
		run.check(name, t not in flat, 'log contains: ' + t)
	for fn in spec['file-exists']:
		run.check(name, os.path.exists(os.path.join(work, fn)), 'missing file ' + fn)
	if 'pdf-images' in spec or 'pdf-images>=' in spec:
		if not tool('pdfimages'):
			run.missing(name, 'pdfimages')
		elif os.path.exists(pdf):
			out = subprocess.run(['pdfimages', '-list', pdf], capture_output=True, text=True).stdout.splitlines()
			count = max(0, len(out) - 2)
			if 'pdf-images' in spec:
				run.check(name, count == int(spec['pdf-images']), f'{count} raster images, expected {spec["pdf-images"]}')
			else:
				run.check(name, count >= spec['pdf-images>='], f'{count} raster images, expected at least {spec["pdf-images>="]}')
	if 'attachments>=' in spec:
		if not tool('pdfdetach'):
			run.missing(name, 'pdfdetach')
		elif os.path.exists(pdf):
			out = subprocess.run(['pdfdetach', '-list', pdf], capture_output=True, text=True).stdout
			m = re.match(r'\s*(\d+) embedded files', out)
			count = int(m.group(1)) if m else 0
			run.check(name, count >= spec['attachments>='], f'{count} attachments, expected at least {spec["attachments>="]}')
	if spec.get('pdfua') == 'yes' and verapdf and os.path.exists(pdf):
		out = subprocess.run([verapdf, '--flavour', 'ua2', pdf], capture_output=True, text=True).stdout
		run.check(name, 'isCompliant="true"' in out, 'veraPDF: not PDF/UA-2 compliant')
	ok = len(run.fails) == before
	print(('ok    ' if ok else 'FAIL  ') + name)
	if not ok:
		tail = '\n'.join(l for l in log.splitlines()[-40:])
		print('      --- log tail ---\n' + '\n'.join('      ' + l for l in tail.splitlines()))


def run_export(run):
	"""beltmap_export.py: a PNG and an SVG of one picture."""
	name = 'export'
	for t in ('lualatex', 'pdftoppm', 'pdftocairo'):
		if not tool(t):
			run.missing(name, t)
			return
	work = os.path.join(TMP, name)
	shutil.rmtree(work, ignore_errors=True)
	os.makedirs(work)
	png_out, svg_out = os.path.join(work, 'f00.png'), os.path.join(work, 'f00.svg')
	r = subprocess.run([sys.executable, os.path.join(ROOT, 'beltmap_export.py'), os.path.join(ROOT, 'examples', 'f00_9x10.json'),
		'--keys', 'mix=strict, marks', '--png', png_out, '--svg', svg_out, '--dpi', '96'], capture_output=True, text=True)
	ok = run.check(name, r.returncode == 0, 'exit %d: %s' % (r.returncode, r.stderr[-500:]))
	ok = run.check(name, os.path.exists(png_out) and open(png_out, 'rb').read(8) == b'\x89PNG\r\n\x1a\n', 'no PNG written') and ok
	ok = run.check(name, os.path.exists(svg_out) and b'<svg' in open(svg_out, 'rb').read(4096), 'no SVG written') and ok
	print(('ok    ' if ok else 'FAIL  ') + name)


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument('names', nargs='*')
	ap.add_argument('--verapdf')
	ap.add_argument('--engines', default='lualatex,pdflatex,xelatex')
	ap.add_argument('--no-export', action='store_true')
	ap.add_argument('--allow-missing-tools', action='store_true')
	a = ap.parse_args()
	engines = set(a.engines.split(','))
	run = Run(a.allow_missing_tools)
	docs = sorted(f for f in os.listdir(os.path.join(HERE, 'latex')) if f.endswith('.tex'))
	for f in docs:
		if a.names and not any(n in f for n in a.names):
			continue
		run_doc(os.path.join(HERE, 'latex', f), run, a.verapdf, engines)
	if not a.no_export and (not a.names or 'export' in a.names):
		run_export(run)
	print(f'\n{run.passes} checks passed, {len(run.fails)} failed, {run.skips} skipped')
	for msg in run.fails:
		print('  - ' + msg)
	sys.exit(1 if run.fails else 0)


if __name__ == '__main__':
	main()
