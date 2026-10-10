--!nocheck
local h = require("./harness")
local registry = require("../lib/registry")

h.group("registry")

local function entry(port, extra)
	local e = {
		port = port, host = "devbox", target = "you@devbox", remote_host = "localhost",
		socket = "/data/cm/" .. port .. ".sock", started = 1000,
	}
	for k, v in extra or {} do
		e[k] = v
	end
	return e
end

local function kv()
	local data = {}
	return {
		data = data,
		get = function(key) return data[key] end,
		set = function(key, value) data[key] = value end,
	}
end

h.test("save then load round-trips; saving nothing deletes the key", function()
	local store = kv()
	registry.save(store, { entry(8250), entry(3000, { expires = 1600 }) })
	h.eq(#registry.load(store), 2)
	registry.save(store, {})
	h.eq(store.data.forwards, nil)
	h.eq(registry.load(store), {})
end)

h.test("load skips malformed entries and survives garbage", function()
	local store = kv()
	store.data.forwards = {
		entry(8250),
		{ port = 0, host = "x", target = "you@devbox", remote_host = "localhost", socket = "/s", started = 1 },
		entry(3000, { target = "-oFoo" }),
		entry(3001, { remote_host = "evil.com" }),
		entry(3002, { socket = "relative.sock" }),
		entry(3003, { started = "yesterday" }),
		entry(3004, { expires = "soon" }),
		"junk",
		42,
	}
	local loaded = registry.load(store)
	h.eq(#loaded, 1)
	h.eq(loaded[1].port, 8250)
	store.data.forwards = "not a table"
	h.eq(registry.load(store), {})
	store.data.forwards = nil
	h.eq(registry.load(store), {})
	h.eq(registry.load({ get = function() error("boom") end, set = function() end }), {})
end)

h.test("find, with and without", function()
	local list = { entry(3000), entry(8250) }
	h.eq(registry.find(list, 8250).port, 8250)
	h.eq(registry.find(list, 1), nil)
	h.eq(#registry.without(list, 3000), 1)
	h.eq(#registry.without(list, 5), 2)
	local replaced = registry.with(list, entry(3000, { expires = 5 }))
	h.eq(#replaced, 2)
	h.eq(registry.find(replaced, 3000).expires, 5)
	local added = registry.with(list, entry(100))
	h.eq(added[1].port, 100, "kept sorted by port")
	h.eq(#list, 2, "the input is not mutated")
end)

return {}
