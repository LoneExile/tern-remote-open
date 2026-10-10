--!strict
-- Remote Open: open files, localhost links and OAuth loopback sign-ins from
-- remote panes. All logic lives in lib/; this file only wires it to Tern.
local app = require("./lib/app")

app.install(tern)
