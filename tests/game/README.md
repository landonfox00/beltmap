# Game measurements

`fullload.txt` holds what Factorio 2.1.24 (base game) passed at full load: 16 layouts, 1392 choices of inputs and outputs, 2 minutes of game time each after a 30 s warm-up. The chosen input lanes are kept full and the chosen output belts are emptied every tick. `tests/lua/test_game_data.lua` compares `full load` with these numbers on every CI run, without the game.

To measure again, with a copy of the game:

```sh
FACTORIO=/path/to/factorio sh tests/game/run.sh
texlua tests/game/record.lua
```

The run uses its own data folder, `tests/tmp/game`, and takes about four minutes.
