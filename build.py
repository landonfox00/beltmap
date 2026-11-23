"""Build the manual and the CTAN upload of beltmap.

    python build.py            # build/beltmap.zip, with build/beltmap/beltmap-doc.pdf
    python build.py --no-pdf   # stage and scan only

Version and date are read from \\ProvidesExplPackage in beltmap.sty; to release, change them there
and in the title block of beltmap-doc.tex. The manual is compiled in build/beltmap/ (three LuaLaTeX
runs, about 3 min: the table of contents moves the pages on the second, and the tagging of a page
needs the page numbers of the run before) with its PDF dates fixed to the release date, UTC.

Before zipping, every staged file (the PDF's streams inflated) is scanned for e-mail addresses and
local paths, and for the extra patterns in .leak-patterns (one regular expression per line, not
under version control). A hit stops the build.
"""
import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, 'build')
STAGE = os.path.join(BUILD, 'beltmap')
SHIP = ['README.md', 'CHANGELOG.md', 'beltmap.sty', 'tikzlibrarybeltmap.code.tex', 'beltmap.lua', 'beltmap-net.lua',
	'beltmap_export.py', 'beltmap-doc.tex', 'examples']
DOC = 'beltmap-doc.tex'

LEAKS = [r'[a-z0-9._%+-]+@[a-z0-9-]+\.[a-z.]{2,}', r'[a-z]:[\\/]+users', r'/c/users', r'/home/[a-z]', r'onedrive', r'appdata']
ALLOWED_EMAIL = re.compile(r'\b(ctan@ctan\.org)\b')


def read(path):
	with open(path, encoding='utf-8') as f:
		return f.read()


# Streams that hold no text a person wrote: font programs and images.  Their bytes, compressed or
# not, can spell anything (a font once matched the e-mail pattern), so they are not scanned.
BINARY_STREAM = re.compile(rb'/Length[123]\b|/FontFile|/Subtype\s*/(?:Type1C|CIDFontType0C|OpenType|Image)')


def pdf_text(path):
	"""The text of a PDF worth scanning: everything outside streams, and every stream inflated,
	but not font programs or images."""
	data = open(path, 'rb').read()
	parts, pos = [], 0
	for m in re.finditer(rb'stream\r?\n', data):
		if data[m.start() - 3:m.start()] == b'end':
			continue
		end = data.find(b'endstream', m.end())
		if end < 0:
			break
		head = data[pos:m.start()]
		parts.append(head)
		# the object's own dictionary: from its "obj" keyword to "stream"
		dictionary = head[head.rfind(b'obj'):]
		if not BINARY_STREAM.search(dictionary):
			try:
				parts.append(zlib.decompressobj().decompress(data[m.end():end]))
			except zlib.error:
				pass
		pos = end + len(b'endstream')
	parts.append(data[pos:])
	return b'\n'.join(parts).decode('latin-1')


def scan():
	pats = list(LEAKS)
	extra = os.path.join(HERE, '.leak-patterns')
	if os.path.exists(extra):
		pats += [l.strip() for l in read(extra).splitlines() if l.strip() and not l.startswith('#')]
	hits = []
	for root, _, files in os.walk(STAGE):
		for fn in files:
			p = os.path.join(root, fn)
			text = pdf_text(p) if fn.endswith('.pdf') else read(p)
			for i, line in enumerate(text.lower().split('\n'), 1):
				clean = ALLOWED_EMAIL.sub('', line)
				for pat in pats:
					if re.search(pat, clean):
						hits.append('%s:%d: /%s/ %s' % (os.path.relpath(p, STAGE), i, pat, line.strip()[:110]))
	return hits


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument('--no-pdf', action='store_true')
	a = ap.parse_args()
	m = re.search(r'\\ProvidesExplPackage\{beltmap\}\{(\d{4}-\d\d-\d\d)\}\{([^}]*)\}', read(os.path.join(HERE, 'beltmap.sty')))
	date, version = m.group(1), m.group(2)
	if version not in read(os.path.join(HERE, DOC)) or date not in read(os.path.join(HERE, DOC)):
		raise SystemExit('beltmap-doc.tex does not carry version %s, %s' % (version, date))

	shutil.rmtree(BUILD, ignore_errors=True)
	os.makedirs(STAGE, exist_ok=True)  # an empty folder that some process still has open survives rmtree
	for name in SHIP:
		src = os.path.join(HERE, name)
		(shutil.copytree if os.path.isdir(src) else shutil.copy2)(src, os.path.join(STAGE, name))

	if not a.no_pdf:
		epoch = int(datetime.datetime.strptime(date, '%Y-%m-%d').replace(tzinfo=datetime.timezone.utc).timestamp())
		env = dict(os.environ, SOURCE_DATE_EPOCH=str(epoch), FORCE_SOURCE_DATE='1', TZ='UTC')
		for run in (1, 2, 3):
			r = subprocess.run(['lualatex', '-interaction=nonstopmode', '-halt-on-error', DOC], cwd=STAGE, env=env,
				capture_output=True, text=True, errors='replace')
			if r.returncode != 0:
				sys.stderr.write(r.stdout[-4000:])
				raise SystemExit('lualatex failed on run %d' % run)
		for fn in os.listdir(STAGE):
			if fn not in SHIP and fn != 'beltmap-doc.pdf':
				os.remove(os.path.join(STAGE, fn))

	hits = scan()
	# The package ships no game graphics; every picture of the manual is vector, so any raster
	# image in it can only be a game icon that slipped in (the manual sets icons=false).
	pdf = os.path.join(STAGE, 'beltmap-doc.pdf')
	if os.path.exists(pdf) and re.search(rb'/Subtype\s*/Image', open(pdf, 'rb').read() + pdf_text(pdf).encode('latin-1')):
		hits.append('beltmap-doc.pdf: holds a raster image (a game icon?); build the manual with icons=false')
	for root, _, files in os.walk(STAGE):
		for fn in files:
			if fn.lower().endswith(('.png', '.jpg', '.jpeg', '.gif')):
				hits.append(os.path.relpath(os.path.join(root, fn), STAGE) + ': image files are not shipped')
	if hits:
		print('\n'.join(hits))
		raise SystemExit('leak scan: %d hit(s); nothing zipped' % len(hits))
	print('beltmap %s, %s: leak scan clean' % (version, date))
	if a.no_pdf:
		return
	zpath = os.path.join(BUILD, 'beltmap.zip')
	with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as z:
		for root, _, files in os.walk(STAGE):
			for fn in sorted(files):
				p = os.path.join(root, fn)
				z.write(p, os.path.relpath(p, BUILD).replace(os.sep, '/'))
	print(zpath)


if __name__ == '__main__':
	main()
