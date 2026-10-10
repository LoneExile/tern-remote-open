--!nocheck
local h = require("./harness")
local hosts = require("../lib/hosts")

h.group("hosts")

local function host(name, kind, state, panes)
	return { id = 1, name = name, kind = kind, state = state, panes = panes, sessions = {}, current = false }
end

h.test("host_for_pane follows pane membership, not order or current", function()
	local a = host("a", "remote", "connected", { 11, 12 })
	local b = host("b", "remote", "connected", { 22 })
	local list = { a, b }
	h.eq(hosts.host_for_pane(list, 22), b)
	h.eq(hosts.host_for_pane(list, 11), a)
	h.eq(hosts.host_for_pane(list, 12), a)
end)

h.test("host_for_pane: an unknown pane has no host (no fallback)", function()
	h.eq(hosts.host_for_pane({ host("a", "remote", "connected", { 1 }) }, 99), nil)
	h.eq(hosts.host_for_pane({}, 1), nil)
end)

h.test("eligible: only a connected remote host", function()
	h.truthy(hosts.eligible(host("a", "remote", "connected", {})))
	h.falsy(hosts.eligible(host("local", "local", "connected", {})))
	for _, state in { "connecting", "stalled", "verify", "reconnecting", "failed" } do
		h.falsy(hosts.eligible(host("a", "remote", state, {})), state)
	end
	h.falsy(hosts.eligible(nil))
end)

return {}
