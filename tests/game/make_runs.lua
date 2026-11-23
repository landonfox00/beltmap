-- Writes mod/beltmap-fullload/runs.lua: each choice of each case, ready to place in the game.
-- Run from tests/game (run.sh does):  texlua make_runs.lua
package.path = '../../?.lua;./?.lua;' .. package.path
local bm, NET = require('beltmap'), require('beltmap-net')
local C = require('cases')

local out, count = { '-- Written by make_runs.lua; do not edit.\nreturn {\n' }, 0
for ci, c in ipairs(C.cases) do
	local L, net, inputs, outputs = C.read(bm, NET, c, '../..')
	local ents = bm.blueprint_of(L, { numbering = 16 }).blueprint.entities
	local es = {}
	for _, e in ipairs(ents) do
		es[#es + 1] = string.format('{name=%q,x=%s,y=%s,direction=%d,type=%s,input_priority=%s,output_priority=%s}',
			e.name, e.position.x, e.position.y, e.direction, e.type and string.format('%q', e.type) or 'nil',
			e.input_priority and string.format('%q', e.input_priority) or 'nil', e.output_priority and string.format('%q', e.output_priority) or 'nil')
	end
	out[#out + 1] = string.format('\t{ case = %d, name = %q, w = %d, h = %d, entities = { %s },\n\t\truns = {\n', ci, c.name, L.w, L.h, table.concat(es, ','))
	for _, ch in ipairs(C.choices(c, net.n, net.m)) do
		local src, snk = {}, {}
		for _, i in ipairs(ch.I) do src[#src + 1] = string.format('{%d,%d}', inputs[i].x, inputs[i].y) end
		for _, o in ipairs(ch.O) do snk[#snk + 1] = string.format('{%d,%d}', outputs[o].x, outputs[o].y) end
		out[#out + 1] = string.format('\t\t\t{ I = {%s}, O = {%s}, src = {%s}, snk = {%s} },\n', table.concat(ch.I, ','), table.concat(ch.O, ','),
			table.concat(src, ','), table.concat(snk, ','))
		count = count + 1
	end
	out[#out + 1] = '\t\t} },\n'
end
out[#out + 1] = string.format('\twarmup = %d, measure = %d, item = %q,\n}\n', C.WARMUP, C.MEASURE, C.ITEM)
local fh = assert(io.open('mod/beltmap-fullload/runs.lua', 'wb'))
fh:write(table.concat(out))
fh:close()
print(count .. ' runs')
print('ticks ' .. (C.WARMUP + C.MEASURE + 5))
