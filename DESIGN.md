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
  unreliable stream. (The ball channel came in v0.5, below, with the reasons the other two are still
  not built.)

## Venues, owner changes, other VMs (v0.4)

Goal: one server running several matches or venues (FM: a stadium per match, spectators without a
character, venue code in Actors). Seven additive changes; every one is opt-in, and a v0.3 game sends the
same bytes (HELLO flags stay 0, protocol version stays 4, tags 17 and 18 only when used).

- Interest without a character: `Tide.focus(player, BasePart | Model | Vector3 | nil)` is the receiver's
  position when it has no `"Player"` entity (a character still wins; a part that goes away keeps its last
  position). Per-entity audiences: `handle:setAudience(fn(player) -> boolean | { Player } | nil)`.
  Receivers outside it get tier 4 (culled: no samples, animations or state, and RESEND is not answered);
  a function is asked every `Config.InterestEvery` and cached per receiver (errors count and mean no).
  Coming back in starts like a cull exit (state snapshot, no hysteresis). Measured on the mock (4 matches
  x 22 bodies, 8 viewers per match): 70.9 KB/s per player to 17.8 KB/s.
- Server-owned jumps made without `handle:teleport` (a `PivotTo` from game code, another VM): kind option
  `teleportDistance` (default `math.huge`) flags a sample farther than that from the previous one, and
  `handle:markTeleport(target?)` flags the next sample (no target: sampled now) or the first one within
  `Config.TeleportGrantRadius` of a CFrame / Vector3 target in the next second. Counted in
  `teleportFlagged`.
- Other VMs (`Shared/Link`, `handle:link(name, key)`): the Tide VM copies each linked entity's new history
  samples into the SharedTable `"Tide:<name>"` at the end of its frame (one packed string per sample, then
  `last`; history is append-only on the server). A reader in any VM copies them once into its own Ring and
  runs the same Interp: `venue:at(key, t)` is `Tide.at` (up to a frame behind). Intents (`setOwner`,
  `teleport`, `markTeleport`) go into a queue (`SharedTable.increment` hands out an index) that the Tide
  VM drains at the start of its next frame, in order, for keys linked then (`linkUnknown`, `linkBad`).
  No reply, never synchronous. SharedTable semantics (atomic increment, visibility between parallel and
  serial phases) are from the documentation and need a Studio check.
- Owner changes: `Config.ownerEase` makes a receiver keep its render clock for the entity across an
  owner change (the new source starts at the old delay and eases to its own at 0.75x..1.1x of real
  time), and the old owner blends from its own pose. `Config.ownerStart` = `"drawn"` (v0.3: where Tide
  drew the copy) | `"latest"` (the newest received sample, carried to now) | `"server"` (17 OWNERPOSE,
  the server's live pose for a server-owned entity or its newest sample, sent with the OWNER). Measured on
  the mock (body at 20 studs/s, owner flipping server <-> client 1 every 0.75 s, client 2 watching,
  buffer 0.12, worst one-frame step error on client 2; one frame's own step is 0.33):
  30 / 60 / 100 ms one-way: v0.3 1.00 / 2.32 / 4.72 studs, `ownerEase` 0.19 / 0.24 / 0.33.
  The server's history stepped back at each grant by 1.41 / 0.75 / 0.38 studs with `"drawn"` and by 0
  with `"latest"` and `"server"`.
- Per-entity origin: `handle:setOrigin(origin?)` (snapped to `Config.origin`'s 1/64 grid; 18 ORIGIN after
  the ADD and to late joiners). Records and the server's history quantize around it, so venues far from
  `Config.origin` keep the compact record (measured: 14 B with full rotation vs 26 B in the absolute
  form). A change after the entity's first frame sends absolute records for a second so a client never
  decodes a record against the wrong origin. Uploads keep the global origin; the server re-quantizes
  them.
- Streamed-out models: with `Config.rebindStreamed` a client treats a model whose Parent became nil as
  missing (dropped, `removed` fires, RESEND asks for it); the re-streamed instance is bound to the same
  entity and keeps its ring and delay (`modelsLost`, `modelsRebound`). A model the game parents back
  itself is bound again locally. RESEND replies are now rate limited on server time.
- `Tide.owner(model)`, `Tide.isMine(model)`, `handle:owner()`: on the server "mine" is a registered
  server-owned entity; on a client, an entity this client owns and uploads.

### v0.4.1: missing models behind audiences

Found wiring FM onto audiences. Every ADD goes to every player, and a client asked again (RESEND) only
for the FIRST 64 entities without a model, always in the same order, while the server does not answer
for entities outside the receiver's audience. A hub player holds model-less entries for every watched
venue's bodies (22 each); cutting to a venue registered after 64 or more of those, it never asked for
its bodies and drew none, forever (FM mock: 0 / 22 with 3 or 4 other venues watched). Two fixes, no
wire change (protocol 4, no new tag):

- Server: when a receiver comes back into an entity's audience (`Relay.onAudienceEnter`), the entity's
  ADD (and ORIGIN) goes to it again after the frame's broadcast (`audienceAdds`). A model already
  streamed in is bound at once, without waiting for a RESEND.
- Client: with more than 64 models missing, each RESEND takes the next 64 (a cursor over the missing
  ones, wrapping around), so every missing model is asked for within `ceil(missing / 64)` asks. Up to
  64 missing, the RESEND is byte for byte v0.4.0's (all of them, in list order).
- Client: an ADD for an entity it already has, same kind and owner but without the model (not streamed
  in for it), keeps the model it has instead of re-adding the entity. Only the new ADD can do that.

Not done: leaving out the ADD for receivers outside the audience. Clients would then add and remove
entities as audiences change (`Tide.added` / `removed` churn, `Tide.owner` and state `ref` fields
unknown outside), and an audience is set after `Tide.add` has queued the ADD. A "not for you" reply was
not needed either: the moving window bounds the cost of unanswered asks to 130 B per `ModelRetry`.
The server sends the same bytes as v0.4.0 for entities without an audience, and the client's RESEND
only differs with more than 64 models missing (where v0.4.0 starved). Tests: `tests/test_resend.luau`
(5 venues x 22 bodies, a hub viewer cutting to the newest: 0 / 22 on v0.4.0, 22 / 22 within 0.5 s).

## Physics bodies, richer state (v0.5)

Goal: the ball. Strike's server simulates it and sent its own snapshot remote (56 B per ball sample:
position, velocity, spin, time) next to a state-only Tide entity; clients predict and draw it
themselves. v0.5 puts the ball's motion on Tide's stream and timeline with what a predictor needs,
and lets one event carry a kick. Everything is opt-in and protocol 4 stays: velocity records, HELLO
kind bits 3 and 4, state types 13 and 14 and SCHEMA member lists appear only for kinds that use them.
`tests/test_golden.luau` replays a recorded v0.4.2 session (players, bots, full rotation, origins,
audiences, animations, state; 2229 remote calls, 88292 B) and compares every byte.

### Velocity kinds

- Kind option `velocity = true` (server-owned entities only: an owner at `Tide.add` or
  `handle:setOwner` is an error, uploads carry no velocity; not with `motion = false`). The entity's
  rings (server history, client buffer, link readers) get six more number arrays: vx, vy, vz, wx, wy,
  wz. The ticker reads `AssemblyLinearVelocity` / `AssemblyAngularVelocity` of the root with the pose,
  on the kind's tick, and stores them **quantized as receivers decode them** (1/32 stud/s, 1/64
  rad/s), like positions. A pose that stands still with a new velocity is a new sample (a kick before
  physics moved the body); a body at rest sends the stop sample and keep-alives only.
- Record: `slot 0 | hdr | slot | dt | sample | [velocity] | [spin]`. Slot 0 is never an entity (slots
  start at 1), so it is the escape that keeps every other record byte for byte as it was. `hdr`: bit 0
  VEL, bit 1 SPIN (a vector that quantizes to zero is left out), bit 2 / 3 the wide form (3 x f32 when
  a component leaves the i16 range; non-finite as 0), bit 4 CUT, bits 5-7 zero. The record states its
  own length, so a client skips one for a slot it does not know yet (ADD is reliable, samples are
  not). Reserved bits, a second slot 0 and truncation stop the packet (`badPacket`), never throw.
  Sizes with a u8 slot and u8 dt: 28 B in flight with full rotation and spin, 24 B yaw only, 22 B with
  one vector, 16 B / 12 B at rest. The game's own snapshot was 56 B.
- Encoded once per frame into the relay scratch and memcpy'd per receiver like any record
  (`Codec.writeMotion` 63 ns, `readMotion` 65 ns native, next to 35 / 48 ns for the core sample).
  Mid and far tiers thin as before; cuts pass the thinning like teleports. The byte budget can still
  drop a mid or far record, a cut included: a ball everyone watches wants `near = math.huge`, and
  `farEvery = 1` plus a `Tide.focus` for receivers without a character (no position: always "far").
- Interpolation (`Shared/Interp`, the same on both sides and in link readers). For a velocity ring the
  Hermite tangents are the samples' velocities when they explain the segment
  (`|(v0 + v1) / 2 * h - d| <= 0.06 + 0.125 |d|` studs), which is exact for constant acceleration
  between samples. When they do not (a bounce nobody flagged, a lost cut, a body moved by CFrame), the
  segment falls back to tangents from positions, so a bad pair of velocities can never fling the path
  out of its segment. A segment that ends in a CUT arrives with constant acceleration from its start
  velocity (`m0 = v0 h, m1 = 2d - m0`, or a straight line when v0 does not explain d); the cut
  sample's new velocity only shapes what follows. Past the newest sample: a straight line at that
  sample's velocity for the caller's bound (no speed clamp: the values are the server's). Tide does
  not integrate gravity or drag; a predictor starts from `Tide.latest`.
- The velocity `Tide.at` returns is blended between the two samples' own velocities where they
  explain the segment (free of position quantization), else the path's slope. The slope at the end of
  a cut segment carries the positions' grid: up to (1/32 stud) / h per axis (0.94 studs/s at 30 Hz).
  A cut less than 12.5 ms behind a sample (a bump in the frame the entity was sampled in) holds the
  start velocity instead: below that length gravity over the segment is smaller than the slope's noise.
  Spin is blended between samples and held up to a cut.
- Measured on the mock (`tests/test_velocity.luau`): ball in flight at 30 Hz, 30 ms +- 4 ms one-way,
  read at the drawn time: within 0.0131 studs and 0.086 studs/s of the true trajectory. Bounces and
  kicks with nothing bumped: at most 0.31 studs from the truth, 0.95 studs with 30 % loss.

### Tide.bump

`Tide.bump(model)` / `handle:bump()` samples a server-owned entity out of tick and returns the
sample's server time (the stamp for the `Tide.fire` of the same moment). For velocity rings the
sample carries CUT. The server's frame has two regimes, told apart by a `PreSimulation` connection
that sets `State.inSim` (cleared after the ticker ran in Tide's `PostSimulation` step):

- Outside (remote handlers, `Heartbeat`, resumed threads): the poses that stand are the ones the last
  frame ended on, so the sample is taken at once and stamped with that frame's time, or 1 ms (two
  ticks of the wire's grid) after the entity's newest sample or held tick when that is later. Stamps
  stay strictly increasing per entity, so history stays append-only (links rely on it) and receivers
  never see two samples at one time.
- Inside (between `PreSimulation` and Tide's step): physics is about to move the body, so sampling now
  would record a pose a frame old with a velocity physics has not applied. The entity is marked and
  sampled at this frame's step whatever the kind's tick (one sample per frame at most); the call
  returns its own time.
- A bump with nothing changed samples nothing (and leaves the idle bookkeeping to the ticks). Bumps
  after Tide's step leave with the next frame's packet, or at once with `Tide.flush` (below). `Relay` takes `max(now, newest stamp)` as the
  packet's base time, so a stamp a few ms ahead (many bumps in one frame) still encodes a
  non-negative age; `Tide.set` / `fire` accept stamps up to 2 ms ahead without counting a clamp.
- Kinds without `velocity` get a plain out-of-tick sample.

### Drawing it yourself

- `apply = "none"` in the server's declaration travels in the kind's HELLO flags (bit 4). A client
  whose kind still has the default apply takes it (and gives it back when the server changes its
  mind: roots are anchored again); a client's own `apply` wins. Tide then neither moves nor anchors
  the model, and keeps buffering, the kind's delay and `Tide.drawn`.
- Client `Tide.at(model, t, extrapolate?)` reads the buffered path at any server time, with velocity
  and spin for velocity kinds; `Tide.latest(model)` returns the newest sample with velocity, spin and
  its stamp (plain kinds: the CFrame alone, as before). The server's `Tide.at` / `Tide.latest` return
  the same shapes from history, and `venue:at` / `venue:latest` / `venue:bump` through links (a
  velocity sample is a 121 B packed string).
- Client kind option `onSample(model, t, cframe, velocity, spin, cut)`: called inside the receive for
  each accepted sample (arrival order; pcall, `applyErrors`), for renderers that keep their own
  buffer. It allocates its arguments; kinds without it allocate nothing.
- Clocks. `Tide.timeOf(model)` on a client is, in order: now for an own entity; the function given
  to `Tide.clock`; `now - kind.buffer` for a state-only entity; `now - delay` of the stream the
  entity is buffered with (per entity for client-owned ones, per kind for server-owned ones).
  Monotonic per entity. `Tide.clock` now also applies to motion entities: it moves when the entity's
  state applies and what `timeOf` answers, and nothing else. A ball next to a body is
  `Tide.at(ball, Tide.timeOf(body))`.

### Server-owned bodies and Roblox's replication

Kind option `lock = true`: each entity gets a near-massless part (`TideLocker`, RootPriority 126)
welded to its root inside a `Camera` (`TideLock`) parented to the root. Cameras created by the server
and their descendants do not replicate, the locker wins the assembly root, and clients have no root
to replicate the motion against; the root's network owner is set to the server. Unlike the player
lock nothing is moved: physics simulates the body as before. This cannot be tested on the mock
(which only checks the instances, the weld and the cleanup); the nine checks are listed in
`Server/Lock.luau` and in the guide. Default off. Without it the documented pattern is the old one:
Roblox replicates the part, Tide anchors and draws over it (`apply = "cframe"`), or game code hides
the replicated part locally and draws its own.

### State: vectors, CFrames, payloads with members

- `"vector"` is an alias of `"pos"` (code 12, the canonical name stays "pos", so checksums and bytes
  are unchanged). `"cframe"` (code 13): 3 x f32 and the 4 B smallest-three quaternion of the sample
  codec, 16 B, stored as decoded.
- An event's `payload` may be a table of 1 to 32 named members (code 14, payload only; any value type
  and `time`; enum members carry their values). Sorted by name. Wire: presence bits (u8 / u16 / u32 by
  member count), then the present members' values; a member left out is its type's default and costs
  nothing. A kick with position, velocity and kicker is a 33 B group. SCHEMA carries the member list,
  so a client that declared nothing decodes it; the checksum covers members.
- The server stores a frozen table (refs as models, times on the fire's grid). Clients hand out a
  frozen table; ref members resolve to local models at read time and read nil once the entity is gone
  (queued and applied values are scrubbed on removal, so a reused slot never resurrects a ref).
- Malformed member payloads and schemas are counted (`stateBad`), never thrown.

### Lighthouse

`Lighthouse.count` (when the profiler has it): `Tide.Velocity.samples` (server: encoded; client:
received), `Tide.Velocity.bytes` (server: bytes of velocity records sent, part of the `Relay`
channel's total), `Tide.Bump`. The same numbers are in `Tide.stats()` (`velocitySamples`,
`velocityBytes`, `bumps`, `bumpsDeferred`, `serverLocks`; client `velocityRecords`).

### Allocation

`tests/test_alloc.luau`: a velocity kind's server tick, bump, relay, the client's receive and
`Interp.sample` allocate nothing per frame. The public reads (`Tide.at`, `Tide.latest`, `onSample`)
allocate the CFrame and Vector3s they return.

### Stops, late bumps, early focus, Tide.span (v0.5, after the first game used it)

Strike moved its ball to a velocity kind and measured three weaknesses and one gap. Still v0.5.0:
the version has not been released, so these are part of it, not a 0.5.1.

**Stop repeats (kind option `restRepeats`, whole number 0 to 8).** The stop sample was said once.
Receivers of a velocity kind carry a body on at its last velocity, so a lost stop ran on until the
keep-alive (measured by the game: 4.0 studs at 60 ms, 5.2 at 200 ms, 10 % loss), and the game had
shortened the keep-alive to 0.1 s to bound it (241 B/s for a resting ball instead of 28).

- What is repeated: on each of the next n ticks that find the entity unchanged (`Ticker` counts them
  down in `State.restLeft` and flags the slot), `Relay` encodes the entity's last three samples again.
  Three, not one: the stop sample says where the body stands, but when it got there, and whether it
  got there by a teleport or a cut, is in the sample before it; and for a body bumped while it rested
  (a placement), the rest marker before that says it stood at the old place until then. With only the
  stop sample repeated, a lost arrival sample left the path bending into the stop a tick late (0.27
  studs worst in 1000 stops at 10 % loss; 0.11 with three), and a lost cut never reached `onSample`
  as a cut.
- Same sample, same time. A copy has to decode to the time its first copy decoded to, from another
  packet with another base time. `round((frameTime - t) / tick)` does not promise that: at server
  times around 1.7e9 a double resolves 2.4e-7 s, and an age that ends near half a tick rounds either
  way from one frame to the next. So kinds with repeats count ages between whole ticks,
  `round(frameTime / tick) - round(t / tick)`, a function of the sample alone; the other kinds keep
  the old expression, and with it the bytes of v0.4.2 (`tests/test_golden.luau`). Changing a kind's
  `restRepeats` between 0 and more at run time can, for the samples in flight at that moment, make a
  copy land one tick from its original: a twin sample at the same pose, harmless and rare.
- Receivers: `Client/Receive` drops a record within a quarter tick of a sample it holds before
  anything looks at it (counter `repeats`): no `onSample`, nothing stored, no buffer need. Exact
  duplicates used to be refused by the ring and counted `late`; they count `repeats` now. A copy of a
  sample the client lacks is stored in its place in time, like any sample that arrives out of
  order (and refused, as those are, when it is older than everything the client holds).
- Audience and budget: a repeat goes to every receiver in tiers 1 to 3, never to culled ones or ones
  outside the audience. It is not thinned and not held back by the byte budget, and is charged to it.
  Held back, a receiver over budget would lose exactly the word it most needs; the cost is bounded
  (3 records, n times, per stop).
- What ends them: any new sample (a tick that finds the entity moved, a bump, a teleport), an owner
  change, a removal. Keep-alives are not repeated and do not use up repeats. A sample older than 30 s
  is not sent again (its age would not fit the record).
- Default: 2 for kinds with `velocity = true`, 0 for the others. A velocity kind is the case that
  goes visibly wrong (the body runs on), nothing was released with the old behaviour, and the cost is
  two packets a stop (140 B for a spinning ball: 10 + 28 + 16 + 16, twice). Plain kinds keep 0: their receivers extrapolate for at most
  `extrapolate`, the 22 players of a match stop and start all the time, and their bytes are pinned by
  the golden test. They may set it.
- Server-owned entities only. A client-owned entity's stop arrives in its owner's upload; repeating
  it would let an owner mint relay bytes that pass every receiver's budget by stopping and starting,
  and the upload leg has `Config.UploadRedundancy`.
- Measured (`tests/test_stop.luau`; 25 studs/s to a dead stop, 60 Hz, `keepAlive = 1`, 1000 stops a
  row, worst error in the 0.4 s after the stop and stops that passed 0.25 studs). At the time Tide
  draws: 10 % loss 2.09 studs (8 stops) without, 0.11 (0) with 2; 30 % loss 2.09 (104) without, 2.08
  (5) with 2, 0.51 (5) with 4. A stop is lost when every packet with it is lost: 1 in 100 at 10 %
  without repeats, 1 in 10 000 with 2. A reader one frame behind arrivals (the game's renderer) keeps
  one error redundancy cannot touch: after two packets lost in a row it is past its newest sample
  for a frame, up to a frame of travel (0.42 studs; 10 stops in 1000), with or without a stop. Bytes
  for that ball: 2292 B/s rolling, 26 B/s at rest with `keepAlive = 1` (222 with 0.1).

**`Tide.flush()`.** A bump made after Tide's step of a frame (the game's kick detector runs in
`Heartbeat`) left with the next frame's packet. Two designs:

- An automatic late pass: a `Heartbeat` connection of Tide's own, or a deferred thread per bump. The
  connection runs in an order Tide does not control: before some of the game's `Heartbeat` code and
  after the rest, so it would fix some games and not others, and silently. A deferred thread would
  add a packet to every bump made in a remote handler (which the frame's relay was about to carry
  anyway) and rests on scheduler order that cannot be checked outside Studio.
- An explicit call, chosen: `Tide.flush()` relays the entities bumped at once since the last relay
  (`State.late`), through the relay's own encode and send (`Relay.flush`): same audiences, tiers and
  budgets, with no time credited to the budgets and no tier recompute. `relayed` moves on, so the
  frame's relay sends nothing twice and every byte is counted once. It is hard to misuse because
  every wrong call is a no-op that returns 0: nothing bumped, called again, called in the physics
  window (that frame's relay is still to come, and a bump made there is not sampled yet), called
  from a callback inside a relay, called before `Tide.start`, called on a client. Forgetting it is
  v0.5 as it was.
- It flushes queued ADD / OWNER messages first, as a frame does. It does not flush reliable state:
  a `Tide.fire` of the same handler leaves with the next frame, stamped with the bump's time.

**`Tide.focus` before the receiver exists.** A focus set in a `PlayerAdded` connection that ran
before Tide's, or before `Tide.start`, was dropped without a word. It is kept in `State.focusPending`
and applied when the receiver record is created; forgotten at `PlayerRemoving`, and whenever Tide
looks and finds the player gone (the next call, the next player, `Tide.start`), so a player that
leaves before Tide meets it leaves nothing behind. `Tide.focus` returns `true` (set or kept) or
`false` (the player is not in the game). Both, because a game that set the focus early wants it to
work, and a game that set it for a player who had left wants to know.

**`Tide.span(target) -> oldest, newest`.** `Tide.at` holds an end of the history outside it, and a
verdict at a client's view time (a tackle, an offside line) could not tell a held answer from one
read off the path. `span` returns the range. On the server the newest end of a server-owned entity
at rest is `max(newest sample, State.heldT)`: ticks that find it unchanged add no sample, but the
pose is known to stand, and without this a resting body would look uncovered between keep-alives.
For a client-owned entity it is the owner's newest sample (at rest up to `keepAlive` old): the
server does not know more. `Tide.at` gets no flag: it returns one value for plain kinds and three
for velocity kinds, so a trailing flag would sit in a different position for each, or pad plain
kinds with nils and change `select("#", Tide.at(...))` for callers that forward its results. Links
have no `span`: the held tick is not mirrored.

`tests/test_alloc.luau`: stops with repeats, `Tide.flush` with and without a bump, `Tide.span` and a
client receiving every packet twice allocate nothing. Flags by slot (`restDue`, `late`) are set to
`false`, never `nil`, while the entity lives: a table whose keys come and go is rebuilt on insert,
which the test caught as one allocation per stop.

### Not done

- A latest-value field mode on the unreliable stream (research note 3.7). Its one user would have
  been the ball's velocity and spin, which now travel in the samples. For other state an unreliable
  delta needs per-receiver resend bookkeeping (a lost latest value is wrong until the next change),
  and reliable state already lands on the timeline with its stamp. No second candidate, so no second
  transport.
- Owner-local `Tide.predict`. Strike predicts the ball with its own physics from the newest sample;
  `Tide.latest` (with stamp), `Tide.at` and `onSample` are the inputs it needs. A generic predictor
  would have to know each game's forces.
- Detecting an unflagged kick from the velocities alone and inserting a corner. The fallback to
  position tangents already bounds the error to the segment; a detector would guess where in the
  segment the kick happened.
- Moving the simulated body into a non-replicated container with a replicated stand-in. Clients bind
  entities by model instance, so the registered model must replicate; `lock` is the in-place answer
  and has to pass its Studio checks first.

### Limits

- A client that joins while a body rests gets its first sample with the next keep-alive (<= 0.5 s).
- An immediate bump is stamped with the last frame's time, up to a frame before the call. Pose and
  stamp agree; the kick's event should use the returned stamp, not now.
- A lost cut and an unbumped kick degrade to the position-only path for one segment (a cut followed
  by rest is repeated with the stop).
- A stop is still lost when all of its packets are (restRepeats + 2 for a body that stops dead).
  `Tide.flush` gains nothing in a remote handler (those run before Tide's step of the same frame)
  and costs a packet header there.
- Pivot-only models have no velocity and cannot be locked.
- Needs Studio: everything about `lock`; that `PreSimulation` fires before `Stepped` handlers and
  physics in the server's frame (the bump regimes rest on it); `AssemblyAngularVelocity` of a rolling
  ball against the game's own spin model.
