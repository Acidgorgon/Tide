# Tide

**Docs: https://acidgorgon.github.io/Tide/**

Replication for things that move on Roblox: player characters, bots and NPCs. Clients upload their own
character, the server samples what it owns, checks everything, and relays each sample to the players
who should see it as a 10-byte record. Every sample is stamped in server time, and the server keeps
exactly what clients draw, so a hit check can ask "where was this character when the shooter saw it?"

> [!NOTE]
> **Made with Claude.** Most of Tide was written with [Claude](https://claude.ai), Anthropic's AI, to speed up my own Roblox workflow. Issues and pull requests are welcome.

```lua
-- server
local Tide = require(ReplicatedStorage.Tide)

Tide.start({ players = true })        -- every character is replicated by Tide
local bot = Tide.add(workspace.Bot)   -- server-owned, kind "Bot" (30 Hz)
bot:teleport(CFrame.new(0, 5, 0))     -- snaps for everyone

local cf = Tide.at(victim.Character, seenAt) -- rewind: where clients drew it at server time seenAt
```

```lua
-- client
local Tide = require(ReplicatedStorage.Tide)

Tide.start()
local seenAt = workspace:GetServerTimeNow() - Tide.delay(target) -- send this with the shot
```

It is part of a family: **Current** (networking), **Ripple** (state sync), **Anchor** (saving) and
**Tide** (motion).

## Why

- **10 B per player update instead of 22 B.** A position at 1/64 stud and a heading pack into 8 bytes;
  a slot and a sample age make the record 10. Each sample is encoded once per frame and copied into
  every receiver's packet, near players get every sample, far ones fewer, and each player has a byte budget.
- **One server timeline.** Clients stamp uploads with `workspace:GetServerTimeNow()` and the server
  keeps the samples quantized exactly as clients decode them. `Tide.at(model, t)` rewinds against what
  players saw, with no clock conversion. Roblox's own position stream for characters is switched off
  (the lock), so there is only one.
- **Zero allocations in steady state.** Samples live in ring buffers of numbers, not tables; packets
  are built with `buffer.copy` into reused buffers, and hot modules run `--!native`. Server relay,
  server receive and client receive/upload allocate nothing per frame; drawing allocates only the one
  `CFrame` per entity that Roblox needs (checked in `tests/test_alloc.luau`).
- **Checked, never thrown.** Ownership, NaN, stamps, speed and per-player byte caps are checked on
  every upload. Bad input is counted and dropped, and `Tide.onSuspicious` tells you who sent it.

Benchmarks against Chrono 2.2.0 are in [bench/](bench/) (results on the
[docs site](https://acidgorgon.github.io/Tide/benchmarks)).

## Install

Copy `src/` into `ReplicatedStorage` as a ModuleScript named `Tide` (with Rojo:
`"Tide": { "$path": "path/to/Tide/src" }`). Then call `Tide.start()` on the server and on the client.
See [Getting started](https://acidgorgon.github.io/Tide/guide/getting-started).

## API at a glance

```lua
-- both
Tide.start(opts?)                 -- server: { players = true, ...Config fields }
Tide.kind(name, opts)             -- rate, rotation, near, far, cull, farEvery, buffer, extrapolate, ...
Tide.added(fn) / Tide.removed(fn)
Tide.at(model, t) / Tide.latest(model)   -- velocity kinds: also velocity and spin (latest: and its stamp)
Tide.owner(model) / Tide.isMine(model)
Tide.stats() / Tide.Config

-- server
local handle = Tide.add(model, kind?, owner?)  -- kind defaults to "Bot"
handle:teleport(cf) / handle:setOwner(player?) / handle:remove() / handle:alive()
handle:markTeleport(target?)      -- snap a jump you made yourself
Tide.bump(model) -> stamp         -- sample now, out of tick (after a kick); handle:bump()
handle:setAudience(fn | { Player } | nil) / Tide.focus(player, part | Vector3 | nil)
handle:setOrigin(origin?)         -- far venues keep the 10-byte record
handle:link(name, key)            -- rewind and intents from other VMs (Actors)
Tide.handle(model) / Tide.remove(model)
Tide.onSuspicious(function(player, reason) end)

-- client
Tide.drawn(model) / Tide.delay(model) / Tide.velocity(model)
Tide.at(model, t, extrapolate?)   -- the buffered path at any server time, e.g. Tide.timeOf(body)

-- a physics body the server simulates (a ball, a projectile), v0.5
Tide.kind("Ball", { velocity = true, rotation = "full", apply = "none", lock = true })

-- another VM of the server (an Actor)
local venue = require(ReplicatedStorage.Tide.Shared.Link).open("Venue1")
venue:at(key, t) / venue:latest(key) / venue:setOwner(key, userId?) / venue:teleport(key, cf) / venue:bump(key)
```

v0.4 additions are opt-in: a game that doesn't call them behaves and sends the same bytes as v0.3.
v0.4.1 fixes models that never bound for a player coming into an entity's audience, or with more than
64 models missing (StreamingEnabled). v0.4.2: a client's `Tide.removed` no longer fires with a `nil` model for an
entity whose model never bound or had already streamed out.

v0.5 adds physics bodies ([Balls and projectiles](https://acidgorgon.github.io/Tide/guide/physics-bodies)):
kinds with `velocity = true` send each sample's linear velocity and spin (28 B for a ball in flight
with full rotation, 16 B at rest), `Tide.bump` samples at once after a kick, `Tide.at` and `Tide.latest`
return velocity and spin on both sides, `apply = "none"` can be declared on the server, and `lock = true`
stops Roblox replicating a server-owned body (check in Studio first). Timeline state gets `"vector"` and
`"cframe"` values and event payloads with named members. All of it is opt-in: a game that uses none of
it sends the same bytes as v0.4.2.

Full reference: [API](https://acidgorgon.github.io/Tide/reference/api),
[Config](https://acidgorgon.github.io/Tide/reference/config),
[Wire format](https://acidgorgon.github.io/Tide/reference/wire-format).

## Tests

```sh
sh bench/fetch_luau.sh                         # Luau 0.700 sources (gitignored)
LUAU_HOST_SRC=bench/host tests/run.sh          # builds the host with CMake, runs interpreted and native
```

## Layout

- `src/` the library: `init.luau`, `Shared/` (codec, kinds, interpolation), `Server/`, `Client/`
- `tests/` correctness, allocation and end-to-end tests on a Roblox mock (`tests/run.sh`)
- `bench/` benchmark harness (Luau 0.700 host + Roblox mock) with Tide and Chrono adapters
- `docs/` the documentation site (VitePress)

## License

MIT. See [LICENSE](LICENSE).
