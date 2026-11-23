"""Static checks of the repository, with no TeX needed: the fast first gate of CI.

    python tests/check_repo.py

- Text files are UTF-8 with LF line endings, a final newline, and no trailing whitespace.
- No binary, image, PDF or archive file is tracked (the package ships no game graphics, and
  build products are not committed).
- The version and date agree in beltmap.sty, the manual's header and title, and README.md; on a
  tag build ($GITHUB_REF_TYPE=tag) the tag is v<version>.
- Every shipped source file carries the LPPL header.
- Every key that beltmap.sty defines is in the manual's table of keys; so is every command,
  every macro that holds a verdict, and every value of expect.
- CHANGELOG.md opens with the current version and date.
- The manual is built with icons=false.
- No e-mail address, home folder or user path is in a tracked file.
- Every Python file compiles.
"""
import os

import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHIPPED = ['beltmap.sty', 'tikzlibrarybeltmap.code.tex', 'beltmap.lua', 'beltmap-net.lua', 'beltmap_export.py', 'beltmap-doc.tex']
BINARY = ('.png', '.jpg', '.jpeg', '.gif', '.pdf', '.zip', '.gz', '.tgz', '.webp', '.svg', '.ico', '.exe', '.dll')
LEAKS = [
	(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z.]{2,}', 'an e-mail address'),
	(r'[A-Za-z]:[\\/]+Users[\\/]', 'a Windows user folder'),
	(r'/home/[a-z][a-z0-9_-]+/', 'a home folder'),
	(r'(?i)appdata[\\/]', 'an AppData path'),
	(r'(?i)onedrive', 'a OneDrive path'),
]
ALLOWED_EMAILS = {'ctan@ctan.org'}

problems = []


def problem(msg):
	problems.append(msg)


def tracked():
	try:
		out = subprocess.run(['git', 'ls-files'], cwd=ROOT, capture_output=True, text=True, check=True).stdout
		return [l for l in out.splitlines() if l]
	except (OSError, subprocess.CalledProcessError):
		files = []
		for d, dirs, fs in os.walk(ROOT):
			dirs[:] = [x for x in dirs if x not in ('.git', 'build', 'tmp', 'actual')]
			files += [os.path.relpath(os.path.join(d, f), ROOT).replace('\\', '/') for f in fs]
		return files


def read(rel):
	with open(os.path.join(ROOT, rel), 'rb') as f:
		return f.read()


files = tracked()

# text hygiene, binaries, leaks
for rel in files:
	if rel.lower().endswith(BINARY):
		problem(f'{rel}: binary or build file is tracked')
		continue
	data = read(rel)
	if b'\0' in data:
		problem(f'{rel}: binary content')
		continue
	try:
		text = data.decode('utf-8')
	except UnicodeDecodeError:
		problem(f'{rel}: not UTF-8')
		continue
	if '\r' in text:
		problem(f'{rel}: CR line endings')
	if text and not text.endswith('\n'):
		problem(f'{rel}: no final newline')
	for i, line in enumerate(text.split('\n'), 1):
		if line != line.rstrip():
			problem(f'{rel}:{i}: trailing whitespace')
			break
	if rel.startswith('tests/golden/'):
		continue
	for pat, what in LEAKS:
		for m in re.finditer(pat, text):
			if m.group(0) in ALLOWED_EMAILS:
				continue
			# the leak patterns themselves, in this file and in build.py
			if rel in ('tests/check_repo.py', 'build.py'):
				continue
			problem(f'{rel}: {what}: {m.group(0)}')

# versions
sty = read('beltmap.sty').decode('utf-8')
doc = read('beltmap-doc.tex').decode('utf-8')
readme = read('README.md').decode('utf-8')
m = re.search(r'\\ProvidesExplPackage\{beltmap\}\{(\d{4}-\d\d-\d\d)\}\{([^}]*)\}', sty)
if not m:
	problem('beltmap.sty: no \\ProvidesExplPackage{beltmap}{date}{version}')
else:
	date, version = m.group(1), m.group(2)
	if not re.search(r'^% beltmap ' + re.escape(version) + r'\s+' + date + r'\s*$', doc, re.M):
		problem(f'beltmap-doc.tex: header comment is not "beltmap {version} ... {date}"')
	if f'version {version}, {date}' not in doc:
		problem(f'beltmap-doc.tex: title block does not say "version {version}, {date}"')
	if f'Version {version}, {date}.' not in readme:
		problem(f'README.md: does not say "Version {version}, {date}."')
	if os.environ.get('GITHUB_REF_TYPE') == 'tag':
		tag = os.environ.get('GITHUB_REF_NAME', '')
		if tag != 'v' + version:
			problem(f'tag {tag} does not match the package version {version}')
	print(f'beltmap {version}, {date}')

# license headers
for rel in SHIPPED:
	head = read(rel).decode('utf-8')[:1500]
	if 'LaTeX Project Public License' not in head or 'version 1.3c' not in head:
		problem(f'{rel}: no LPPL 1.3c header')
if 'LaTeX Project Public License' not in readme:
	problem('README.md: no license statement')

# every key documented
keys = set()
for km in re.finditer(r'^\s*([a-z][a-z~-]*)\s*\.(?:choices|tl_set|code|bool_set|int_set|default|meta)', sty, re.M):
	keys.add(km.group(1).replace('~', ' '))
cl = re.search(r'\\clist_map_function:nN\s*\{([^}]*)\}\s*\\__beltmap_bool_key:n', sty)
if cl:
	keys |= {k.strip() for k in cl.group(1).split(',') if k.strip()}
for k in sorted(keys):
	if '\\key{' + k + '}' not in doc and '\\key{' + k + '=' not in doc:
		problem(f'key "{k}" is defined in beltmap.sty but not described in the manual (\\key{{{k}}})')
print(f'{len(keys)} keys, all documented' if not any('key "' in p for p in problems) else '')

# every command, verdict macro and expect value documented
commands = set(re.findall(r'\\NewDocumentCommand\s*\\(\w+)', sty))
commands |= set(re.findall(r'\\tl_new:N \\(beltmap\w+)', sty))
for name in sorted(commands):
	if '\\cs{' + name + '}' not in doc and '\\' + name not in doc:
		problem(f'command \\{name} is defined in beltmap.sty but not described in the manual')
lua = read('beltmap.lua').decode('utf-8')
vm = re.search(r"unknown value \(the values are ([^)]*)\)", lua)
if not vm:
	problem('beltmap.lua: no list of expect values')
else:
	for value in [v.strip() for v in vm.group(1).split(',')]:
		if '\\key{' + value + '}' not in doc:
			problem(f'expect={value} is not described in the manual')

# the changelog opens with this version
if m:
	log = read('CHANGELOG.md').decode('utf-8') if 'CHANGELOG.md' in files else ''
	head = re.search(r'^## (\S+) \((\d{4}-\d\d-\d\d)\)', log, re.M)
	if not head or head.group(1) != version or head.group(2) != date:
		problem(f'CHANGELOG.md: the first entry is not "## {version} ({date})"')

# the manual must not embed game icons
if not re.search(r'^\\beltmapset\{icons=false\}', doc, re.M):
	problem('beltmap-doc.tex: the manual must set \\beltmapset{icons=false}')

# python compiles
for rel in files:
	if rel.endswith('.py'):
		try:
			compile(read(rel).decode('utf-8'), rel, 'exec')
		except SyntaxError as e:
			problem(f'{rel}: does not compile: {e}')

print(f'{len(files)} files checked')
if problems:
	print(f'\n{len(problems)} problem(s):')
	for p in problems:
		print('  - ' + p)
	sys.exit(1)
print('PASS')
