-- Shared helpers for the Lua tests (tests/run.lua loads this first).
local T = {}

T.root = BELTMAP_TEST.root
T.update = BELTMAP_TEST.update
T.bm = require('beltmap')
T.NET = require('beltmap-net')

function T.ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
	return v
end

function T.eq(got, want, msg)
	if got ~= want then
		error(string.format('%s: expected %s, got %s', msg or 'not equal', tostring(want), tostring(got)), 2)
	end
end

function T.example(name) return T.bm.layout_from_file(T.root .. '/examples/' .. name, {}) end
function T.grid(body) return T.bm.grid_layout(body) end

-- The network of a layout.
function T.net(L) return T.NET.build(T.bm.trace(L, L.gap or 10)) end

-- What output o of net carries of each input, as strings of exact fractions.
function T.output_shares(net, o)
	local out = net.outputs[o]
	local per = T.NET.belt(net, net.last[out.k])
	local s = {}
	for i = 1, net.n do s[i] = tostring(per[i]) end
	return s
end

-- The four examples, and small grids with known answers.  Grid rows are separated by \\.
T.EXAMPLES = { 'f00_9x10.json', 'f01_9x10.json', 'f04_11x8.txt', 'f05_11x8.txt' }
T.GRIDS = {
	['2-2'] = '> S> > \\\\ > S> >',
	['4-4 three splitters'] = '> S> > > > \\\\ > S> > S> > \\\\ > S> > S> > \\\\ > S> > > >',
	['2-3 uneven'] = '> S> > > > \\\\ > S> > S> > \\\\ . . . S> >',
	['2-2 input priority'] = '> S>[in=left] > \\\\ > S> >',
	['2-2 output priority'] = '> S>[out=left] > \\\\ > S> >',
	['1-2 one belt in'] = '> S> > \\\\ . S> >',
	['2-2 limited'] = '> S> > S> > \\\\ > S> . S> >',
}

function T.read(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local s = f:read('*a')
	f:close()
	return s
end

function T.write(path, s)
	local f = assert(io.open(path, 'wb'))
	f:write(s)
	f:close()
end

-- A real RGBA PNG of w by h pixels, gray, with a pHYs chunk when dpi is given: made here so
-- that the repository holds no image files.
function T.png(w, h, dpi)
	local function chunk(typ, data)
		local crc = zlib.crc32(zlib.crc32(), typ .. data)
		return string.pack('>I4', #data) .. typ .. data .. string.pack('>I4', crc)
	end
	local rows = {}
	for _ = 1, h do rows[#rows + 1] = '\0' .. string.rep('\128\128\128\255', w) end
	local s = '\137PNG\r\n\26\n' .. chunk('IHDR', string.pack('>I4>I4BBBBB', w, h, 8, 6, 0, 0, 0))
	if dpi then
		local ppm = math.floor(dpi / 0.0254 + 0.5)
		s = s .. chunk('pHYs', string.pack('>I4>I4B', ppm, ppm, 1))
	end
	return s .. chunk('IDAT', zlib.compress(table.concat(rows))) .. chunk('IEND', '')
end

function T.mkdirs(path)
	local acc = ''
	for part in path:gmatch('[^/]+') do
		acc = (acc == '' and (path:sub(1, 1) == '/' and '/' or '') or acc .. '/') .. part
		if not lfs.attributes(acc) then lfs.mkdir(acc) end
	end
end

return T
