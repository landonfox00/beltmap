-- The fluid model of full load against what Factorio 2.1.24 measured (tests/game/fullload.txt).
local T = require('lib')
local bm, NET = T.bm, T.NET
package.path = T.root .. '/tests/game/?.lua;' .. package.path
local C = require('cases')

local function measurements()
	local text = assert(T.read(T.root .. '/tests/game/fullload.txt'), 'no measurements')
	local head = text:match('^#[^\n]*')
	local ticks = tonumber(head:match('measure (%d+) ticks'))
	local list = {}
	for line in text:gmatch('[^\r\n]+') do
		if line:sub(1, 1) ~= '#' then
			local c, a, b, n = line:match('^(%d+)|([%d,]+)|([%d,]+)|(%d+)$')
			local I, O = {}, {}
			for x in a:gmatch('%d+') do I[#I + 1] = tonumber(x) end
			for x in b:gmatch('%d+') do O[#O + 1] = tonumber(x) end
			list[#list + 1] = { case = tonumber(c), I = I, O = O, belts = tonumber(n) / (ticks / 60) / 15 }
		end
	end
	return list
end

return {
	{ 'full load: the model is within the measured band of the game', function()
		local list, nets = measurements(), {}
		T.eq(#list, 1392, 'measurements')
		local over, under = 0, 0
		for _, r in ipairs(list) do
			if not nets[r.case] then
				local _, net = C.read(bm, NET, C.cases[r.case], T.root)
				nets[r.case] = net
			end
			local d = NET.full_flow(nets[r.case], r.I, r.O) - r.belts
			over, under = math.max(over, d), math.max(under, -d)
		end
		T.ok(under <= 0.002, string.format('the model fell %.3f belts below the game', under))
		T.ok(over <= 0.11, string.format('the model rose %.3f belts above the game', over))
	end },
	{ 'full load: every shortfall of the model is a shortfall in the game', function()
		local list, nets = measurements(), {}
		local short, pass = 0, 0
		for _, r in ipairs(list) do
			if not nets[r.case] then
				local _, net = C.read(bm, NET, C.cases[r.case], T.root)
				nets[r.case] = net
			end
			local need = math.min(#r.I, #r.O)
			if NET.full_flow(nets[r.case], r.I, r.O) < need * 0.996 then
				short = short + 1
				T.ok(r.belts < need - 0.02, string.format('case %d: short in the model, not in the game', r.case))
			else
				pass = pass + 1
				T.ok(r.belts >= need * 0.9, string.format('case %d: passes in the model, under 90%% in the game', r.case))
			end
		end
		T.eq(short, 240, 'shortfalls')
		T.eq(pass, 1152, 'passes')
	end },
}
