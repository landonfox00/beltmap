# beltmap

Schematic pictures of Factorio belt layouts in LuaLaTeX.

Version 0.6, 2026-11-23. Landon Fox.

In the game Factorio, conveyor belts carry items and a splitter takes two belts in and sends half of what arrives out of each side. A *belt balancer* is a network of splitters whose outputs each carry an equal share of every input. `beltmap` draws these networks and computes what they do.

```latex
\usepackage{beltmap}
...
\begin{beltgrid}[labels, expect=balanced]
  > S> > \\
  > S> >
\end{beltgrid}
```

This draws one splitter on two belts. `expect=balanced` makes LuaLaTeX stop with an error if the drawn layout is not a balancer.

| To | Use |
|---|---|
| draw a blueprint string copied from the game | `\beltblueprint{0eNqt...}` |
| draw a blueprint or Factorio-SAT file | `\beltlayout{layout.json}` |
| type a layout | the `beltgrid` environment |
| print each input's exact share of each output | `\beltmapmatrix` |
| color belts so that gray means balanced | `mix=strict`, `marks` |
| test whether lanes are kept or evened | `mix lanes`, `lane balance` |
| test throughput | `throughput` (max-flow), `full load` (fluid model) |
| test balance with outputs blocked | `blocked` |
| test whether two layouts are one network | `same network=file` |
| draw the network without its positions | `view=graph`, `view=wires` |
| get the blueprint back out of the PDF | `blueprint` |

The manual is `beltmap-doc.pdf`, and changes are in `CHANGELOG.md`.

## Requirements

- LuaLaTeX, with a LaTeX kernel of 2024-06-01 or later. The package stops with a message under pdfLaTeX or XeLaTeX.
- TikZ, and `embedfile` in documents without `\DocumentMetadata`.
- The TikZ library alone (`\usetikzlibrary{beltmap}`) runs in any engine.
- `beltmap_export.py` (PNG, SVG, or GIF of one picture) needs Python 3, LuaLaTeX, Poppler's `pdftoppm` and `pdftocairo`, and Pillow for GIFs.

## Files

| File | Contents |
|---|---|
| `beltmap.sty` | The LaTeX interface. |
| `tikzlibrarybeltmap.code.tex` | The glyphs and the five themes. |
| `beltmap.lua`, `beltmap-net.lua` | Reading, tracing, the analyses, and the TikZ and blueprint writers. |
| `beltmap-doc.tex`, `beltmap-doc.pdf` | The manual and its source. |
| `beltmap_export.py` | Exports one picture as PNG, SVG, or animated GIF. |
| `examples/` | The layouts the manual draws. |

## Installing by hand

`beltmap` is in TeX Live and MiKTeX. By hand, put `beltmap.sty`, `tikzlibrarybeltmap.code.tex`, `beltmap.lua`, and `beltmap-net.lua` beside the document, or in `tex/latex/beltmap/` of a local `texmf` tree. To build the manual, run `lualatex beltmap-doc.tex` three times in this folder (the table of contents moves the pages, and the tagging needs them settled).

## Source and issues

The source is at <https://github.com/landonfox00/beltmap>; report bugs at <https://github.com/landonfox00/beltmap/issues>. `python build.py` compiles the manual and writes the CTAN archive to `build/beltmap.zip`.

## Tests

The repository (not the CTAN archive) holds the tests that CI runs on every change:

| Command | What it checks |
|---|---|
| `python tests/check_repo.py` | Line endings, matching versions, license headers, every key, command and verdict documented, nothing leaked; needs no TeX. |
| `texlua tests/run.lua` | Shares, verdicts, all the analyses, blueprints, icon lookup, golden snapshots, properties of random layouts (`BELTMAP_SEED`, `BELTMAP_CASES`), and the full-load model against measurements from Factorio. `--update` rewrites the snapshots after an intended change. |
| `python tests/run_latex.py` | Real documents in LuaLaTeX, pdfLaTeX, and XeLaTeX: refusals, `expect=` failures, tagged output (`--verapdf PATH`), attachments, `-output-directory`, the cache, icons from a fake game folder, the README's example, the export script. |
| `python tests/check_dist.py` | The CTAN archive from `build.py`: exactly the shipped files, no images, a complete manual. |
| `sh tests/game/run.sh` | Measures full-load throughput again in a copy of Factorio (not in CI). |

CI runs these on a pinned TeX Live 2026, on TeX Live 2024 (the oldest supported), and on Windows. A weekly job runs them on the newest TeX Live, with a thousand random layouts from a new seed.

## Known limitations

- Blueprints were tested in Factorio 2.1.24 only.
- Entities other than belts, underground belts, and splitters are left out.
- `throughput` is max-flow only: necessary for full throughput, not sufficient. `full load` is a fluid model, at most 0.101 belts above the game on the 1392 choices measured.

The full list is at the end of the manual.

## License

Copyright (C) 2026 Landon Fox.

This work may be distributed and/or modified under the conditions of the LaTeX Project Public License, either version 1.3c of this license or (at your option) any later version. The latest version of this license is at <https://www.latex-project.org/lppl.txt>. This work has the LPPL maintenance status `maintained`; the Current Maintainer is Landon Fox.

Factorio is a trademark of Wube Software. `beltmap` is not affiliated with Wube Software and contains none of the game's graphics.
