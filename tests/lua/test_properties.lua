-- Properties that hold for every layout, checked on random ones.  The generator is seeded, so a
-- failure can be repeated: BELTMAP_SEED=n texlua tests/run.lua properties.  BELTMAP_CASES sets how
-- many layouts; the weekly canary run uses a new seed and more of them.
local T = require('lib')
local bm, NET = T.bm, T.NET

local SEED = tonumber(os.getenv('BELTMAP_SEED') or '') or 20261123
local CASES = tonumber(os.getenv('BELTMAP_CASES') or '') or 120

-- A small generator of our own, so that a seed means the same thing in every Lua.
local function rng(seed)
	local x = (seed * 2654435761 + 1) & 0xffffffff
	return function(n)
		x = (x * 1664525 + 1013904223) & 0xffffffff
		return ((x >> 8) % n) + 1
	end
end

-- A random network as a grid: rows of belts running right, crossed by columns of splitters on
-- adjacent rows.  It has h inputs and h outputs; some layouts get priorities.
local function random_grid(r, plain)
	local h, cols = r(5) + 1, r(5)
	local grid = {}
	for y = 1, h do grid[y] = { '>' } end
	for _ = 1, cols do
		local used, col = {}, {}
		for y = 1, h do col[y] = '>' end
		for _ = 1, r(h) do
			local y = r(h - 1)
			if not used[y] and not used[y + 1] then
				used[y], used[y + 1] = true, true
				local opt = ''
				if not plain then
					local c = r(8)
					if c == 1 then opt = '[in=left]' elseif c == 2 then opt = '[in=right]' elseif c == 3 then opt = '[out=left]' elseif c == 4 then opt = '[out=right]' end
				end
				col[y], col[y + 1] = 'S>' .. opt, 'S>'
			end
		end
		for y = 1, h do
			table.insert(grid[y], col[y])
			table.insert(grid[y], '>')
		end
	end
	local rows = {}
	for y = 1, h do rows[y] = table.concat(grid[y], ' ') end
	return table.concat(rows, ' \\\\ '), h
end

local function each(plain, f)
	local r = rng(SEED + (plain and 1 or 0))
	for c = 1, CASES do
		local g, h = random_grid(r, plain)
		local ok, err = pcall(f, g, h, c)
		if not ok then
			error(string.format('seed %d, layout %d: %s\n  grid: %s', SEED, c, type(err) == 'table' and (err.beltmap or 'error') or tostring(err), g), 0)
		end
	end
end

local function zero_sum(net, i)
	local total = 0
	for o = 1, net.m do
		local per = NET.belt(net, net.last[net.outputs[o].k])
		total = total + NET.float(per[i])
	end
	return total
end

return {
	{ 'every input\'s shares add up to one', function()
		each(false, function(g)
			local net = T.net(T.grid(g))
			T.ok(NET.shares(net), 'no steady state')
			for i = 1, net.n do
				T.ok(math.abs(zero_sum(net, i) - 1) < 1e-9, 'input ' .. i)
			end
		end)
	end },
	{ 'plain splitters: the share matrix is doubly stochastic', function()
		each(true, function(g)
			local net = T.net(T.grid(g))
			for o = 1, net.m do
				local per, tot = NET.belt(net, net.last[net.outputs[o].k])
				T.ok(math.abs(NET.float(tot) - 1) < 1e-9, 'output ' .. o .. ' carries one belt')
				T.ok(per, 'shares')
			end
		end)
	end },
	{ 'plain splitters: output balance and input balance agree', function()
		each(true, function(g)
			local net = T.net(T.grid(g))
			local out = NET.verdicts(net).balanced
			T.eq(NET.input_balance(T.net(T.grid(g))).balanced, out, 'input balance')
		end)
	end },
	{ 'turning a layout changes no verdict', function()
		each(false, function(g)
			local L = T.grid(g)
			local a = NET.verdicts(T.net(L))
			for turns = 1, 3 do
				local b = NET.verdicts(T.net(bm.rotate(L, turns)))
				T.eq(b.balanced, a.balanced, 'balanced, turned ' .. turns)
				T.eq(b.lanes, a.lanes, 'lanes, turned ' .. turns)
			end
		end)
	end },
	{ 'a blueprint reads back as the same network', function()
		each(false, function(g)
			local L = T.grid(g)
			for _, numbering in ipairs({ 16, 8 }) do
				local s = bm.encode_blueprint(bm.blueprint_of(L, { numbering = numbering }))
				T.eq(#bm.check_blueprint(L, s, numbering), 0, 'the string differs')
				local back = bm.layout_from_text(s, nil, { numbering = numbering })
				T.eq(NET.same_network(T.net(L), T.net(back)), true, 'same network')
			end
		end)
	end },
	{ 'a layout is the same network as itself turned, and the check is symmetric', function()
		local r = rng(SEED + 2)
		each(false, function(g)
			local L = T.grid(g)
			T.eq(NET.same_network(T.net(L), T.net(bm.rotate(L, r(3)))), true, 'turned')
			local g2 = random_grid(r, false)
			local a, b = T.net(L), T.net(T.grid(g2))
			T.eq(NET.same_network(a, b), NET.same_network(b, a), 'symmetric')
		end)
	end },
	{ 'same network implies the same verdicts', function()
		local r = rng(SEED + 3)
		each(true, function(g)
			local g2 = random_grid(r, true)
			local a, b = T.net(T.grid(g)), T.net(T.grid(g2))
			if NET.same_network(a, b) then
				T.eq(NET.verdicts(a).balanced, NET.verdicts(b).balanced, 'balanced')
				T.eq(NET.throughput(a).limited ~= nil, NET.throughput(b).limited ~= nil, 'max-flow')
			end
		end)
	end },
	{ 'full load never beats max-flow or the smaller side', function()
		local r = rng(SEED + 4)
		each(false, function(g)
			local net = T.net(T.grid(g))
			local function subset(n)
				local s = {}
				for i = 1, n do if r(2) == 1 then s[#s + 1] = i end end
				if #s == 0 then s[1] = r(n) end
				return s
			end
			for _ = 1, 3 do
				local I, O = subset(net.n), subset(net.m)
				local f = NET.full_flow(net, I, O)
				T.ok(f <= NET.maxflow_of(net, I, O) + 1e-6, 'above max-flow')
				T.ok(f <= math.min(#I, #O) + 1e-6, 'above the smaller side')
				T.ok(f >= -1e-9, 'negative flow')
			end
		end)
	end },
	{ 'the wire diagram is the same for a network and its turned layout', function()
		each(true, function(g)
			local L = T.grid(g)
			local a = NET.wires(NET.graph(T.net(L)))
			local b = NET.wires(NET.graph(T.net(bm.rotate(L, 2))))
			if a and b then T.eq(a.code, b.code, 'wire code') end
		end)
	end },
	{ 'malformed input gives a beltmap error, never a Lua crash', function()
		local r = rng(SEED + 5)
		local tokens = { '>', '<', '^', 'v', 'S>', 'S<', 'S^', 'Sv', 'I>', 'O>', '.', '_', 'S>[in=left]', 'S>[bad', '\\\\', '??' }
		for c = 1, CASES * 2 do
			local parts = {}
			for i = 1, r(14) do parts[i] = tokens[r(#tokens)] end
			local body = table.concat(parts, ' ')
			local ok, err = pcall(function()
				local L = bm.grid_layout(body)
				return bm.prepare(L, { mix = 'blend', throughput = true, lane_balance = true })
			end)
			if not ok and not (type(err) == 'table' and err.beltmap) then
				error(string.format('seed %d, case %d: a Lua error on grid "%s": %s', SEED, c, body, tostring(err)), 0)
			end
		end
	end },
}
