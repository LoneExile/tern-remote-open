--!nocheck
-- A minimal test harness: `test(name, fn)` runs `fn` under pcall; `eq` compares
-- deeply; `summary()` prints counts and raises when anything failed, so
-- `luau tests/run.luau` exits non-zero.

local harness = {}

local passed = 0
local failed = 0
local failures = {}
local groups = {}
local current_group = "?"

function harness.group(name)
	current_group = name
	groups[name] = groups[name] or { passed = 0, failed = 0 }
end

function harness.test(name, fn)
	local ok, err = pcall(fn)
	local g = groups[current_group]
	if ok then
		passed += 1
		g.passed += 1
	else
		failed += 1
		g.failed += 1
		table.insert(failures, current_group .. " :: " .. name .. "\n    " .. tostring(err))
	end
end

local function show(v, depth)
	depth = depth or 0
	if type(v) == "string" then
		return string.format("%q", v)
	end
	if type(v) ~= "table" then
		return tostring(v)
	end
	if depth > 4 then
		return "{...}"
	end
	local keys = {}
	for k in v do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, k in keys do
		table.insert(parts, tostring(k) .. "=" .. show(v[k], depth + 1))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end
harness.show = show

local function same(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function harness.eq(actual, expected, msg)
	if not same(actual, expected) then
		error((msg or "values differ") .. "\n      expected: " .. show(expected) .. "\n      actual:   " .. show(actual), 2)
	end
end

function harness.truthy(value, msg)
	if not value then
		error((msg or "expected a truthy value") .. " (got " .. show(value) .. ")", 2)
	end
end

function harness.falsy(value, msg)
	if value then
		error((msg or "expected a falsy value") .. " (got " .. show(value) .. ")", 2)
	end
end

function harness.raises(fn, msg)
	local ok = pcall(fn)
	if ok then
		error(msg or "expected the call to raise", 2)
	end
end

function harness.summary()
	local names = {}
	for name in groups do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local g = groups[name]
		print(string.format("  %-12s %3d passed, %d failed", name, g.passed, g.failed))
	end
	print(string.format("%d passed, %d failed", passed, failed))
	if failed > 0 then
		for _, f in failures do
			print("FAIL " .. f)
		end
		error(string.format("%d test(s) failed", failed), 0)
	end
end

return harness
