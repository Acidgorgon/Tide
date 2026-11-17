# Tide design (v0.1, players + server entities)

Tide replicates moving things on Roblox: player characters, bots, NPCs (later: route walkers and the ball).
It replaces Chrono in Strike and engine physics replication for bots in FM. Family: Current (net),
Ripple (state), Anchor (saves), Tide (motion). Must be very easy to use. Not modelled on any other
author's library; own names and design.

Goals vs Strike's patched Chrono 2.2.0 (numbers in /tmp/claude-0/chrono reports):
- Bytes: 22 B per relayed player update -> about 10 B. Server-owned entity 16 B -> about 10 B.
- One timeline: the server keeps the exact samples clients draw, keyed by server time, so hit checks
  rewind against what players saw. Roblox's own character position stream is switched off (lock).
- Server relay CPU 3-5x lower: encode each sample once per frame, memcpy per receiver, no per-receiver
  table clones/closures, no per-sample table allocation (ring buffers of numbers).
- Client: allocation-free per frame, `--!native` on hot modules, positions applied once per frame
  (BulkMoveTo for anchored/rig roots where possible, else CFrame).
- Latency: same smart buffer idea as our Chrono patch (p95 of observed refill need), plus bounded
  extrapolation built in (replaces StallDraw/LookAhead basics).
- No ticker drift: server entity ticks use an accumulator, not `last = now`.
- Safety: never-throw receive; NaN/inf/speed checks; per-player byte and packet caps; stamps clamped.

## Time

All times are server time: clients use `workspace:GetServerTimeNow()`; the server uses the same call.
Client upload stamps are server-time f64. The server clamps each stamp to
`[arrival - Config.MaxBackdate, arrival + 0.005]` and requires it to increase per entity (drop otherwise).
Receivers render every entity on the one server timeline at `now - delay`, delay per source chosen by the
smart buffer (see Client).

## Entity model

- `kind`: a named config (`Tide.kind(name, opts)`). Built-ins: `Player` (client-owned characters),
  `Bot` (server-owned, 30 Hz), `Npc` (server-owned, 15 Hz). Opts: `rate` (Hz), `rotation` ("yaw" |
  "full"), `near`, `far`, `cull` (studs; `cull = math.huge` = never culled; players default never),
  `farEvery` (send every Nth sample beyond `near`), `buffer` (min seconds), `extrapolate` (max seconds),
  `apply` ("cframe" | "none" | function(model, cf)).
- Every entity gets a slot (u16 internally). Slot table replicated reliably: add/remove/owner change go
  through one reliable RemoteEvent as compact buffers (not Roblox tables).
- Owner: `nil` = server-owned (server samples the model each tick), or a Player (client samples and
  uploads; server validates and relays).

## Wire format

All little-endian via the `buffer` library. Position quantized to 1/64 stud relative to `Config.origin`
(default 0,0,0) within +-1024 studs per axis (17 bits each); outside that range a record uses the
absolute form. Yaw 10 bits (0.35 deg). Full rotation adds a 32-bit smallest-three quaternion (2 bits
index + 3x10 bits).

Packed core (64 bits = 8 B), written as two u32 (or with buffer.writebits if faster; benchmark both):
`x:17 | y:17 | z:17 | yaw:10 | flags:3` where flags = bit0 teleport, bit1 full-rotation follows,
bit2 absolute-position (then the core's xyz bits are zero and 3x f32 follow).

Relay packet (server -> client, UnreliableRemoteEvent "TideU"), at most 1000 B (config `MaxPacket` 900
default to stay safe):
```
u8  tag = 1 (entity frame)            | u8 flags (bit0 wide slots)
f64 frameTime (server time)
repeated records:
  slot  u8 (u16 if wide)
  dt    u8  = round((frameTime - sampleTime) / 0.0005), 0..254; 255 = extended: u16 in 0.5 ms units follows
  core  8 B (+4 B quaternion if flag) (+12 B abs pos if flag)
```
Typical record = 10 B (u8 slot + u8 dt + 8 B core). A player's several samples in one server frame are
several records (no delta in v0.1; intra-frame delta is a later option).

Upload (client -> server, UnreliableRemoteEvent "TideU"): `u8 tag=2 | u8 count | count x (slot u16, f64
stamp, core 8 B (+extras))`. Uploads may carry the last 2 samples redundantly (config `UploadRedundancy`,
default 1 = no redundancy) to survive drops; the server drops non-increasing stamps.

Reliable control (RemoteEvent "TideR"): buffers with tag: 10 add (slot, kind id, model ref via the
remote's instance argument array, owner userId), 11 remove, 12 owner change, 13 teleport ack, 14 config
hello (origin, kinds table). Instances travel as extra RemoteEvent arguments, never inside the buffer.

## Server

- Receive: per packet validate tag/length (never throw; bad packet -> counter + optional hook), owner
  check per slot, stamp clamp, monotonic stamp, NaN/inf, speed check (distance / dt > kind.maxSpeed
  (default 120 studs/s) and not teleport -> drop + hook `onSuspicious(player, reason)`), byte cap per
  player per second (default 8 KB/s) and per frame.
- History: per entity a fixed ring (default 1 s at 100 Hz = 128 entries) of (t, x, y, z, yaw[, quat])
  as numbers in typed arrays (buffers) or parallel number arrays; `Tide.at(entity|model, t)` returns an
  interpolated CFrame for hit checks; `Tide.latest(model)`.
- Lock (players): when `lockPlayers = true` (default), the server stops Roblox replicating the
  character's position: welds the HumanoidRootPart to an anchored locker part parented under the server
  Camera (not replicated) and moves the locker to the newest sample each frame. Option exists to keep
  native replication (`lockPlayers = false`) for a safe rollout. Must be verified in Studio.
- Server-owned ticking: accumulator per kind (`acc += dt; while acc >= 1/rate do ...`), sample model
  pivot, skip unchanged (fuzzy) but send a keep-alive every `keepAlive` (default 0.5 s) so receivers
  can tell idle from loss.
- Relay each frame (PostSimulation): one shared scratch buffer per frame with every new record encoded
  once; per entity remember its records' byte range. For each receiver: walk the entity list, decide
  include (self skip, cull radius, near/far + farEvery by distance from the receiver's last known root,
  hysteresis), memcpy ranges into the receiver's reusable out buffer, split at MaxPacket, FireClient.
  Distances recomputed every `interestEvery` (0.1 s) into a per-receiver per-entity tier byte array.
- Per-receiver byte budget per second (default 40 KB/s): when over, far records are dropped first.

## Client

- Upload own entities each Heartbeat at kind.rate with a steady schedule (`next += 1/rate`, catch-up
  capped) so a 144 fps client sends a steady rate.
- Receive: decode into per-entity ring buffers of numbers (no tables, no CFrames on receive).
- Smart buffer per source owner (per entity for client-owned, per kind for server-owned): on each packet
  record need = arrivalServerTime - newestSampleTime_before; delay = p95 of the last 128 needs + 2 ms,
  clamped to [kind.buffer, Config.MaxBuffer]; render clock eases toward it (no snaps under 100 ms).
- Render each frame (PreRender): for each visible entity, sample at `now - delay`: Hermite between the
  two bracketing samples with finite-difference tangents; past the newest sample extrapolate with the
  last velocity up to kind.extrapolate (default 0.1 s), then hold; corrections blend over 0.1 s.
  Teleport flag = snap. Apply: one CFrame per entity (collect anchored roots for one BulkMoveTo).
- API: `Tide.drawn(model) -> CFrame?`, `Tide.delay(model) -> number`, `Tide.velocity(model)`,
  signals `Tide.added(fn)`, `Tide.removed(fn)`.

## Public API (v0.1)

```lua
-- server
local Tide = require(ReplicatedStorage.Tide)
Tide.start({ players = true })          -- auto-adds characters as kind "Player", owned by their player
local bot = Tide.add(model, "Bot")      -- server-owned; returns a handle
bot:teleport(cf)                        -- snap for everyone
bot:remove()
Tide.at(player.Character, t)            -- server rewind: CFrame at server time t
Tide.kind("Ball", { rate = 60, rotation = "full" })

-- client
local Tide = require(ReplicatedStorage.Tide)
Tide.start()
Tide.drawn(otherCharacter)              -- where Tide draws it this frame
```

## Not in v0.1

Route entities (FM city crowd), ball channel (events + client sim), intra-frame deltas, priority
accumulator beyond tiers+budget, animation replication (Animator replication stays Roblox's).

## Benchmarks

Harness = Ripple/Current's Luau 0.700 host + Roblox mock (copied into bench/). Adapters: Tide and
Strike's patched Chrono 2.2.0 (source on disk, not vendored in the repo: pass its path). Scenarios:
players_10 / players_16 / players_22 (client-owned, 98 Hz send, sprint paths on a pitch, mix of near/far),
bots_22 (server-owned 30 Hz), npcs_150 (server-owned 15-20 Hz, walking). Metrics: server CPU per frame,
client CPU per frame (receive + render for one client), allocations, bytes per client per second
(payload + an estimated 12 B per remote call), and correctness (decoded positions within 1/64 stud,
yaw within 0.5 deg of what was sent).
