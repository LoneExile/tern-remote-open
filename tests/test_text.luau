--!nocheck
local h = require("./harness")
local text = require("../lib/text")

h.group("text")

h.test("hash8 matches the FNV-1a 32 reference vectors", function()
	h.eq(text.hash8(""), "811c9dc5")
	h.eq(text.hash8("a"), "e40c292c")
	h.eq(text.hash8("foobar"), "bf9cf968")
end)

h.test("hash8 is stable and sensitive to every byte", function()
	h.eq(text.hash8("devbox\0/tmp/a.html"), text.hash8("devbox\0/tmp/a.html"))
	h.truthy(text.hash8("devbox\0/tmp/a.html") ~= text.hash8("devbox\0/tmp/b.html"))
	h.truthy(text.hash8("devbox\0/tmp/a.html") ~= text.hash8("other\0/tmp/a.html"))
	h.eq(#text.hash8("some long input with many bytes in it, well beyond a word"), 8)
end)

h.test("clean strips control characters, collapses space and truncates", function()
	h.eq(text.clean("  hi\r\n\tthere  ", 40), "hi there")
	h.eq(text.clean("\27[31mred\27[0m", 40), "[31mred [0m")
	h.eq(text.clean(string.rep("x", 50), 10), string.rep("x", 9) .. "…")
	h.eq(text.clean("", 10), "")
end)

h.test("first_line picks the first non-empty line, cleaned", function()
	h.eq(text.first_line("\n\nHost key verification failed.\nmore", 80), "Host key verification failed.")
	h.eq(text.first_line("", 80), "")
	h.eq(text.first_line("  \r\n \r\n", 80), "")
end)

h.test("safe_name keeps [A-Za-z0-9._-], hides leading dots, keeps the extension", function()
	h.eq(text.safe_name("report.html", 80), "report.html")
	h.eq(text.safe_name("my file (1).pdf", 80), "my_file__1_.pdf")
	h.eq(text.safe_name("../../etc/passwd", 80), "__.._etc_passwd")
	h.eq(text.safe_name(".hidden.png", 80), "_hidden.png")
	h.eq(text.safe_name("", 80), "file")
	h.eq(text.safe_name("é.png", 80), "__.png")
	local long = text.safe_name(string.rep("a", 200) .. ".html", 40)
	h.eq(#long, 40)
	h.eq(string.sub(long, -5), ".html")
	h.eq(text.safe_name("a\nb.png", 80), "a_b.png")
	h.falsy(string.find(text.safe_name("a/b\\c:d*e", 80), "[/\\:*]"))
end)

return {}
