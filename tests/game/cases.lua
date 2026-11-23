-- The layouts of the full-load comparison with Factorio.  Every run keeps its fed input lanes
-- full and empties its open outputs.  `all` runs every choice of inputs and outputs.
local C = {}

C.cases = {
	{ name = 'one splitter', grid = '> S> > \\\\ > S> >', all = true },
	{ name = 'manual example', grid = '> S> > S> > \\\\ > S> . S> >', all = true },
	{ name = 'two in series', grid = '> S> > S> > \\\\ > S> > S> >', all = true },
	{ name = 'four belts, three splitters', grid = '> S> > > > \\\\ > S> > S> > \\\\ > S> > S> > \\\\ > S> > > >', all = true },
	{ name = 'two to three', grid = '> S> > > > \\\\ > S> > S> > \\\\ . . . S> >', all = true },
	{ name = 'input priority', grid = '> S>[in=left] > \\\\ > S> >', all = true },
	{ name = 'output priority', grid = '> S>[out=left] > \\\\ > S> >', all = true },
	{ name = 'side-load onto a belt', grid = '. v . . \\\\ > > > >', all = true },
	{ name = 'side-load, both sides', grid = '. v . . \\\\ > > > > \\\\ . ^ . .', all = true },
	{ name = 'lane balancer', grid = '. S> > > v . \\\\ > S> v . > > \\\\ . . > > ^ .', all = true },
	{ name = 'entrance side-load', grid = '. v . . . . \\\\ > I> . . O> >', all = true },
	{ name = 'exit side-load', grid = '. . . . v . \\\\ > I> . . O> >', all = true },
	{ name = 'f00', file = 'f00_9x10.json', all = true },
	{ name = 'f01', file = 'f01_9x10.json', sample = 40 },
	{ name = 'f04', file = 'f04_11x8.txt', sample = 40 },
	{ name = 'f05', file = 'f05_11x8.txt', sample = 40 },
}

C.ITEM = 'iron-plate'
C.WARMUP, C.MEASURE = 1800, 7200

-- root: the folder that holds examples/.
function C.read(bm, NET, c, root)
	local L = c.file and bm.layout_from_file(root .. '/examples/' .. c.file, {}) or bm.grid_layout(c.grid)
	local tr = bm.trace(L, L.gap or 4)
	local net = NET.build(tr)
	local inputs, outputs = {}, {}
	for i, k in ipairs(net.sources) do
		local t = tr.segs[k].tiles[1]
		inputs[i] = { x = t.x, y = t.y }
	end
	for o, out in ipairs(net.outputs) do outputs[o] = { x = out.tile.x, y = out.tile.y } end
	return L, net, inputs, outputs
end

-- The choices of a case: every pair of nonempty sets, or an evenly spaced sample of them plus the
-- all-to-all choice.  Each choice is { I = {...}, O = {...} }.
function C.choices(c, n, m)
	local list = {}
	local function members(mask, size)
		local s = {}
		for i = 1, size do if (mask >> (i - 1)) & 1 == 1 then s[#s + 1] = i end end
		return s
	end
	for mi = 1, (1 << n) - 1 do
		for mo = 1, (1 << m) - 1 do list[#list + 1] = { I = members(mi, n), O = members(mo, m) } end
	end
	if c.all then return list end
	local out, step = {}, #list / c.sample
	for j = 0, c.sample - 1 do out[#out + 1] = list[math.floor(j * step) + 1] end
	out[#out + 1] = list[#list]
	return out
end

return C
