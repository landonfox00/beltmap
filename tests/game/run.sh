#!/bin/sh
# Measures full-load throughput in Factorio, headless, in a data folder of its own (tests/tmp/game),
# so the player's mods, saves and settings are never touched.  Needs a copy of Factorio 2.x:
#     FACTORIO=/path/to/bin/x64/factorio sh tests/game/run.sh
#     texlua tests/game/record.lua       # rewrites tests/game/fullload.txt from the run
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${FACTORIO:?set FACTORIO to the game executable}"
RUN="$HERE/../tmp/game"
if command -v cygpath >/dev/null 2>&1; then W() { cygpath -m "$1"; }; else W() { printf '%s' "$1"; }; fi
cd "$HERE"
texlua make_runs.lua > make.out 2>&1
cat make.out
TICKS=$(sed -n 's/^ticks //p' make.out | tr -cd 0-9)
rm -f make.out
mkdir -p "$RUN/mods" "$RUN/saves"
rm -rf "$RUN/mods/beltmap-fullload" "$RUN/script-output/beltmap-fullload"
cp -r "$HERE/mod/beltmap-fullload" "$RUN/mods/"
cat > "$RUN/mods/mod-list.json" <<'EOT'
{"mods": [
 {"name": "base", "enabled": true}, {"name": "elevated-rails", "enabled": false},
 {"name": "quality", "enabled": false}, {"name": "recycler", "enabled": false},
 {"name": "space-age", "enabled": false}, {"name": "beltmap-fullload", "enabled": true}
]}
EOT
cat > "$RUN/config.ini" <<EOT
[path]
read-data=__PATH__executable__/../../data
write-data=$(W "$RUN")
EOT
ARGS="--config $(W "$RUN/config.ini") --mod-directory $(W "$RUN/mods") --disable-audio"
"$FACTORIO" $ARGS --create "$(W "$RUN/saves/fullload.zip")" > "$RUN/create.out" 2>&1
"$FACTORIO" $ARGS --benchmark "$(W "$RUN/saves/fullload.zip")" --benchmark-ticks "$TICKS" --benchmark-runs 1 > "$RUN/benchmark.out" 2>&1
ls -l "$RUN/script-output/beltmap-fullload/results.json"
