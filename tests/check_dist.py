"""Check the CTAN archive build.py wrote, as CTAN's upload rules ask.

    python tests/check_dist.py [build/beltmap.zip]

- One top-level folder, beltmap/, and exactly the files the package ships: no tests, build
  products, hidden files or images.
- File names in plain ASCII without spaces; text files UTF-8 with LF endings.
- The manual is there, has its pages, holds no raster image (no game icon), and its version
  agrees with beltmap.sty in the archive.
"""
import os
import re
import shutil
import subprocess
import tempfile
import sys
import zipfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXPECTED = {'README.md', 'beltmap.sty', 'tikzlibrarybeltmap.code.tex', 'beltmap.lua', 'beltmap-net.lua',
	'beltmap_export.py', 'beltmap-doc.tex', 'beltmap-doc.pdf'}

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build', 'beltmap.zip')
problems = []
z = zipfile.ZipFile(path)
names = [n for n in z.namelist() if not n.endswith('/')]

tops = {n.split('/')[0] for n in names}
if tops != {'beltmap'}:
	problems.append(f'top-level entries {sorted(tops)}, expected only beltmap/')
rel = {n[len('beltmap/'):] for n in names if n.startswith('beltmap/')}
loose = {r for r in rel if '/' not in r}
missing = EXPECTED - loose
extra = loose - EXPECTED
if missing:
	problems.append(f'missing: {sorted(missing)}')
if extra:
	problems.append(f'unexpected files: {sorted(extra)}')
examples = sorted(r for r in rel if r.startswith('examples/'))
if not examples:
	problems.append('no examples')
others = sorted(r for r in rel if '/' in r and not r.startswith('examples/'))
if others:
	problems.append(f'unexpected folders: {others}')

for n in names:
	base = n.rsplit('/', 1)[-1]
	if base.startswith('.'):
		problems.append(f'{n}: hidden file')
	if not re.fullmatch(r'[A-Za-z0-9._/-]+', n):
		problems.append(f'{n}: name is not plain ASCII without spaces')
	if n.lower().endswith(('.png', '.jpg', '.jpeg', '.gif', '.svg')):
		problems.append(f'{n}: image file')
	if not n.endswith('.pdf'):
		data = z.read(n)
		try:
			data.decode('utf-8')
		except UnicodeDecodeError:
			problems.append(f'{n}: not UTF-8')
		if b'\r' in data:
			problems.append(f'{n}: CR line endings')

pdf = z.read('beltmap/beltmap-doc.pdf') if 'beltmap/beltmap-doc.pdf' in names else b''
if pdf:
	inflated = [pdf]
	for m in re.finditer(rb'stream\r?\n', pdf):
		end = pdf.find(b'endstream', m.end())
		try:
			inflated.append(zlib.decompressobj().decompress(pdf[m.end():end]))
		except zlib.error:
			pass
	blob = b'\n'.join(inflated)
	if re.search(rb'/Subtype\s*/Image', blob):
		problems.append('beltmap-doc.pdf: holds a raster image')
	pages = len(re.findall(rb'/Type\s*/Page[^s]', blob))
	if pages < 10:
		problems.append(f'beltmap-doc.pdf: only {pages} pages')
	# the version on the manual's title page, read as text (the PDF's own bytes hold glyph codes)
	sty = z.read('beltmap/beltmap.sty').decode('utf-8')
	m = re.search(r'\\ProvidesExplPackage\{beltmap\}\{([^}]*)\}\{([^}]*)\}', sty)
	if m and shutil.which('pdftotext'):
		with tempfile.TemporaryDirectory() as tmp:
			p = os.path.join(tmp, 'manual.pdf')
			with open(p, 'wb') as f:
				f.write(pdf)
			text = subprocess.run(['pdftotext', '-l', '1', p, '-'], capture_output=True, text=True, errors='replace').stdout
		want = f'version {m.group(2)}, {m.group(1)}'
		if want not in text:
			problems.append(f'beltmap-doc.pdf: the title page does not say "{want}"')
	elif m:
		print('  (pdftotext missing: the title page was not read)')
	print(f'manual: {pages} pages')

print(f'{path}: {len(names)} files, {len(examples)} examples, {os.path.getsize(path) // 1024} KB')
if problems:
	for p in problems:
		print('  - ' + p)
	sys.exit(1)
print('PASS')
