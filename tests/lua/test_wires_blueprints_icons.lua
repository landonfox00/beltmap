-- view=wires, blueprint strings, and game-icon lookup.
local T = require('lib')
local bm, NET = T.bm, T.NET

local function wires_of(L) return NET.wires(NET.graph(T.net(L))) end

return {
	{ 'wires: isomorphic layouts draw the same, others differ', function()
		local c00 = wires_of(T.example('f00_9x10.json'))
		local c01 = wires_of(T.example('f01_9x10.json'))
		local c04 = wires_of(T.example('f04_11x8.txt'))
		local c05 = wires_of(T.example('f05_11x8.txt'))
		T.eq(c00.code, c01.code, 'f00 and f01 are one network')
		T.ok(c04.code ~= c05.code, 'f04 and f05 are not')
		T.eq(c00.cost, 16)
		T.eq(#c00.loops, 1)
		T.eq(#c04.loops, 2)
	end },
	{ 'wires: reordering the graph does not change the drawing', function()
		local g = NET.graph(T.net(T.example('f00_9x10.json')))
		local g2 = { nodes = {}, arcs = {} }
		for i = #g.nodes, 1, -1 do g2.nodes[#g2.nodes + 1] = g.nodes[i] end
		for i = #g.arcs, 1, -1 do g2.arcs[#g2.arcs + 1] = g.arcs[i] end
		T.eq(NET.wires(g2).code, NET.wires(g).code)
	end },
	{ 'wires: a splitter with one belt in is refused with a reason', function()
		local r, why = wires_of(T.grid(T.GRIDS['1-2 one belt in']))
		T.ok(not r and why and why:find('two belts in'), tostring(why))
	end },
	{ 'blueprints: every example writes and reads back, 2.0 and 1.1', function()
		local layouts = {}
		for _, f in ipairs(T.EXAMPLES) do layouts[#layouts + 1] = { f, T.example(f) } end
		for key, body in pairs(T.GRIDS) do layouts[#layouts + 1] = { key, T.grid(body) } end
		for _, c in ipairs(layouts) do
			for _, numbering in ipairs({ 16, 8 }) do
				local s = bm.encode_blueprint(bm.blueprint_of(c[2], { numbering = numbering }))
				local diffs = bm.check_blueprint(c[2], s, numbering)
				T.eq(#diffs, 0, c[1] .. ' (' .. numbering .. ' directions): ' .. table.concat(diffs, '; '))
			end
		end
	end },
	{ 'blueprints: the network survives the round trip', function()
		for _, f in ipairs(T.EXAMPLES) do
			local L = T.example(f)
			local s = bm.encode_blueprint(bm.blueprint_of(L, {}))
			local back = bm.blueprint_layout(bm.decode_blueprint(s).blueprint, 16)
			T.ok(NET.verdicts(T.net(back)).balanced, f)
		end
	end },
	{ 'icons: PNG size from the header, with and without pHYs', function()
		local dir = T.root .. '/tests/tmp'
		T.mkdirs(dir)
		T.write(dir .. '/a.png', T.png(120, 64))
		T.write(dir .. '/b.png', T.png(120, 64, 144))
		T.write(dir .. '/c.png', 'GIF89a nonsense')
		local w, h = bm.png_size(dir .. '/a.png')
		T.eq(w, 120); T.eq(h, 64)
		w, h = bm.png_size(dir .. '/b.png')
		T.ok(math.abs(w - 60) < 0.01 and math.abs(h - 32) < 0.01, 'at 144 dpi a pixel is half a point: ' .. w .. ' x ' .. h)
		T.eq(bm.png_size(dir .. '/c.png'), nil, 'not a PNG')
	end },
	{ 'icons: lookup through prototypes, mods, and the fallback', function()
		local dir = T.root .. '/tests/tmp/factorio-data'
		T.mkdirs(dir .. '/base/prototypes')
		T.mkdirs(dir .. '/base/graphics/icons')
		T.mkdirs(dir .. '/extra/prototypes')
		T.mkdirs(dir .. '/extra/graphics/icons')
		T.write(dir .. '/base/prototypes/item.lua',
			'data:extend({\n  { type = "item", name = "widget", icon = "__base__/graphics/icons/widget-art.png" },\n' ..
			'  { type = "item", name = "bare" },\n})\n')
		T.write(dir .. '/extra/prototypes/item.lua', 'data:extend({ { type = "item", name = "gizmo", icon = "__extra__/graphics/icons/gizmo.png" } })\n')
		for _, p in ipairs({ '/base/graphics/icons/widget-art.png', '/base/graphics/icons/bare.png', '/extra/graphics/icons/gizmo.png' }) do
			T.write(dir .. p, T.png(120, 64))
		end
		T.write(dir .. '/base/prototypes/broken.lua', 'data:extend({ { type = "item", name = "broken", icon = "__base__/graphics/icons/broken.png" } })\n')
		T.write(dir .. '/base/graphics/icons/broken.png', 'not a PNG at all')
		bm.icon_opts = { data = dir }
		T.ok((bm.icon_file('widget') or ''):find('/base/graphics/icons/widget%-art%.png$'), 'prototype icon path')
		T.ok((bm.icon_file('gizmo') or ''):find('/extra/graphics/icons/gizmo%.png$'), 'a mod icon')
		T.ok((bm.icon_file('bare') or ''):find('/base/graphics/icons/bare%.png$'), 'name.png fallback')
		local p, why = bm.icon_file('nothing-like-it')
		T.ok(not p and why:find('no icon for nothing%-like%-it'), tostring(why))
		T.eq(bm.icon_tex('gizmo', '1em'), '\\BeltmapIconImage{0 0 64.0000 64.0000}{1em}{' .. dir .. '/extra/graphics/icons/gizmo.png}',
			'the left 64 by 64 square of a 120 by 64 icon at 72 dpi')
		-- a file that is not a PNG gets the placeholder (img.scan would crash LuaTeX on it)
		T.eq(bm.icon_tex('broken', '1em'), '\\BeltmapIconMissing{1em}{B}')
		bm.icon_opts = { data = dir, off = true }
		T.eq(bm.icon_tex('iron-ore', '1em'), '\\BeltmapIconMissing{1em}{IO}', 'placeholder with initials')
		bm.icon_opts = nil
	end },
}
