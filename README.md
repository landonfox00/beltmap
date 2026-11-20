# beltmap

Schematic pictures of Factorio belt layouts in LuaLaTeX.

Version 0.1, 2026-11-19.

`beltmap` draws belt balancers and other belt-and-splitter layouts. It reads Factorio-SAT tile files, Factorio blueprint strings and books (1.1 and 2.0), or a layout typed as a character grid. It traces every belt from splitter to splitter and draws the result in TikZ under one of five themes. On the traced network it computes the exact share of every input on every output, runs a max-flow throughput test, and draws the splitter graph. Every picture also yields the blueprint string of the layout as drawn, which can be attached to the PDF. In a tagged document every picture gets generated alternative text.

```latex
\usepackage{beltmap}
\beltlayout[labels]{layout.json}                     % a tile file, or a file holding a blueprint string
\beltblueprint{0eNqtkMEKwjAQRH9F9...}                 % a blueprint string in the document
\begin{beltgrid} > S> > \\ > S> > \end{beltgrid}      % a layout typed as a grid
\beltlayout[mix=bands]{layout.json} \beltmapverdict  % belts colored by the inputs they carry
```

The manual is `beltmap-doc.pdf`. Every picture in it is drawn by the package from the files in `examples/`.

## Requirements

- LuaLaTeX, with a LaTeX kernel of 2024-06-01 or later. The package stops with a message under pdfLaTeX or XeLaTeX.
- TikZ. `embedfile` when blueprints are attached without `\DocumentMetadata`.
- The TikZ library alone (`\usetikzlibrary{beltmap}`) runs in any engine.
- `beltmap_export.py` (PNG, SVG, or GIF of one picture) needs Python 3, LuaLaTeX, Poppler's `pdftoppm` and `pdftocairo`, and Pillow for GIFs.

## Files

| File | Contents |
|---|---|
| `beltmap.sty` | The LaTeX interface. |
| `tikzlibrarybeltmap.code.tex` | The glyphs and the five themes. |
| `beltmap.lua`, `beltmap-net.lua` | Reading, tracing, the flow analysis, and the TikZ and blueprint writers. |
| `beltmap-doc.tex`, `beltmap-doc.pdf` | The manual and its source. |
| `beltmap_export.py` | Exports one picture as PNG, SVG, or animated GIF. |
| `examples/` | The layouts the manual draws. |

## Installing by hand

Put `beltmap.sty`, `tikzlibrarybeltmap.code.tex`, `beltmap.lua`, and `beltmap-net.lua` beside the document, or in `tex/latex/beltmap/` of a local `texmf` tree. To build the manual, run `lualatex beltmap-doc.tex` twice in this folder.

## Source and issues

The source is at <https://github.com/landonfox00/beltmap>; report bugs at <https://github.com/landonfox00/beltmap/issues>. `python build.py` compiles the manual and writes the CTAN archive to `build/beltmap.zip`.

## Known limitations

- Blueprints were tested in Factorio 2.1.24 only.
- Entities other than belts, underground belts, and splitters are left out.
- The throughput test is max-flow only: necessary for full throughput, not sufficient.

The full list is at the end of the manual.

## License

Copyright (C) 2026 Landon Fox.

This work may be distributed and/or modified under the conditions of the LaTeX Project Public License, either version 1.3c of this license or (at your option) any later version. The latest version of this license is at <https://www.latex-project.org/lppl.txt>. This work has the LPPL maintenance status `maintained`; the Current Maintainer is Landon Fox.

Factorio is a trademark of Wube Software. `beltmap` is not affiliated with Wube Software and contains none of the game's graphics.
