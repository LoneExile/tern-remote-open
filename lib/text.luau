--!strict
-- Small text helpers for toasts and cache names.

local text = {}

-- Drops control characters and truncates, so remote-controlled text cannot
-- spoof a toast with escape sequences or flood it.
function text.clean(s: string, max: number): string
	local cleaned = string.gsub(s, "%c", " ")
	cleaned = string.gsub(cleaned, "%s+", " ")
	cleaned = string.gsub(cleaned, "^ ", "")
	cleaned = string.gsub(cleaned, " $", "")
	if #cleaned > max then
		return string.sub(cleaned, 1, max - 1) .. "…"
	end
	return cleaned
end

-- The first non-empty line of ssh/scp stderr, cleaned.
function text.first_line(stderr: string, max: number): string
	for line in string.gmatch(stderr, "[^\r\n]+") do
		local c = text.clean(line, max)
		if c ~= "" then
			return c
		end
	end
	return ""
end

-- FNV-1a, 32 bit, as 8 hex digits. The multiply by 16777619 (2^24 + 403) is
-- split so no intermediate leaves the range a double holds exactly.
function text.hash8(s: string): string
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		h = bit32.band(h * 403 + bit32.lshift(h, 24), 0xFFFFFFFF)
	end
	return string.format("%08x", h)
end

-- `name` reduced to `[A-Za-z0-9._-]`, at most `max` bytes, extension kept.
function text.safe_name(name: string, max: number): string
	local cleaned = string.gsub(name, "[^%w._-]", "_")
	cleaned = string.gsub(cleaned, "^%.+", "_")
	if cleaned == "" then
		cleaned = "file"
	end
	if #cleaned > max then
		local ext = string.match(cleaned, "(%.[%w]+)$") or ""
		if #ext > 12 then
			ext = ""
		end
		cleaned = string.sub(cleaned, 1, max - #ext) .. ext
	end
	return cleaned
end

return text
