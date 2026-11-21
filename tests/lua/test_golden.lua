-- Golden snapshots: for every example and test grid, the exact shares, every verdict, the wire
-- diagram's code, the alternative text and caption, and the TikZ the package writes for three
-- sets of keys.  A change anywhere in reading, tracing, the flow, the analyses or the drawing
-- shows up here as a diff to review.  `texlua tests/run.lua --update` rewrites the files; the
-- mismatching ones also go to tests/golden/actual/ so CI can upload them.
--
-- Numbers are compared with a tolerance, so that the last digit of a coordinate or an RGB value
-- may differ between platforms' math libraries: integers within 1, decimals within 0.002.
local T = require('lib')
local bm, NET = T.bm, T.NET

local KEYSETS = {
	{ 'layout, mix', { mix = 'blend', labels = true } },
	{ 'layout, strict, marks, throughput', { mix = 'strict', marks = true, throughput = true } },
	{ 'wires, check, marks', { view = 'wires', mix = 'check', marks = true, labels = true } },
}

local function snapshot(L)
	local out = {}
	local function line(s) out[#out + 1] = s end
	local tr = bm.trace(L, L.gap or 10)
	local net = NET.build(tr)
	NET.shares(net)
	line(string.format('inputs %d, outputs %d, splitters %d, tunnels %d, exact %s', net.n, net.m, #tr.splitters, #tr.tunnels, tostring(net.exact)))
	for o = 1, net.m do line('output ' .. o .. ': ' .. table.concat(T.output_shares(net, o), ' ')) end
	local st = bm.prepare(L, { mix = 'blend', throughput = true, blocked = true, marks = true })
	line('balance: ' .. tostring(st.bal and st.bal.verdict))
	line('lanes: ' .. tostring(st.bal and st.bal.lane_verdict))
	line('throughput: ' .. tostring(st.tp and st.tp.verdict))
	line('blocked: ' .. tostring(st.blk and st.blk.verdict))
	line('inputs: ' .. tostring(st.ibal and st.ibal.verdict))
	local D, why = NET.wires(NET.graph(net))
	line('wires: ' .. (D and (D.cost .. ' ' .. D.code) or ('none: ' .. why)))
	line('alt: ' .. bm.describe(st))
	line('caption: ' .. bm.caption(st))
	for _, ks in ipairs(KEYSETS) do
		local opts = {}
		for k, v in pairs(ks[2]) do opts[k] = v end
		local s = bm.prepare(L, opts)
		line('')
		line('== tikz: ' .. ks[1])
		for _, l in ipairs(bm.tikz(s)) do line(l) end
	end
	return table.concat(out, '\n') .. '\n'
end

-- Equal up to the numeric tolerance; returns nil or the first differing line.
local function compare(a, b)
	local la, lb = {}, {}
	for l in (a .. '\n'):gmatch('([^\n]*)\n') do la[#la + 1] = l end
	for l in (b .. '\n'):gmatch('([^\n]*)\n') do lb[#lb + 1] = l end
	if #la ~= #lb then return string.format('%d lines, expected %d', #la, #lb) end
	for i = 1, #la do
		if la[i] ~= lb[i] then
			local na, nb = {}, {}
			local sa = la[i]:gsub('%-?%d+%.?%d*', function(x) na[#na + 1] = x; return '#' end)
			local sb = lb[i]:gsub('%-?%d+%.?%d*', function(x) nb[#nb + 1] = x; return '#' end)
			local fine = (sa == sb) and (#na == #nb)
			if fine then
				for j = 1, #na do
					local tol = (na[j]:find('%.') or nb[j]:find('%.')) and 0.002 or 1
					if math.abs(tonumber(na[j]) - tonumber(nb[j])) > tol then fine = false end
				end
			end
			if not fine then return string.format('line %d:\n  got:      %s\n  expected: %s', i, la[i]:sub(1, 160), lb[i]:sub(1, 160)) end
		end
	end
	return nil
end

local cases = {}
local subjects = {}
for _, f in ipairs(T.EXAMPLES) do subjects[#subjects + 1] = { f:gsub('%..*$', ''), function() return T.example(f) end } end
local keys = {}
for k in pairs(T.GRIDS) do keys[#keys + 1] = k end
table.sort(keys)
for _, k in ipairs(keys) do
	subjects[#subjects + 1] = { 'grid ' .. k, function() return T.grid(T.GRIDS[k]) end }
end

for _, s in ipairs(subjects) do
	local slug = s[1]:gsub('[^%w]+', '-'):gsub('^%-', ''):gsub('%-$', ''):lower()
	cases[#cases + 1] = { s[1], function()
		local got = snapshot(s[2]())
		local path = T.root .. '/tests/golden/' .. slug .. '.txt'
		if T.update then
			T.write(path, got)
			return
		end
		local want = T.read(path)
		T.ok(want, 'no golden file ' .. path .. ' (run texlua tests/run.lua --update)')
		want = want:gsub('\r\n', '\n')
		local diff = compare(got, want)
		if diff then
			T.mkdirs(T.root .. '/tests/golden/actual')
			T.write(T.root .. '/tests/golden/actual/' .. slug .. '.txt', got)
			error('snapshot differs from tests/golden/' .. slug .. '.txt, ' .. diff, 0)
		end
	end }
end

return cases
