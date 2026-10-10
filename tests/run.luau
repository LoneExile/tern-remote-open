--!nocheck
-- Runs every test module, then reports. Exits non-zero on any failure.
local harness = require("./harness")

require("./test_check")
require("./test_text")
require("./test_url")
require("./test_hosts")
require("./test_target")
require("./test_config")
require("./test_argv")
require("./test_classify")
require("./test_registry")
require("./test_forward")
require("./test_serve")
require("./test_app")

harness.summary()
