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

-- beltmap.lua: reads belt layouts, traces their belts, and writes TikZ for beltmap.sty.
--
-- Inputs: Factorio-SAT tiles (JSON), search records (JSONL), blueprint strings and books
-- (Factorio 1.1 and 2.0), and the character grid of the beltgrid environment.  The tracer
-- numbers the belts in the order it meets them, which fixes their colors.
--  Runs under LuaLaTeX, and under texlua for the
-- tests (no tex or token library needed until emit()).

local M = { version = '0.2' }
local NET = require('beltmap-net')
M.NET = NET

local VEC = { [0] = { 1, 0 }, { 0, -1 }, { -1, 0 }, { 0, 1 } }
local DIRS = { right = 0, up = 1, left = 2, down = 3 }
local DIRNAME = { [0] = 'right', 'up', 'left', 'down' }
local TIERS = {
	yellow = { prefix = '', gap = 4, name = 'yellow' },
	red = { prefix = 'fast-', gap = 6, name = 'red' },
	blue = { prefix = 'express-', gap = 8, name = 'blue' },
	turbo = { prefix = 'turbo-', gap = 10, name = 'turbo' },
}
local TIER_ORDER = { 'yellow', 'red', 'blue', 'turbo' }
local PREFIX = { [''] = 'yellow', ['fast-'] = 'red', ['express-'] = 'blue', ['turbo-'] = 'turbo' }
local TIER_RGB = { yellow = { 240, 184, 32 }, red = { 226, 66, 50 }, blue = { 64, 150, 236 }, turbo = { 132, 204, 56 } }

-- Geometry in tiles.
local LW, MARGIN, UNDER, HOOD_MOUTH, HOOD_END = 0.29, 0.16, 0.05, 0.06, 0.42

local function fail(msg)
	error({ beltmap = msg }, 0)
end

-- ------------------------------------------------------------------ JSON

local function json_decode(s)
	local pos = 1
	local value
	local function ws()
		pos = s:find('[^ \t\r\n]', pos) or #s + 1
	end
	local function bad(what)
		fail(string.format('bad JSON (%s) at character %d', what, pos))
	end
	local ESC = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
	local function str()
		if s:sub(pos, pos) ~= '"' then bad('string expected') end
		local out, i = {}, pos + 1
		while true do
			local c = s:sub(i, i)
			if c == '"' then
				pos = i + 1
				return table.concat(out)
			elseif c == '\\' then
				local e = s:sub(i + 1, i + 1)
				if e == 'u' then
					out[#out + 1] = utf8.char(tonumber(s:sub(i + 2, i + 5), 16))
					i = i + 6
				else
					out[#out + 1] = ESC[e] or e
					i = i + 2
				end
			elseif c == '' then
				bad('unterminated string')
			else
				local j = s:find('["\\]', i) or #s + 1
				out[#out + 1] = s:sub(i, j - 1)
				i = j
			end
		end
	end
	function value()
		ws()
		local c = s:sub(pos, pos)
		if c == '{' then
			local t = {}
			pos = pos + 1
			ws()
			if s:sub(pos, pos) == '}' then
				pos = pos + 1
				return t
			end
			while true do
				ws()
				local k = str()
				ws()
				if s:sub(pos, pos) ~= ':' then bad('":" expected') end
				pos = pos + 1
				t[k] = value()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == '}' then return t end
				if d ~= ',' then bad('"," or "}" expected') end
			end
		elseif c == '[' then
			local t, n = {}, 0
			pos = pos + 1
			ws()
			if s:sub(pos, pos) == ']' then
				pos = pos + 1
				return t
			end
			while true do
				n = n + 1
				t[n] = value()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == ']' then return t end
				if d ~= ',' then bad('"," or "]" expected') end
			end
		elseif c == '"' then
			return str()
		elseif s:sub(pos, pos + 3) == 'true' then
			pos = pos + 4
			return true
		elseif s:sub(pos, pos + 4) == 'false' then
			pos = pos + 5
			return false
		elseif s:sub(pos, pos + 3) == 'null' then
			pos = pos + 4
			return nil
		else
			local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
			if not num or num == '' then bad('value expected') end
			pos = pos + #num
			local v = tonumber(num)
			return math.tointeger(v) or v
		end
	end
	local v = value()
	return v
end
M.json_decode = json_decode

-- ------------------------------------------------------------------ positions and layouts
-- A layout is { w, h, cells = { [key] = tile } }; every tile carries pos = { x, y, k }.

local function P(x, y)
	return { x = x, y = y, k = x .. ',' .. y }
end

local function less(a, b)
	if a.x ~= b.x then return a.x < b.x end
	return a.y < b.y
end

local function add(p, d, n)
	n = n or 1
	return P(p.x + n * VEC[d][1], p.y + n * VEC[d][2])
end

local function out_dir(t)
	if t.type == 'belt' then return t.output_direction end
	return t.direction
end

local function copy(t)
	local u = {}
	for k, v in pairs(t) do u[k] = v end
	return u
end

-- {[{x,y}] = tile} with any coordinates -> a layout moved to start at 0, with the input
-- direction of every belt that has none set by Factorio's rule: a belt turns when exactly
-- one neighbor feeds it from a side and none from behind.
local function from_cells(list)
	if #list == 0 then fail('the layout holds no belts, underground belts or splitters') end
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, e in ipairs(list) do
		x0, y0 = math.min(x0, e[1]), math.min(y0, e[2])
		x1, y1 = math.max(x1, e[1]), math.max(y1, e[2])
	end
	local L = { w = x1 - x0 + 1, h = y1 - y0 + 1, cells = {} }
	for _, e in ipairs(list) do
		local t = e[3]
		t.pos = P(e[1] - x0, e[2] - y0)
		if L.cells[t.pos.k] then fail('two entities on the tile ' .. t.pos.k) end
		L.cells[t.pos.k] = t
	end
	local function feeds(c, d)
		local n = L.cells[add(c, d, -1).k]
		if n == nil or (n.type == 'underground_belt' and n.is_input) then return false end
		return out_dir(n) == d
	end
	for _, t in pairs(L.cells) do
		if t.type == 'belt' and t.input_direction == nil then
			local o = t.output_direction
			local sides = {}
			for _, d in ipairs({ (o + 1) % 4, (o + 3) % 4 }) do
				if feeds(t.pos, d) then sides[#sides + 1] = d end
			end
			t.input_direction = (#sides == 1 and not feeds(t.pos, o)) and sides[1] or o
		end
	end
	return L
end

local function from_tile_rows(rows)
	local list = {}
	for y, row in ipairs(rows) do
		for x, t in ipairs(row) do
			if t.type == 'belt' or t.type == 'underground_belt' or t.type == 'splitter' then
				list[#list + 1] = { x - 1, y - 1, copy(t) }
			end
		end
	end
	local L = from_cells(list)
	-- Keep the grid of the file, empty border included.
	L.w = math.max(L.w, #rows[1])
	L.h = math.max(L.h, #rows)
	local ox, oy = math.huge, math.huge
	for _, e in ipairs(list) do ox, oy = math.min(ox, e[1]), math.min(oy, e[2]) end
	if ox > 0 or oy > 0 then
		local moved = {}
		for _, t in pairs(L.cells) do
			t.pos = P(t.pos.x + ox, t.pos.y + oy)
			moved[t.pos.k] = t
		end
		L.cells = moved
	end
	return L
end

function M.rotate(L, turns)
	for _ = 1, turns % 4 do
		local N = { w = L.h, h = L.w, cells = {} }
		for _, t in pairs(L.cells) do
			local u = copy(t)
			for _, key in ipairs({ 'direction', 'input_direction', 'output_direction' }) do
				if u[key] ~= nil then u[key] = (u[key] + 1) % 4 end
			end
			u.pos = P(t.pos.y, L.w - 1 - t.pos.x)
			N.cells[u.pos.k] = u
		end
		L = N
	end
	return L
end

local function with_tier(L, tier)
	for _, t in pairs(L.cells) do
		if t.tier == nil then t.tier = tier end
	end
end

local function tiers_of(L)
	local seen, out = {}, {}
	for _, t in pairs(L.cells) do
		if t.tier and TIERS[t.tier] then seen[t.tier] = true end
	end
	for _, name in ipairs(TIER_ORDER) do
		if seen[name] then out[#out + 1] = name end
	end
	return out
end

-- ------------------------------------------------------------------ blueprints

function M.decode_blueprint(text)
	text = text:gsub('^%s+', ''):gsub('%s+$', '')
	if text:sub(1, 1) == '{' then return json_decode(text) end
	text = text:gsub('%s+', '')
	if text:sub(1, 1) ~= '0' then fail('a blueprint string starts with the version byte 0') end
	local mime = require('mime')
	local ok, raw = pcall(function() return zlib.decompress(mime.unb64(text:sub(2))) end)
	if not ok or not raw then fail('the blueprint string does not decode (base64, then zlib)') end
	return json_decode(raw)
end

local function blueprints_in(obj, path, out)
	out = out or {}
	path = path or ''
	if obj.blueprint then
		out[#out + 1] = { label = path .. (obj.blueprint.label or '(no label)'), bp = obj.blueprint }
	elseif obj.blueprint_book then
		local book = obj.blueprint_book
		for _, item in ipairs(book.blueprints or {}) do
			blueprints_in(item, path .. (book.label or 'book') .. ' / ', out)
		end
	end
	return out
end
M.blueprints_in = blueprints_in

local KINDS = { { 'underground-belt', 'underground_belt' }, { 'transport-belt', 'belt' }, { 'splitter', 'splitter' } }

-- Directions: Factorio 1.1 counts 8 (north 0, east 2, south 4, west 6), Factorio 2.0
-- counts 16 (north 0, east 4, south 8, west 12).  "version" holds the game version with the
-- major number in its highest 16 bits; numbering (8 or 16) overrides it.  A splitter
-- filter is a string in 1.1 and { name, quality, comparator } in 2.0.
function M.blueprint_layout(bp, numbering)
	local version = bp.version
	local major = math.type(version) == 'integer' and (version >> 48) or nil
	if not numbering then
		numbering = (major and major >= 2) and 16 or 8
		if not major then
			for _, e in ipairs(bp.entities or {}) do
				if (e.direction or 0) > 7 then numbering = 16 end
			end
		end
	end
	local step = numbering // 4
	local list, skipped = {}, {}
	for _, e in ipairs(bp.entities or {}) do
		local name, kind, suffix = e.name or '', nil, nil
		for _, ks in ipairs(KINDS) do
			if name == ks[1] or name:sub(-#ks[1] - 1) == '-' .. ks[1] then
				kind, suffix = ks[2], ks[1]
				break
			end
		end
		local raw = math.tointeger(e.direction or 0) or 0
		if kind == nil or raw % step ~= 0 then
			skipped[#skipped + 1] = name
		else
			local tier = PREFIX[name:sub(1, #name - #suffix)]
			local d = ({ [0] = 1, 0, 3, 2 })[(raw // step) % 4]
			local x, y = e.position.x, e.position.y
			if kind == 'belt' then
				list[#list + 1] = { math.floor(x), math.floor(y), { type = 'belt', output_direction = d, tier = tier } }
			elseif kind == 'underground_belt' then
				list[#list + 1] = { math.floor(x), math.floor(y), { type = 'underground_belt', direction = d, is_input = (e.type or 'input') == 'input', tier = tier } }
			else
				local n = VEC[(d + 1) % 4]
				local hx, hy = math.floor(x - n[1] / 2), math.floor(y - n[2] / 2)
				local t = { type = 'splitter', direction = d, is_head = true, tier = tier }
				if e.input_priority == 'left' or e.input_priority == 'right' then t.input_priority = e.input_priority end
				if e.output_priority == 'left' or e.output_priority == 'right' then t.output_priority = e.output_priority end
				local f = e.filter
				if type(f) == 'table' then
					-- Kept as read, so that writing the layout again gives the same filter: the
					-- game leaves out quality and comparator when the filter takes any quality.
					t.filter_object = { quality = f.quality, comparator = f.comparator }
					local note = ''
					if f.quality == nil then
						note = ' (any quality)'
					elseif f.quality ~= 'normal' or (f.comparator and f.comparator ~= '=' and f.comparator ~= '==') then
						note = string.format(' (quality %s %s)', f.comparator or '=', f.quality)
					end
					f = (f.name or 'any item') .. note
				end
				if f and f ~= '' then t.filter = f end
				list[#list + 1] = { hx, hy, t }
				list[#list + 1] = { hx + n[1], hy + n[2], { type = 'splitter', direction = d, is_head = false, tier = tier } }
			end
		end
	end
	local L = from_cells(list)
	L.numbering, L.skipped, L.label = numbering, skipped, bp.label
	if major then
		L.version = string.format('%d.%d.%d', version >> 48, (version >> 32) & 0xffff, (version >> 16) & 0xffff)
	end
	return L
end

-- ------------------------------------------------------------------ writing blueprints

local function json_encode(v)
	local t = type(v)
	if t == 'table' then
		local parts = {}
		if v[1] ~= nil then
			for i, x in ipairs(v) do parts[i] = json_encode(x) end
			return '[' .. table.concat(parts, ',') .. ']'
		end
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys)
		for i, k in ipairs(keys) do parts[i] = json_encode(k) .. ':' .. json_encode(v[k]) end
		return '{' .. table.concat(parts, ',') .. '}'
	elseif t == 'string' then
		return '"' .. v:gsub('[%c"\\]', function(c)
			return ({ ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' })[c] or string.format('\\u%04x', c:byte())
		end) .. '"'
	elseif t == 'number' then
		if math.type(v) == 'integer' then return string.format('%d', v) end
		if v == math.floor(v) then return string.format('%d', math.floor(v)) end
		return string.format('%.1f', v)
	end
	return tostring(v)
end
M.json_encode = json_encode

-- The item of a filter as blueprint_layout() shows it, without its quality note.
function M.filter_item(s)
	return (s:gsub(' %(quality [^()]*%)$', ''):gsub(' %(any quality%)$', ''))
end

-- Game versions written into the blueprint, packed as the game packs them.
local function pack_version(a, b, c) return (a << 48) | (b << 32) | (c << 16) end
local VERSION = { [8] = pack_version(1, 1, 110), [16] = pack_version(2, 0, 28) }

-- The blueprint of a layout: belts, underground belts and splitters, in the numbering of
-- Factorio 2.0 (16) or 1.1 (8).  Tiles without a tier become yellow (plain) entities.
-- Belt turns are not stored in a blueprint: the game works them out from the neighbors,
-- as from_cells() does, so check_blueprint() can tell when a turn would come out wrong.
function M.blueprint_of(L, opts)
	opts = opts or {}
	local numbering = opts.numbering or 16
	local step = numbering // 4
	local function dir(d) return ({ [0] = 1, 0, 3, 2 })[d] * step end
	local function name(t, kind)
		local tier = (t.tier and TIERS[t.tier]) and t.tier or (opts.tier or 'yellow')
		return TIERS[tier].prefix .. kind
	end
	local order = {}
	for _, t in pairs(L.cells) do order[#order + 1] = t end
	table.sort(order, function(a, b)
		if a.pos.y ~= b.pos.y then return a.pos.y < b.pos.y end
		return a.pos.x < b.pos.x
	end)
	local ents, partner_of = {}, {}
	for _, t in ipairs(order) do
		local x, y = t.pos.x, t.pos.y
		local e
		if t.type == 'belt' then
			e = { name = name(t, 'transport-belt'), position = { x = x + 0.5, y = y + 0.5 }, direction = dir(t.output_direction) }
		elseif t.type == 'underground_belt' then
			e = { name = name(t, 'underground-belt'), position = { x = x + 0.5, y = y + 0.5 }, direction = dir(t.direction), type = t.is_input and 'input' or 'output' }
		elseif t.is_head then
			local d = t.direction
			local n = VEC[(d + 1) % 4]
			local o = L.cells[add(t.pos, (d + 1) % 4).k]
			if not o or o.type ~= 'splitter' or o.is_head or o.direction ~= d then
				fail('the splitter at column ' .. (x + 1) .. ', row ' .. (y + 1) .. ' has no second tile, so it has no blueprint')
			end
			partner_of[o.pos.k] = true
			e = { name = name(t, 'splitter'), position = { x = x + 0.5 + n[1] / 2, y = y + 0.5 + n[2] / 2 }, direction = dir(d) }
			if t.input_priority then e.input_priority = t.input_priority end
			if t.output_priority then e.output_priority = t.output_priority end
			if t.filter then
				local item = M.filter_item(t.filter)
				if numbering == 8 then
					e.filter = item
				elseif t.filter_object then
					e.filter = { name = item, quality = t.filter_object.quality, comparator = t.filter_object.comparator }
				else
					-- What the game makes of a 1.1 filter: this item in normal quality.
					e.filter = { name = item, quality = 'normal', comparator = '=' }
				end
			end
		end
		if e then
			e.entity_number = #ents + 1
			ents[#ents + 1] = e
		end
	end
	for _, t in ipairs(order) do
		if t.type == 'splitter' and not t.is_head and not partner_of[t.pos.k] then
			fail('the splitter tile at column ' .. (t.pos.x + 1) .. ', row ' .. (t.pos.y + 1) .. ' has no head, so it has no blueprint')
		end
	end
	local belt = ents[1] and ents[1].name or 'transport-belt'
	local icon = (numbering == 16) and { name = belt } or { type = 'item', name = belt }
	return {
		blueprint = {
			item = 'blueprint',
			label = opts.label or L.label or 'Belt layout',
			icons = { { index = 1, signal = icon } },
			entities = ents,
			version = VERSION[numbering],
		},
	}
end

function M.encode_blueprint(obj)
	local mime = require('mime')
	return '0' .. (mime.b64(zlib.compress(json_encode(obj), 9)))
end

-- Reads a blueprint string back and compares it with the layout, tile by tile.  Returns a
-- list of differences; a belt whose turn the game would work out differently is one.
function M.check_blueprint(L, s, numbering)
	local back = M.blueprint_layout(M.decode_blueprint(s).blueprint, numbering)
	local x0, y0 = math.huge, math.huge
	for _, t in pairs(L.cells) do x0, y0 = math.min(x0, t.pos.x), math.min(y0, t.pos.y) end
	local diffs, n = {}, 0
	for _, t in pairs(L.cells) do
		n = n + 1
		local u = back.cells[P(t.pos.x - x0, t.pos.y - y0).k]
		local where = 'column ' .. (t.pos.x + 1) .. ', row ' .. (t.pos.y + 1)
		if not u or u.type ~= t.type then
			diffs[#diffs + 1] = where .. ': missing'
		elseif t.type == 'belt' then
			if u.output_direction ~= t.output_direction then diffs[#diffs + 1] = where .. ': belt points another way' end
			if u.input_direction ~= t.input_direction then diffs[#diffs + 1] = where .. ': the game would turn this belt differently' end
		elseif t.type == 'underground_belt' then
			if u.direction ~= t.direction or u.is_input ~= t.is_input then diffs[#diffs + 1] = where .. ': underground belt differs' end
		elseif u.direction ~= t.direction or u.is_head ~= (t.is_head and true or false) then
			diffs[#diffs + 1] = where .. ': splitter differs'
		elseif t.is_head and (u.input_priority ~= t.input_priority or u.output_priority ~= t.output_priority) then
			diffs[#diffs + 1] = where .. ': splitter priorities differ'
		end
	end
	local m = 0
	for _ in pairs(back.cells) do m = m + 1 end
	if m ~= n then diffs[#diffs + 1] = string.format('%d tiles written, %d read back', n, m) end
	table.sort(diffs)
	return diffs
end

-- ------------------------------------------------------------------ the beltgrid environment
-- Cells separated by spaces, rows by \\.  > < ^ v belt; I> underground entrance and O> exit
-- (any direction letter); S> a splitter tile, typed on both of its tiles, with options in
-- brackets on either: S>[in=left,out=right,filter=iron-ore]; . or _ an empty tile.

local ARROW = { ['>'] = 0, ['^'] = 1, ['<'] = 2, ['v'] = 3 }

local function parse_options(s)
	local t = {}
	for item in s:gmatch('[^,]+') do
		local k, v = item:match('^%s*([%w ]-)%s*=%s*(.-)%s*$')
		if not k then fail('splitter option without "=": ' .. item) end
		k = k:gsub('%s+', ' ')
		if k == 'in' or k == 'input priority' then t.input_priority = v
		elseif k == 'out' or k == 'output priority' then t.output_priority = v
		elseif k == 'filter' then t.filter = v
		elseif k == 'tier' then t.tier = v
		else fail('unknown splitter option ' .. k) end
	end
	for _, key in ipairs({ 'input_priority', 'output_priority' }) do
		if t[key] and t[key] ~= 'left' and t[key] ~= 'right' then fail(key:gsub('_', ' ') .. ' is left or right, not ' .. t[key]) end
	end
	return t
end

function M.grid_layout(body)
	body = body:gsub('\\par%s', '\\\\ ')
	local list, splits = {}, {}
	local y = 0
	for row in (body .. '\\\\'):gmatch('(.-)\\\\') do
		local x, any = 0, false
		local rest = row
		while true do
			rest = rest:gsub('^%s+', '')
			if rest == '' then break end
			any = true
			local tok, opts, after = rest:match('^([^%s%[]+)(%b[])(.*)$')
			if not tok then
				tok, after = rest:match('^(%S+)(.*)$')
			end
			rest = after
			opts = opts and parse_options(opts:sub(2, -2)) or {}
			local d = ARROW[tok]
			if d then
				list[#list + 1] = { x, y, { type = 'belt', output_direction = d, tier = opts.tier } }
			elseif tok == '.' or tok == '_' then
				-- empty
			else
				local kind, a = tok:sub(1, 1), ARROW[tok:sub(2)]
				if a == nil or #tok ~= 2 then fail('unknown grid cell "' .. tok .. '" in row ' .. (y + 1)) end
				if kind == 'I' or kind == 'O' then
					list[#list + 1] = { x, y, { type = 'underground_belt', direction = a, is_input = kind == 'I', tier = opts.tier } }
				elseif kind == 'S' then
					local t = { type = 'splitter', direction = a, is_head = false }
					for k, v in pairs(opts) do t[k] = v end
					list[#list + 1] = { x, y, t }
					splits[x .. ',' .. y] = t
				else
					fail('unknown grid cell "' .. tok .. '" in row ' .. (y + 1))
				end
			end
			x = x + 1
		end
		if any then y = y + 1 end
	end
	-- Pair splitter tiles side by side across their direction; the head is the right-hand one.
	local done = {}
	local keys = {}
	for _, e in ipairs(list) do
		if e[3].type == 'splitter' then keys[#keys + 1] = e end
	end
	for _, e in ipairs(keys) do
		local k = e[1] .. ',' .. e[2]
		if not done[k] then
			local t = e[3]
			local d = t.direction
			local across = (d % 2 == 0) and 3 or 0       -- the partner is below, or to the right
			local ok = P(e[1] + VEC[across][1], e[2] + VEC[across][2]).k
			local u = splits[ok]
			if not u or done[ok] or u.direction ~= d then
				fail('splitter tile at column ' .. (e[1] + 1) .. ', row ' .. (e[2] + 1) .. ' has no partner ' .. ((d % 2 == 0) and 'below it' or 'to its right'))
			end
			done[k], done[ok] = true, true
			-- The head's partner lies in direction d + 1 (to its left).
			local left = VEC[(d + 1) % 4]
			local head, other = t, u
			if not (left[1] == VEC[across][1] and left[2] == VEC[across][2]) then head, other = u, t end
			head.is_head = true
			for _, key in ipairs({ 'input_priority', 'output_priority', 'filter', 'tier' }) do
				if other[key] and not head[key] then head[key] = other[key] end
				if key ~= 'tier' then other[key] = nil end
			end
		end
	end
	return from_cells(list)
end

-- ------------------------------------------------------------------ the tracer

function M.trace(L, gap)
	local cell = L.cells
	local tr = { w = L.w, h = L.h, cell = cell, splitters = {}, splitter_of = {}, segs = {}, on = {}, tunnels = {}, into = {}, outof = {} }
	local order = {}
	for _, t in pairs(cell) do order[#order + 1] = t.pos end
	table.sort(order, less)

	for _, c in ipairs(order) do
		local t = cell[c.k]
		if t.type == 'splitter' and t.is_head then
			local d = t.direction
			local o = add(c, (d + 1) % 4)
			local u = cell[o.k]
			if u == nil or u.type ~= 'splitter' or u.is_head or u.direction ~= d or tr.splitter_of[o.k] then
				o, u = nil, {}
			end
			local idx = #tr.splitters + 1
			tr.splitter_of[c.k] = idx
			if o then tr.splitter_of[o.k] = idx end
			local function opt(key, values)
				local v = t[key] or u[key]
				if v and (values == nil or values[v]) then return v end
				return nil
			end
			local lr = { left = true, right = true }
			tr.splitters[idx] = { tiles = { c, o }, d = d, input = opt('input_priority', lr), output = opt('output_priority', lr), filter = opt('filter'), tier = opt('tier') }
		end
	end
	for _, c in ipairs(order) do
		local t = cell[c.k]
		if t.type == 'splitter' and not tr.splitter_of[c.k] then
			local idx = #tr.splitters + 1
			tr.splitter_of[c.k] = idx
			tr.splitters[idx] = { tiles = { c, nil }, d = t.direction, tier = t.tier }
		end
	end
	tr.filters = {}
	for _, s in ipairs(tr.splitters) do
		if s.filter then
			local found = false
			for _, f in ipairs(tr.filters) do found = found or f == s.filter end
			if not found then tr.filters[#tr.filters + 1] = s.filter end
		end
	end

	local function partner(c)
		local t = cell[c.k]
		local d = t.direction
		local reach = (t.tier and TIERS[t.tier]) and TIERS[t.tier].gap or gap
		for k = 1, reach + 1 do
			local e = add(c, d, k)
			local u = cell[e.k]
			if u and u.type == 'underground_belt' and u.direction == d and u.tier == t.tier then
				if u.is_input then return nil end
				return e
			end
		end
		return nil
	end

	-- Where the contents of tile c go: (tile, how), how one of cont tunnel side out dead.
	local function step(c)
		local t = cell[c.k]
		if t.type == 'underground_belt' and t.is_input then
			local e = partner(c)
			if e then return e, 'tunnel' end
			return nil, 'dead'
		end
		local d = out_dir(t)
		local e = add(c, d)
		local u = cell[e.k]
		if u == nil then
			if e.x >= 0 and e.x < L.w and e.y >= 0 and e.y < L.h then return e, 'dead' end
			return e, 'out'
		end
		local back = (d + 2) % 4
		if u.type == 'belt' then
			if u.output_direction == back then return e, 'dead' end
			return e, (u.input_direction == d) and 'cont' or 'side'
		elseif u.type == 'splitter' then
			return e, (u.direction == d) and 'cont' or 'dead'
		end
		if u.direction == d then return e, u.is_input and 'cont' or 'dead' end
		return e, (u.direction == back) and 'dead' or 'side'
	end
	tr.step = step

	local fed = {}
	for _, c in ipairs(order) do
		local e, how = step(c)
		if how == 'cont' or how == 'tunnel' then fed[e.k] = true end
	end

	local function walk(c, src)
		local k = #tr.segs + 1
		local seg = { src = src, tiles = {}, ['end'] = { 'dead' } }
		tr.segs[k] = seg
		if src then tr.outof[src.k] = k end
		while true do
			local t = cell[c.k]
			if t.type == 'splitter' then
				tr.into[c.k] = k
				seg['end'] = { 'splitter', c }
				return
			end
			if tr.on[c.k] then return end
			tr.on[c.k] = k
			seg.tiles[#seg.tiles + 1] = c
			local e, how = step(c)
			if how == 'tunnel' then tr.tunnels[#tr.tunnels + 1] = { c, e, k } end
			if how ~= 'cont' and how ~= 'tunnel' then
				seg['end'] = { how, e, out_dir(t) }
				return
			end
			c = e
		end
	end

	for _, c in ipairs(order) do
		if not fed[c.k] and cell[c.k].type ~= 'splitter' then walk(c, nil) end
	end
	local outs = {}
	for _, c in ipairs(order) do
		if cell[c.k].type == 'splitter' then
			local e, how = step(c)
			outs[#outs + 1] = { e = e, c = c, how = how }
		end
	end
	table.sort(outs, function(a, b)
		if a.e.k ~= b.e.k then return less(a.e, b.e) end
		return less(a.c, b.c)
	end)
	for _, o in ipairs(outs) do
		if o.how == 'cont' then
			walk(o.e, o.c)
		else
			local k = #tr.segs + 1
			tr.outof[o.c.k] = k
			tr.segs[k] = { src = o.c, tiles = {}, ['end'] = { o.how, o.e, cell[o.c.k].direction } }
		end
	end
	for _, c in ipairs(order) do
		if not tr.on[c.k] and cell[c.k].type ~= 'splitter' then walk(c, nil) end
	end

	tr.inputs, tr.outputs = {}, {}
	for _, s in ipairs(tr.segs) do
		if s.src == nil and #s.tiles > 0 and cell[s.tiles[1].k].type == 'belt' then tr.inputs[#tr.inputs + 1] = s.tiles[1] end
		if s['end'][1] == 'out' then tr.outputs[#tr.outputs + 1] = { s['end'][2], s['end'][3] } end
	end
	local w, h = L.w, L.h
	for f = 0, 3 do
		local function line(c, last)
			if f % 2 == 0 then return c.x == (((f == 0) == last) and (w - 1) or 0) end
			return c.y == (((f == 3) == last) and (h - 1) or 0)
		end
		local ok = #tr.inputs > 0 and #tr.outputs > 0
		for _, c in ipairs(tr.inputs) do
			ok = ok and line(c, false) and cell[c.k].input_direction == f
		end
		for _, o in ipairs(tr.outputs) do
			ok = ok and o[2] == f and line(add(o[1], f, -1), true)
		end
		if ok then tr.flow = f end
	end
	return tr
end

-- ------------------------------------------------------------------ colors

local function hsv(hue, s, v)
	-- colorsys.hsv_to_rgb
	if s == 0 then return v, v, v end
	local i = math.floor(hue * 6.0)
	local f = hue * 6.0 - i
	local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
	i = i % 6
	if i == 0 then return v, t, p elseif i == 1 then return q, v, p elseif i == 2 then return p, v, t
	elseif i == 3 then return p, q, v elseif i == 4 then return t, p, v end
	return v, p, q
end

function M.palette(n)
	local out = {}
	for k = 0, n - 1 do
		local hue = (0.07 + k * 0.6180339887) % 1.0
		local s = ({ 0.78, 0.6, 0.9 })[k % 3 + 1]
		local v = ({ 0.86, 0.7, 0.78 })[k % 3 + 1]
		local r, g, b = hsv(hue, s, v)
		out[k + 1] = { math.floor(255 * r), math.floor(255 * g), math.floor(255 * b) }
	end
	return out
end

-- ------------------------------------------------------------------ mixing
-- The flow model: every input carries one unit of an item of its own; a splitter sends half of
-- what enters it out of each side, or all of it to its output-priority side, or all of it to
-- the one side that leads anywhere; a side-load adds to the belt it joins.  Belts never fill
-- up, so the model says nothing about throughput.  A belt that leads nowhere carries nothing.
-- Filters are ignored: every item is the same item.

-- OKLab to sRGB, clipped to the gamut.
local function oklab(L, a, b)
	local l = (L + 0.3963377774 * a + 0.2158037573 * b) ^ 3
	local m = (L - 0.1055613458 * a - 0.0638541728 * b) ^ 3
	local s = (L - 0.0894841775 * a - 1.2914855480 * b) ^ 3
	local lin = {
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
	}
	local out = {}
	for i, x in ipairs(lin) do
		x = math.max(0, math.min(1, x))
		x = (x <= 0.0031308) and 12.92 * x or (1.055 * x ^ (1 / 2.4) - 0.055)
		out[i] = math.floor(255 * x + 0.5)
	end
	return out
end

-- sRGB (0 to 255) to OKLab.
local function srgb_lab(c)
	local function lin(v)
		v = v / 255
		return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
	end
	local r, g, b = lin(c[1]), lin(c[2]), lin(c[3])
	local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
	local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
	local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
	return {
		0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
	}
end

-- Okabe and Ito's eight colors for color-blind readers, with gray for their black.
local OKABE = { { 230, 159, 0 }, { 86, 180, 233 }, { 0, 158, 115 }, { 240, 228, 66 }, { 0, 114, 178 }, { 213, 94, 0 }, { 204, 121, 167 }, { 150, 150, 150 } }

-- The colors of n inputs in OKLab.
--   wheel      hues evenly round the circle at one chroma, so the even blend of all of them
--              is a neutral gray; the lightness wobbles so that two opposite inputs do not
--              also blend to that same gray.
--   okabe-ito  Okabe and Ito's colors (repeated past eight inputs).
--   lightness  dark blue to light yellow: told apart by lightness alone, so by every reader.
--   gray       black to light gray, for print.
local PALETTES = { wheel = true, ['okabe-ito'] = true, lightness = true, gray = true }
local function input_labs(n, palette)
	local labs = {}
	for k = 0, n - 1 do
		local t = (n == 1) and 0.5 or k / (n - 1)
		if palette == 'okabe-ito' then
			labs[k + 1] = srgb_lab(OKABE[k % #OKABE + 1])
		elseif palette == 'lightness' then
			local h = math.rad(265 - 170 * t)
			labs[k + 1] = { 0.38 + 0.52 * t, 0.11 * math.cos(h), 0.11 * math.sin(h) }
		elseif palette == 'gray' then
			labs[k + 1] = { 0.22 + 0.68 * t, 0, 0 }
		else
			local h = 0.5 + 2 * math.pi * k / n
			labs[k + 1] = { 0.70 + 0.07 * math.cos(4 * math.pi * k / n + 0.4), 0.13 * math.cos(h), 0.13 * math.sin(h) }
		end
	end
	return labs
end

-- ------------------------------------------------------------------ analysis
-- The network of the trace and what is computed on it live in beltmap-net.lua; here the
-- results become colors and sentences.

-- Exact equality of shares (rationals when exact, else within 1e-9).
local function same(a, b)
	if type(a) == 'table' and type(b) == 'table' then return a == b end
	return math.abs(NET.float(a) - NET.float(b)) < 1e-9
end

local function pct(v)
	return (string.format('%.1f', 100 * NET.float(v)):gsub('%.0$', '')) .. '\\%'
end

-- A share as TeX: a fraction when exact, else a decimal.
local function frac_tex(v)
	if type(v) == 'table' then
		if v.d == 1 then return tostring(v.n) end
		return string.format('\\tfrac{%d}{%d}', v.n, v.d)
	end
	return (string.format('%.4f', v):gsub('0+$', ''):gsub('%.$', ''))
end

-- The network of state.tr, built once; false when it cannot be built.
function M.network(state)
	if state.net == nil then
		local ok, net = pcall(NET.build, state.tr)
		state.net = ok and net or false
		if not ok then state.net_error = type(net) == 'table' and (net.beltmap or 'error') or tostring(net) end
	end
	return state.net
end

-- Balance and lane verdicts as sentences (nil when there is no input).
function M.balance(state)
	if state.bal ~= nil then return state.bal end
	local net = M.network(state)
	state.bal = false
	if not net then return false end
	if net.n == 0 then
		state.bal = { verdict = 'no input leads out of the layout' }
		return state.bal
	end
	local v = NET.verdicts(net)
	if not v then
		state.bal = { verdict = 'a loop keeps items forever, so the flow has no steady state' }
		return state.bal
	end
	local n, m = net.n, net.m
	local text
	if m == 0 then
		text = 'no belt leaves the layout'
	elseif v.balanced and m == 1 then
		text = string.format('balanced: the one output carries all of each of the %d inputs', n)
	elseif v.balanced then
		text = string.format('balanced: each of the %d outputs carries %s of each of the %d inputs', m, pct(v.target), n)
	else
		local b = v.worst
		text = string.format('not balanced: output %d carries %s of input %d, not %s', b.o, pct(b.v), b.i, pct(v.target))
	end
	local SIDE = { 'left', 'right' }
	local lanes
	if m == 0 then
		lanes = text
	elseif v.lanes then
		lanes = string.format('lanes kept: each output lane carries %s of each input lane on its side, and nothing of the other side', pct(v.target))
	else
		local b = v.lane_bad
		lanes = string.format('lanes not kept: the %s lane of output %d carries %s of the %s lane of input %d, not %s',
			SIDE[b.l], b.o, pct(b.v), SIDE[b.l2], b.i, pct(b.want))
	end
	state.bal = { verdict = text, balanced = v.balanced, lanes = v.lanes, lane_verdict = lanes, exact = net.exact }
	return state.bal
end

-- The max-flow test as a sentence.
function M.throughput(state)
	if state.tp ~= nil then return state.tp end
	local net = M.network(state)
	state.tp = false
	if not net or net.n == 0 or net.m == 0 then return false end
	local r = NET.throughput(net)
	local which = (r.rule == 'every') and 'no choice of inputs and outputs' or 'no choice of as many outputs as inputs'
	local text
	if not r.limited then
		text = string.format('passes the max-flow test: %s is held below min($|I|$, $|O|$) belts by a cut (%d choices; necessary for throughput-unlimited, not sufficient)', which, r.tested)
	else
		local L = r.limited
		local belts = {}
		for _, c in ipairs(L.cut) do belts[net.pieces[c[1]].k] = true end
		local nb = 0
		for _ in pairs(belts) do nb = nb + 1 end
		local flow = (L.flow == math.floor(L.flow)) and string.format('%d', L.flow) or string.format('%.1f', L.flow)
		text = string.format('limited: inputs %s to outputs %s get at most %s of %d belt%s', table.concat(L.I, ', '), table.concat(L.O, ', '),
			flow, L.need, L.need == 1 and '' or 's')
		if #L.cut == 0 then
			text = text .. ' (no belt leads from those inputs to those outputs)'
		else
			text = text .. string.format(' (the %d lane%s marked form a cut)', #L.cut, #L.cut == 1 and '' or 's')
		end
	end
	state.tp = { verdict = text, ok = (r.limited == nil), limited = r.limited, tested = r.tested }
	return state.tp
end

-- Input balance (beltmap-net.lua's N.input_balance), as a verdict: at full backpressure, each
-- input supplies 1/n of every output's demand.
function M.input_balance(state)
	if state.ibal ~= nil then return state.ibal end
	state.ibal = false
	local net = M.network(state)
	if not net or net.n == 0 or net.m == 0 then return false end
	local r = NET.input_balance(net)
	if not r then
		state.ibal = { verdict = 'no input-balance verdict: the demand has no steady state' }
		return state.ibal
	end
	local text
	if r.balanced then
		text = string.format('input balanced: each of the %d inputs supplies %s of every output\'s demand (at full backpressure)', net.n, pct(1 / net.n))
	else
		local w = r.worst
		text = string.format('not input balanced: input %d supplies %s of output %d\'s demand, not %s (at full backpressure)', w.i, pct(w.v), w.o, pct(w.target))
	end
	state.ibal = { verdict = text, balanced = r.balanced, per_input = r.per_input }
	return state.ibal
end

-- marks: a check or a cross on every input (input balance) and output (balance of that output:
-- it carries 1/m of every input).
function M.marks(state)
	if state.marks ~= nil then return state.marks end
	state.marks = false
	local net = M.network(state)
	if not net or net.n == 0 or net.m == 0 or not NET.shares(net) then return false end
	local outs = {}
	for _, out in ipairs(net.outputs) do
		local per = NET.belt(net, net.last[out.k])
		local ok = true
		for i = 1, net.n do
			if not same(per[i], net.exact and NET.q(1, net.m) or 1 / net.m) then ok = false end
		end
		outs[out.index] = ok
	end
	local ib = M.input_balance(state)
	state.marks = { outs = outs, ins = ib and ib.per_input or {} }
	return state.marks
end

-- blocked: balance with outputs blocked (beltmap-net.lua's N.blocked), as a verdict.
function M.blocked(state)
	if state.blk ~= nil then return state.blk end
	state.blk = false
	local r, why = NET.blocked(state.tr)
	if not r then
		state.blk = { verdict = 'no blocked-output test: ' .. why }
		return state.blk
	end
	local text
	if r.fails == 0 then
		text = string.format('stays balanced with any outputs blocked: every open output carries an even share of every input (%d choices, at light load)', r.tested)
	else
		local w = r.worst
		local which = string.format('output%s %s', #w.B == 1 and '' or 's', table.concat(w.B, ', '))
		if w.none then
			text = string.format('with %s blocked the flow has no steady state', which)
		else
			text = string.format('not balanced with %s blocked: output %d carries %s of input %d, not %s', which, w.o, pct(w.v), w.i, pct(w.target))
		end
		text = text .. string.format(' (%d of %d choices fail, at light load)', r.fails, r.tested)
	end
	state.blk = { verdict = text, ok = (r.fails == 0), tested = r.tested, fails = r.fails }
	return state.blk
end

-- mix=strict and mix=check: colors that are gray exactly when a belt is balanced.
--   vals   what the belt carries of each of k kinds (floats); labs: the k colors in OKLab
--   target the share each kind should have, as an amount (outputs, input belts of the demand
--          view), or nil for an even mix whatever the amount (every other belt)
--   even   whether the belt is balanced, decided exactly by the caller
-- strict: the blend of the kinds, as mix=blend, except that a belt that is not balanced stays at
-- least STRICT_GAP from the balanced gray (pushed along its own tint, or toward the kind it has
-- most of when its tint is nil), and a target belt is lighter when it carries too much and
-- darker when too little.  check: gray, or the color of the kind most in excess at a strength
-- that grows with log2 of the largest error from a floor, or slate when short of every kind.
local STRICT_GAP, CHECK_FLOOR, SLATE = 0.045, 0.45, { 0.40, -0.005, -0.045 }
local function shade(mode, vals, labs, target, even)
	local k = #vals
	local tot = 0
	for i = 1, k do tot = tot + vals[i] end
	local G = { 0, 0, 0 }
	for i = 1, k do for c = 1, 3 do G[c] = G[c] + labs[i][c] / k end end
	if even then return oklab(G[1], G[2], G[3]) end
	local err, best, beste = {}, 1, -math.huge
	for i = 1, k do
		err[i] = target and (vals[i] - target) or (vals[i] / tot - 1 / k)
		if err[i] > beste then best, beste = i, err[i] end
	end
	if mode == 'check' then
		if beste <= 1e-12 then return oklab(SLATE[1], SLATE[2], SLATE[3]) end
		local d = 0
		for i = 1, k do d = math.max(d, math.abs(err[i])) end
		local t = math.max(0, math.min(1, (math.log(math.max(d, 1e-300), 2) + 10) / 9))
		local s = CHECK_FLOOR + (1 - CHECK_FLOOR) * t
		local c = labs[best]
		return oklab(G[1] + s * (c[1] - G[1]), G[2] + s * (c[2] - G[2]), G[3] + s * (c[3] - G[3]))
	end
	-- strict
	local p = { -G[1], -G[2], -G[3] }
	for i = 1, k do for c = 1, 3 do p[c] = p[c] + vals[i] / tot * labs[i][c] end end
	local mixed_even = true
	for i = 1, k do if math.abs(vals[i] / tot - 1 / k) > 1e-12 then mixed_even = false end end
	if not mixed_even then
		local norm = math.sqrt(p[1] ^ 2 + p[2] ^ 2 + p[3] ^ 2)
		if norm < STRICT_GAP then
			local d = (norm > 1e-9) and p or { labs[best][1] - G[1], labs[best][2] - G[2], labs[best][3] - G[3] }
			local dn = math.sqrt(d[1] ^ 2 + d[2] ^ 2 + d[3] ^ 2)
			if dn > 0 then for c = 1, 3 do p[c] = d[c] * STRICT_GAP / dn end end
		end
	end
	if target then
		local want = target * k
		if math.abs(tot - want) > 1e-12 then
			local dL = math.max(-0.25, math.min(0.25, 0.15 * math.log(tot / want, 2)))
			if math.abs(dL) < STRICT_GAP then dL = (tot > want) and STRICT_GAP or -STRICT_GAP end
			p[1] = p[1] + dL
		end
	end
	return oklab(G[1] + p[1], G[2] + p[2], G[3] + p[3])
end

-- The colors of a mixed picture.  opts.mix: blend or bands; opts.focus: an input number;
-- opts.step: a frame of the animation; opts.palette.  Returns the table M.tikz reads, or nil
-- and the reason.
function M.mixing(state)
	local opts = state.opts
	local net = M.network(state)
	if not net then return nil, state.net_error or 'the belts could not be followed' end
	if net.n == 0 then return nil, 'no input leads out of the layout' end
	local x
	if opts.step then
		state.frames = state.frames or NET.frames(net)
		if not state.frames then return nil, 'a loop keeps items forever, so the flow has no steady state' end
		x = state.frames[math.min(opts.step + 1, #state.frames)]
	else
		x = NET.shares(net)
		if not x then return nil, 'a loop keeps items forever, so the flow has no steady state' end
	end
	local n = net.n
	local palette = opts.palette or ((opts.theme == 'print') and 'gray' or 'wheel')
	local labs = input_labs(n, palette)
	local inputs = {}
	for i = 1, n do inputs[i] = oklab(labs[i][1], labs[i][2], labs[i][3]) end
	local function blend_of(per, tot)
		local L, a, b = 0, 0, 0
		for i = 1, n do
			local w = per[i] / tot
			L, a, b = L + w * labs[i][1], a + w * labs[i][2], b + w * labs[i][3]
		end
		return oklab(L, a, b)
	end
	-- per piece and per lane: what it carries of each input (floats), its total, its color
	local mix = { n = n, net = net, inputs = inputs, piece_at = net.piece_at, first = net.first, pieces = net.pieces,
		comp = {}, rgb = {}, expr = {}, lane = {}, focus = opts.focus }
	if mix.focus and (mix.focus < 1 or mix.focus > n) then
		return nil, string.format('focus=%d, but the layout has %d inputs', mix.focus, n)
	end
	local function color(id, per, tot)
		if tot <= 1e-9 then return nil, nil, 'bm-idle' end
		if mix.focus then
			local s = per[mix.focus] / tot
			return nil, nil, string.format('bmi%d!%d!bm-idle', mix.focus - 1, math.floor(100 * s + 0.5))
		end
		local comp = {}
		for i = 1, n do comp[i] = per[i] / tot end
		return comp, blend_of(per, tot), id
	end
	for p = 1, #net.pieces do
		local per, tot = {}, 0
		local lanes = { {}, {} }
		local ltot = { 0, 0 }
		for i = 1, n do
			local v = 0
			for l = 1, 2 do
				local lv = NET.float(x[p][l][2 * i - 1]) + NET.float(x[p][l][2 * i])
				lanes[l][i] = lv
				ltot[l] = ltot[l] + lv
				v = v + lv
			end
			per[i] = v
			tot = tot + v
		end
		mix.comp[p], mix.rgb[p], mix.expr[p] = color('bmp' .. (p - 1), per, tot)
		mix.lane[p] = {}
		for l = 1, 2 do
			local c, rgb, expr = color('bmq' .. (p - 1) .. 'l' .. l, lanes[l], ltot[l])
			mix.lane[p][l] = { comp = c, rgb = rgb, expr = expr }
		end
		mix.total = mix.total or {}
		mix.total[p] = tot
	end
	local mode = (opts.mix == 'strict' or opts.mix == 'check') and opts.mix or nil
	-- mix=strict, mix=check: each belt gray exactly when balanced.  An output is balanced when it
	-- carries 1/m of every input (amounts); any other belt when it carries every input alike.
	-- Exact on the steady state; within 1e-9 on an animation frame.
	if mode and not mix.focus and not opts.demand then
		local outpiece = {}
		for _, out in ipairs(net.outputs) do outpiece[net.last[out.k]] = out.index end
		local m = net.m
		for p = 1, #net.pieces do
			if mix.total[p] and mix.total[p] > 1e-9 then
				local per
				if opts.step then
					per = {}
					for i = 1, n do per[i] = (NET.float(x[p][1][2 * i - 1]) + NET.float(x[p][1][2 * i]) + NET.float(x[p][2][2 * i - 1]) + NET.float(x[p][2][2 * i])) / 2 end
				else
					per = NET.belt(net, p)
				end
				local even = true
				local target = outpiece[p] and (1 / m) or nil
				for i = 1, n do
					if outpiece[p] then
						if not same(per[i], net.exact and not opts.step and NET.q(1, m) or 1 / m) then even = false end
					elseif not same(per[i], per[1]) then
						even = false
					end
				end
				local vals = {}
				for i = 1, n do vals[i] = NET.float(per[i]) end
				mix.rgb[p], mix.expr[p] = shade(mode, vals, labs, target, even), 'bmp' .. (p - 1)
			end
		end
	end
	-- demand: color each belt by the outputs whose demand passes through it (beltmap-net.lua's
	-- N.demand), with blend, strict or check.  Input belts are judged by amount: balanced when
	-- they supply 1/n of every output's demand.
	if opts.demand and not mix.focus then
		if opts.mix == 'bands' then return nil, 'demand works with mix=blend, strict or check, not bands' end
		local D = NET.demand(net)
		if not D then return nil, 'the demand has no steady state' end
		local m = net.m
		local olabs = input_labs(m, palette)
		mix.outputs = {}
		for o = 1, m do mix.outputs[o] = oklab(olabs[o][1], olabs[o][2], olabs[o][3]) end
		for p = 1, #net.pieces do mix.rgb[p], mix.expr[p] = nil, 'bm-idle' end
		for idx, a in ipairs(D.g.arcs) do
			local p = a[3]
			if p then
				local v = D.arc[idx]
				local vals, tot = {}, 0
				for o = 1, m do vals[o] = NET.float(v[o]); tot = tot + vals[o] end
				if tot > 1e-9 then
					local isin = a[1]:sub(1, 2) == 'in'
					local even = true
					for o = 1, m do
						if isin then
							if not same(v[o], D.exact and NET.q(1, n) or 1 / n) then even = false end
						elseif not same(v[o], v[1]) then
							even = false
						end
					end
					local rgb
					if mode then
						rgb = shade(mode, vals, olabs, isin and (1 / n) or nil, even)
					else
						local L, A, B = 0, 0, 0
						for o = 1, m do
							L, A, B = L + vals[o] / tot * olabs[o][1], A + vals[o] / tot * olabs[o][2], B + vals[o] / tot * olabs[o][3]
						end
						rgb = oklab(L, A, B)
					end
					mix.rgb[p], mix.expr[p] = rgb, 'bmp' .. (p - 1)
				end
			end
		end
		for p = 1, #net.pieces do
			for l = 1, 2 do mix.lane[p][l] = { comp = nil, rgb = mix.rgb[p], expr = mix.expr[p] } end
		end
	end
	-- With focus: the share of the input that reaches each output.
	if mix.focus then
		mix.reach = {}
		for _, out in ipairs(net.outputs) do
			local per = NET.belt(net, net.last[out.k])
			mix.reach[out.index] = per[mix.focus]
		end
	end
	return mix
end

-- The share matrix as a TeX tabular: rows inputs, columns outputs.
function M.matrix_tex(state)
	local net = M.network(state)
	if not net or net.n == 0 or net.m == 0 then return '(no matrix: ' .. (state.net_error or 'no inputs or outputs') .. ')' end
	if not NET.shares(net) then return '(no matrix: the flow has no steady state)' end
	local n, m = net.n, net.m
	local rows = {}
	rows[#rows + 1] = '\\begingroup\\renewcommand\\arraystretch{1.45}\\begin{tabular}{@{}r@{\\quad}' .. string.rep('c', m) .. '@{}}'
	rows[#rows + 1] = string.format('& \\multicolumn{%d}{c@{}}{output} \\\\', m)
	local head = { 'input' }
	for o = 1, m do head[#head + 1] = tostring(o) end
	rows[#rows + 1] = table.concat(head, ' & ') .. ' \\\\[2pt]'
	for i = 1, n do
		local cells = { tostring(i) }
		for _, out in ipairs(net.outputs) do
			local per = NET.belt(net, net.last[out.k])
			cells[#cells + 1] = '$' .. frac_tex(per[i]) .. '$'
		end
		rows[#rows + 1] = table.concat(cells, ' & ') .. ' \\\\'
	end
	rows[#rows + 1] = '\\end{tabular}\\endgroup'
	return table.concat(rows, '\n')
end

-- ------------------------------------------------------------------ TikZ

local function at(c, d, a, b)
	a, b = a or 0, b or 0
	local f, n = VEC[d], VEC[(d + 1) % 4]
	return { c.x + 0.5 + a * f[1] + b * n[1], c.y + 0.5 + a * f[2] + b * n[2] }
end

local function num(v)
	local s = string.format('%.3f', v):gsub('0+$', ''):gsub('%.$', '')
	if s == '-0' then s = '0' end
	return s
end

local function pt(p)
	return '(' .. num(p[1]) .. ',' .. num(-p[2]) .. ')'
end

local function split_list(s)
	-- Top-level commas of a TeX list; braces kept balanced, the outer pair dropped.
	local out, depth, cur = {}, 0, {}
	for ch in s:gmatch('.') do
		if ch == '{' then depth = depth + 1 end
		if ch == '}' then depth = depth - 1 end
		if ch == ',' and depth == 0 then
			out[#out + 1] = table.concat(cur)
			cur = {}
		else
			cur[#cur + 1] = ch
		end
	end
	out[#out + 1] = table.concat(cur)
	for i, v in ipairs(out) do
		v = v:gsub('^%s+', ''):gsub('%s+$', '')
		if v:sub(1, 1) == '{' and v:sub(-1) == '}' then v = v:sub(2, -2) end
		out[i] = v
	end
	if #out == 1 and out[1] == '' then return {} end
	return out
end
M.split_list = split_list

-- opts: gap, tier, trim ('auto' or boolean), color ('belt' or 'tier'), flow (name or nil),
-- grid, ends, heads, lanes, labels (booleans), inputs, outputs (lists); mix (blend, bands),
-- lanemix, focus, step, palette, throughput, numbers, compare (a file), view (graph).
function M.prepare(L, opts)
	opts = opts or {}
	local gap = opts.gap or L.gap or 10
	if opts.tier and TIERS[opts.tier] then
		with_tier(L, opts.tier)
	end
	local turns = 0
	if opts.flow and DIRS[opts.flow] then
		local f = M.trace(L, gap).flow
		if f == nil then fail('flow= needs a layout with an entry line and an exit line') end
		turns = (DIRS[opts.flow] - f) % 4
		L = M.rotate(L, turns)
	end
	local tr = M.trace(L, gap)
	local trim = opts.trim
	-- The industrial theme always shows the tier; elsewhere only when a tier is given or mixed.
	if trim == nil or trim == 'auto' then trim = (opts.tier ~= nil) or #tiers_of(L) > 1 or opts.theme == 'industrial' end
	local state = { L = L, tr = tr, opts = opts, trim = trim }
	if opts.focus or opts.step then
		opts.mix = (opts.mix == 'bands' or opts.mix == 'strict' or opts.mix == 'check') and opts.mix or 'blend'
	end
	if opts.demand and not opts.mix then opts.mix = 'blend' end
	if opts.palette and not PALETTES[opts.palette] then fail('unknown palette ' .. opts.palette) end
	if opts.mix == 'blend' or opts.mix == 'bands' or opts.mix == 'strict' or opts.mix == 'check' then
		local mix, why = M.mixing(state)
		if mix then
			state.mix = mix
		else
			state.mix_failed = why
		end
		M.balance(state)
		M.input_balance(state)
	end
	if opts.marks then M.marks(state) end
	if opts.throughput then M.throughput(state) end
	if opts.blocked then M.blocked(state) end
	if opts.compare then state.diff = M.diff(L, M.rotate(M.layout_from_file(opts.compare, {}), turns)) end
	return state
end

-- Tiles of layout A (as drawn) that differ from layout B, after lining up their top left
-- entities: { list = { {x, y, kind} }, added, removed, changed }.
local function signature(t)
	if t == nil then return nil end
	return table.concat({ t.type, tostring(t.direction), tostring(t.input_direction), tostring(t.output_direction),
		tostring(t.is_input), tostring(t.is_head), tostring(t.input_priority), tostring(t.output_priority),
		tostring(t.filter), tostring(t.tier) }, '|')
end
function M.diff(A, B)
	local function corner(L)
		local x0, y0 = math.huge, math.huge
		for _, t in pairs(L.cells) do x0, y0 = math.min(x0, t.pos.x), math.min(y0, t.pos.y) end
		return x0, y0
	end
	local ax, ay = corner(A)
	local bx, by = corner(B)
	local moved = {}
	for _, t in pairs(B.cells) do moved[P(t.pos.x - bx + ax, t.pos.y - by + ay).k] = t end
	local d = { list = {}, added = 0, removed = 0, changed = 0 }
	local keys = {}
	for k in pairs(A.cells) do keys[k] = true end
	for k in pairs(moved) do keys[k] = true end
	for k in pairs(keys) do
		local a, b = A.cells[k], moved[k]
		local kind
		if a and not b then kind = 'added' elseif b and not a then kind = 'removed'
		elseif signature(a) ~= signature(b) then kind = 'changed' end
		if kind then
			local x, y = k:match('^(-?%d+),(-?%d+)$')
			d.list[#d.list + 1] = { tonumber(x), tonumber(y), kind }
			d[kind] = d[kind] + 1
		end
	end
	table.sort(d.list, function(p, q) return p[2] < q[2] or (p[2] == q[2] and p[1] < q[1]) end)
	return d
end

-- Width of the band strokes, in tiles, per theme (as bm band width in the TikZ library).
local BAND_W = { schematic = 0.46, dark = 0.46, transit = 0.26, print = 0.2, industrial = 0.46 }

-- A polyline of right angles moved sideways by delta (positive: to the left of travel).
local function offset(pts, delta)
	local res = {}
	local function nrm(a, b)
		local dx, dy = b[1] - a[1], b[2] - a[2]
		local len = math.abs(dx) + math.abs(dy)
		return { dy / len, -dx / len }
	end
	for i, p in ipairs(pts) do
		local n1 = (i > 1) and nrm(pts[i - 1], p) or nil
		local n2 = (i < #pts) and nrm(p, pts[i + 1]) or nil
		local ox, oy
		if n1 and n2 and math.abs(n1[1] * n2[1] + n1[2] * n2[2]) < 1e-6 then
			ox, oy = n1[1] + n2[1], n1[2] + n2[2]
		else
			local nn = n1 or n2
			ox, oy = nn[1], nn[2]
		end
		res[i] = { p[1] + delta * ox, p[2] + delta * oy }
	end
	return res
end

local function path_of(pts)
	local s = {}
	for j, p in ipairs(pts) do s[j] = pt(p) end
	return table.concat(s, ' -- ')
end

function M.tikz(state)
	if state.opts.view == 'wires' then
		local code, why = M.wires_tikz(state)
		if code then return code end
		-- No wire diagram for this network: say why, and draw the splitter graph instead.
		state.opts.view = 'graph'
		state.wires_failed = why
		if texio then texio.write_nl('term and log', 'beltmap warning: view=wires: ' .. why .. '; drawn as view=graph') end
	end
	if state.opts.view == 'graph' then return M.graph_tikz(state) end
	local tr, opts, trim = state.tr, state.opts, state.trim
	local cell = tr.cell
	local out = {}
	local function w(s) out[#out + 1] = s end
	local cols = M.palette(#tr.segs)
	for k, seg in ipairs(tr.segs) do
		local col = cols[k]
		if opts.color == 'tier' then
			local first = seg.tiles[1] or seg.src
			local tier = first and cell[first.k].tier
			if tier and TIER_RGB[tier] then col = TIER_RGB[tier] end
		end
		w(string.format('\\definecolor{bmc%d}{RGB}{%d,%d,%d}', k - 1, col[1], col[2], col[3]))
	end
	-- With mixing, each piece of belt has the blend of what it carries; an idle piece is bm-idle.
	local mix = state.mix
	local function piece_color(k, p)
		if not mix then return 'bmc' .. (k - 1) end
		return mix.expr[p]
	end
	if mix then
		for i, col in ipairs(mix.inputs) do
			w(string.format('\\definecolor{bmi%d}{RGB}{%d,%d,%d}', i - 1, col[1], col[2], col[3]))
		end
		for p = 1, #mix.pieces do
			local col = mix.rgb[p]
			if col then w(string.format('\\definecolor{bmp%d}{RGB}{%d,%d,%d}', p - 1, col[1], col[2], col[3])) end
			if opts.lanemix then
				for l = 1, 2 do
					local c = mix.lane[p][l].rgb
					if c then w(string.format('\\definecolor{bmq%dl%d}{RGB}{%d,%d,%d}', p - 1, l, c[1], c[2], c[3])) end
				end
			end
		end
	end
	local flow = tr.flow
	-- The inside of the layout: the tiles between the entry and exit lines, which the search
	-- records count as its size.  Major lines, rulers and dimensions count from its corner.
	local gx0, gx1, gy0, gy1 = 0, tr.w, 0, tr.h
	if flow ~= nil then
		if flow % 2 == 0 then gx0, gx1 = 1, tr.w - 1 else gy0, gy1 = 1, tr.h - 1 end
	end
	local level = opts.grid_level or 'normal'
	local GRID_STYLE = { faint = 'bm grid, bm grid faint', normal = 'bm grid', strong = 'bm grid strong' }
	if opts.grid ~= false and level ~= 'strong' then
		w(string.format('\\path[%s] (0,0) grid[step=1] (%d,%d);', GRID_STYLE[level] or 'bm grid', tr.w, -tr.h))
	end
	if flow ~= nil and opts.ends ~= false then
		for _, last in ipairs({ false, true }) do
			if flow % 2 == 0 then
				local x = ((flow == 0) == last) and (tr.w - 1) or 0
				w(string.format('\\path[bm end] (%d,0) rectangle (%d,%d);', x, x + 1, -tr.h))
			else
				local y = ((flow == 3) == last) and (tr.h - 1) or 0
				w(string.format('\\path[bm end] (0,%d) rectangle (%d,%d);', -y, tr.w, -(y + 1)))
			end
		end
	end
	-- A strong grid goes over the entry and exit lines too, so every tile can be counted.
	if opts.grid ~= false and level == 'strong' then
		w(string.format('\\path[bm grid strong] (0,0) grid[step=1] (%d,%d);', tr.w, -tr.h))
	end
	local major = opts.grid_major
	if major and major > 0 then
		for x = gx0, gx1 do
			if (x - gx0) % major == 0 then w(string.format('\\path[bm grid major] (%d,0) -- (%d,%d);', x, x, -tr.h)) end
		end
		for y = gy0, gy1 do
			if (y - gy0) % major == 0 then w(string.format('\\path[bm grid major] (0,%d) -- (%d,%d);', -y, tr.w, -y)) end
		end
	end
	if opts.grid ~= false or (flow ~= nil and opts.ends ~= false) then
		w(string.format('\\path[bm frame] (0,0) rectangle (%d,%d);', tr.w, -tr.h))
	end
	-- Rulers: the columns of the inside numbered along the top, its rows down the left, every
	-- opts.rulers-th tile and the first; pushed past the input labels when those are on the left.
	local labels_left = (flow == 0 and (opts.labels or opts.inputs)) or (flow == 2 and (opts.labels or opts.outputs))
	local left_x = labels_left and -1.25 or -0.3
	if opts.rulers then
		local r = opts.rulers
		for x = gx0, gx1 - 1 do
			local i = x - gx0 + 1
			if i == 1 or i % r == 0 then w(string.format('\\node[bm ruler, anchor=south] at (%s,0.08) {%d};', num(x + 0.5), i)) end
		end
		for y = gy0, gy1 - 1 do
			local i = y - gy0 + 1
			if i == 1 or i % r == 0 then w(string.format('\\node[bm ruler, anchor=east] at (%s,%s) {%d};', num(left_x + 0.2), num(-(y + 0.5)), i)) end
		end
	end
	-- Dimensions: the size of the inside, below the layout and to its left.
	if opts.dimensions then
		local yb = -tr.h - ((flow == 3 and (opts.labels or opts.outputs)) and 1.2 or 0.45)
		w(string.format('\\draw[bm dim] (%d,%s) -- node[bm dim label, below] {%d tiles} (%d,%s);', gx0, num(yb), gx1 - gx0, gx1, num(yb)))
		local xl = left_x - (opts.rulers and 0.55 or 0)
		w(string.format('\\draw[bm dim] (%s,%d) -- node[bm dim label, above, sloped] {%d tiles} (%s,%d);', num(xl), -gy1, gy1 - gy0, num(xl), -gy0))
	end
	-- compare=: tiles added, changed, and removed (the last drawn over everything, below).
	if state.diff then
		for _, d in ipairs(state.diff.list) do
			if d[3] ~= 'removed' then
				w(string.format('\\path[bm diff %s] (%d,%d) rectangle (%d,%d);', d[3], d[1], -d[2], d[1] + 1, -(d[2] + 1)))
			end
		end
	end

	-- Tunnels under everything; two tunnels along one line side by side.
	local spans = {}
	for i, tu in ipairs(tr.tunnels) do
		local a, b = tu[1], tu[2]
		local d = cell[a.k].direction
		local n = math.abs(b.x - a.x) + math.abs(b.y - a.y)
		local s = {}
		for j = 0, n do
			local p = add(a, d, j)
			s[p.k .. '/' .. (d % 2)] = true
		end
		spans[i] = s
	end
	for i, tu in ipairs(tr.tunnels) do
		local a, b, k = tu[1], tu[2], tu[3]
		local d = cell[a.k].direction
		local same, crossed = { i }, false
		for j = 1, #spans do
			if j ~= i then
				local meets = false
				for key in pairs(spans[i]) do meets = meets or spans[j][key] end
				if meets then
					crossed = true
					if cell[tr.tunnels[j][1].k].direction == d then same[#same + 1] = j end
				end
			end
		end
		local off = 0
		if crossed then
			table.sort(same)
			local idx
			for j, v in ipairs(same) do if v == i then idx = j - 1 end end
			if #same == 1 then off = -0.1 else off = ((idx % 2 == 1) and 0.1 or -0.1) * (d < 2 and 1 or -1) end
		end
		local tcol = 'bmc' .. (k - 1)
		if mix then
			local j
			for jj, c in ipairs(tr.segs[k].tiles) do if c.k == a.k then j = jj end end
			tcol = piece_color(k, j and mix.piece_at[k][j] or mix.first[k])
		end
		w(string.format('\\path[bm tunnel=%s] %s -- %s;', tcol, pt(at(a, d, HOOD_END, off)), pt(at(b, d, -HOOD_END, off))))
	end

	-- Belts: one path per piece of belt, broken where it goes underground.
	local heads, lines_all = {}, {}
	local net = (mix or state.tp) and M.network(state) or nil
	for k, seg in ipairs(tr.segs) do
		local lines, cur = {}, {}
		local curp = net and net.first[k] or 0
		local function flush()
			cur.p = curp
			if #cur > 1 then lines[#lines + 1] = cur end
		end
		local function put(p)
			local q = cur[#cur]
			if not q or math.abs(q[1] - p[1]) + math.abs(q[2] - p[2]) > 1e-6 then cur[#cur + 1] = p end
		end
		local e = seg['end']
		if seg.src and e[1] ~= 'dead' and not (opts.open_ends == false and e[1] == 'out') then
			local sd = cell[seg.src.k].direction
			put(at(seg.src, sd, 0.5 - MARGIN - UNDER))
			put(at(seg.src, sd, 0.5))
		end
		for j, c in ipairs(seg.tiles) do
			local t = cell[c.k]
			-- A side-load starts a new piece at the edge of the tile it joins.
			if net and net.piece_at[k][j] ~= curp then
				local edge = at(c, t.type == 'belt' and t.input_direction or t.direction, -0.5)
				put(edge)
				flush()
				cur = { edge }
				curp = net.piece_at[k][j]
			end
			if t.type == 'belt' then
				local i, o = t.input_direction, t.output_direction
				put(at(c, i, -0.5))
				if i ~= o then put(at(c, o, 0)) end
				put(at(c, o, 0.5))
				heads[#heads + 1] = { at(c, o, 0.25), o }
			else
				local d = t.direction
				if t.is_input then
					put(at(c, d, -0.5))
					put(at(c, d, -HOOD_MOUTH + UNDER))
					flush()
					cur = {}
				else
					flush()
					cur = {}
					put(at(c, d, HOOD_MOUTH - UNDER))
					put(at(c, d, 0.5))
				end
			end
		end
		if e[1] == 'splitter' then
			local d = cell[e[2].k].direction
			put(at(e[2], d, -0.5))
			put(at(e[2], d, -0.5 + MARGIN + UNDER))
		elseif e[1] == 'side' then
			put(at(e[2], e[3], -LW / 2 + 0.02))
			heads[#heads + 1] = { at(e[2], e[3], -LW / 2 - 0.13), e[3] }
		end
		flush()
		for _, pts in ipairs(lines) do
			local keep = { pts[1] }
			for j = 2, #pts - 1 do
				local a, p, q = keep[#keep], pts[j], pts[j + 1]
				if math.abs((p[1] - a[1]) * (q[2] - p[2]) - (p[2] - a[2]) * (q[1] - p[1])) > 1e-6 then keep[#keep + 1] = p end
			end
			keep[#keep + 1] = pts[#pts]
			lines_all[#lines_all + 1] = { k = k, p = pts.p, pts = keep, path = path_of(keep) }
		end
	end

	-- throughput: the cut of the worst choice glows under its belts.
	if opts.throughput and state.tp and state.tp.limited then
		local cut = {}
		for _, c in ipairs(state.tp.limited.cut) do cut[c[1]] = true end
		for _, ln in ipairs(lines_all) do
			if cut[ln.p] then w(string.format('\\path[bm cut] %s;', ln.path)) end
		end
	end

	-- Bands: one stroke per input, each narrower than the last by that input's share, so each
	-- input shows as a pair of stripes as wide as its share of the stroke.
	local function bands(comp, path, scale)
		local width = 1
		for i = 1, mix.n do
			local f = comp[i]
			if f > 1e-9 then
				w(string.format('\\path[bm band={bmi%d}{%s}] %s;', i - 1, num(width * scale), path))
			end
			width = width - f
		end
	end
	local delta = (BAND_W[opts.theme or 'schematic'] or 0.46) / 4
	for _, ln in ipairs(lines_all) do
		local col = piece_color(ln.k, ln.p)
		local lanes = opts.lanes and (', bm lanes=' .. col) or ''
		w(string.format('\\path[bm belt=%s%s] %s;', col, lanes, ln.path))
		if mix and opts.lanemix then
			for l = 1, 2 do
				local lane = mix.lane[ln.p][l]
				local lpath = path_of(offset(ln.pts, (l == 1) and delta or -delta))
				if opts.mix == 'bands' and lane.comp then
					bands(lane.comp, lpath, 0.5)
				else
					w(string.format('\\path[bm band={%s}{0.5}] %s;', lane.expr, lpath))
				end
			end
		elseif mix and opts.mix == 'bands' and mix.comp[ln.p] then
			bands(mix.comp[ln.p], ln.path, 1)
		end
	end
	if opts.heads ~= false then
		for _, hd in ipairs(heads) do
			w(string.format('\\pic at %s {bm head=%s};', pt(hd[1]), DIRNAME[hd[2]]))
		end
	end

	local order = {}
	for _, t in pairs(cell) do order[#order + 1] = t.pos end
	table.sort(order, less)
	for _, c in ipairs(order) do
		local t = cell[c.k]
		if t.type == 'underground_belt' then
			local o = DIRNAME[t.direction]
			-- With trim on, a tile without a tier shows yellow, the tier of the plain belt.
			if trim then o = o .. ',trim=' .. ((t.tier and TIERS[t.tier]) and t.tier or 'yellow') end
			w(string.format('\\pic at %s {bm %s={%s}};', pt(at(c, t.direction)), t.is_input and 'entrance' or 'exit', o))
		end
	end
	for si, s in ipairs(tr.splitters) do
		local c, d = s.tiles[1], s.d
		local ctr = s.tiles[2] and at(c, d, 0, 0.5) or at(c, d)
		local o = { DIRNAME[d] }
		if s.input then o[#o + 1] = 'in=' .. s.input end
		if s.output then o[#o + 1] = 'out=' .. s.output end
		if s.filter then
			local idx = 0
			for j, f in ipairs(tr.filters) do if f == s.filter then idx = j - 1 end end
			o[#o + 1] = 'filter, filter color=bmf' .. (idx % 6)
			-- the filtered item's icon over the diamond, from the reader's copy of the game
			if opts.icons ~= false and M.icon_opts then
				o[#o + 1] = 'filter icon={' .. M.icon_tex(M.filter_item(s.filter), '0.62\\bmunit') .. '}'
			end
		end
		if trim then o[#o + 1] = 'trim=' .. ((s.tier and TIERS[s.tier]) and s.tier or 'yellow') end
		if opts.numbers then o[#o + 1] = 'number=' .. si end
		w(string.format('\\pic at %s {bm splitter={%s}};', pt(ctr), table.concat(o, ', ')))
	end
	if state.diff then
		for _, d in ipairs(state.diff.list) do
			if d[3] == 'removed' then
				w(string.format('\\path[bm diff removed] (%d,%d) rectangle (%d,%d);', d[1], -d[2], d[1] + 1, -(d[2] + 1)))
			end
		end
	end

	-- Labels beside the entry and exit lines; with focus, the share of that input at each output.
	if flow ~= nil then
		local function sorted(list)
			table.sort(list, function(a, b)
				if flow % 2 == 0 then
					if a.y ~= b.y then return a.y < b.y end
					return a.x < b.x
				end
				return less(a, b)
			end)
			return list
		end
		local ins = sorted({ table.unpack(tr.inputs) })
		local outs = {}
		for _, o in ipairs(tr.outputs) do outs[#outs + 1] = add(o[1], flow, -1) end
		outs = sorted(outs)
		local ANCHOR = { [0] = 'west', 'south', 'east', 'north' }
		-- marks: a check or cross just past the belt end, the label beyond it
		local function place(names, tiles, away, extra, marks)
			if names == true then
				names = {}
				for i = 1, #tiles do names[i] = tostring(i) end
			end
			for i, c in ipairs(tiles) do
				local off = 0.5
				if marks and marks[i] ~= nil then
					w(string.format('\\pic at %s {bm mark=%s};', pt(at(c, away, 0.78)), marks[i] and 'ok' or 'bad'))
					off = 1.12
				end
				local name = names and names[i]
				if name then
					if extra and extra[i] then name = name .. '~' .. extra[i] end
					w(string.format('\\node[bm label, anchor=%s] at %s {%s};', ANCHOR[away], pt(at(c, away, off)), name))
				end
			end
		end
		local reach
		if mix and mix.reach then
			reach = {}
			for o, v in pairs(mix.reach) do reach[o] = '{\\scriptsize(' .. pct(v) .. ')}' end
		end
		local mk = opts.marks and state.marks or nil
		place(opts.inputs or (opts.labels and true or nil), ins, (flow + 2) % 4, nil, mk and mk.ins)
		place(opts.outputs or ((opts.labels or reach) and true or nil), outs, flow, reach, mk and mk.outs)
	end
	return out
end

-- view=graph: the splitter network on its own, without the positions of the layout.  Inputs
-- stand in a column on the left and outputs on the right; splitters (numbered as numbers=true
-- numbers them on the layout) and the merges where a belt side-loads are placed by the force
-- layout of beltmap-net.lua.  Arcs are curves that leave each node to the right and enter the
-- next from the left, each at its own point, so the two belts into or out of a splitter part;
-- they take the colors of the layout, mix included.
-- The belt colors (bmc*), and with mix the input and piece colors (bmi*, bmp*), as TeX.
local function color_defs(state, w)
	local tr, mix = state.tr, state.mix
	local cols = M.palette(#tr.segs)
	for k = 1, #tr.segs do
		local col = cols[k]
		w(string.format('\\definecolor{bmc%d}{RGB}{%d,%d,%d}', k - 1, col[1], col[2], col[3]))
	end
	if mix then
		for i, col in ipairs(mix.inputs) do w(string.format('\\definecolor{bmi%d}{RGB}{%d,%d,%d}', i - 1, col[1], col[2], col[3])) end
		for p = 1, #mix.pieces do
			local col = mix.rgb[p]
			if col then w(string.format('\\definecolor{bmp%d}{RGB}{%d,%d,%d}', p - 1, col[1], col[2], col[3])) end
		end
	end
end

-- The color of piece p of the network: its mix, else its belt's color.
local function piece_color(state, net, p)
	if not p then return 'bm-idle' end
	return state.mix and state.mix.expr[p] or ('bmc' .. (net.pieces[p].k - 1))
end

function M.graph_tikz(state)
	local net = M.network(state)
	if not net then fail('view=graph: ' .. (state.net_error or 'the belts could not be followed')) end
	local g = NET.graph(net)
	local pos, info = NET.layout(g)
	local tr, mix = state.tr, state.mix
	local out = {}
	local function w(s) out[#out + 1] = s end
	color_defs(state, w)
	-- Layout units are about a centimeter at the default tile of 4.4mm; the graph scales with tile.
	local S = 2.3
	local function xy(p) return string.format('(%s,%s)', num(p[1] * S), num(p[2] * S)) end
	for _, nd in ipairs(g.nodes) do
		w(string.format('\\node[bm g %s] (%s) at %s {%s};', nd.kind, nd.name, xy(pos[nd.name]), nd.label))
	end
	-- The point where each arc leaves and enters: arcs into a node are spread over its height
	-- from top to bottom in the order of their other ends, and so are arcs out of it.
	local into, outof = {}, {}
	for idx, a in ipairs(g.arcs) do
		into[a[2]] = into[a[2]] or {}
		table.insert(into[a[2]], idx)
		outof[a[1]] = outof[a[1]] or {}
		table.insert(outof[a[1]], idx)
	end
	local SPREAD = { splitter = 0.62, input = 0, output = 0, merge = 0 }
	local kind_of = {}
	for _, nd in ipairs(g.nodes) do kind_of[nd.name] = nd.kind end
	local function offsets(list, other)
		table.sort(list, function(i, j)
			local yi, yj = pos[other(g.arcs[i])][2], pos[other(g.arcs[j])][2]
			if yi ~= yj then return yi > yj end
			return i < j
		end)
		local off = {}
		for r, idx in ipairs(list) do
			off[idx] = (#list == 1) and 0 or (0.5 - (r - 1) / (#list - 1))
		end
		return off
	end
	local in_off, out_off = {}, {}
	for name, list in pairs(into) do
		for idx, v in pairs(offsets(list, function(a) return a[1] end)) do in_off[idx] = v * (SPREAD[kind_of[name]] or 0) end
	end
	for name, list in pairs(outof) do
		for idx, v in pairs(offsets(list, function(a) return a[2] end)) do out_off[idx] = v * (SPREAD[kind_of[name]] or 0) end
	end
	w('\\begin{pgfonlayer}{bmarcs}')
	for idx, a in ipairs(g.arcs) do
		local p = a[3]
		local col = 'bm-idle'
		if p then col = mix and mix.expr[p] or ('bmc' .. (net.pieces[p].k - 1)) end
		local from, to = pos[a[1]], pos[a[2]]
		local function anchor(name, side, off)
			if kind_of[name] == 'merge' then return '(' .. name .. ')' end
			if off == 0 then return '(' .. name .. '.' .. side .. ')' end
			return string.format('([yshift=%s\\bmunit]%s.%s)', num(off), name, side)
		end
		local a1, a2 = anchor(a[1], 'east', out_off[idx] or 0), anchor(a[2], 'west', in_off[idx] or 0)
		if info.back[idx] or to[1] - from[1] < 0.3 then
			-- An arc that closes a loop leaves to the right and swings round, below the two
			-- nodes when they sit low and above when they sit high, into its node from the left.
			local low = (from[2] + to[2]) / 2 <= 0
			local y = low and (math.min(from[2], to[2]) - 1.1) or (math.max(from[2], to[2]) + 1.1)
			w(string.format('\\draw[bm g arc={%s}] %s .. controls %s and %s .. %s;', col, a1,
				xy({ from[1] + 1.3, y }), xy({ to[1] - 1.3, y }), a2))
		else
			w(string.format('\\draw[bm g arc={%s}] %s to[out=0, in=180, looseness=0.8] %s;', col, a1, a2))
		end
	end
	w('\\end{pgfonlayer}')
	return out
end

-- view=wires: the canonical wire diagram of beltmap-net.lua's N.wires.  Wire 0 is on top;
-- inputs on the left, outputs on the right, one column per layer of splitters, and each loop
-- wire leaving on the right and coming back round underneath.  Returns nil and the reason
-- when the network has no wire diagram.
-- The wire diagram of a picture, searched once and kept: the alternative text needs it before
-- the picture is drawn.
function M.wires_data(state)
	if state.wires == nil then
		local net = M.network(state)
		local D, why
		if net then D, why = NET.wires(NET.graph(net)) else why = state.net_error or 'the belts could not be followed' end
		state.wires, state.wires_failed = D or false, why
	end
	return state.wires or nil, state.wires_failed
end

function M.wires_tikz(state)
	local D, why = M.wires_data(state)
	if not D then return nil, why end
	local net = M.network(state)
	local opts = state.opts
	local out = {}
	local function w(s) out[#out + 1] = s end
	color_defs(state, w)
	local DX, DY = 2.3, 1.4
	local nl = 0
	for _, l in pairs(D.layer) do nl = math.max(nl, l) end
	local xR = (nl + 1) * DX
	local function Y(l) return -l * DY end
	-- Bars in one layer whose spans overlap step sideways.
	local xbar, by = {}, {}
	for _, b in ipairs(D.bars) do
		by[b[1]] = by[b[1]] or {}
		table.insert(by[b[1]], b)
	end
	for lyr, list in pairs(by) do
		table.sort(list, function(a, b) return a[2] < b[2] or (a[2] == b[2] and a[3] < b[3]) end)
		local slot, used = {}, {}
		for _, b in ipairs(list) do
			local k = 0
			while true do
				local clash = false
				for _, u in ipairs(used) do
					if u[3] == k and not (b[3] < u[1] or b[2] > u[2]) then clash = true end
				end
				if not clash then break end
				k = k + 1
			end
			used[#used + 1] = { b[2], b[3], k }
			slot[b] = k
		end
		local ks = 0
		for _, u in ipairs(used) do ks = math.max(ks, u[3] + 1) end
		for _, b in ipairs(list) do xbar[b[4]] = lyr * DX + (slot[b] - (ks - 1) / 2) * 0.7 end
	end
	local loopline = {}
	for _, id in ipairs(D.loops) do loopline[D.line[id]] = id end
	-- the line an arc runs on: its own token; a loop arc's two ends share one line
	w('\\begin{pgfonlayer}{bmarcs}')
	local lowest = {}
	for _, id in ipairs(D.loops) do lowest[#lowest + 1] = D.line[id] end
	table.sort(lowest, function(a, b) return a > b end)
	local ring = {}
	for k, l in ipairs(lowest) do ring[l] = k end
	local ybot = Y(D.w - 1)
	for _, a in ipairs(D.arcs) do
		local col = piece_color(state, net, a.piece)
		local l = D.line[a.id]
		local y = Y(l)
		local x1 = (D.kind[a[1]] == 'input') and 0 or xbar[a[1]]
		local x2 = (D.kind[a[2]] == 'output') and xR or xbar[a[2]]
		if D.F[a.id] then
			-- leaves its tail to the right end, round underneath, and in from the left end
			local k = ring[l]
			local yb = ybot - 0.9 - (k - 1) * 0.75
			local r = 0.8 + (k - 1) * 0.35
			w(string.format('\\draw[bm w wire={%s}] (%s,%s) -- (%s,%s) .. controls (%s,%s) and (%s,%s) .. (%s,%s) -- (%s,%s) .. controls (%s,%s) and (%s,%s) .. (%s,%s) -- (%s,%s);',
				col, num(x1), num(y), num(xR), num(y), num(xR + 1.4 * r), num(y), num(xR + 1.4 * r), num(yb), num(xR), num(yb),
				num(0), num(yb), num(-1.4 * r), num(yb), num(-1.4 * r), num(y), num(0), num(y), num(x2), num(y)))
		else
			w(string.format('\\draw[bm w wire={%s}] (%s,%s) -- (%s,%s);', col, num(x1), num(y), num(x2), num(y)))
		end
	end
	w('\\end{pgfonlayer}')
	for _, b in ipairs(D.bars) do
		local x = xbar[b[4]]
		w(string.format('\\draw[bm w bar] (%s,%s) -- (%s,%s);', num(x), num(Y(b[2])), num(x), num(Y(b[3]))))
		local label = opts.numbers and b[4]:sub(2) or ''
		w(string.format('\\node[bm w pad] at (%s,%s) {%s};', num(x), num(Y(b[2])), label))
		w(string.format('\\node[bm w pad] at (%s,%s) {};', num(x), num(Y(b[3]))))
	end
	local mk = opts.marks and state.marks or nil
	for _, a in ipairs(D.arcs) do
		local y = Y(D.line[a.id])
		if D.kind[a[1]] == 'input' then
			w(string.format('\\node[bm g input] at (%s,%s) {%s};', num(0), num(y), opts.labels and a[1]:sub(3) or ''))
			local ok = mk and mk.ins[tonumber(a[1]:sub(3))]
			if ok ~= nil then w(string.format('\\pic at (%s,%s) {bm mark=%s};', num(-1.0), num(y), ok and 'ok' or 'bad')) end
		end
		if D.kind[a[2]] == 'output' then
			w(string.format('\\node[bm g output] at (%s,%s) {%s};', num(xR), num(y), opts.labels and a[2]:sub(4) or ''))
			local ok = mk and mk.outs[tonumber(a[2]:sub(4))]
			if ok ~= nil then w(string.format('\\pic at (%s,%s) {bm mark=%s};', num(xR + 1.0), num(y), ok and 'ok' or 'bad')) end
		end
	end
	return out
end

-- A sentence for the alternative text of a tagged PDF.
function M.describe(state)
	local tr = state.tr
	state.opts = state.opts or {}
	local n_split, n_tunnel = #tr.splitters, #tr.tunnels
	local parts = {}
	local D = (state.opts.view == 'wires') and M.wires_data(state)
	if D then
		parts[#parts + 1] = string.format('Wire diagram of a splitter network: %d splitter%s as bars across %d wire%s, %d of them loop%s',
			n_split, n_split == 1 and '' or 's', D.w, D.w == 1 and '' or 's', #D.loops, #D.loops == 1 and '' or 's')
	elseif state.opts.view == 'graph' then
		parts[#parts + 1] = string.format('Splitter graph of a belt layout with %d splitter%s', n_split, n_split == 1 and '' or 's')
	else
		parts[#parts + 1] = string.format('Belt layout of %d by %d tiles with %d splitter%s and %d underground tunnel%s',
			tr.w, tr.h, n_split, n_split == 1 and '' or 's', n_tunnel, n_tunnel == 1 and '' or 's')
	end
	if tr.flow ~= nil then
		local SIDE = { [0] = { 'left', 'right' }, { 'bottom', 'top' }, { 'right', 'left' }, { 'top', 'bottom' } }
		parts[#parts] = parts[#parts] .. string.format('; %d input%s enter on the %s and %d output%s leave on the %s',
			#tr.inputs, #tr.inputs == 1 and '' or 's', SIDE[tr.flow][1], #tr.outputs, #tr.outputs == 1 and '' or 's', SIDE[tr.flow][2])
	end
	local ins, outs, filters = 0, 0, {}
	for _, s in ipairs(tr.splitters) do
		if s.input then ins = ins + 1 end
		if s.output and not s.filter then outs = outs + 1 end
		if s.filter then filters[#filters + 1] = s.filter .. ' to the ' .. (s.output or 'left') end
	end
	local opt = {}
	if ins > 0 then opt[#opt + 1] = ins .. ' with input priority' end
	if outs > 0 then opt[#opt + 1] = outs .. ' with output priority' end
	if #filters > 0 then opt[#opt + 1] = 'filters: ' .. table.concat(filters, ', ') end
	if #opt > 0 then parts[#parts + 1] = 'Splitters ' .. table.concat(opt, '; ') end
	local function plain(s) return (s:gsub('\\%%', ' percent'):gsub('%$', '')) end
	if state.mix and state.bal then
		local how = state.mix.focus and ('Belts are shaded by how much of input ' .. state.mix.focus .. ' they carry') or 'Belts are colored by the inputs they carry'
		parts[#parts + 1] = how .. '; the layout is ' .. plain(state.bal.verdict)
		if state.opts.lanemix then parts[#parts + 1] = 'Each lane is colored on its own; ' .. plain(state.bal.lane_verdict) end
	end
	if state.tp then parts[#parts + 1] = 'Throughput: ' .. plain(state.tp.verdict) end
	if state.blk then parts[#parts + 1] = 'With outputs blocked: ' .. plain(state.blk.verdict) end
	if state.ibal and state.opts.marks then parts[#parts + 1] = 'Input balance: ' .. plain(state.ibal.verdict) end
	if state.diff then
		parts[#parts + 1] = string.format('Compared with another layout: %d tiles added, %d removed, %d changed', state.diff.added, state.diff.removed, state.diff.changed)
	end
	return table.concat(parts, '. ') .. '.'
end

-- A short caption: inputs and outputs, size, splitters, tunnels, and the verdicts computed.
function M.caption(state)
	local tr = state.tr
	local w_, h_ = tr.w, tr.h
	if tr.flow ~= nil then
		if tr.flow % 2 == 0 then w_ = w_ - 2 else h_ = h_ - 2 end
	end
	local net = M.network(state)
	local parts = {}
	if net then parts[#parts + 1] = string.format('%d--%d', net.n, net.m) end
	parts[#parts + 1] = string.format('%d$\\times$%d', w_, h_)
	parts[#parts + 1] = string.format('%d splitter%s', #tr.splitters, #tr.splitters == 1 and '' or 's')
	parts[#parts + 1] = string.format('%d tunnel%s', #tr.tunnels, #tr.tunnels == 1 and '' or 's')
	if state.bal and state.bal.balanced ~= nil then parts[#parts + 1] = state.bal.balanced and 'balanced' or 'not balanced' end
	if state.opts.lanemix and state.bal and state.bal.lanes ~= nil then parts[#parts + 1] = state.bal.lanes and 'lanes kept' or 'lanes not kept' end
	if state.tp then parts[#parts + 1] = state.tp.ok and 'passes max-flow' or 'throughput limited' end
	if state.blk and state.blk.ok ~= nil then parts[#parts + 1] = state.blk.ok and 'balanced when blocked' or 'unbalanced when blocked' end
	if state.ibal and state.ibal.balanced ~= nil and state.opts.marks then parts[#parts + 1] = state.ibal.balanced and 'input balanced' or 'not input balanced' end
	if state.diff then
		parts[#parts + 1] = string.format('+%d $-$%d $\\sim$%d tiles', state.diff.added, state.diff.removed, state.diff.changed)
	end
	return table.concat(parts, ' \\textperiodcentered\\ ')
end

-- ------------------------------------------------------------------ loading

local function read(path)
	local found = path
	if kpse then
		-- Under texlua without a program name, kpse refuses; the path is then used as given.
		local ok, hit = pcall(function() return kpse.find_file(path, 'tex') or kpse.find_file(path) end)
		found = ok and hit or path
	end
	local f = io.open(found, 'rb')
	if not f then fail('cannot open ' .. path) end
	local s = f:read('a')
	f:close()
	return s
end

-- A layout from the text of a file or string; opts.kind is json, jsonl or blueprint.
function M.layout_from_text(text, kind, opts)
	opts = opts or {}
	text = text:gsub('^\239\187\191', '')
	if kind == 'jsonl' then
		local best, n = nil, 0
		local recs = {}
		for line in text:gmatch('[^\r\n]+') do
			if line:find('%S') then
				local r = json_decode(line)
				if r.status == 'sat' and (opts.pick == nil or r.file == opts.pick) then recs[#recs + 1] = r end
			end
		end
		if #recs == 0 then fail('no record with status "sat"' .. (opts.pick and (' for ' .. opts.pick) or '')) end
		if opts.record then
			best = recs[opts.record + 1]
			if not best then fail('record ' .. opts.record .. ' does not exist; there are ' .. #recs) end
		else
			for _, r in ipairs(recs) do
				if best == nil or r.area < best.area or (r.area == best.area and r.W < best.W) then best = r end
			end
		end
		local L = from_tile_rows(best.tiles)
		L.gap = best.gap
		return L
	end
	local trimmed = text:gsub('^%s+', '')
	if kind == 'json' or (kind == nil and trimmed:sub(1, 1) == '[') then
		local obj = json_decode(text)
		if obj.tiles or obj[1] then
			local L = from_tile_rows(obj.tiles or obj)
			L.gap = obj.gap
			L.inputs, L.outputs, L.tier = obj.inputs, obj.outputs, obj.tier
			return L
		end
		kind = 'blueprint'
	end
	local obj = M.decode_blueprint(text)
	if obj.tiles then
		local L = from_tile_rows(obj.tiles)
		L.gap = obj.gap
		L.inputs, L.outputs, L.tier = obj.inputs, obj.outputs, obj.tier
		return L
	end
	local found = blueprints_in(obj)
	if #found == 0 then fail('no blueprint found') end
	local pick = found[1]
	if opts.label then
		pick = nil
		for _, f in ipairs(found) do
			if not pick and f.label:lower():find(opts.label:lower(), 1, true) then pick = f end
		end
		if not pick then fail('no blueprint with a label containing "' .. opts.label .. '"') end
	elseif opts.index then
		pick = found[opts.index + 1]
		if not pick then fail('the book has ' .. #found .. ' blueprints, numbered from 0') end
	end
	return M.blueprint_layout(pick.bp, opts.numbering)
end

function M.layout_from_file(path, opts)
	local kind = path:match('%.jsonl$') and 'jsonl' or (path:match('%.json$') and 'json') or nil
	return M.layout_from_text(read(path), kind, opts)
end

-- Inline glyphs for running text and captions.
local GLYPHS = {
	belt = '> >',
	splitter = 'S^ S^',
	entrance = '> I>',
	exit = 'O> >',
	tunnel = 'I> . O>',
	['input priority'] = 'S^[in=left] S^',
	['output priority'] = 'S^[out=right] S^',
	filter = 'S^[filter=item] S^',
	-- A lone feed from the side turns a belt; a side-load needs a belt behind as well.
	['side-load'] = '. v . \\\\ > > >',
}
local GLYPH_ALT = {
	belt = 'belt', splitter = 'splitter', entrance = 'underground belt entrance', exit = 'underground belt exit',
	tunnel = 'underground belt', ['input priority'] = 'splitter with input priority', ['output priority'] = 'splitter with output priority',
	filter = 'splitter with a filter', ['side-load'] = 'side-loading',
}

-- ------------------------------------------------------------------ the TeX side

local current
local function topt(name)
	local v = token.get_macro('l__beltmap_' .. name .. '_tl')
	if v == nil then return nil end
	v = v:gsub('^%s+', ''):gsub('%s+$', '')
	if v == '' then return nil end
	return v
end

local function bool(name)
	local v = topt(name)
	if v == nil then return nil end
	return v == 'true'
end

local function tex_options(L)
	local o = {}
	o.gap = tonumber(topt('gap') or '')
	o.tier = topt('tier')
	local trim = topt('trim')
	o.trim = (trim == nil or trim == 'auto') and 'auto' or trim == 'true'
	o.color = topt('color') or 'belt'
	o.flow = topt('flow')
	o.theme = topt('theme')
	o.mix = topt('mix')
	if o.mix == 'none' then o.mix = nil end
	o.lanemix = bool('mixlanes')
	o.focus = tonumber(topt('focus') or '')
	o.step = tonumber(topt('step') or '')
	o.palette = topt('palette')
	o.throughput = bool('throughput')
	o.blocked = bool('blocked')
	o.marks = bool('marks')
	o.demand = bool('demand')
	o.numbers = bool('numbers')
	o.compare = topt('compare')
	o.view = topt('view')
	M.icon_opts = { data = topt('factoriodata'), off = (topt('icons') == 'false') }
	o.icons = not M.icon_opts.off
	o.ends, o.heads, o.lanes = bool('ends'), bool('heads'), bool('lanes')
	local grid = topt('grid')
	if grid == 'false' or grid == 'none' then
		o.grid = false
	else
		o.grid = true
		o.grid_level = (grid == 'faint' or grid == 'strong') and grid or 'normal'
	end
	o.grid_major = tonumber(topt('gridmajor') or '')
	local rulers = topt('rulers')
	o.rulers = (rulers and rulers ~= 'none') and (tonumber(rulers) or 1) or nil
	o.dimensions = bool('dimensions')
	o.labels = bool('labels')
	o.open_ends = bool('openends')
	local ins, outs = topt('inputs'), topt('outputs')
	o.inputs = ins and split_list(ins) or (L and L.inputs)
	o.outputs = outs and split_list(outs) or (L and L.outputs)
	if not o.tier and L and L.tier then o.tier = L.tier end
	return o
end

local function load_opts()
	local numbering = topt('factorio')
	return {
		pick = topt('pick'),
		record = tonumber(topt('record') or ''),
		index = tonumber(topt('index') or ''),
		label = topt('label'),
		numbering = numbering == '1.1' and 8 or (numbering == '2.0' and 16 or nil),
	}
end

local function plain(s) return (s:gsub('\\%%', '%%'):gsub('%$', '')) end

-- expect={balanced, unbalanced, lanes, throughput, limited, blocked, blocked-unbalanced, input-balanced,
-- input-unbalanced}: stop with an error when the layout
-- is not what the document says it is.
local function check_expect(state, list)
	for _, e in ipairs(list) do
		local ok, why
		if e == 'balanced' or e == 'unbalanced' or e == 'lanes' then
			local b = M.balance(state)
			if not b or b.balanced == nil then
				ok, why = false, b and b.verdict or 'the flow could not be computed'
			elseif e == 'balanced' then
				ok, why = b.balanced, b.verdict
			elseif e == 'unbalanced' then
				ok, why = not b.balanced, b.verdict
			else
				ok, why = b.lanes, b.lane_verdict
			end
		elseif e == 'input-balanced' or e == 'input-unbalanced' then
			local b = M.input_balance(state)
			if not b or b.balanced == nil then
				ok, why = false, b and b.verdict or 'the demand could not be computed'
			else
				ok, why = (e == 'input-balanced') == b.balanced, b.verdict
			end
		elseif e == 'blocked' or e == 'blocked-unbalanced' then
			local b = M.blocked(state)
			if b.ok == nil then
				ok, why = false, b.verdict
			else
				ok, why = (e == 'blocked') == b.ok, b.verdict
			end
		elseif e == 'throughput' or e == 'limited' then
			local t = M.throughput(state)
			if not t then
				ok, why = false, 'the layout has no inputs or no outputs'
			else
				ok, why = (e == 'throughput') == t.ok, t.verdict
			end
		else
			ok, why = false, 'unknown value (the values are balanced, unbalanced, lanes, throughput, limited, blocked, blocked-unbalanced, input-balanced, input-unbalanced)'
		end
		if not ok then tex.error('beltmap: expect=' .. e .. ' fails: ' .. plain(why)) end
	end
end

M.collected = {}

local function finish(getL, alt_override)
	local ok, err = pcall(function()
		local L = getL()
		current = M.prepare(L, tex_options(L))
		local expect = topt('expect')
		if expect then check_expect(current, split_list(expect)) end
		current.alt = alt_override or M.describe(current)
		if L.skipped and #L.skipped > 0 and texio then
			texio.write_nl('log', 'beltmap: left out ' .. #L.skipped .. ' entities of other kinds')
		end
		if current.mix_failed then
			texio.write_nl('term and log', 'beltmap warning: mix is off for this picture: ' .. current.mix_failed)
		end
		if current.bal and current.bal.verdict and texio then
			texio.write_nl('log', 'beltmap: ' .. plain(current.bal.verdict))
			local net = current.net
			for _, out in ipairs(net and net.outputs or {}) do
				local per = NET.belt(net, net.last[out.k])
				local f = {}
				for i = 1, net.n do f[i] = tostring(per[i]) end
				texio.write_nl('log', string.format('beltmap: output %d carries %s', out.index, table.concat(f, ' ')))
			end
		end
		if current.tp and texio then texio.write_nl('log', 'beltmap: ' .. plain(current.tp.verdict)) end
	end)
	if not ok then
		current = nil
		local msg = type(err) == 'table' and err.beltmap or tostring(err)
		tex.error('beltmap: ' .. msg)
	end
	-- The blueprint string of the picture; with blueprint=file or attach also a text file.
	local bpstring, bpfile = '', ''
	if current then
		local okb, res = pcall(function()
			local L = current.L
			local f = topt('factorio')
			local numbering = (f == '1.1' and 8) or (f == '2.0' and 16) or L.numbering or 16
			local obj = M.blueprint_of(L, { numbering = numbering, label = topt('bplabel') })
			local s = M.encode_blueprint(obj)
			local diffs = M.check_blueprint(L, s, numbering)
			if #diffs > 0 and topt('blueprint') then
				texio.write_nl('term and log', 'beltmap warning: the blueprint differs from the picture: ' .. table.concat(diffs, '; '))
			end
			return { s = s, obj = obj }
		end)
		local mode = topt('blueprint')
		if okb then
			bpstring = res.s
			if mode == 'file' or mode == 'attach' then M.collected[#M.collected + 1] = res.obj end
		elseif mode then
			texio.write_nl('term and log', 'beltmap warning: no blueprint: ' .. (type(res) == 'table' and res.beltmap or tostring(res)))
		end
		if bpstring ~= '' and (mode == 'file' or mode == 'attach') then
			M.bp_count = (M.bp_count or 0) + 1
			bpfile = (tex.jobname or 'beltmap') .. '-blueprint-' .. M.bp_count .. '.txt'
			local fh = io.open(bpfile, 'wb')
			if fh then
				fh:write(bpstring, '\n')
				fh:close()
			else
				texio.write_nl('term and log', 'beltmap warning: cannot write ' .. bpfile)
				bpfile = ''
			end
		end
	end
	token.set_macro('beltmapstring', bpstring, 'global')
	token.set_macro('l__beltmap_bpfile_tl', bpfile)
	token.set_macro('l__beltmap_auto_alt_tl', current and current.alt or 'Belt layout')
	local verdict = current and ((current.bal and current.bal.verdict) or current.mix_failed) or ''
	token.set_macro('beltmapverdict', verdict, 'global')
	token.set_macro('beltmaplanes', current and current.bal and current.bal.lane_verdict or '', 'global')
	token.set_macro('beltmapthroughput', current and current.tp and current.tp.verdict or '', 'global')
	token.set_macro('beltmapblocked', current and current.blk and current.blk.verdict or '', 'global')
	token.set_macro('beltmapinputs', current and current.ibal and current.ibal.verdict or '', 'global')
	local okc, cap = pcall(function() return current and M.caption(current) or '' end)
	token.set_macro('beltmapcaption', okc and cap or '', 'global')
end

function M.from_file(path) finish(function() return M.layout_from_file(path, load_opts()) end) end
function M.from_string(s) finish(function() return M.layout_from_text(s, nil, load_opts()) end) end
function M.from_grid(body) finish(function() return M.grid_layout(body) end) end
function M.from_glyph(kind)
	local g = GLYPHS[kind]
	if not g then
		local names = {}
		for k in pairs(GLYPHS) do names[#names + 1] = k end
		table.sort(names)
		tex.error('beltmap: unknown glyph "' .. kind .. '"; the glyphs are ' .. table.concat(names, ', '))
		g = 'belt'
	end
	finish(function() return M.grid_layout(g) end, GLYPH_ALT[kind] or kind)
end

local function catcodes()
	return luatexbase and luatexbase.registernumber('catcodetable@latex') or nil
end
local function print_lines(lines)
	local ctab = catcodes()
	for _, line in ipairs(lines) do
		if ctab then tex.print(ctab, line) else tex.print(line) end
	end
end

-- The last blueprint string, typeset so that a line may break after any character.
function M.print_string()
	local s = token.get_macro('beltmapstring') or ''
	local ctab = catcodes()
	local body = s:gsub('(.)', '%1\\allowbreak ')
	if ctab then tex.sprint(ctab, body) else tex.sprint(body) end
end

-- \beltmapmatrix: the shares of the last picture, exact when they fit.
function M.print_matrix()
	if not current then return end
	local ok, s = pcall(M.matrix_tex, current)
	if not ok then s = '(no matrix)' end
	local lines = {}
	for line in s:gmatch('[^\n]+') do lines[#lines + 1] = line end
	print_lines(lines)
end

-- \beltanimation: the number of frames of a layout file, into \l__beltmap_frames_tl.
function M.count_frames(path)
	local n = 1
	local ok, err = pcall(function()
		local L = M.layout_from_file(path, load_opts())
		local o = tex_options(L)
		o.step = 0
		local st = M.prepare(L, o)
		n = st.frames and #st.frames or 1
	end)
	if not ok then tex.error('beltmap: ' .. (type(err) == 'table' and err.beltmap or tostring(err))) end
	token.set_macro('l__beltmap_frames_tl', tostring(n))
end

-- \beltgallery: one cell per record with status "sat" of a .jsonl file (pick= keeps one
-- family, limit= the first so many), columns= per row.
function M.gallery(path)
	local recs = {}
	local ok, err = pcall(function()
		local fh = io.open((kpse and kpse.find_file(path, 'tex')) or path, 'rb') or io.open(path, 'rb')
		if not fh then fail('cannot open ' .. path) end
		local pick = topt('pick')
		for line in fh:lines() do
			if line:find('%S') then
				local r = json_decode(line)
				if r.status == 'sat' and (pick == nil or r.file == pick) then recs[#recs + 1] = r end
			end
		end
		fh:close()
	end)
	if not ok then
		tex.error('beltmap: ' .. (type(err) == 'table' and err.beltmap or tostring(err)))
		return
	end
	local limit = tonumber(topt('limit') or '') or #recs
	local cols = (tex and tex.count and tex.count['l__beltmap_columns_int']) or 3
	if cols < 1 then cols = 1 end
	local lines = {}
	for i = 1, math.min(limit, #recs) do
		local r = recs[i]
		local name = tostring(r.file or ('record ' .. (i - 1)))
		if r.W and r.H then name = name .. string.format(', %d$\\times$%d', r.W, r.H) end
		if r.area then name = name .. ', area ' .. r.area end
		name = name:gsub('_', '\\_')
		lines[#lines + 1] = string.format('\\BeltmapGalleryCell{%d}{%s}', i - 1, name)
		if i % cols == 0 or i == math.min(limit, #recs) then
			lines[#lines + 1] = '\\par\\medskip\\noindent'
		else
			lines[#lines + 1] = '\\hfill'
		end
	end
	print_lines(lines)
end

-- \beltmapbook: every blueprint written with blueprint=file or attach, as one book, written to
-- <jobname>-book.txt; its string goes to \l__beltmap_bookstring_tl and the file name to
-- \l__beltmap_bookfile_tl (empty when there is nothing to collect).
function M.book(label)
	token.set_macro('l__beltmap_bookfile_tl', '')
	token.set_macro('l__beltmap_bookstring_tl', '')
	if #M.collected == 0 then
		texio.write_nl('term and log', 'beltmap warning: \\beltmapbook: no picture has blueprint=file or blueprint=attach')
		return
	end
	local list, version = {}, 0
	for i, obj in ipairs(M.collected) do
		list[i] = { index = i - 1, blueprint = obj.blueprint }
		version = math.max(version, obj.blueprint.version or 0)
	end
	local book = { blueprint_book = { item = 'blueprint-book', label = label ~= '' and label or 'beltmap', blueprints = list,
		active_index = 0, version = version } }
	local s = M.encode_blueprint(book)
	local name = (tex.jobname or 'beltmap') .. '-book.txt'
	local fh = io.open(name, 'wb')
	if fh then
		fh:write(s, '\n')
		fh:close()
		token.set_macro('l__beltmap_bookfile_tl', name)
	end
	token.set_macro('l__beltmap_bookstring_tl', s)
	texio.write_nl('log', string.format('beltmap: wrote %s with %d blueprints', name, #list))
end

function M.emit()
	if not current then return end
	print_lines(M.tikz(current))
end

-- ------------------------------------------------------------------ game icons
-- beltmap ships no game graphics.  With icons on, it reads them from the reader's own copy of
-- Factorio: the data folder given by factorio data=, else $FACTORIO_DATA, else the usual Steam
-- places.  An item's icon file is the one its prototype names (icon = "__mod__/..."), read from
-- the prototype sources of every mod in the data folder; a game icon holds mipmaps side by side,
-- and only the full-size square on the left is shown.  Without a data folder, or for an unknown
-- name, a placeholder with the item's initials is drawn instead, and the log says why.

local ICON_PLACES = {
	'C:/Program Files (x86)/Steam/steamapps/common/Factorio/data',
	'C:/Program Files/Steam/steamapps/common/Factorio/data',
	'C:/Program Files/Factorio/data',
	'~/.steam/steam/steamapps/common/Factorio/data',
	'~/.local/share/Steam/steamapps/common/Factorio/data',
	'~/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/data',
	'/Applications/factorio.app/Contents/data',
}

local icon_index, icon_dir, icon_warned = nil, nil, {}

local function is_dir(p)
	return lfs and lfs.attributes(p, 'mode') == 'directory'
end

local icon_given
local function factorio_data()
	local given = M.icon_opts and M.icon_opts.data
	if icon_dir ~= nil and icon_given == given then return icon_dir or nil end
	icon_given, icon_index = given, nil
	local home = os.getenv('HOME') or os.getenv('USERPROFILE') or ''
	local list = {}
	if given then list[#list + 1] = given end
	if os.getenv('FACTORIO_DATA') then list[#list + 1] = os.getenv('FACTORIO_DATA') end
	for _, p in ipairs(ICON_PLACES) do list[#list + 1] = p end
	for _, p in ipairs(list) do
		p = p:gsub('^~', home):gsub('\\', '/'):gsub('/$', '')
		if is_dir(p .. '/base/graphics/icons') then
			icon_dir = p
			if texio then texio.write_nl('log', 'beltmap: game icons from ' .. p) end
			return p
		end
	end
	icon_dir = false
	return nil
end

-- name -> { mod, path } from the prototype sources: the first icon = "__mod__/..." after each
-- name = "...", item files first.
local function build_index(data)
	local idx = {}
	local files = {}
	local function walk(dir)
		for f in lfs.dir(dir) do
			if f ~= '.' and f ~= '..' then
				local p = dir .. '/' .. f
				if is_dir(p) then walk(p) elseif f:match('%.lua$') then files[#files + 1] = p end
			end
		end
	end
	for mod in lfs.dir(data) do
		if mod ~= '.' and mod ~= '..' and is_dir(data .. '/' .. mod .. '/prototypes') then walk(data .. '/' .. mod .. '/prototypes') end
	end
	table.sort(files, function(a, b)
		local ia, ib = a:match('/item[^/]*%.lua$') and 0 or 1, b:match('/item[^/]*%.lua$') and 0 or 1
		if ia ~= ib then return ia < ib end
		return a < b
	end)
	for _, p in ipairs(files) do
		local fh = io.open(p, 'r')
		if fh then
			local text = fh:read('*a')
			fh:close()
			local names = {}
			for pos, nm in text:gmatch('()name%s*=%s*"([^"]+)"') do names[#names + 1] = { pos, nm } end
			for i, nm in ipairs(names) do
				if not idx[nm[2]] then
					local stop = names[i + 1] and names[i + 1][1] or #text
					local seg = text:sub(nm[1], stop)
					local mod, path = seg:match('icon%s*=%s*"__([%w%-_]+)__/([^"]+%.png)"')
					if mod then idx[nm[2]] = { mod, path } end
				end
			end
		end
	end
	return idx
end

-- The icon file of an item, or nil and the reason.
function M.icon_file(name)
	local data = factorio_data()
	if not data then return nil, 'no Factorio data folder was found (set factorio data=)' end
	if not icon_index then icon_index = build_index(data) end
	local e = icon_index[name]
	local p
	if e then p = data .. '/' .. e[1] .. '/' .. e[2] end
	if not (p and lfs.attributes(p)) then
		p = data .. '/base/graphics/icons/' .. name .. '.png'
		if not lfs.attributes(p) then return nil, 'no icon for ' .. name end
	end
	return p
end

local function initials(name)
	local s = ''
	for part in name:gmatch('[^%-_ ]+') do s = s .. part:sub(1, 1):upper() end
	return s:sub(1, 3)
end

-- TeX for the icon of item name at the given width: the game's icon, or a placeholder.
function M.icon_tex(name, width)
	local p, why
	if not (M.icon_opts and M.icon_opts.off) then p, why = M.icon_file(name) else why = 'icons=false' end
	if p then
		local im = img and img.scan({ filename = p })
		local vp = '0 0 64 64'
		if im and im.xsize and im.xsize > 0 then
			-- the leftmost square, in the image's own big points
			local wbp, hbp = im.width / 65536 * 72 / 72.27, im.height / 65536 * 72 / 72.27
			local side = hbp
			vp = string.format('0 0 %.4f %.4f', side * math.min(1, wbp / hbp), hbp)
		end
		return string.format('\\BeltmapIconImage{%s}{%s}{%s}', vp, width, p)
	end
	if why and why ~= 'icons=false' and not icon_warned[why] and texio then
		icon_warned[why] = true
		texio.write_nl('term and log', 'beltmap warning: ' .. why .. '; drawing a placeholder')
	end
	return string.format('\\BeltmapIconMissing{%s}{%s}', width, initials(name))
end

-- \beltmapicon[width]{name}
function M.icon(name, width)
	M.icon_opts = { data = topt('factoriodata'), off = (topt('icons') == 'false') }
	tex.sprint(M.icon_tex(name, width ~= '' and width or '1.2em'))
end

M.TIERS, M.DIRS, M.GLYPHS = TIERS, DIRS, GLYPHS
return M
