--!strict
-- `config.json` in the plugin's data directory. It is user-written, so every
-- field is validated and a bad one is dropped with a warning rather than
-- trusted.

local check = require("./check")

local config = {}

export type Config = {
	hosts: { [string]: string },
	allowed_ports: { number }?,
	control_dir: string?,
}

export type Result = { config: Config, warnings: { string } }

-- Turns the decoded JSON `raw` (anything) into a Config.
function config.normalize(raw: any): Result
	local result: Result = { config = { hosts = {} }, warnings = {} }
	if raw == nil then
		return result
	end
	if type(raw) ~= "table" then
		table.insert(result.warnings, "config.json is not an object")
		return result
	end
	local data = raw :: { [string]: any }

	if data.hosts ~= nil then
		if type(data.hosts) ~= "table" then
			table.insert(result.warnings, "hosts must be an object")
		else
			for key, value in data.hosts :: { [any]: any } do
				if type(key) == "string" and check.target(value) then
					result.config.hosts[key] = value :: string
				else
					table.insert(result.warnings, "ignored an invalid hosts entry")
				end
			end
		end
	end

	if data.allowed_ports ~= nil then
		if type(data.allowed_ports) ~= "table" then
			table.insert(result.warnings, "allowed_ports must be a list")
		else
			local ports: { number } = {}
			local bad = false
			for _, value in data.allowed_ports :: { any } do
				local port = check.port(value)
				if port == nil then
					bad = true
				else
					table.insert(ports, port)
				end
			end
			if bad then
				-- An invalid list must not silently widen access to every port.
				table.insert(result.warnings, "allowed_ports has an invalid port; every port is refused")
				ports = {}
			end
			result.config.allowed_ports = ports
		end
	end

	if data.control_dir ~= nil then
		if check.abs_path(data.control_dir) then
			result.config.control_dir = data.control_dir :: string
		else
			table.insert(result.warnings, "control_dir must be an absolute path")
		end
	end
	return result
end

return config
