--!optimize 2
-- Tide with its own default interest settings (see the "tide-defaults" profile in
-- adapters/tide/adapter.luau).
local ctx = ...
return ctx.import(`{ctx.benchRoot}/adapters/tide/adapter.luau`, ctx)
