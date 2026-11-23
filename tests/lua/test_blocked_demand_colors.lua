-- Blocked outputs, demand (input balance), and the colorings whose gray means balanced.
local T = require('lib')
local bm, NET = T.bm, T.NET

local function supply_row(r, i, m)
	local s = r.demand.supply[i] or {}
	local c = {}
	for o = 1, m do c[o] = tostring(s[o] or 0) end
	return table.concat(c, ' ')
end

return {
	{ 'blocked: the examples fail with an output blocked', function()
		for _, f in ipairs(T.EXAMPLES) do
			local L = T.example(f)
			local r = NET.blocked(bm.trace(L, L.gap or 10))
			T.eq(r.tested, 30, f .. ' choices')
			T.eq(r.fails, 18, f .. ' failing choices')
			T.eq(#r.worst.B, 1, f .. ' worst blocks one output')
			T.eq(tostring(r.worst.v), '2/5', f .. ' worst share')
		end
	end },
	{ 'blocked: one splitter and the 2-3 pass, the 4-4 fails', function()
		local function run(key) local L = T.grid(T.GRIDS[key]); return NET.blocked(bm.trace(L, 10)) end
		T.eq(run('2-2').fails, 0)
		T.eq(run('2-3 uneven').fails, 0)
		T.ok(run('4-4 three splitters').fails > 0)
	end },
	{ 'demand: exact, and the examples are input balanced', function()
		for _, f in ipairs(T.EXAMPLES) do
			local r = NET.input_balance(T.net(T.example(f)))
			T.ok(r.demand.exact, f .. ' exact')
			T.ok(r.balanced, f .. ' input balanced')
			T.eq(supply_row(r, 3, 5), '1/5 1/5 1/5 1/5 1/5', f)
		end
	end },
	{ 'demand: the transpose for two-in two-out splitters', function()
		local net = T.net(T.grid(T.GRIDS['4-4 three splitters']))
		local r = NET.input_balance(net)
		T.ok(not r.balanced)
		T.eq(supply_row(r, 1, 4), '1/2 1/4 1/4 0')
		T.eq(supply_row(r, 4, 4), '0 1/4 1/4 1/2')
	end },
	{ 'demand: input balanced is not output balanced', function()
		local net = T.net(T.grid(T.GRIDS['2-3 uneven']))
		T.ok(NET.input_balance(net).balanced, 'inputs drain evenly')
		T.ok(not NET.verdicts(net).balanced, 'outputs uneven')
	end },
	{ 'demand: input priority draws everything from one side', function()
		local net = T.net(T.grid(T.GRIDS['2-2 input priority']))
		local r = NET.input_balance(net)
		T.ok(not r.balanced)
		local a, b = supply_row(r, 1, 2), supply_row(r, 2, 2)
		T.ok((a == '1 1' and b == '0 0') or (a == '0 0' and b == '1 1'), a .. ' / ' .. b)
		T.ok(NET.verdicts(net).balanced, 'priority on the input side leaves the outputs even')
	end },
	{ 'colors: gray exactly when balanced, in strict and check', function()
		local cases = 0
		for _, mode in ipairs({ 'strict', 'check' }) do
			local layouts = { T.example('f00_9x10.json'), T.example('f04_11x8.txt') }
			for _, key in ipairs({ '4-4 three splitters', '2-3 uneven', '2-2 input priority' }) do layouts[#layouts + 1] = T.grid(T.GRIDS[key]) end
			for _, L in ipairs(layouts) do
				local st = bm.prepare(L, { mix = mode, marks = true })
				local net, mix = st.net, st.mix
				local gray
				for _, out in ipairs(net.outputs) do
					if st.marks.outs[out.index] then gray = mix.rgb[net.last[out.k]] end
				end
				for _, out in ipairs(net.outputs) do
					local c = mix.rgb[net.last[out.k]]
					local is_gray = gray and c[1] == gray[1] and c[2] == gray[2] and c[3] == gray[3]
					if st.marks.outs[out.index] then
						T.ok(is_gray, mode .. ': balanced output not gray')
						T.ok(c[1] == c[2] and c[2] == c[3], 'the gray is neutral')
					elseif gray then
						T.ok(not is_gray, mode .. ': unbalanced output is gray')
					end
					cases = cases + 1
				end
			end
		end
		T.ok(cases >= 38, 'outputs checked: ' .. cases)
	end },
	{ 'strict: an output carrying too much is lighter, too little darker', function()
		local st = bm.prepare(T.grid(T.GRIDS['2-3 uneven']), { mix = 'strict' })
		local function lum(o) local c = st.mix.rgb[st.net.last[st.net.outputs[o].k]]; return c[1] + c[2] + c[3] end
		T.ok(lum(1) > lum(2), 'output 1 lighter than output 2')
		T.eq(lum(2), lum(3), 'outputs 2 and 3 alike')
	end },
	{ 'check: an output short of everything is slate', function()
		local st = bm.prepare(T.grid(T.GRIDS['2-3 uneven']), { mix = 'check' })
		local c = st.mix.rgb[st.net.last[st.net.outputs[2].k]]
		T.ok(c[3] > c[1], 'slate is bluish: ' .. table.concat(c, ','))
	end },
	{ 'marks, verdicts and the demand view', function()
		local st = bm.prepare(T.grid(T.GRIDS['2-3 uneven']), { mix = 'strict', marks = true })
		T.ok(st.marks.ins[1] and st.marks.ins[2], 'inputs pass')
		T.ok(not (st.marks.outs[1] or st.marks.outs[2] or st.marks.outs[3]), 'outputs fail')
		T.ok(st.ibal.verdict:find('^input balanced'), st.ibal.verdict)
		st = bm.prepare(T.example('f00_9x10.json'), { mix = 'strict', demand = true })
		T.ok(st.mix, 'demand view: ' .. tostring(st.mix_failed))
		st = bm.prepare(T.example('f00_9x10.json'), { mix = 'bands', demand = true })
		T.ok(not st.mix and st.mix_failed:find('bands'), 'demand refuses bands')
	end },
}
