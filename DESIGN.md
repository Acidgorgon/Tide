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

## Animations (v0.2)

Goal: animations play on the same timeline as the body. Today Roblox's Animator replicates tracks on its own
clock, so on other screens an action anim can start ~30-60 ms before Tide draws the body there. Tide's
animation channel carries play/stop/adjust events stamped with server time; each receiver applies them when its
render clock for that entity (`now - delay(entity)`) reaches the stamp, so anim and motion stay in step. Zero code
changes for games that already play anims on the character's Animator: Tide watches the Animator.

Switch: `Config.animations` = `false` (default in v0.2, Roblox replication as today) | `true`. Per kind opt-out:
kind opt `animations = false`.

### Who watches, who plays
- Source side ("watch"): the entity's owner. Client-owned (players): the owner client watches the Animator under
  the character's Humanoid (or AnimationController). Server-owned (bots/NPCs): the server watches the bot's Animator.
- Receiver side ("play"): every other client. For each animated Tide entity a receiver creates its OWN local
  Animator (client-created, so it never replicates) and destroys/ignores Roblox's replicated one locally, so
  Roblox-replicated tracks no longer show. Tide loads tracks on the local Animator (cached per entity per anim id).
- Owner client of a player: keeps playing on its Animator as before (sees its own anims instantly). To stop Roblox
  also sending those tracks (wasted bytes), the owner swaps in a client-created Animator under its Humanoid at
  character spawn (before game code loads tracks; Tide.start runs early). Flag `Config.animationsOwnerLocal`
  (default true). Must be verified in Studio: client-created Animator does not replicate; game code that waits for
  `Humanoid.Animator` finds the new one.
- Server for players: removes nothing (the server never needs to play player anims).

### Watching (shared module Shared/AnimWatch.luau)
- Hook `Animator.AnimationPlayed(track)`: assign anim id (registry below), emit PLAY with fade estimate, weight
  target, speed, time position, priority, looped.
- Each watch step (owner upload step / server tick, max 60 Hz), for every watched track diff: IsPlaying->false or
  WeightTarget->0 => STOP (fade estimate); Speed change => SPEED; WeightTarget change (>0.02) => WEIGHT; TimePosition
  jump vs expected (|actual - (last + dt*speed)| > 0.05 s, loop-aware via track.Length) => SEEK; Priority change =>
  sent inside next event (PLAY carries it; PRIORITY op otherwise).
- Fade estimate: AnimationTrack does not expose the fade time. Estimate from WeightCurrent change over the first
  observed step (fade ~= dt * WeightTarget / WeightCurrent), clamped [0, 1], fallback `Config.animationFade`
  (0.1). Explicit API gives exact fades (below).
- Allocation-light: per-track state in parallel arrays/tables reused; no per-step closures.

### Explicit API (exact, optional)
- `Tide.play(model, animation: Animation | string, fade?, weight?, speed?) -> AnimationTrack?` (owner side: plays
  on the entity's Animator and emits PLAY with exact fade; a string = name under `Config.animationFolder`).
- `Tide.stop(model, animation, fade?)`. Watch mode dedups: a track played via Tide.play is not re-emitted.

### Registry (anim ids)
- u16 ids for AnimationId strings. Pre-seeded from `Config.animationFolder` (an Instance, e.g.
  ReplicatedStorage.Assets.Animations; descendants sorted by full name) on both sides, no bytes needed.
- Unknown AnimationId seen by a watcher: client sends REGISTER (string) once on TideR; server assigns the next id
  (cap `Config.MaxAnimIds` 1024 total, 64 new per player per minute, string length <= 100, must look like
  "rbxassetid://<digits>" or "http..." asset URL) and broadcasts ANIMID (id, string) reliably; the client holds its
  events for that track until the id arrives (or the server includes the string inline once). Late joiners get the
  table in HELLO (or a following ANIMIDS message).

### Wire (reliable TideR, new tags; protocol version 3)
Anim events go reliable+ordered (they are rare, a few per second per entity, and must not be lost).
- client -> server 20 ANIM: f64 baseTime, u8 count, count x event
- server -> client 21 ANIM: f64 baseTime, u16 count, count x event (batched per receiver per frame, flushed with
  the frame)
- 22 REGISTER (c->s): u8 len, string;  23 ANIMID (s->c): u16 id, u8 len, string
- 24 ANIMSNAP (s->c): u16 slot, u8 count, count x PLAY-shaped state (sent when a receiver starts receiving an
  entity: ADD, entering cull range, late join), so receivers converge.
- event: u16 slot (on c->s also u16; server checks ownership), u16 dt (0.5 ms units relative to baseTime, signed
  i16 so events can precede baseTime), u8 op, u16 animId, then by op:
  - PLAY(1): u8 fade (10 ms), u8 weight (1/100, 0..2.55), i16 speed (1/256, -128..128), u16 timePos (ms, 0..65.5 s),
    u8 priority (Enum index), u8 flags (bit0 looped)
  - STOP(2): u8 fade
  - SPEED(3): i16 speed
  - WEIGHT(4): u8 weight, u8 fade
  - SEEK(5): u16 timePos
  - PRIORITY(6): u8 priority
- Server validates: owner check, op range, id known, stamp clamp like samples (MaxBackdate) and monotonic per
  entity (equal allowed), per-player cap `Config.AnimEventsPerSecond` (default 60, burst 30) -> drop + onSuspicious.

### Server state
- Per entity: current playing set (animId -> {t0, timePos0, speed, weight, fade, priority, looped}), updated by
  events, entries removed on STOP (after fade) and capped at 16 per entity (oldest dropped). Used for ANIMSNAP and
  for `Tide.playing(model) -> {name/id -> info}` (server-side queries, e.g. "is the tackler in the slide anim at t").
- Relay: each event goes to every receiver that currently receives the entity (not culled; tiers do not thin anim
  events), except the owner.

### Receiver playback (Client/AnimPlay.luau)
- Queue per entity (ring of events, cap 64). Each render step, for each entity with queued events, apply all with
  time <= renderTime(entity) = now - delay(entity). Apply = PLAY: load/cached track on the local Animator, set
  Priority, Looped as sent, track:Play(fade, weight, speed), then TimePosition = timePos + (renderTime - eventTime)
  * speed (catch-up, loop-wrapped). STOP: track:Stop(fade). SPEED: AdjustSpeed. WEIGHT: AdjustWeight(w, fade). SEEK:
  TimePosition = timePos + lag*speed.
- ANIMSNAP: stop all local tracks of that entity not in the snapshot, play the rest with fade 0 at the caught-up
  time position.
- Entity removed / Animator gone: stop and destroy tracks. Streaming: model missing -> keep queue (capped), apply
  snapshot state when it arrives.
- Bounded work: at most `Config.AnimApplyPerFrame` (default 64) events per frame overall.
- API: `Tide.playing(model)` (client: what Tide is playing for that entity), signal
  `Tide.animated(fn(model, op, name, info))` for gameplay hooks (e.g. VFX on a receiver exactly when the kick anim
  starts).

### Tests (mock)
Mock gets Animator / Animation / AnimationTrack (Play/Stop/AdjustSpeed/AdjustWeight, IsPlaying, Speed, WeightTarget,
WeightCurrent ramping by fade, TimePosition advancing with dt*speed, Looped, Length, Priority, AnimationPlayed
signal, Stopped). Tests: owner play -> receivers play at the right render time (not before body), stop/speed/seek
propagate, fade estimate within 0.03 s, snapshot for a late joiner and for an entity entering range, registry for
unknown ids + caps, bots watched on the server, ownership checks, rate caps, allocation check of the watch step and
apply step with no events (zero allocs).

## Timeline state (v0.3)

Goal: gameplay state that travels as Roblox attributes today ("until"/"at" windows, ball owner, slide
and tackle statuses) lands on the same timeline as the body. Design from the research note
(fsf-match/tide/research/timeline-state.md); Strike is the first user.

- Schema per kind, declared once in shared code: `Tide.state(kind, { Field = { type, default, to, apply,
  mirror, mirrorOn, mirrorNil, values, payload, history } })`. Types: bool, u8, u16, i16, f32, f64, time
  (absolute server time; wire i16 0.5 ms relative to the change's stamp, f64 escape), ref (another
  entity; u16 slot), enum (u8), event (pulse, optional payload), yaw (u16 flat direction), pos (3 x f32).
  `to` = all | owner | others | server; `apply` = drawn | arrival. Fields sorted by name -> ids (max 127).
  The server sends its schemas (32 SCHEMA) to clients, so clients decode exactly what the server encodes;
  a differing client declaration is warned about (checksum). No declaration: nothing changes (v0.2 bytes
  apart from the version byte, 4).
- Server-authoritative: `Tide.set(target, field, value, stamp?)`, `Tide.fire(target, event, payload?,
  stamp?)`. Stamp = now or given, clamped to [now - MaxBackdate, now], on the 0.5 ms grid; stamps need
  not be ordered (an older one only enters history). Values stored as clients decode them. Same-value
  sets skipped. Clients sending state tags are counted and dropped.
- History: per entity per field a sorted ring (`Config.StateHistory` = 32, field `history`), evicted
  values become the base; `Tide.stateAt(target, field, t)`, `Tide.changedAt(target, field, t0, t1)`.
  Refs to an entity that goes are set to nil and read nil in history. Allocation-free steady state.
- Wire: reliable TideR, merged with the frame's ANIM events into one message per receiver per frame.
  30 STATE = f64 base, u16 groups x (u16 slot, i16 dt, u8 n, n x (u8 field [bit7 default], value)).
  Groups (entity, stamp, audience) are encoded once per frame and memcpy'd per receiver (skips culled
  receivers and `to`).
- Snapshots (31 STATESNAP) when a receiver starts getting an entity (READY, back in cull range, owner
  change for owner/others fields): the changes it missed (tracked by flush number per receiver and
  audience class (all / owner / others), so no duplicates across cull and owner changes) after t0 = now -
  `Config.StateReplay` one by one, plus each field's value at t0 when older missed changes exist. The
  receiver applies them on its own clock, landing on the same timeline. An owner is never culled from
  its own entity's state.
- Client: per entity a queue in stamp order (64), applied in PreRender after Render and AnimPlay when
  the entity's clock reaches the stamp: remote entities `now - delay` (same as body and animations),
  `Tide.clock(model, fn(now))` for entities game code draws, `now - kind.buffer` for state-only ones
  without a clock; own entities, `apply = "arrival"` and owner-only fields on arrival. Clock monotonic per
  entity; changes older than the applied one are stale (events always fire). `Tide.get` (as drawn),
  `Tide.peek` (newest received), `Tide.timeOf(model)` (compare "until" times against it),
  `Tide.changed(model, field, fn)`, `Tide.stateChanged(fn)`. Never-throw receive (counted).
- Mirror mode: `mirror = "AttrName"`: the client sets the attribute locally when a change applies (refs
  as the model's Name, `mirrorNil` for nil, events as their time, `mirrorOn = "player"`), so existing
  attribute reads keep working at the drawn time. The server must stop writing that attribute.
- State-only kinds (`motion = false`): no sampling, relay, upload, lock, drawing or anchoring; never
  culled; state and history only. For the ball until the ball channel exists.
- Not done (proposal 3.8 and later): owner-local `Tide.predict`, a latest-value field mode on the
  unreliable stream, a ball channel.
