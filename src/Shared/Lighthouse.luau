--!strict
-- Optional Lighthouse hooks (https://acidgorgon.github.io/Lighthouse/).
-- Lighthouse sets shared.Lighthouse when it is required. Tide reads it once per
-- frame per side (frame()); send and receive points test the cached `api` field,
-- so without Lighthouse the cost is that one lookup per frame and an `if` per
-- packet. Channels: "Relay", "Upload", "Control", "Anim" (out only; incoming
-- animation messages share TideR and count as "Control") (lh.net, one call per packet,
-- with the player on the server). Probes: see the names below.

local Lighthouse = {}

Lighthouse.api = nil :: any -- shared.Lighthouse as of the last frame(), or nil

-- probes, set while `api` is set
Lighthouse.sample = nil :: any -- server: Ticker, teleports, lock ("Tide.Sample")
Lighthouse.relay = nil :: any -- server: control broadcast + relay ("Tide.Relay")
Lighthouse.receive = nil :: any -- both: one incoming upload / relay packet ("Tide.Receive")
Lighthouse.upload = nil :: any -- client: sample and send own entities ("Tide.Upload")
Lighthouse.render = nil :: any -- client: draw remote entities ("Tide.Render")

local cached: any = nil
local usable: any = nil -- cached, or nil if its probe() failed

-- Once per frame per side. Probes are fetched again only when shared.Lighthouse
-- changes identity.
function Lighthouse.frame(): any
	local s: any = shared
	local api = if s ~= nil then s.Lighthouse else nil
	if api ~= cached then
		cached = api
		usable = nil
		if api ~= nil then
			local ok = pcall(function()
				Lighthouse.sample = api.probe("Tide.Sample")
				Lighthouse.relay = api.probe("Tide.Relay")
				Lighthouse.receive = api.probe("Tide.Receive")
				Lighthouse.upload = api.probe("Tide.Upload")
				Lighthouse.render = api.probe("Tide.Render")
			end)
			if ok then
				usable = api
			end
		end
	end
	Lighthouse.api = usable
	return usable
end

return Lighthouse
