-- Exact shares, the balance verdict, priorities, and the trace of the examples.
local T = require('lib')
local bm, NET = T.bm, T.NET

local function row(net, o) return table.concat(T.output_shares(net, o), ' ') end

return {
	{ 'examples trace to 5-5 networks with 11 splitters', function()
		for _, f in ipairs(T.EXAMPLES) do
			local L = T.example(f)
			local tr = bm.trace(L, L.gap or 10)
			local net = NET.build(tr)
			T.eq(net.n, 5, f .. ' inputs')
			T.eq(net.m, 5, f .. ' outputs')
			T.eq(#tr.splitters, 11, f .. ' splitters')
		end
	end },
	{ 'every example is an exact balancer', function()
		for _, f in ipairs(T.EXAMPLES) do
			local net = T.net(T.example(f))
			T.ok(NET.shares(net), f .. ': no steady state')
			T.ok(net.exact, f .. ': shares not exact')
			for o = 1, 5 do T.eq(row(net, o), '1/5 1/5 1/5 1/5 1/5', f .. ' output ' .. o) end
			local v = NET.verdicts(net)
			T.ok(v.balanced, f .. ' verdict')
		end
	end },
	{ 'turning a layout does not change its network', function()
		for _, f in ipairs(T.EXAMPLES) do
			local L = T.example(f)
			for turns = 1, 3 do
				local net = T.net(bm.rotate(L, turns))
				T.ok(NET.verdicts(net).balanced, f .. ' turned ' .. turns)
			end
		end
	end },
	{ '4-4 of three splitters: outputs 2 and 3 even, 1 and 4 not', function()
		local net = T.net(T.grid(T.GRIDS['4-4 three splitters']))
		T.eq(row(net, 1), '1/2 1/2 0 0')
		T.eq(row(net, 2), '1/4 1/4 1/4 1/4')
		T.eq(row(net, 3), '1/4 1/4 1/4 1/4')
		T.eq(row(net, 4), '0 0 1/2 1/2')
		T.ok(not NET.verdicts(net).balanced)
	end },
	{ '2-3: the same mix in unequal amounts is not balanced', function()
		local net = T.net(T.grid(T.GRIDS['2-3 uneven']))
		T.eq(row(net, 1), '1/2 1/2')
		T.eq(row(net, 2), '1/4 1/4')
		T.eq(row(net, 3), '1/4 1/4')
		T.ok(not NET.verdicts(net).balanced)
	end },
	{ 'output priority sends everything to one side', function()
		local net = T.net(T.grid(T.GRIDS['2-2 output priority']))
		local a, b = row(net, 1), row(net, 2)
		T.ok((a == '1 1' and b == '0 0') or (a == '0 0' and b == '1 1'), 'got ' .. a .. ' / ' .. b)
	end },
	{ 'a splitter with one belt in halves it', function()
		local net = T.net(T.grid(T.GRIDS['1-2 one belt in']))
		T.eq(net.n, 1)
		T.eq(row(net, 1), '1/2')
		T.eq(row(net, 2), '1/2')
	end },
	{ 'the share matrix and verdict reach TeX', function()
		local state = bm.prepare(T.example('f00_9x10.json'), { mix = 'blend' })
		T.ok(state.bal.balanced)
		T.ok(state.bal.verdict:find('balanced: each of the 5 outputs carries 20', 1, true), state.bal.verdict)
		local _, count = bm.matrix_tex(state):gsub('\\frac{1}{5}', '')
		T.eq(count, 25, 'a 5 by 5 matrix of 1/5')
	end },
	{ 'throughput: the max-flow test and its cut', function()
		local st = bm.prepare(T.example('f00_9x10.json'), { throughput = true })
		T.ok(st.tp.ok, 'f00 passes max-flow: ' .. st.tp.verdict)
		st = bm.prepare(T.grid(T.GRIDS['2-2 limited']), { throughput = true, mix = 'blend' })
		T.ok(not st.tp.ok, '2-2 limited')
		T.ok(st.bal.balanced, 'and still balanced')
		T.ok(#st.tp.limited.cut > 0, 'a cut is found')
	end },
}
