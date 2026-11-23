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
--   full_load()  a fluid model of full belts, compared with Factorio in tests/game.
--   lane_balance()  whether the two lanes of every output carry the same of every input lane.
--   same_network()  whether two networks are one, up to renaming.
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

-- Where belt s side-loads: the tile it joins (w = { belt, tile index }), the near lane it lands
-- on, and, onto an underground belt, the one incoming lane that gets on.  Measured in Factorio
-- 2.1.24: the hood blocks the lane on its side, so an entrance takes the upstream lane of the
-- incoming belt and an exit the downstream lane.
local function side_target(tr, where, s)
	local e = s['end']
	if e[1] ~= 'side' or not e[2] then return nil end
	local w = where[e[2].k]
	if not w then return nil end
	local t = tr.cell[e[2].k]
	local along = (t.type == 'belt') and t.input_direction or t.direction
	local lane = (e[3] == (along + 3) % 4) and LEFT or RIGHT
	local only
	if t.type ~= 'belt' then
		-- Coming from the left of the target, the incoming belt's right lane is upstream.
		local upstream = (lane == LEFT) and RIGHT or LEFT
		only = t.is_input and upstream or (3 - upstream)
	end
	return { w = w, lane = lane, only = only }
end

-- A lane is live when what it carries can leave the layout, and a belt when either lane is.
-- blocked: belts known to be full (a loop that only a priority side feeds), which are not live,
-- and neither is anything that leads only into them.  Returns live[k] and lanes[k][l].
local function compute_live(tr, where, blocked)
	local segs = tr.segs
	local lanes, changed = {}, true
	for k in ipairs(segs) do lanes[k] = { false, false } end
	while changed do
		changed = false
		for k, s in ipairs(segs) do
			if not blocked[k] then
				local e = s['end']
				for l = LEFT, RIGHT do
					if not lanes[k][l] then
						local v = false
						if e[1] == 'out' then
							v = true
						elseif e[1] == 'side' then
							local st = side_target(tr, where, s)
							v = st and (not st.only or st.only == l) and lanes[st.w[1]][st.lane] or false
						elseif e[1] == 'splitter' then
							local sp = tr.splitters[tr.splitter_of[e[2].k]]
							for i = 1, 2 do
								local t = sp.tiles[i]
								if t and tr.outof[t.k] and lanes[tr.outof[t.k]][l] then v = true end
							end
						end
						if v then lanes[k][l], changed = true, true end
					end
				end
			end
		end
	end
	local live = {}
	for k in ipairs(segs) do
		if lanes[k][LEFT] or lanes[k][RIGHT] then live[k] = true end
	end
	return live, lanes
end

function N.build(tr)
	local segs = tr.segs
	local where = {}
	for k, s in ipairs(segs) do
		for j, c in ipairs(s.tiles) do where[c.k] = { k, j } end
	end
	-- Side-loads: which belt joins which tile, onto which lane.
	local sides = {}
	for k2, s in ipairs(segs) do
		local st = side_target(tr, where, s)
		if st then
			local key = st.w[1] .. ':' .. st.w[2]
			sides[key] = sides[key] or {}
			table.insert(sides[key], { k = k2, lane = st.lane, only = st.only })
		end
	end

	local live, lane_live = compute_live(tr, where, {})

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
		if s.src == nil and #s.tiles > 0 and live[k] and not sides[k .. ':1'] then sources[#sources + 1] = k end
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
		lane_live = lane_live, sources = sources, input_of = input_of, outputs = outputs, n = #sources,
		m = #outputs, where = where, blocked = {} }
end

-- The share of what enters splitter sp on lane l that leaves by its tile t.
local function share(net, sp, t, l)
	local tr, lanes = net.tr, net.lane_live
	local open = {}
	for i = 1, 2 do
		local u = sp.tiles[i]
		if u and tr.outof[u.k] and lanes[tr.outof[u.k]][l] then open[#open + 1] = u end
	end
	if #open == 0 then return 0, 1 end
	local prio = (not sp.filter) and sp.output and sp.tiles[sp.output == 'right' and 1 or 2] or nil
	if prio and tr.outof[prio.k] and lanes[tr.outof[prio.k]][l] then return (prio.k == t.k) and 1 or 0, 1 end
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
					local num, den = share(net, sp, s.src, l)
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
						for l2 = LEFT, RIGHT do
							if not sd.only or sd.only == l2 then row[#row + 1] = { idx(net.last[sd.k], l2), 1, 1 } end
						end
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
		net.live, net.lane_live = compute_live(net.tr, net.where, net.blocked)
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

local THROUGHPUT_MAX = 20000
N.THROUGHPUT_MAX = THROUGHPUT_MAX

-- n choose k, as a float: a count of choices, compared with a limit.
local function choose(n, k)
	local c = 1.0
	for i = 1, k do c = c * (n - k + i) / i end
	return math.floor(c + 0.5)
end

-- The next integer with as many one bits (Gosper's hack), so subsets of one size come in order.
local function next_subset(x)
	local c = x & -x
	local r = x + c
	return (((r ~ x) >> 2) // c) | r
end

-- The lane network as a flow graph, with the arcs from the source and to the sink switched off.
local function flow_graph(net)
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
					for l2 = LEFT, RIGHT do
						if not sd.only or sd.only == l2 then G.edge(lout[q2][l2], lin[p][sd.lane], INF) end
					end
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
	return G, S, T, src_e, snk_e, lin, lout
end

-- For every set I of inputs and O of outputs of one size, the maximum flow in belts with every
-- lane of capacity one, up to THROUGHPUT_MAX choices.  Returns { tested, total, partial,
-- limited = { I, O, flow, need, short, cut = { {piece, lane} } } or nil }; partial: not every
-- choice was tried, so a missing limit proves nothing.
function N.throughput(net)
	if net.tp then return net.tp end
	local G, S, T, src_e, snk_e, lin, lout = flow_graph(net)
	local n, m = net.n, net.m
	local function members(mask, size)
		local list = {}
		for i = 1, size do if (mask >> (i - 1)) & 1 == 1 then list[#list + 1] = i end end
		return list
	end
	-- Choices with |I| = |O| decide all of them.  Flow only grows with I and O, so a choice with
	-- |I| < |O| carries at least what I carries to any |I| of its outputs, and the same way round;
	-- and the worst shortfall of any choice is reached by one of equal size.
	local total = 0.0
	for k = 1, math.min(n, m) do total = total + choose(n, k) * choose(m, k) end
	local tested, worst, partial = 0, nil, false
	for k = 1, math.min(n, m) do
		local mi, top_i, top_o = (1 << k) - 1, 1 << n, 1 << m
		while mi < top_i and not partial do
			local I = members(mi, n)
			local mo = (1 << k) - 1
			while mo < top_o do
				if tested >= THROUGHPUT_MAX then
					partial = true
					break
				end
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
				local f = G.maxflow(S, T, 2 * k)
				if f < 2 * k then
					local short = (2 * k - f) / (2 * k)
					if not worst or short > worst.short then
						local seen = G.reach(S)
						local cut = {}
						for p in pairs(lin) do
							for l = LEFT, RIGHT do
								if seen[lin[p][l]] and not seen[lout[p][l]] then cut[#cut + 1] = { p, l } end
							end
						end
						table.sort(cut, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
						worst = { I = I, O = members(mo, m), flow = f / 2, need = k, short = short, cut = cut }
					end
				end
				mo = next_subset(mo)
			end
			mi = next_subset(mi)
		end
		if partial then break end
	end
	net.tp = { tested = tested, total = total, limited = worst, partial = partial }
	return net.tp
end

-- The maximum flow from inputs I to outputs O, in belts.
function N.maxflow_of(net, I, O)
	local G, S, T, src_e, snk_e = flow_graph(net)
	for _, i in ipairs(I) do
		for _, e in ipairs(src_e[i]) do G.base[e] = 1 end
	end
	for _, o in ipairs(O) do
		for _, e in ipairs(snk_e[o]) do G.base[e] = 1 end
	end
	G.reset()
	return G.maxflow(S, T, 2 * math.min(#I, #O)) / 2
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

-- ------------------------------------------------------------------ demand

-- Demand: the network read backwards, as at full backpressure.  Every output asks for one unit
-- of its own kind; a splitter or merge passes what is asked of it to the belts that feed it,
-- evenly, or all of it to its input-priority side when that side is live (a backed-up splitter
-- takes from both inputs alike unless one has priority).  Solved exactly, like the shares.
-- Returns { g, arc = d[idx][o], supply = s[i][o] (what input i supplies of output o's demand),
-- exact } or nil when the demand has no steady state.
function N.demand(net)
	local tr = net.tr
	local g = N.graph(net)
	local m = net.m
	local kind, ins, outs = {}, {}, {}
	for _, nd in ipairs(g.nodes) do kind[nd.name], ins[nd.name], outs[nd.name] = nd.kind, {}, {} end
	for idx, a in ipairs(g.arcs) do
		table.insert(outs[a[1]], idx)
		table.insert(ins[a[2]], idx)
	end
	-- the in-arc of each splitter node that has input priority, when that side is fed
	local prio = {}
	for name, k in pairs(kind) do
		if k == 'splitter' then
			local sp = tr.splitters[tonumber(name:sub(2))]
			local t = sp and sp.input and sp.tiles[sp.input == 'right' and 1 or 2]
			local seg = t and tr.into[t.k]
			if seg then
				for _, idx in ipairs(ins[name]) do
					if g.arcs[idx][3] == net.last[seg] then prio[name] = idx end
				end
			end
		end
	end
	local A = #g.arcs
	local out_of = {}
	for _, out in ipairs(net.outputs) do out_of['out' .. out.index] = out.index end
	local function attempt(exact)
		local zero, one = exact and q(0) or 0, exact and q(1) or 1
		local M_, B = {}, {}
		for r = 1, A do
			M_[r], B[r] = {}, {}
			for c = 1, A do M_[r][c] = zero end
			M_[r][r] = one
			for o = 1, m do B[r][o] = zero end
			local v = g.arcs[r][2]
			local nin = #ins[v]
			if kind[v] == 'output' then
				B[r][out_of[v]] = exact and q(1, nin) or 1 / nin
			elseif prio[v] then
				if prio[v] == r then
					for _, e2 in ipairs(outs[v]) do M_[r][e2] = M_[r][e2] - one end
				end
			else
				for _, e2 in ipairs(outs[v]) do
					M_[r][e2] = M_[r][e2] - (exact and q(1, nin) or 1 / nin)
				end
			end
		end
		return solve(M_, B, m, exact)
	end
	local ok, X = pcall(attempt, true)
	local exact = ok and X ~= nil
	if not ok then
		if type(X) ~= 'table' or not X.overflow then error(X, 0) end
		X = attempt(false)
	end
	if not X then return nil end
	local supply = {}
	for idx, a in ipairs(g.arcs) do
		if kind[a[1]] == 'input' then
			local i = tonumber(a[1]:sub(3))
			supply[i] = supply[i] or {}
			for o = 1, m do supply[i][o] = supply[i][o] and (supply[i][o] + X[idx][o]) or X[idx][o] end
		end
	end
	return { g = g, arc = X, supply = supply, exact = exact }
end

-- Input balance: each input supplies 1/n of every output's demand (the dual of balance).
-- Returns { balanced, worst = { i, o, v, target } } or nil.
function N.input_balance(net)
	local D = N.demand(net)
	if not D then return nil end
	local n, m = net.n, net.m
	local target = D.exact and q(1, math.max(n, 1)) or 1 / math.max(n, 1)
	local worst, per_input = nil, {}
	for i = 1, n do
		local s = D.supply[i]
		local ok = s ~= nil
		for o = 1, m do
			local v = s and s[o] or (D.exact and q(0) or 0)
			local same = (D.exact and is_q(v)) and (v == target) or math.abs(float(v) - float(target)) < 1e-9
			if not same then
				ok = false
				local dev = math.abs(float(v) - float(target))
				if not worst or dev > worst.dev then worst = { dev = dev, i = i, o = o, v = v, target = target } end
			end
		end
		per_input[i] = ok
	end
	return { balanced = (n > 0 and m > 0 and worst == nil), worst = worst, per_input = per_input, demand = D }
end

-- ------------------------------------------------------------------ blocked outputs

-- Balance with outputs blocked.  A blocked output backs up: its belt is full, so the splitter
-- feeding it sends everything to its other side, and a belt that now leads only into full belts
-- is full too (the same rule settle() uses for loops that fill).  For every nonempty proper set B
-- of outputs, those outputs are blocked and the shares solved again; the layout passes when
-- every open output carries 1/|open| of every input.  Blocking inputs needs no test: without
-- belt capacity the flow of each input is independent of the others.  Up to 10 outputs (1022
-- choices).  Returns { tested, fails, worst = { B, o, i, v, target } } or nil and a reason.
local BLOCKED_MAX = 10

function N.blocked(tr)
	local base = N.build(tr)
	local m, n = base.m, base.n
	if m < 2 or n < 1 then return nil, 'it needs at least one input and two outputs' end
	if m > BLOCKED_MAX then return nil, 'it has more than ' .. BLOCKED_MAX .. ' outputs' end
	local tested, fails, worst = 0, 0, nil
	for mask = 1, (1 << m) - 2 do
		local net = N.build(tr)
		local B, open = {}, {}
		for o, out in ipairs(net.outputs) do
			if mask & (1 << (o - 1)) ~= 0 then
				B[#B + 1] = o
				net.blocked[out.k] = true
			else
				open[#open + 1] = out
			end
		end
		net.live, net.lane_live = compute_live(tr, net.where, net.blocked)
		tested = tested + 1
		local x = N.shares(net)
		local exact = net.exact
		local target = exact and q(1, #open) or 1 / #open
		local bad
		if not x then
			bad = { dev = math.huge, none = true }
		else
			for _, out in ipairs(open) do
				local per = N.belt(net, net.last[out.k])
				for i = 1, n do
					local same = (exact and is_q(per[i])) and (per[i] == target) or math.abs(float(per[i]) - float(target)) < 1e-9
					if not same then
						local dev = math.abs(float(per[i]) - float(target))
						if not bad or dev > bad.dev then bad = { dev = dev, o = out.index, i = i, v = per[i] } end
					end
				end
			end
		end
		if bad then
			fails = fails + 1
			-- the worst case to show: fewest blocked outputs first, then the largest deviation
			if not worst or #B < #worst.B or (#B == #worst.B and bad.dev > worst.dev) then
				bad.B, bad.target = B, target
				worst = bad
			end
		end
	end
	return { tested = tested, fails = fails, worst = worst }
end

-- ------------------------------------------------------------------ lane balance

-- A layout evens the lanes when, on every output, the left and right lanes carry the same amount
-- of every input lane.  Returns { balanced, worst = { o, i, l, left, right } } or nil.
function N.lane_balance(net)
	local x = N.shares(net)
	if not x then return nil end
	local worst
	for _, out in ipairs(net.outputs) do
		local p = net.last[out.k]
		for c = 1, 2 * net.n do
			local a, b = x[p][LEFT][c], x[p][RIGHT][c]
			local same
			if net.exact and is_q(a) and is_q(b) then
				same = (a == b)
			else
				same = math.abs(float(a) - float(b)) < 1e-9
			end
			if not same then
				local dev = math.abs(float(a) - float(b))
				if not worst or dev > worst.dev then
					worst = { dev = dev, o = out.index, i = (c + 1) // 2, l = 2 - c % 2, left = a, right = b }
				end
			end
		end
	end
	return { balanced = (net.n > 0 and net.m > 0 and worst == nil), worst = worst }
end

-- ------------------------------------------------------------------ full load

-- A fluid model of full belts.  Every lane is a queue that passes at most 1 per step and holds at
-- most FULL_STORE.  An open input keeps its lanes supplied and an open output takes all it is
-- offered; a closed output takes nothing.  A straight belt goes before anything side-loading onto
-- it; side-loads share what room is left.  A splitter works lane by lane: it passes as much as
-- its inputs offer and its outputs have room for, evenly on each side unless a priority says
-- otherwise, and what one side cannot take goes to the other.  Filters are ignored.
local FULL_STORE, FULL_MAX, FULL_TOLERANCE = 2, 4096, 0.004
N.FULL_MAX = FULL_MAX

local function full_model(net)
	local tr, segs = net.tr, net.tr.segs
	local function idx(p, l) return 2 * p - 2 + l end
	local M = { size = 2 * #net.pieces, prev = {}, side = {}, src = {}, sink = {}, splitters = {} }
	for p, pc in ipairs(net.pieces) do
		for l = LEFT, RIGHT do
			local i = idx(p, l)
			if pc.j > 1 then
				M.prev[#M.prev + 1] = { i, idx(net.piece_at[pc.k][pc.j - 1], l) }
			elseif not segs[pc.k].src and net.input_of[pc.k] then
				M.src[#M.src + 1] = { i, net.input_of[pc.k] }
			end
			local feeders = {}
			for _, sd in ipairs(pc.sides) do
				if sd.lane == l then
					for l2 = LEFT, RIGHT do
						if not sd.only or sd.only == l2 then feeders[#feeders + 1] = idx(net.last[sd.k], l2) end
					end
				end
			end
			if #feeders > 0 then M.side[#M.side + 1] = { i, feeders } end
		end
	end
	for _, out in ipairs(net.outputs) do
		for l = LEFT, RIGHT do M.sink[#M.sink + 1] = { idx(net.last[out.k], l), out.index } end
	end
	for _, sp in ipairs(tr.splitters) do
		local pin = sp.input and (sp.input == 'right' and 1 or 2) or nil
		local pout = (not sp.filter and sp.output) and (sp.output == 'right' and 1 or 2) or nil
		for l = LEFT, RIGHT do
			local e = { pin = pin, pout = pout }
			for t = 1, 2 do
				local u = sp.tiles[t]
				local a, b = u and tr.into[u.k], u and tr.outof[u.k]
				e['i' .. t] = a and idx(net.last[a], l) or nil
				e['o' .. t] = b and idx(net.first[b], l) or nil
			end
			M.splitters[#M.splitters + 1] = e
		end
	end
	M.steps = 200 + 16 * #net.pieces
	return M
end

-- Two amounts adding up to total, at most a and b: all from the first choice when prio names one,
-- else evenly, with what one side cannot supply taken from the other.
local function split_two(total, a, b, prio)
	local x, y
	if prio == 1 then
		x = math.min(a, total)
		y = total - x
	elseif prio == 2 then
		y = math.min(b, total)
		x = total - y
	else
		x = math.min(a, total / 2)
		y = math.min(b, total - x)
		x = math.min(a, total - y)
	end
	return x, y
end

-- The steady flow, in belts, from the open inputs to the open outputs.
local function full_run(M, open_in, open_out)
	local size = M.size
	local q_, offer, room, o0, r0 = {}, {}, {}, {}, {}
	for i = 1, size do q_[i] = 0.0 end
	local recent, W = {}, 32
	local result
	for step = 1, M.steps do
		for i = 1, size do
			local h = q_[i]
			local o, r = (h < 1 and h or 1), FULL_STORE - h
			if r > 1 then r = 1 end
			offer[i], room[i], o0[i], r0[i] = o, r, o, r
		end
		for _, e in ipairs(M.src) do
			if open_in[e[2]] then room[e[1]] = 0 end
		end
		for _, e in ipairs(M.prev) do
			local g = math.min(offer[e[2]], room[e[1]])
			offer[e[2]], room[e[1]] = offer[e[2]] - g, room[e[1]] - g
		end
		for _, e in ipairs(M.splitters) do
			local i1, i2, o1, o2 = e.i1, e.i2, e.o1, e.o2
			local a, b = i1 and offer[i1] or 0, i2 and offer[i2] or 0
			local c, d = o1 and room[o1] or 0, o2 and room[o2] or 0
			local total = math.min(a + b, c + d)
			if total > 0 then
				local x, y = split_two(total, a, b, e.pin)
				local u, v = split_two(total, c, d, e.pout)
				if i1 then offer[i1] = a - x end
				if i2 then offer[i2] = b - y end
				if o1 then room[o1] = c - u end
				if o2 then room[o2] = d - v end
			end
		end
		for _, e in ipairs(M.side) do
			local left, f = room[e[1]], e[2]
			for _ = 1, #f do
				local active = 0
				for _, w in ipairs(f) do if offer[w] > 1e-12 then active = active + 1 end end
				if active == 0 or left <= 1e-12 then break end
				local each = left / active
				for _, w in ipairs(f) do
					local g = math.min(offer[w], each)
					offer[w], left = offer[w] - g, left - g
				end
			end
			room[e[1]] = left
		end
		local flow = 0
		for _, e in ipairs(M.sink) do
			if open_out[e[2]] then
				flow = flow + offer[e[1]]
				offer[e[1]] = 0
			end
		end
		local change = 0
		for _, e in ipairs(M.src) do
			-- an open input fills whatever room its lane had
			if open_in[e[2]] then room[e[1]] = 0 end
		end
		for i = 1, size do
			local d = (r0[i] - room[i]) - (o0[i] - offer[i])
			q_[i] = q_[i] + d
			if d > change then change = d elseif -d > change then change = -d end
		end
		recent[(step % W) + 1] = flow
		if change < 1e-7 and step > W then
			result = flow
			break
		end
	end
	if not result then
		local sum = 0
		for _, v in ipairs(recent) do sum = sum + v end
		result = sum / #recent
	end
	return result / 2
end

-- The flow of one choice, in belts: for tests and for comparing with the game.
function N.full_flow(net, I, O)
	local M = full_model(net)
	local a, b = {}, {}
	for _, i in ipairs(I) do a[i] = true end
	for _, o in ipairs(O) do b[o] = true end
	return full_run(M, a, b)
end

-- Every choice of inputs and outputs when there are at most FULL_MAX; otherwise all inputs to all
-- outputs and then choices of equal size until the limit, and only a shortfall is a verdict.
-- Returns { tested, total, partial, worst = { I, O, flow, need, short } }.
function N.full_load(net)
	local n, m = net.n, net.m
	local M = full_model(net)
	local total = (2.0 ^ n - 1) * (2.0 ^ m - 1)
	local function members(mask, size)
		local list, set = {}, {}
		for i = 1, size do
			if (mask >> (i - 1)) & 1 == 1 then list[#list + 1], set[i] = i, true end
		end
		return list, set
	end
	local tested, worst = 0, nil
	local function try(mi, mo)
		local I, a = members(mi, n)
		local O, b = members(mo, m)
		local need = math.min(#I, #O)
		local f = full_run(M, a, b)
		tested = tested + 1
		local short = (need - f) / need
		if short > FULL_TOLERANCE and (not worst or short > worst.short + 1e-9) then
			worst = { I = I, O = O, flow = f, need = need, short = short }
		end
	end
	local partial = false
	if total <= FULL_MAX then
		for mi = 1, (1 << n) - 1 do
			for mo = 1, (1 << m) - 1 do try(mi, mo) end
		end
	else
		partial = true
		if n < 63 and m < 63 then try((1 << n) - 1, (1 << m) - 1) end
		for k = 1, math.min(n, m) do
			local mi, top_i, top_o = (1 << k) - 1, 1 << n, 1 << m
			while mi < top_i and tested < FULL_MAX do
				local mo = (1 << k) - 1
				while mo < top_o and tested < FULL_MAX do
					try(mi, mo)
					mo = next_subset(mo)
				end
				mi = next_subset(mi)
			end
		end
	end
	return { tested = tested, total = total, partial = partial, worst = worst }
end

-- ------------------------------------------------------------------ same network

-- The network as a colored multigraph: a node for each input, output, splitter and merge that
-- has a belt, an arc for each belt.  Arcs are colored by what distinguishes them at their ends:
-- a priority side, a filter side, and at a merge whether the belt runs straight through,
-- side-loads, or side-loads with one lane onto an underground belt.
local function structure(net)
	local tr, segs = net.tr, net.tr.segs
	local g = N.graph(net)
	local used = {}
	for _, a in ipairs(g.arcs) do used[a[1]], used[a[2]] = true, true end
	local id, kinds = {}, {}
	for _, nd in ipairs(g.nodes) do
		if nd.kind == 'input' or nd.kind == 'output' or used[nd.name] then
			kinds[#kinds + 1] = nd.kind
			id[nd.name] = #kinds
		end
	end
	local function color(a)
		local from, to = '', ''
		local pc = a[3] and net.pieces[a[3]]
		if pc and a[1]:sub(1, 1) == 's' then
			local seg = segs[pc.k]
			if pc.j == 1 and seg.src then
				local sp = tr.splitters[tonumber(a[1]:sub(2))]
				local side = sp.tiles[sp.output == 'right' and 1 or 2]
				if sp.filter then
					from = (side and side.k == seg.src.k) and ('f=' .. tostring(sp.filter)) or 'r'
				elseif sp.output and side and side.k == seg.src.k then
					from = 'p'
				end
			end
		end
		local head = a[2]:sub(1, 1)
		if pc and head == 's' then
			local sp = tr.splitters[tonumber(a[2]:sub(2))]
			local e = segs[pc.k]['end']
			local side = sp.input and sp.tiles[sp.input == 'right' and 1 or 2]
			if side and e[2] and side.k == e[2].k then to = 'p' end
		elseif pc and head == 'm' then
			local p2 = tonumber(a[2]:sub(2))
			if a.lead or net.pieces[p2].k == pc.k then
				to = 't'
			else
				to = 's'
				for _, sd in ipairs(net.pieces[p2].sides) do
					if sd.k == pc.k and sd.only then to = 'u' end
				end
			end
		end
		return from .. '>' .. to
	end
	local arcs = {}
	for _, a in ipairs(g.arcs) do
		if id[a[1]] and id[a[2]] then arcs[#arcs + 1] = { id[a[1]], id[a[2]], color(a) } end
	end
	return kinds, arcs
end

local ISO_MAX = 20000

-- Whether two networks are the same up to renaming inputs, outputs, splitters and merges: color
-- refinement on the two graphs together, then a search over the classes it leaves.  Returns
-- true, false, or nil when the search ran past ISO_MAX steps.
function N.same_network(a, b)
	local ka, aa = structure(a)
	local kb, ab = structure(b)
	if #ka ~= #kb or #aa ~= #ab then return false end
	local na, total = #ka, #ka + #kb
	local adj, start = {}, {}
	for v = 1, total do adj[v] = {} end
	for i, k in ipairs(ka) do start[i] = k end
	for i, k in ipairs(kb) do start[na + i] = k end
	local function add(arcs, off)
		for _, e in ipairs(arcs) do
			table.insert(adj[e[1] + off], { 'o' .. e[3], e[2] + off })
			table.insert(adj[e[2] + off], { 'i' .. e[3], e[1] + off })
		end
	end
	add(aa, 0)
	add(ab, na)
	local function ranks(sig)
		local uniq, seen = {}, {}
		for v = 1, total do
			if not seen[sig[v]] then seen[sig[v]] = true; uniq[#uniq + 1] = sig[v] end
		end
		table.sort(uniq)
		local r = {}
		for i, s in ipairs(uniq) do r[s] = i end
		local col = {}
		for v = 1, total do col[v] = r[sig[v]] end
		return col, #uniq
	end
	local function refine(col, classes)
		while true do
			local sig = {}
			for v = 1, total do
				local parts = {}
				for i, e in ipairs(adj[v]) do parts[i] = e[1] .. ':' .. col[e[2]] end
				table.sort(parts)
				sig[v] = col[v] .. '|' .. table.concat(parts, ',')
			end
			local nxt, count = ranks(sig)
			col = nxt
			if count == classes then return col, count end
			classes = count
		end
	end
	local steps = 0
	local function search(col, classes)
		steps = steps + 1
		if steps > ISO_MAX then error({ iso_budget = true }, 0) end
		col, classes = refine(col, classes)
		local ca, cb = {}, {}
		for v = 1, na do ca[col[v]] = (ca[col[v]] or 0) + 1 end
		for v = na + 1, total do cb[col[v]] = (cb[col[v]] or 0) + 1 end
		for c = 1, classes do
			if ca[c] ~= cb[c] then return false end
		end
		local pick
		for c = 1, classes do
			if ca[c] > 1 and (not pick or ca[c] < ca[pick]) then pick = c end
		end
		if not pick then return true end
		local first
		for v = 1, na do
			if col[v] == pick then first = v; break end
		end
		for v = na + 1, total do
			if col[v] == pick then
				local c2 = {}
				for u = 1, total do c2[u] = col[u] * 2 end
				c2[first], c2[v] = col[first] * 2 + 1, col[first] * 2 + 1
				local c3, count = ranks(c2)
				if search(c3, count) then return true end
			end
		end
		return false
	end
	local start_sig = {}
	for v = 1, total do start_sig[v] = start[v] end
	local c0, classes = ranks(start_sig)
	local ok, res = pcall(search, c0, classes)
	if ok then return res end
	if type(res) == 'table' and res.iso_budget then return nil end
	error(res, 0)
end

-- ------------------------------------------------------------------ the wire diagram

-- view=wires: the network as a balancing-network diagram (Aspnes, Herlihy and Shavit), drawn
-- the same way for isomorphic networks.  Belts are horizontal wires and a splitter is a bar
-- joining its two wires.
--   Loops: inside each strongly connected component, every minimum set of arcs that breaks
--   all its cycles is tried; each arc of the set becomes a loop wire, which leaves on the
--   right and comes back on the left.
--   Layers: a splitter's layer is its longest path from the inputs once the loops are cut.
--   Choices: which wire each input and loop starts on, and at each splitter which output
--   stays on which of its two wires.  All are searched; the drawing kept has the least total
--   bar length, then its loop wires lowest, then the least code, where the code (bars as
--   layer, low wire, high wire; loop wires; output wires) names no node.
-- Handles networks whose splitters each take two belts in and send two out, with no
-- side-loads.  Returns nil and the reason otherwise, or when the search would be too large.
local WIRES_MAX, SPLITTERS_MAX, FAS_MAX = 7, 24, 20000

local function sccs(names, succ)
	local index, low, on, stack, comps, c = {}, {}, {}, {}, {}, 0
	local function visit(v)
		c = c + 1
		index[v], low[v] = c, c
		stack[#stack + 1] = v
		on[v] = true
		for _, w in ipairs(succ[v]) do
			if not index[w] then
				visit(w)
				low[v] = math.min(low[v], low[w])
			elseif on[w] then
				low[v] = math.min(low[v], index[w])
			end
		end
		if low[v] == index[v] then
			local comp = {}
			repeat
				local w = table.remove(stack)
				on[w] = nil
				comp[#comp + 1] = w
			until w == v
			comps[#comps + 1] = comp
		end
	end
	for _, v in ipairs(names) do
		if not index[v] then visit(v) end
	end
	return comps
end

local function acyclic(nodes, arcs, skip)
	local succ, state = {}, {}
	for _, v in ipairs(nodes) do succ[v] = {} end
	for _, e in ipairs(arcs) do
		if not skip[e.id] then table.insert(succ[e[1]], e[2]) end
	end
	local function dfs(v)
		state[v] = 1
		for _, w in ipairs(succ[v]) do
			if state[w] == 1 then return false end
			if not state[w] and not dfs(w) then return false end
		end
		state[v] = 2
		return true
	end
	for _, v in ipairs(nodes) do
		if not state[v] and not dfs(v) then return false end
	end
	return true
end

-- All k-subsets of list, in order, passed to f; stops when f returns true.
local function subsets(list, k, f)
	local pick = {}
	local function rec(start, depth)
		if depth > k then return f(pick) end
		for i = start, #list - (k - depth) do
			pick[depth] = list[i]
			if rec(i + 1, depth + 1) then return true end
		end
		return false
	end
	return rec(1, 1)
end

local function binom(n, k)
	local r = 1
	for i = 1, k do r = r * (n - k + i) / i end
	return r
end

-- Every feedback set minimum within each strongly connected component, or nil and a reason.
local function feedback_choices(names, arcs)
	local succ = {}
	for _, v in ipairs(names) do succ[v] = {} end
	for _, a in ipairs(arcs) do table.insert(succ[a[1]], a[2]) end
	local per = {}
	for _, comp in ipairs(sccs(names, succ)) do
		local cs = {}
		for _, v in ipairs(comp) do cs[v] = true end
		local inner = {}
		for _, a in ipairs(arcs) do
			if cs[a[1]] and cs[a[2]] then inner[#inner + 1] = a end
		end
		if #inner > 0 then
			table.sort(comp)
			for k = 1, #inner do
				if binom(#inner, k) > FAS_MAX then return nil, 'its loops are too tangled to search' end
				local sols = {}
				subsets(inner, k, function(pick)
					local skip = {}
					for _, a in ipairs(pick) do skip[a.id] = true end
					if acyclic(comp, inner, skip) then
						local s = {}
						for _, a in ipairs(pick) do s[#s + 1] = a.id end
						sols[#sols + 1] = s
					end
				end)
				if #sols > 0 then
					per[#per + 1] = sols
					break
				end
			end
		end
	end
	-- the product of the choices per component
	local out = { {} }
	for _, sols in ipairs(per) do
		local nxt = {}
		for _, base in ipairs(out) do
			for _, s in ipairs(sols) do
				local u = {}
				for _, id in ipairs(base) do u[#u + 1] = id end
				for _, id in ipairs(s) do u[#u + 1] = id end
				nxt[#nxt + 1] = u
			end
		end
		out = nxt
		if #out > 64 then return nil, 'its loops can be cut in too many ways to search' end
	end
	return out
end

local function ch(n) return string.char(48 + n) end

-- The search for one feedback set F (a set of arc ids).  Returns the best drawing or nil.
local function wires_for(g, arcs, F, kind)
	local ins, outs = {}, {}
	for _, nd in ipairs(g.nodes) do ins[nd.name], outs[nd.name] = {}, {} end
	for _, a in ipairs(arcs) do
		table.insert(outs[a[1]], a)
		table.insert(ins[a[2]], a)
	end
	local spl = {}
	for _, nd in ipairs(g.nodes) do
		if nd.kind == 'splitter' then spl[#spl + 1] = nd.name end
	end
	local layer = {}
	local function lay(v)
		if not layer[v] then
			local l = 1
			for _, a in ipairs(ins[v]) do
				if not F[a.id] and kind[a[1]] == 'splitter' then l = math.max(l, lay(a[1]) + 1) end
			end
			layer[v] = l
		end
		return layer[v]
	end
	for _, v in ipairs(spl) do lay(v) end
	table.sort(spl, function(a, b)
		if layer[a] ~= layer[b] then return layer[a] < layer[b] end
		return a < b
	end)
	-- Tokens: arc id for an arc, and #arcs + k for the right-hand end of the k-th loop.
	local m = #arcs
	local left, Fl, loop_of = {}, {}, {}
	for _, a in ipairs(arcs) do
		if kind[a[1]] == 'input' then left[#left + 1] = a.id end
	end
	for _, a in ipairs(arcs) do
		if F[a.id] then
			Fl[#Fl + 1] = a.id
			left[#left + 1] = a.id
			loop_of[m + #Fl] = a.id
		end
	end
	local function out_tok(a)
		if F[a.id] then
			for k, id in ipairs(Fl) do if id == a.id then return m + k end end
		end
		return a.id
	end
	local S = {}
	for _, v in ipairs(spl) do
		S[#S + 1] = { layer[v], ins[v][1].id, ins[v][2].id, out_tok(outs[v][1]), out_tok(outs[v][2]), v }
	end
	local out_toks = {}
	for _, a in ipairs(arcs) do
		if kind[a[2]] == 'output' then out_toks[#out_toks + 1] = a.id end
	end
	local w, K = #left, #S
	local best = { cost = math.huge }
	local line, bars = {}, {}
	-- The code of the drawing on the current lines, read straight (flip false) or upside down.
	local function code_of(flip)
		local function L(l) return flip and (w - 1 - l) or l end
		local lp, lb, lo = {}, {}, {}
		for _, id in ipairs(Fl) do lp[#lp + 1] = L(line[id]) end
		table.sort(lp)
		local low = {}
		for i, l in ipairs(lp) do low[i] = ch(w - 1 - l) end
		table.sort(low)
		for i, b in ipairs(bars) do
			local a, c = L(b[2]), L(b[3])
			lb[i] = ch(b[1]) .. ch(math.min(a, c)) .. ch(math.max(a, c))
		end
		table.sort(lb)
		for _, id in ipairs(out_toks) do lo[#lo + 1] = L(line[id]) end
		table.sort(lo)
		local lps, los = {}, {}
		for i, l in ipairs(lp) do lps[i] = ch(l) end
		for i, l in ipairs(lo) do los[i] = ch(l) end
		return table.concat(low) .. '|' .. table.concat(lb) .. '|' .. table.concat(lps) .. '|' .. table.concat(los)
	end
	local function leaf(cost)
		-- A drawing and its mirror image cost the same; only half the starts are searched, so
		-- both are scored here.
		for _, flip in ipairs({ false, true }) do
			local code = code_of(flip)
			if cost < best.cost or (cost == best.cost and code < best.code) then
				local copy, bcopy = {}, {}
				for k, v in pairs(line) do copy[k] = flip and (w - 1 - v) or v end
				for i, b in ipairs(bars) do
					local a, c = flip and (w - 1 - b[2]) or b[2], flip and (w - 1 - b[3]) or b[3]
					bcopy[i] = { b[1], math.min(a, c), math.max(a, c), b[4] }
				end
				best = { cost = cost, code = code, line = copy, bars = bcopy }
			end
		end
	end
	-- A lower bound on the bars still to come: a bar is at least as long as the distance
	-- between its two wires once both are known, and at least 1.
	local function bound(pos)
		local b = 0
		for k = pos, K do
			local i, j = line[S[k][2]], line[S[k][3]]
			b = b + ((i and j) and math.abs(i - j) or 1)
		end
		return b
	end
	local function search(pos, cost)
		if cost + bound(pos) > best.cost then return end
		if pos > K then return leaf(cost) end
		local s = S[pos]
		local i, j = line[s[2]], line[s[3]]
		local lo, hi = math.min(i, j), math.max(i, j)
		for t = 1, 2 do
			local p, q = s[4], s[5]
			if t == 2 then p, q = q, p end
			if not ((loop_of[p] and line[loop_of[p]] ~= lo) or (loop_of[q] and line[loop_of[q]] ~= hi)) then
				line[p], line[q] = lo, hi
				bars[#bars + 1] = { s[1], lo, hi, s[6] }
				search(pos + 1, cost + hi - lo)
				bars[#bars] = nil
				line[p], line[q] = nil, nil
			end
		end
	end
	-- every assignment of the left-hand tokens to wires 0 .. w-1 (Heap's algorithm)
	local perm, c = {}, {}
	for i = 0, w - 1 do perm[i], c[i] = i, 0 end
	local function try()
		-- the mirror of a start puts the first token on w - 1 - perm[0]: keep one of each pair
		if 2 * perm[0] > w - 1 then return end
		for i, tok in ipairs(left) do line[tok] = perm[i - 1] end
		search(1, 0)
	end
	try()
	local i = 1
	while i < w do
		if c[i] < i then
			if i % 2 == 0 then perm[0], perm[i] = perm[i], perm[0] else perm[c[i]], perm[i] = perm[i], perm[c[i]] end
			try()
			c[i] = c[i] + 1
			i = 1
		else
			c[i] = 0
			i = i + 1
		end
	end
	if not best.line then return nil end
	best.w, best.layer, best.loops, best.F, best.m = w, layer, Fl, F, m
	return best
end

function N.wires(g)
	local kind, names, arcs = {}, {}, {}
	for _, nd in ipairs(g.nodes) do
		kind[nd.name] = nd.kind
		names[#names + 1] = nd.name
		if nd.kind == 'merge' then return nil, 'a belt side-loads onto another' end
	end
	for idx, a in ipairs(g.arcs) do arcs[#arcs + 1] = { a[1], a[2], piece = a[3], id = idx } end
	local nin, nout, nspl = {}, {}, 0
	for _, a in ipairs(arcs) do
		nout[a[1]] = (nout[a[1]] or 0) + 1
		nin[a[2]] = (nin[a[2]] or 0) + 1
	end
	for _, v in ipairs(names) do
		if kind[v] == 'splitter' then
			nspl = nspl + 1
			if nin[v] ~= 2 or nout[v] ~= 2 then return nil, 'splitter ' .. v:sub(2) .. ' does not take two belts in and send two out' end
		end
	end
	if nspl > SPLITTERS_MAX then return nil, 'it has more than ' .. SPLITTERS_MAX .. ' splitters' end
	local choices, why = feedback_choices(names, arcs)
	if not choices then return nil, why end
	local best
	for _, ids in ipairs(choices) do
		local F, nwires = {}, 0
		for _, id in ipairs(ids) do F[id] = true end
		for _, a in ipairs(arcs) do
			if kind[a[1]] == 'input' or F[a.id] then nwires = nwires + 1 end
		end
		if nwires > WIRES_MAX then return nil, 'it needs more than ' .. WIRES_MAX .. ' wires' end
		local r = wires_for(g, arcs, F, kind)
		if r and (not best or r.cost < best.cost or (r.cost == best.cost and r.code < best.code)) then best = r end
	end
	if not best then return nil, 'no drawing was found' end
	best.arcs, best.kind = arcs, kind
	return best
end

return N
