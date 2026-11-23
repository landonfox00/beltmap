-- beltmap-fullload: places one copy of a layout for every choice of inputs and outputs, keeps the
-- chosen input lanes full, empties the chosen output belts every tick, and counts what arrives
-- after a warm-up.  Other inputs and outputs are left alone, so a closed output backs up.
local cases = require('runs')
local SLOT = 40

local state

local function setup()
	local s = game.create_surface('fullload', { seed = 1 })
	s.always_day = true
	local list = {}
	local index = 0
	for _, c in ipairs(cases) do
		for _, r in ipairs(c.runs) do
			index = index + 1
			local col, row = (index - 1) % 40, math.floor((index - 1) / 40)
			local cx, cy = col * SLOT, row * SLOT
			s.request_to_generate_chunks({ cx, cy }, 2)
			list[index] = { c = c, r = r, cx = cx, cy = cy }
		end
	end
	s.force_generate_chunk_requests()
	for _, R in ipairs(list) do
		local cx, cy = R.cx, R.cy
		local tiles = {}
		for x = cx - 3, cx + SLOT - 6 do
			for y = cy - 3, cy + SLOT - 6 do tiles[#tiles + 1] = { name = 'lab-dark-1', position = { x, y } } end
		end
		s.set_tiles(tiles, false, true, true, false)
		for _, e in pairs(s.find_entities_filtered({ area = { { cx - 3, cy - 3 }, { cx + SLOT - 6, cy + SLOT - 6 } } })) do
			if e.valid and e.type ~= 'character' then e.destroy() end
		end
		for _, e in ipairs(R.c.entities) do
			local ent = s.create_entity({ name = e.name, position = { cx + e.x, cy + e.y }, direction = e.direction, type = e.type, force = 'player' })
			if not ent then
				R.error = 'could not place ' .. e.name
			else
				if e.input_priority then ent.splitter_input_priority = e.input_priority end
				if e.output_priority then ent.splitter_output_priority = e.output_priority end
			end
		end
		local function belt_at(p)
			return s.find_entities_filtered({ area = { { cx + p[1] + 0.3, cy + p[2] + 0.3 }, { cx + p[1] + 0.7, cy + p[2] + 0.7 } },
				type = { 'transport-belt', 'underground-belt' } })[1]
		end
		R.lines_in, R.lines_out = {}, {}
		for _, p in ipairs(R.r.src) do
			local b = belt_at(p)
			if not b then R.error = 'no input belt' else
				for l = 1, 2 do R.lines_in[#R.lines_in + 1] = b.get_transport_line(l) end
			end
		end
		for _, p in ipairs(R.r.snk) do
			local b = belt_at(p)
			if not b then R.error = 'no output belt' else
				for l = 1, 2 do R.lines_out[#R.lines_out + 1] = b.get_transport_line(l) end
			end
		end
		R.count = 0
	end
	return list
end

script.on_event(defines.events.on_tick, function(ev)
	if not state then
		state = { start = ev.tick, list = setup() }
		return
	end
	local t = ev.tick - state.start
	local measuring = t > cases.warmup and t <= cases.warmup + cases.measure
	local item = { name = cases.item, count = 1 }
	for _, R in ipairs(state.list) do
		for _, line in ipairs(R.lines_out) do
			if measuring then R.count = R.count + line.get_item_count() end
			line.clear()
		end
		for _, line in ipairs(R.lines_in) do
			for _ = 1, 4 do
				if not line.can_insert_at_back() then break end
				line.insert_at_back(item)
			end
		end
	end
	if t == cases.warmup + cases.measure then
		local out = { warmup = cases.warmup, measure = cases.measure, runs = {} }
		for i, R in ipairs(state.list) do
			out.runs[i] = { case = R.c.case, I = R.r.I, O = R.r.O, count = R.count, error = R.error }
		end
		helpers.write_file('beltmap-fullload/results.json', helpers.table_to_json(out))
		log('beltmap-fullload: wrote ' .. #out.runs .. ' runs')
	end
end)
