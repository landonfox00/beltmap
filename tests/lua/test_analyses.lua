-- Underground side-loads, the bounded max-flow test, lane balance, full load, same network, and
-- the analysis cache.  The numbers marked "game" were measured in Factorio 2.1.24.
local T = require('lib')
local bm, NET = T.bm, T.NET

local LANE_BALANCER = '. S> > > v . \\\\ > S> v . > > \\\\ . . > > ^ .'

-- What output lane l carries of input lane c.
local function lane_share(net, o, l, c)
	local x = NET.shares(net)
	return tostring(x[net.last[net.outputs[o].k]][l][c])
end

local function straight(n)
	local rows = {}
	for i = 1, n do rows[i] = '> > >' end
	return table.concat(rows, ' \\\\ ')
end

local function near(a, b, tol, msg)
	if math.abs(a - b) > (tol or 1e-3) then
		error(string.format('%s: expected %.4f, got %.4f', msg or 'not near', b, a), 2)
	end
end

return {
	{ 'side-load onto an entrance: only the upstream lane gets on (game)', function()
		-- from the left: the incoming belt's right lane is upstream
		local net = T.net(T.grid('. v . . . . \\\\ > I> . . O> >'))
		local side = net.input_of[net.sources[1]] and 1
		T.ok(side, 'the side belt is an input')
		local which
		for i, k in ipairs(net.sources) do
			if net.tr.segs[k].tiles[1].k == '1,0' then which = i end
		end
		T.eq(lane_share(net, 1, 1, 2 * which - 1), '0', 'its left lane is blocked')
		T.eq(lane_share(net, 1, 1, 2 * which), '1', 'its right lane lands on the near lane')
	end },
	{ 'side-load onto an exit: only the downstream lane gets on (game)', function()
		local net = T.net(T.grid('. . . . v . \\\\ > I> . . O> >'))
		local which
		for i, k in ipairs(net.sources) do
			if net.tr.segs[k].tiles[1].k == '4,0' then which = i end
		end
		T.eq(lane_share(net, 1, 1, 2 * which - 1), '1', 'its left lane lands on the near lane')
		T.eq(lane_share(net, 1, 1, 2 * which), '0', 'its right lane is blocked')
	end },
	{ 'a belt fed only by side-loads is not an input', function()
		local L = T.grid('. v . \\\\ . > > \\\\ . ^ .')
		local tr = bm.trace(L, 10)
		T.eq(#tr.inputs, 2, 'inputs of the trace')
		T.eq(NET.build(tr).n, 2, 'inputs of the network')
	end },
	{ 'throughput: wide layouts finish, and an undecided test is not a pass', function()
		local t = os.clock()
		local st = bm.prepare(T.grid(straight(16)), { throughput = true })
		T.ok(os.clock() - t < 20, 'bounded time')
		T.eq(st.tp.ok, false, 'straight belts are limited')
		T.ok(st.tp.partial, 'not every choice was tried')
		local net = T.net(T.grid(straight(2)))
		T.eq(NET.throughput(net).tested, 5, '2-2 has 5 choices of equal size')
	end },
	{ 'throughput: equal sizes decide every choice (checked exhaustively)', function()
		for name, g in pairs(T.GRIDS) do
			local net = T.net(T.grid(g))
			local r = NET.throughput(net)
			local any = false
			for mi = 1, (1 << net.n) - 1 do
				local I = {}
				for i = 1, net.n do if (mi >> (i - 1)) & 1 == 1 then I[#I + 1] = i end end
				for mo = 1, (1 << net.m) - 1 do
					local O = {}
					for o = 1, net.m do if (mo >> (o - 1)) & 1 == 1 then O[#O + 1] = o end end
					if NET.maxflow_of(net, I, O) < math.min(#I, #O) then any = true end
				end
			end
			T.eq(r.limited ~= nil, any, name)
		end
	end },
	{ 'lane balance: a lane balancer passes, a belt and a splitter do not', function()
		local st = bm.prepare(T.grid(LANE_BALANCER), { lane_balance = true })
		T.ok(st.lbal.balanced, st.lbal.verdict)
		T.ok(not bm.prepare(T.grid('> > >'), { lane_balance = true }).lbal.balanced)
		T.ok(not bm.prepare(T.grid(T.GRIDS['2-2']), { lane_balance = true }).lbal.balanced)
	end },
	{ 'full load: small layouts as measured (game)', function()
		local net = T.net(T.grid(T.GRIDS['2-2 limited']))
		near(NET.full_flow(net, { 1, 2 }, { 1, 2 }), 1, 1e-3, 'the middle belt caps two belts at one')
		net = T.net(T.grid('> S> > S> > \\\\ > S> > S> >'))
		near(NET.full_flow(net, { 1, 2 }, { 1, 2 }), 2, 1e-3, 'two in series pass two')
		net = T.net(T.grid('. v . . \\\\ > > > >'))
		local side
		for i, k in ipairs(net.sources) do
			if net.tr.segs[k].tiles[1].k == '1,0' then side = i end
		end
		near(NET.full_flow(net, { side }, { 1 }), 0.5, 1e-3, 'a side-load passes half a belt')
		near(NET.full_flow(net, { 3 - side }, { 1 }), 1, 1e-3, 'the straight belt keeps a full belt')
		near(NET.full_flow(net, { 1, 2 }, { 1 }), 1, 1e-3, 'side-load onto a full belt adds nothing')
	end },
	{ 'full load: f00 passes five belts and is limited from input 5 to output 5', function()
		local net = T.net(T.example('f00_9x10.json'))
		near(NET.full_flow(net, { 1, 2, 3, 4, 5 }, { 1, 2, 3, 4, 5 }), 5, 1e-3, 'all five')
		local r = NET.full_load(net)
		T.eq(r.tested, 961)
		T.ok(r.worst, 'a shortfall')
		T.eq(table.concat(r.worst.I, ','), '5')
		T.eq(table.concat(r.worst.O, ','), '5')
		near(r.worst.flow, 2 / 3, 2e-3, 'two thirds of a belt')
		local st = bm.prepare(T.example('f00_9x10.json'), { full_load = true })
		T.eq(st.full.ok, false)
	end },
	{ 'full load: a closed output carries nothing, and flow never beats max-flow', function()
		for name, g in pairs(T.GRIDS) do
			local net = T.net(T.grid(g))
			for i = 1, net.n do
				for o = 1, net.m do
					local f = NET.full_flow(net, { i }, { o })
					T.ok(f <= NET.maxflow_of(net, { i }, { o }) + 1e-6, name .. ': above max-flow')
				end
			end
		end
	end },
	{ 'same network: f00 and f01 match, f04 differs, turning changes nothing', function()
		local a, b, c = T.net(T.example('f00_9x10.json')), T.net(T.example('f01_9x10.json')), T.net(T.example('f04_11x8.txt'))
		T.eq(NET.same_network(a, b), true, 'f00 and f01')
		T.eq(NET.same_network(a, c), false, 'f00 and f04')
		T.eq(NET.same_network(a, T.net(bm.rotate(T.example('f00_9x10.json'), 1))), true, 'turned')
	end },
	{ 'same network: priorities, filters and side-loads count', function()
		local plain = T.net(T.grid(T.GRIDS['2-2']))
		T.eq(NET.same_network(plain, T.net(T.grid(T.GRIDS['2-2 input priority']))), false, 'input priority')
		T.eq(NET.same_network(plain, T.net(T.grid(T.GRIDS['2-2 output priority']))), false, 'output priority')
		T.eq(NET.same_network(plain, T.net(T.grid('> S>[filter=a] > \\\\ > S> >'))), false, 'filter')
		T.eq(NET.same_network(T.net(T.grid('> S>[in=left] > \\\\ > S> >')), T.net(T.grid('> S>[in=right] > \\\\ > S> >'))), true, 'mirror image')
		T.eq(NET.same_network(T.net(T.grid('. v . . \\\\ > > > >')), T.net(T.grid('> > > > \\\\ . ^ . .'))), true, 'side-load from either side')
	end },
	{ 'cache: results survive a round trip exactly', function()
		local value = { a = 1, b = 0.1 + 0.2, c = { 1, 2, 3 }, d = NET.q(3, 7), e = math.huge, f = { { 1, 2 } }, s = 'x"y' }
		local back = bm.cache_unser(bm.json_decode(bm.cache_ser(value)))
		T.eq(back.a, 1)
		T.eq(back.b, 0.1 + 0.2, 'a float to the last bit')
		T.eq(tostring(back.d), '3/7')
		T.eq(back.e, math.huge)
		T.eq(back.c[3], 3)
		T.eq(back.f[1][2], 2)
		T.eq(back.s, 'x"y')
	end },
	{ 'cache: a cached verdict equals a computed one', function()
		T.mkdirs(T.root .. '/tests/tmp')
		for _, f in ipairs({ T.EXAMPLES[1] }) do
			bm.cache_on = false
			local plain = bm.prepare(T.example(f), { throughput = true, blocked = true, full_load = true })
			bm.cache_on = true
			bm.cache_reset()
			local first = bm.prepare(T.example(f), { throughput = true, blocked = true, full_load = true })
			local second = bm.prepare(T.example(f), { throughput = true, blocked = true, full_load = true })
			bm.cache_on = false
			bm.cache_reset()
			for _, st in ipairs({ first, second }) do
				T.eq(st.tp.verdict, plain.tp.verdict, f .. ' throughput')
				T.eq(st.blk.verdict, plain.blk.verdict, f .. ' blocked')
				T.eq(st.full.verdict, plain.full.verdict, f .. ' full load')
			end
		end
	end },
}
