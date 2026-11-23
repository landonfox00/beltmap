-- Rewrites tests/game/fullload.txt from the last run of run.sh: one line per choice of inputs and
-- outputs, "case | inputs | outputs | items counted".  Run from the top of the repository.
package.path = './?.lua;' .. package.path
local bm = require('beltmap')
local fh = assert(io.open('tests/tmp/game/script-output/beltmap-fullload/results.json', 'rb'))
local R = bm.json_decode(fh:read('a'))
fh:close()
local out = { string.format('# Factorio 2.1.24, base game; measure %d ticks after %d of warm-up', R.measure, R.warmup) }
for _, r in ipairs(R.runs) do
	out[#out + 1] = string.format('%d|%s|%s|%d', r.case, table.concat(r.I, ','), table.concat(r.O, ','), r.count)
end
local w = assert(io.open('tests/game/fullload.txt', 'wb'))
w:write(table.concat(out, '\n'), '\n')
w:close()
print((#out - 1) .. ' measurements')
