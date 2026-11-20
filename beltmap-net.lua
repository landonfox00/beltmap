-- Copyright (C) 2026 Landon Fox
--
-- This work may be distributed and/or modified under the conditions of the
-- LaTeX Project Public License, either version 1.3c of this license or (at your
-- option) any later version. The latest version of this license is in
--   https://www.latex-project.org/lppl.txt
-- and version 1.3c or later is part of all distributions of LaTeX version
-- 2008 or later.
--
-- This work has the LPPL maintenance status `maintained'.
-- The Current Maintainer of this work is Landon Fox.
--
-- This work consists of the files beltmap.sty, tikzlibrarybeltmap.code.tex,
-- beltmap.lua, beltmap-net.lua, beltmap_export.py, beltmap-doc.tex, and the
-- files in examples/.

-- beltmap-net.lua: the belt network of a traced layout, and what beltmap.lua computes on it.
--
-- A traced belt (a segment of beltmap.lua's tracer) is cut into pieces where something
-- side-loads onto it; every piece has two lanes, left and right as seen along the belt.
-- On this network:
--   shares()     what each lane carries, exactly (rationals) or in floats when the
--                numbers grow too large: every input lane carries one unit of its own item;
--                a splitter halves what enters it, per lane side, or sends it all to its
--                output-priority side, or to its one side that leads anywhere; a side-load
--                puts both lanes of the incoming belt onto the near lane of the belt it joins.
--   throughput() the max-flow test: every lane has capacity one; for each choice of open
--                inputs I and outputs O, the most that can pass, and a cut when it falls
--                short of min(|I|, |O|) belts.  Passing is necessary for throughput-unlimited,
--                not sufficient: a splitter does not route along a maximum flow.
--   frames()     the shares after t steps of flow, for animations.
--   graph()      the splitter graph: inputs, splitters, merges, outputs, one arc per piece.
-- Belts never fill up in shares(); filters are ignored (every item is the same item).

local N = {}

-- ------------------------------------------------------------------ rationals

local Q = {}
Q.__index = Q

local function gcd(a, b)
	a, b = math.abs(a), math.abs(b)
	while b ~= 0 do a, b = b, a % b end
	return a
end

local BIG = 2.0 ^ 62
local function guard(x)
	if math.abs(x) > BIG then error({ overflow = true }, 0) end
end

local function q(n, d)
	d = d or 1
	if d < 0 then n, d = -n, -d end
	local g = gcd(n, d)
	if g > 1 then n, d = n // g, d // g end
	return setmetatable({ n = n, d = d }, Q)
end
N.q = q

function Q.__add(a, b)
	if a.d == b.d then
		guard(a.n * 1.0 + b.n)
		return q(a.n + b.n, a.d)
	end
	guard(a.n * 1.0 * b.d + b.n * 1.0 * a.d)
	guard(a.d * 1.0 * b.d)
	return q(a.n * b.d + b.n * a.d, a.d * b.d)
end
function Q.__unm(a) return setmetatable({ n = -a.n, d = a.d }, Q) end
function Q.__sub(a, b) return a + (-b) end
function Q.__mul(a, b)
	guard(a.n * 1.0 * b.n)
	guard(a.d * 1.0 * b.d)
	return q(a.n * b.n, a.d * b.d)
end
function Q.__div(a, b)
	guard(a.n * 1.0 * b.d)
	guard(a.d * 1.0 * b.n)
	return q(a.n * b.d, a.d * b.n)
end
function Q.__eq(a, b) return a.n == b.n and a.d == b.d end
function Q.__tostring(a) return a.d == 1 and tostring(a.n) or (a.n .. '/' .. a.d) end
function Q.float(a) return a.n / a.d end

local function is_q(x) return getmetatable(x) == Q end
local function float(x) return is_q(x) and x:float() or x end
N.float = float

-- Gauss-Jordan elimination of A X = B, in place.  exact: entries are rationals.
local function solve(A, B, nb, exact)
	local P = #A
	local function zero(x) if exact then return x.n == 0 end return math.abs(x) < 1e-12 end
	for col = 1, P do
		local piv
		if exact then
			for r = col, P do if not piv and not zero(A[r][col]) then piv = r end end
		else
			local best = 1e-12
			for r = col, P do
				if math.abs(A[r][col]) > best then piv, best = r, math.abs(A[r][col]) end
			end
		end
		if not piv then return nil end
		A[col], A[piv], B[col], B[piv] = A[piv], A[col], B[piv], B[col]
		local p = A[col][col]
		for c = col, P do A[col][c] = A[col][c] / p end
		for i = 1, nb do B[col][i] = B[col][i] / p end
		for r = 1, P do
			local f = A[r][col]
			if r ~= col and not zero(f) then
				for c = col, P do
					if not zero(A[col][c]) then A[r][c] = A[r][c] - f * A[col][c] end
				end
				for i = 1, nb do
					if not zero(B[col][i]) then B[r][i] = B[r][i] - f * B[col][i] end
				end
			end
		end
	end
	return B
end

-- ------------------------------------------------------------------ the network

local function less(a, b)
	if a.x ~= b.x then return a.x < b.x end
	return a.y < b.y
end

-- Sort tiles across the direction of flow, as the labels are numbered.
local function across(flow)
	return function(a, b)
		if flow ~= nil and flow % 2 == 0 then
			if a.y ~= b.y then return a.y < b.y end
			return a.x < b.x
		end
		return less(a, b)
	end
end
N.across = across

local VEC = { [0] = { 1, 0 }, { 0, -1 }, { -1, 0 }, { 0, 1 } }
local function back_of(p, d)
	return { x = p.x - VEC[d][1], y = p.y - VEC[d][2], k = (p.x - VEC[d][1]) .. ',' .. (p.y - VEC[d][2]) }
end

-- LEFT, RIGHT: lane indices.
local LEFT, RIGHT = 1, 2
N.LEFT, N.RIGHT = LEFT, RIGHT

-- A belt is live when what it carries can leave the layout.  blocked: belts known to be full
-- (a loop that only a priority side feeds), which are not live, and neither is anything that
-- leads only into them.
local function compute_live(tr, where, blocked)
	local segs = tr.segs
	local live, changed = {}, true
	while changed do
		changed = false
		for k, s in ipairs(segs) do
			if not live[k] and not blocked[k] then
				local e, v = s['end'], false
				if e[1] == 'out' then
					v = true
				elseif e[1] == 'side' then
					local w = e[2] and where[e[2].k]
					v = w and live[w[1]] or false
				elseif e[1] == 'splitter' then
					local sp = tr.splitters[tr.splitter_of[e[2].k]]
					for i = 1, 2 do
						local t = sp.tiles[i]
						if t and tr.outof[t.k] and live[tr.outof[t.k]] then v = true end
					end
				end
				if v then live[k], changed = true, true end
			end
		end
	end
	return live
end

function N.build(tr)
	local cell, segs = tr.cell, tr.segs
	local where = {}
	for k, s in ipairs(segs) do
		for j, c in ipairs(s.tiles) do where[c.k] = { k, j } end
	end
	-- Side-loads: which belt joins which tile, onto which lane.
	local sides, approx = {}, {}
	for k2, s in ipairs(segs) do
		local e = s['end']
		if e[1] == 'side' and e[2] and where[e[2].k] then
			local w = where[e[2].k]
			local t = cell[e[2].k]
			local along = (t.type == 'belt') and t.input_direction or t.direction
			local lane = (e[3] == (along + 3) % 4) and LEFT or RIGHT
			if t.type ~= 'belt' then approx[#approx + 1] = 'a side-load onto an underground belt' end
			local key = w[1] .. ':' .. w[2]
			sides[key] = sides[key] or {}
			table.insert(sides[key], { k = k2, lane = lane })
		end
	end

	local live = compute_live(tr, where, {})

	local pieces, piece_at, first, last = {}, {}, {}, {}
	for k, s in ipairs(segs) do
		piece_at[k] = {}
		local p = #pieces + 1
		pieces[p] = { k = k, j = 1, sides = sides[k .. ':1'] or {} }
		first[k] = p
		for j = 1, #s.tiles do
			if j > 1 and sides[k .. ':' .. j] then
				p = #pieces + 1
				pieces[p] = { k = k, j = j, sides = sides[k .. ':' .. j] }
			end
			piece_at[k][j] = p
		end
		last[k] = p
	end

	local sources = {}
	for k, s in ipairs(segs) do
		if s.src == nil and #s.tiles > 0 and live[k] then sources[#sources + 1] = k end
	end
	table.sort(sources, function(a, b) return across(tr.flow)(segs[a].tiles[1], segs[b].tiles[1]) end)
	local input_of = {}
	for i, k in ipairs(sources) do input_of[k] = i end

	local outputs = {}
	for k, s in ipairs(segs) do
		if s['end'][1] == 'out' then
			local e = s['end']
			outputs[#outputs + 1] = { k = k, tile = back_of(e[2], e[3]) }
		end
	end
	table.sort(outputs, function(a, b) return across(tr.flow)(a.tile, b.tile) end)
	for o, out in ipairs(outputs) do out.index = o end

	return { tr = tr, pieces = pieces, piece_at = piece_at, first = first, last = last, live = live,
		sources = sources, input_of = input_of, outputs = outputs, n = #sources, m = #outputs, approx = approx,
		where = where, blocked = {} }
end

-- The share of what enters splitter sp that leaves by its tile t.
local function share(net, sp, t)
	local tr, live = net.tr, net.live
	local open = {}
	for i = 1, 2 do
		local u = sp.tiles[i]
		if u and tr.outof[u.k] and live[tr.outof[u.k]] then open[#open + 1] = u end
	end
	if #open == 0 then return 0, 1 end
	local prio = (not sp.filter) and sp.output and sp.tiles[sp.output == 'right' and 1 or 2] or nil
	if prio and tr.outof[prio.k] and live[tr.outof[prio.k]] then return (prio.k == t.k) and 1 or 0, 1 end
	for _, u in ipairs(open) do
		if u.k == t.k then return 1, #open end
	end
	return 0, 1
end

-- The linear system of the lane flows: unknown (p, lane) at row 2p - 2 + lane; one right-hand
-- column per input lane, 2i - 2 + lane.  Returns rows of { [col] = coefficient } and b.
local function system(net)
	local tr, segs = net.tr, net.tr.segs
	local rows, rhs = {}, {}
	local function idx(p, l) return 2 * p - 2 + l end
	for p, pc in ipairs(net.pieces) do
		local k, j = pc.k, pc.j
		local s = segs[k]
		for l = LEFT, RIGHT do
			local r = idx(p, l)
			local row, b = {}, {}
			if net.live[k] then
				if j == 1 and s.src then
					local sp = tr.splitters[tr.splitter_of[s.src.k]]
					local num, den = share(net, sp, s.src)
					for i = 1, 2 do
						local u = sp.tiles[i]
						local qk = u and tr.into[u.k]
						if qk and num > 0 then row[#row + 1] = { idx(net.last[qk], l), num, den } end
					end
				elseif j == 1 then
					local i = net.input_of[k]
					if i then b[2 * i - 2 + l] = true end
				else
					row[#row + 1] = { idx(net.piece_at[k][j - 1], l), 1, 1 }
				end
				for _, sd in ipairs(pc.sides) do
					if sd.lane == l then
						row[#row + 1] = { idx(net.last[sd.k], LEFT), 1, 1 }
						row[#row + 1] = { idx(net.last[sd.k], RIGHT), 1, 1 }
					end
				end
			end
			rows[r], rhs[r] = row, b
		end
	end
	return rows, rhs
end

-- Loops that fill up.  With output priority a splitter sends everything to one side, so a loop
-- fed only through priority sides takes in flow and lets none out: in the game it fills, and
-- then the splitter overflows to its other side.  Such a loop is a closed class of pieces, a
-- strongly connected set that no flow leaves; its belts are marked full (blocked) and the
-- liveness is worked out again, until no closed class is left.  Returns the rows and rhs.
local function settle(net)
	for _ = 1, 32 do
		local rows, rhs = system(net)
		local P = #net.pieces
		local nxt = {}
		for p = 1, P do nxt[p] = {} end
		for r, row in pairs(rows) do
			local pr = (r + 1) // 2
			for _, t in ipairs(row) do
				if t[2] > 0 then nxt[(t[1] + 1) // 2][pr] = true end
			end
		end
		local exit = {}
		for _, o in ipairs(net.outputs) do exit[net.last[o.k]] = true end
		-- Tarjan's strongly connected components over the live pieces.
		local index, low, onstack, stack, comp, counter = {}, {}, {}, {}, {}, 0
		local comps = {}
		local function visit(v)
			counter = counter + 1
			index[v], low[v] = counter, counter
			stack[#stack + 1] = v
			onstack[v] = true
			for w in pairs(nxt[v]) do
				if net.live[net.pieces[w].k] then
					if not index[w] then
						visit(w)
						low[v] = math.min(low[v], low[w])
					elseif onstack[w] then
						low[v] = math.min(low[v], index[w])
					end
				end
			end
			if low[v] == index[v] then
				local c = {}
				repeat
					local w = table.remove(stack)
					onstack[w] = false
					comp[w] = #comps + 1
					c[#c + 1] = w
				until w == v
				comps[#comps + 1] = c
			end
		end
		for p = 1, P do
			if net.live[net.pieces[p].k] and not index[p] then visit(p) end
		end
		local trapped = false
		for ci, c in ipairs(comps) do
			local closed = (#c > 1) or nxt[c[1]][c[1]]
			for _, v in ipairs(c) do
				if exit[v] then closed = false end
				for w in pairs(nxt[v]) do
					if comp[w] ~= ci and net.live[net.pieces[w].k] then closed = false end
				end
			end
			if closed then
				for _, v in ipairs(c) do net.blocked[net.pieces[v].k] = true end
				trapped = true
			end
		end
		if not trapped then return rows, rhs end
		net.live = compute_live(net.tr, net.where, net.blocked)
		net.full = true
	end
	return system(net)
end

-- x[p][l][c]: what lane l of piece p carries of input lane c (c = 2i - 2 + lane).
-- Exact rationals when they fit, floats otherwise (net.exact says which).
function N.shares(net)
	if net.x then return net.x end
	local rows, rhs = settle(net)
	local P2, nb = #rows, 2 * net.n
	local function attempt(exact)
		local zero, one = exact and q(0) or 0, exact and q(1) or 1
		local A, B = {}, {}
		for r = 1, P2 do
			A[r], B[r] = {}, {}
			for c = 1, P2 do A[r][c] = zero end
			A[r][r] = one
			for i = 1, nb do B[r][i] = rhs[r][i] and one or zero end
			for _, t in ipairs(rows[r]) do
				local v = exact and q(t[2], t[3]) or t[2] / t[3]
				A[r][t[1]] = A[r][t[1]] - v
			end
		end
		return solve(A, B, nb, exact)
	end
	local ok, X = pcall(attempt, true)
	net.exact = ok and X ~= nil
	if not ok then
		if type(X) ~= 'table' or not X.overflow then error(X, 0) end
		X = attempt(false)
	end
	if not X then return nil end
	local x = {}
	for p = 1, #net.pieces do
		x[p] = { X[2 * p - 1], X[2 * p] }
	end
	net.x = x
	return x
end

-- What piece p carries of input i, as a share of one belt (both lanes of the input), and in all.
function N.belt(net, p)
	local x = N.shares(net)
	local exact = net.exact
	local zero = exact and q(0) or 0
	local per, tot = {}, zero
	for i = 1, net.n do
		local v = zero
		for l = LEFT, RIGHT do
			v = v + x[p][l][2 * i - 1] + x[p][l][2 * i]
		end
		v = exact and v / q(2) or v / 2
		per[i] = v
		tot = tot + v
	end
	return per, tot
end

-- Verdicts.  balanced: each output carries 1/m of every input.  lanes: each output lane carries
-- 1/m of each input lane on its own side and nothing of the other side.
function N.verdicts(net)
	local x = N.shares(net)
	if not x then return nil end
	local n, m = net.n, net.m
	local exact = net.exact
	local function eq(a, b)
		if exact and is_q(a) and is_q(b) then return a == b end
		return math.abs(float(a) - float(b)) < 1e-9
	end
	local target = exact and q(1, math.max(m, 1)) or 1 / math.max(m, 1)
	local zero = exact and q(0) or 0
	local worst = nil
	for _, out in ipairs(net.outputs) do
		local per = N.belt(net, net.last[out.k])
		out.per = per
		for i = 1, n do
			if not eq(per[i], target) then
				local dev = math.abs(float(per[i]) - float(target))
				if not worst or dev > worst.dev then worst = { dev = dev, o = out.index, i = i, v = per[i] } end
			end
		end
	end
	local lane_bad = nil
	for _, out in ipairs(net.outputs) do
		local p = net.last[out.k]
		for l = LEFT, RIGHT do
			for i = 1, n do
				for l2 = LEFT, RIGHT do
					local want = (l == l2) and target or zero
					local v = x[p][l][2 * i - 2 + l2]
					if not lane_bad and not eq(v, want) then
						lane_bad = { o = out.index, l = l, i = i, l2 = l2, v = v, want = want }
					end
				end
			end
		end
	end
	return { balanced = (m > 0 and worst == nil), worst = worst, target = target, lanes = (m > 0 and lane_bad == nil), lane_bad = lane_bad }
end

-- ------------------------------------------------------------------ throughput

-- A flow network with integer capacities, and Edmonds-Karp.
local function flownet()
	local G = { head = {}, to = {}, cap = {}, nxt = {}, base = {} }
	function G.edge(u, v, c)
		local e = #G.to + 1
		G.to[e], G.cap[e], G.base[e], G.nxt[e] = v, c, c, G.head[u]
		G.head[u] = e
		G.to[e + 1], G.cap[e + 1], G.base[e + 1], G.nxt[e + 1] = u, 0, 0, G.head[v]
		G.head[v] = e + 1
		return e
	end
	function G.reset()
		for e = 1, #G.cap do G.cap[e] = G.base[e] end
	end
	function G.maxflow(s, t, limit)
		local flow = 0
		while flow < limit do
			local prev, queue, qi = { [s] = 0 }, { s }, 1
			while qi <= #queue and prev[t] == nil do
				local u = queue[qi]
				qi = qi + 1
				local e = G.head[u]
				while e do
					local v = G.to[e]
					if G.cap[e] > 0 and prev[v] == nil then
						prev[v] = e
						queue[#queue + 1] = v
					end
					e = G.nxt[e]
				end
			end
			if prev[t] == nil then break end
			local f, v = math.huge, t
			while v ~= s do
				local e = prev[v]
				f = math.min(f, G.cap[e])
				v = G.to[e % 2 == 1 and e + 1 or e - 1]
			end
			v = t
			while v ~= s do
				local e = prev[v]
				local r = (e % 2 == 1) and e + 1 or e - 1
				G.cap[e], G.cap[r] = G.cap[e] - f, G.cap[r] + f
				v = G.to[r]
			end
			flow = flow + f
		end
		return flow
	end
	function G.reach(s)
		local seen, stack = { [s] = true }, { s }
		while #stack > 0 do
			local u = table.remove(stack)
			local e = G.head[u]
			while e do
				if G.cap[e] > 0 and not seen[G.to[e]] then
					seen[G.to[e]] = true
					stack[#stack + 1] = G.to[e]
				end
				e = G.nxt[e]
			end
		end
		return seen
	end
	return G
end

-- For every nonempty set I of inputs and O of outputs (only |I| = |O| when there are more
-- than 4096 choices), the maximum flow in belts with every lane of capacity one.  Returns
-- { tested, limited = { I, O, flow, need, cut = { {piece, lane} } } or nil, rule }.
function N.throughput(net)
	if net.tp then return net.tp end
	local tr, segs = net.tr, net.tr.segs
	local G = flownet()
	local INF = 1000000
	local id = 0
	local function node() id = id + 1 return id end
	local S, T = node(), node()
	local lin, lout, lane_edge = {}, {}, {}
	for p, pc in ipairs(net.pieces) do
		if net.live[pc.k] then
			lin[p], lout[p], lane_edge[p] = {}, {}, {}
			for l = LEFT, RIGHT do
				lin[p][l], lout[p][l] = node(), node()
				lane_edge[p][l] = G.edge(lin[p][l], lout[p][l], 1)
			end
		end
	end
	local spl = {}
	for s = 1, #tr.splitters do spl[s] = { node(), node() } end
	for p, pc in ipairs(net.pieces) do
		if lin[p] then
			local k, j = pc.k, pc.j
			local seg = segs[k]
			for l = LEFT, RIGHT do
				if j == 1 and seg.src then
					local s = tr.splitter_of[seg.src.k]
					G.edge(spl[s][l], lin[p][l], INF)
				elseif j > 1 then
					local prev = net.piece_at[k][j - 1]
					if lout[prev] then G.edge(lout[prev][l], lin[p][l], INF) end
				end
			end
			for _, sd in ipairs(pc.sides) do
				local q2 = net.last[sd.k]
				if lout[q2] then
					G.edge(lout[q2][LEFT], lin[p][sd.lane], INF)
					G.edge(lout[q2][RIGHT], lin[p][sd.lane], INF)
				end
			end
			if p == net.last[k] then
				local e = seg['end']
				if e[1] == 'splitter' then
					local s = tr.splitter_of[e[2].k]
					for l = LEFT, RIGHT do G.edge(lout[p][l], spl[s][l], INF) end
				end
			end
		end
	end
	-- Source and sink arcs, switched on per choice.
	local src_e, snk_e = {}, {}
	for i, k in ipairs(net.sources) do
		local p = net.first[k]
		src_e[i] = { G.edge(S, lin[p][LEFT], 0), G.edge(S, lin[p][RIGHT], 0) }
	end
	for o, out in ipairs(net.outputs) do
		local p = net.last[out.k]
		snk_e[o] = { G.edge(lout[p][LEFT], T, 0), G.edge(lout[p][RIGHT], T, 0) }
	end
	local n, m = net.n, net.m
	local all = (2 ^ n - 1) * (2 ^ m - 1) <= 4096
	local function members(mask, size)
		local list = {}
		for i = 1, size do if (mask >> (i - 1)) & 1 == 1 then list[#list + 1] = i end end
		return list
	end
	local tested, worst = 0, nil
	for mi = 1, (1 << n) - 1 do
		local I = members(mi, n)
		for mo = 1, (1 << m) - 1 do
			local O = members(mo, m)
			if all or #I == #O then
				tested = tested + 1
				for i = 1, n do
					local on = (mi >> (i - 1)) & 1
					for _, e in ipairs(src_e[i]) do G.base[e] = on end
				end
				for o = 1, m do
					local on = (mo >> (o - 1)) & 1
					for _, e in ipairs(snk_e[o]) do G.base[e] = on end
				end
				G.reset()
				local need = math.min(#I, #O)
				local f = G.maxflow(S, T, 2 * need)
				if f < 2 * need then
					local short = (2 * need - f) / (2 * need)
					if not worst or short > worst.short or (short == worst.short and #I + #O < #worst.I + #worst.O) then
						local seen = G.reach(S)
						local cut = {}
						for p in pairs(lin) do
							for l = LEFT, RIGHT do
								if seen[lin[p][l]] and not seen[lout[p][l]] then cut[#cut + 1] = { p, l } end
							end
						end
						table.sort(cut, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
						worst = { I = I, O = O, flow = f / 2, need = need, short = short, cut = cut }
					end
				end
			end
		end
	end
	net.tp = { tested = tested, limited = worst, rule = all and 'every' or 'equal' }
	return net.tp
end

-- ------------------------------------------------------------------ frames

-- The lane flows after t steps (t = 0: nothing has entered), in floats: each step moves
-- flow one piece on.  Returns a list of frames, each x[p][l][c], ending at the steady state:
-- once a step changes little, the exact shares are the last frame.  nil when the flow has no
-- steady state.
function N.frames(net, limit)
	local exact = N.shares(net)
	if not exact then return nil end
	local rows, rhs = system(net)
	local P2, nb = #rows, 2 * net.n
	local cur = {}
	for r = 1, P2 do
		cur[r] = {}
		for c = 1, nb do cur[r][c] = 0 end
	end
	local function snapshot(X)
		local x = {}
		for p = 1, #net.pieces do x[p] = { X[2 * p - 1], X[2 * p] } end
		return x
	end
	local frames = { snapshot(cur) }
	for _ = 1, limit or 80 do
		local nxt, delta = {}, 0
		for r = 1, P2 do
			nxt[r] = {}
			for c = 1, nb do
				local v = rhs[r][c] and 1 or 0
				for _, t in ipairs(rows[r]) do v = v + (t[2] / t[3]) * cur[t[1]][c] end
				nxt[r][c] = v
				delta = math.max(delta, math.abs(v - cur[r][c]))
			end
		end
		cur = nxt
		if delta < 2e-3 then break end
		frames[#frames + 1] = snapshot(cur)
	end
	local final = {}
	for p = 1, #net.pieces do
		final[p] = {}
		for l = LEFT, RIGHT do
			final[p][l] = {}
			for c = 1, nb do final[p][l][c] = float(exact[p][l][c]) end
		end
	end
	frames[#frames + 1] = final
	return frames
end

-- ------------------------------------------------------------------ the splitter graph

-- Nodes: in i, out o, s j (splitter j of the trace), m p (a merge where piece p starts by a
-- side-load).  Arcs: one per live piece that has an end, { from, to, piece }.
function N.graph(net)
	local tr, segs = net.tr, net.tr.segs
	local nodes, arcs = {}, {}
	local function add(name, kind, label)
		if not nodes[name] then
			nodes[name] = { name = name, kind = kind, label = label }
			nodes[#nodes + 1] = nodes[name]
		end
		return name
	end
	for i = 1, net.n do add('in' .. i, 'input', tostring(i)) end
	local start = {}
	for p, pc in ipairs(net.pieces) do
		local seg = segs[pc.k]
		local from
		if pc.j == 1 and seg.src then
			from = add('s' .. tr.splitter_of[seg.src.k], 'splitter', 'S' .. tr.splitter_of[seg.src.k])
		elseif pc.j == 1 then
			local i = net.input_of[pc.k]
			from = i and ('in' .. i) or nil
		else
			from = nil -- set below: the merge of this piece
		end
		if #pc.sides > 0 then
			local mname = add('m' .. p, 'merge', '')
			if from then arcs[#arcs + 1] = { from, mname, nil, lead = true } end
			from = mname
		elseif pc.j > 1 then
			from = add('m' .. p, 'merge', '')
		end
		start[p] = from
	end
	for o, out in ipairs(net.outputs) do add('out' .. o, 'output', tostring(o)) end
	local out_of = {}
	for _, out in ipairs(net.outputs) do out_of[out.k] = out.index end
	for p, pc in ipairs(net.pieces) do
		local k = pc.k
		if net.live[k] and start[p] then
			local to
			if p ~= net.last[k] then
				to = start[p + 1]
			else
				local e = segs[k]['end']
				if e[1] == 'splitter' then
					local s = tr.splitter_of[e[2].k]
					to = add('s' .. s, 'splitter', 'S' .. s)
				elseif e[1] == 'out' then
					to = 'out' .. out_of[k]
				elseif e[1] == 'side' then
					-- the merge of the piece it joins
					for p2, pc2 in ipairs(net.pieces) do
						for _, sd in ipairs(pc2.sides) do
							if sd.k == k then to = start[p2] end
						end
					end
				end
			end
			if to then arcs[#arcs + 1] = { start[p], to, p } end
		end
	end
	-- Fix the lead arcs: they carry the piece that the merge starts.
	for _, a in ipairs(arcs) do
		if a.lead then
			for p, _ in ipairs(net.pieces) do
				if start[p] == a[2] then a[3] = p end
			end
		end
	end
	return { nodes = nodes, arcs = arcs }
end

-- Positions for the graph, in units of about a centimeter: inputs pinned in a column on the
-- left, outputs on the right.  Splitters and merges get a column each, the
-- longest path to them from the inputs once the loops are cut, and then a force layout
-- (Fruchterman and Reingold) places them: every pair of nodes repels, every arc pulls its ends
-- together, and every node, inputs and outputs too, moves only up and down in its column, so
-- the inputs and outputs fall in whatever order the forces give.  Last, nodes in a column are pushed
-- apart until none overlaps.  Deterministic: no random numbers.  Returns the positions and
-- { back = the arcs that close loops, col = the columns }.
function N.layout(g, opts)
	opts = opts or {}
	local nodes, arcs = g.nodes, g.arcs
	local ins, outs, free = {}, {}, {}
	local kind = {}
	for _, nd in ipairs(nodes) do
		kind[nd.name] = nd.kind
		if nd.kind == 'input' then ins[#ins + 1] = nd
		elseif nd.kind == 'output' then outs[#outs + 1] = nd
		else free[#free + 1] = nd end
	end
	local succ = {}
	for i, a in ipairs(arcs) do
		succ[a[1]] = succ[a[1]] or {}
		table.insert(succ[a[1]], i)
	end
	-- Loops: a depth-first walk from the inputs marks the arcs back to a node on its stack;
	-- without them the network is acyclic, and each node's column is its longest path.
	local back, state = {}, {}
	local function dfs(u)
		state[u] = 1
		for _, i in ipairs(succ[u] or {}) do
			local v = arcs[i][2]
			if state[v] == 1 then
				back[i] = true
			elseif state[v] == nil then
				dfs(v)
			end
		end
		state[u] = 2
	end
	for _, nd in ipairs(ins) do dfs(nd.name) end
	for _, nd in ipairs(free) do if state[nd.name] == nil then dfs(nd.name) end end
	local col = {}
	for _, nd in ipairs(nodes) do col[nd.name] = 0 end
	for _ = 1, #nodes do
		local changed = false
		for i, a in ipairs(arcs) do
			if not back[i] and col[a[2]] < col[a[1]] + 1 then
				col[a[2]] = col[a[1]] + 1
				changed = true
			end
		end
		if not changed then break end
	end
	local last = 1
	for _, nd in ipairs(free) do last = math.max(last, col[nd.name] + 1) end
	for _, nd in ipairs(ins) do col[nd.name] = 0 end
	for _, nd in ipairs(outs) do col[nd.name] = last end

	local dx = opts.dx or 1.5
	local gap = opts.dy or 1.0
	local H = (math.max(#ins, #outs, 2) - 1) * gap
	local pos = {}
	local function column(list, x)
		for i, nd in ipairs(list) do
			local y = (#list == 1) and 0 or (H / 2 - (i - 1) * H / (#list - 1))
			pos[nd.name] = { x, y }
		end
	end
	column(ins, 0)
	column(outs, last * dx)
	-- Start: each free node at its column, at the mean height of what feeds it.
	local order = {}
	for _, nd in ipairs(free) do order[#order + 1] = nd end
	table.sort(order, function(a, b) return col[a.name] < col[b.name] or (col[a.name] == col[b.name] and a.name < b.name) end)
	for idx, nd in ipairs(order) do
		local s, c = 0, 0
		for i, a in ipairs(arcs) do
			if a[2] == nd.name and pos[a[1]] and not back[i] then s, c = s + pos[a[1]][2], c + 1 end
		end
		local y = (c > 0) and s / c or 0
		pos[nd.name] = { col[nd.name] * dx, y + 0.01 * idx }
	end
	-- Forces.  Repulsion counts height twice as much as width, as a splitter is twice as tall
	-- as wide; arcs pull their ends together; every free node is held to its column by a
	-- spring of its own.
	local size = { splitter = 1.0, merge = 0.35, input = 0.6, output = 0.6 }
	local k = opts.k or 1.0
	local iters = opts.iterations or 500
	local temp = 0.5
	for it = 1, iters do
		local disp = {}
		for _, nd in ipairs(nodes) do disp[nd.name] = { 0, 0 } end
		for i = 1, #nodes do
			local a = nodes[i]
			for j = i + 1, #nodes do
				local b = nodes[j]
				if disp[a.name] or disp[b.name] then
					local pa, pb = pos[a.name], pos[b.name]
					local ddx, ddy = pa[1] - pb[1], (pa[2] - pb[2]) * 0.6
					local d2 = ddx * ddx + ddy * ddy
					if d2 < 1e-6 then ddx, ddy, d2 = 0, 0.01 * (j - i), 1e-4 end
					local d = math.sqrt(d2)
					local f = k * k * (size[a.kind] + size[b.kind]) / 2 / d
					local fx, fy = ddx / d * f, ddy / d * f * 1.6
					if disp[a.name] then disp[a.name][1], disp[a.name][2] = disp[a.name][1] + fx, disp[a.name][2] + fy end
					if disp[b.name] then disp[b.name][1], disp[b.name][2] = disp[b.name][1] - fx, disp[b.name][2] - fy end
				end
			end
		end
		for i, arc in ipairs(arcs) do
			local pa, pb = pos[arc[1]], pos[arc[2]]
			local ddx, ddy = pb[1] - pa[1], pb[2] - pa[2]
			local d = math.max(math.sqrt(ddx * ddx + ddy * ddy), 1e-3)
			local f = d * d / k * (back[i] and 0.3 or 1)
			local fx, fy = ddx / d * f, ddy / d * f
			if disp[arc[1]] then disp[arc[1]][1], disp[arc[1]][2] = disp[arc[1]][1] + fx, disp[arc[1]][2] + fy end
			if disp[arc[2]] then disp[arc[2]][1], disp[arc[2]][2] = disp[arc[2]][1] - fx, disp[arc[2]][2] - fy end
		end
		for _, nd in ipairs(nodes) do
			-- Columns stay put: the forces move nodes up and down only.
			local p, d = pos[nd.name], disp[nd.name]
			local len = math.abs(d[2])
			if len > 1e-9 then
				p[2] = p[2] + d[2] / len * math.min(len, temp)
			end
		end
		temp = 0.5 * (1 - it / iters) + 0.005
	end
	-- No two nodes overlap: in each column, from top to bottom, a node keeps at least the
	-- half heights of both apart from the one above; then the column is centered again.
	local HALF = { splitter = 0.5, merge = 0.15, input = 0.3, output = 0.3 }
	local bycol = {}
	for _, nd in ipairs(nodes) do
		local c = col[nd.name]
		bycol[c] = bycol[c] or {}
		table.insert(bycol[c], nd)
	end
	for _, list in pairs(bycol) do
		table.sort(list, function(a, b) return pos[a.name][2] > pos[b.name][2] end)
		local before = 0
		for _, nd in ipairs(list) do before = before + pos[nd.name][2] end
		for i = 2, #list do
			local a, b = list[i - 1], list[i]
			local need = HALF[a.kind] + HALF[b.kind] + 0.35
			if pos[a.name][2] - pos[b.name][2] < need then pos[b.name][2] = pos[a.name][2] - need end
		end
		local after = 0
		for _, nd in ipairs(list) do after = after + pos[nd.name][2] end
		local shift = (before - after) / #list
		for _, nd in ipairs(list) do pos[nd.name][2] = pos[nd.name][2] + shift end
	end
	return pos, { back = back, col = col }
end

return N
