-- The Lua test suite of beltmap.
--
--     texlua tests/run.lua              run every tests/lua/test_*.lua
--     texlua tests/run.lua wires        only the files whose name contains "wires"
--     texlua tests/run.lua --update     rewrite the golden files in tests/golden (then review the diff)
--
-- Each test file returns a list of { name, function }.  A case passes when its function returns
-- without an error.  Exit status 0 when every case passes, 1 otherwise; CI runs this.
local here = arg[0]:gsub('\\', '/')
local root = here:match('^(.*)/tests/[^/]*$') or (here:match('^tests/') and '.') or '..'
local update, filter = false, nil
for _, a in ipairs(arg) do
	if a == '--update' then update = true else filter = a end
end
BELTMAP_TEST = { root = root, update = update }
package.path = root .. '/?.lua;' .. root .. '/tests/lua/?.lua;' .. package.path

local files = {}
for f in lfs.dir(root .. '/tests/lua') do
	if f:match('^test_.*%.lua$') and (not filter or f:find(filter, 1, true)) then files[#files + 1] = f end
end
table.sort(files)

local passed, failed, failures = 0, 0, {}
local t0 = os.clock()
for _, f in ipairs(files) do
	local ok, cases = pcall(dofile, root .. '/tests/lua/' .. f)
	if not ok then
		failed = failed + 1
		failures[#failures + 1] = f .. ': could not load: ' .. tostring(cases)
		print('LOAD FAIL  ' .. f)
	else
		for _, case in ipairs(cases) do
			local t = os.clock()
			local good, err = xpcall(case[2], function(e)
				return (type(e) == 'table' and (e.beltmap or tostring(e)) or tostring(e)) .. '\n' .. debug.traceback('', 2)
			end)
			local label = string.format('%-22s %s', f:gsub('^test_', ''):gsub('%.lua$', ''), case[1])
			if good then
				passed = passed + 1
				print(string.format('ok    %s  (%.2fs)', label, os.clock() - t))
			else
				failed = failed + 1
				failures[#failures + 1] = label .. '\n' .. err
				print('FAIL  ' .. label)
			end
		end
	end
end

print(string.format('\n%d passed, %d failed in %.1fs', passed, failed, os.clock() - t0))
for _, msg in ipairs(failures) do print('\n--- ' .. msg) end
os.exit(failed == 0 and 0 or 1)
