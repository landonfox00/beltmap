# Changelog

## 0.6 (2026-11-23)

Added:

- `full load`: a fluid model of full belts, for every choice of inputs and outputs, with `\beltmapfullload` and `expect=full-load` or `full-load-limited`. Compared with 1392 measurements from Factorio 2.1.24.
- `lane balance`: whether every output's two lanes carry the same of every input lane, with `\beltmaplanebalance` and `expect=lane-balanced` or `lane-unbalanced`.
- `same network=file`: whether two layouts are one network up to renaming, with `\beltmapsame` and `expect=same-network` or `different-network`.
- `cache`: keeps the results of `throughput`, `blocked`, and `full load` between runs.

Fixed:

- A side-load onto an underground belt took both incoming lanes. As measured in the game, an entrance takes only the upstream lane and an exit only the downstream lane.
- A belt fed only by side-loads was counted as an input.
- `throughput` ran for hours on wide layouts. It now tries choices of equal size, which decide all the others, and stops at 20000 choices with an undecided verdict that `expect=throughput` refuses.
- With `-output-directory`, written blueprints and books landed beside the source.
- A key that takes a number ignored anything else (`focus=abc`). It now stops with an error.
- Manual: the claim that input and output balance imply each other now excludes priorities, and the 5-input gray example adds up to 100%.
- Manual: the title is tagged, and data tables declare their header rows.

Changed:

- The manual is reorganized around tasks, with a table of contents and a command reference.

## 0.5.1 (2026-11-21)

CI and tests in the repository. Fixed `\beltmapbook` without `\DocumentMetadata`, `\beltmapmatrix` without `amsmath`, a crash on a corrupt icon file, a placeholder drawn for a filter without an icon, and macros in `compare=` and `factorio data=`.

## 0.5 (2026-11-21)

`mix=strict`, `mix=check`, `marks`, and `demand`.

## 0.4 (2026-11-21)

`blocked`: balance with every set of outputs blocked.

## 0.3 (2026-11-21)

Game icons read from the reader's own copy of Factorio.

## 0.2 (2026-11-21)

`view=wires`: a canonical wire diagram.

## 0.1.1 (2026-11-21)

Manual: gray outputs and equal stripes do not prove balance.

## 0.1 (2026-11-19)

First release.
