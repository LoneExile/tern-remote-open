--!strict
-- Which machine a pane belongs to, and whether it is one we may act for.

local hosts = {}

-- The host whose `panes` list holds `pane`, or nil. Membership decides: the
-- current or first host is never a fallback.
function hosts.host_for_pane(list: { ManagedHost }, pane: number): ManagedHost?
	for _, host in list do
		for _, member in host.panes do
			if member == pane then
				return host
			end
		end
	end
	return nil
end

-- A remote host with a live connection. Anything else (local, connecting,
-- stalled, reconnecting, failed, unverified) is left to Tern.
function hosts.eligible(host: ManagedHost?): boolean
	return host ~= nil and host.kind == "remote" and host.state == "connected"
end

return hosts
