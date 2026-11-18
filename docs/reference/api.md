# API

```lua
local Tide = require(game.ReplicatedStorage.Tide)
```

The same module runs on both sides. Functions marked **server** or **client** only exist on that side.
All times are server time (`workspace:GetServerTimeNow()`). A `target` is a model registered with Tide
or its [handle](#handle).

## Both sides

### Tide.start

```lua
Tide.start(opts: { [string]: any }?) -> boolean
```

Starts Tide. Call it once on the server and once on each client; later calls do nothing (and return
`true`). `opts` takes any [`Tide.Config`](/reference/config) field; each value must have the type of the
field's default (`lockHumanoidStates` takes `false` or a list, `lockMode` `"root"` or `"anchored"`, NaN
is refused). An unknown key or a wrong type is an error. `kinds = { Name = kindOptions }` defines or
changes kinds, as [`Tide.kind`](#tide-kind) does. On the server, `opts` also takes `players = true` to
register every character as kind `"Player"`.

The server creates the remotes `TideU` and `TideR` inside the Tide module. The client waits for them
(at most `Config.startTimeout` seconds; then it warns and returns `false`), then asks the server for
the current entities. Returns `true` once running.

```lua
-- server
Tide.start({ players = true, ReceiverBytesPerSecond = 30000, kinds = { Player = { maxFall = 400 } } })
-- client
task.spawn(Tide.start) -- it waits for the server's remotes
```

### Tide.kind

```lua
Tide.kind(name: string, opts: { [string]: any }?) -> Kind
```

Defines a kind, or changes an existing one (including the built-ins `"Player"`, `"Bot"`, `"Npc"`).
Up to 255 kinds; names under 64 characters. Errors on an unknown option or a value of the wrong type.

| Option | Type | Default | Side | Meaning |
|---|---|---|---|---|
| `rate` | number | 30 | server | samples per second, in (0, 240] |
| `rotation` | `"yaw"` \| `"full"` | `"yaw"` | server | heading only, or the full rotation (+4 B) |
| `near` | number | 100 | server | studs: every sample within this |
| `far` | number | 250 | server | studs: every `farEvery`-th sample within this (at least `near`) |
| `cull` | number | `math.huge` | server | studs: nothing beyond this (at least `far`) |
| `farEvery` | number | 2 | server | send every Nth sample beyond `near` (whole, at least 1) |
| `buffer` | number | 0.04 | server | minimum interpolation delay, seconds |
| `extrapolate` | number | 0.1 | server | max seconds drawn past the newest sample |
| `maxSpeed` | number | 120 | server | studs/s horizontally (client-owned speed check; also caps client extrapolation) |
| `maxFall` | number | 300 | server | studs/s downwards (client-owned speed check; also caps client extrapolation) |
| `maxRise` | number | 60 | server | studs/s upwards (client-owned speed check; also caps client extrapolation) |
| `keepAlive` | number | 0.5 | server | seconds between samples of an idle entity (server-owned samples and client uploads) |
| `teleportDistance` | number | `math.huge` | server | studs: a server-owned sample this far from the previous one is flagged a teleport (receivers snap instead of sweeping). For jumps game code makes without `handle:teleport` |
| `apply` | `"cframe"` \| `"none"` \| `(model, CFrame) -> ()` | `"cframe"` | client | how a client applies the drawn pose |
| `afterApply` | `false` \| `(model, CFrame) -> ()` | `false` | client | called each frame after the pose is applied (the default apply, anchoring included, still runs); errors count as `applyErrors` |
| `animations` | boolean | `true` | server | `false`: this kind's animations stay Roblox's when `Config.animations` is on |
| `motion` | boolean | `true` | server | `false`: a [state-only](/guide/state#state-only-entities) kind: no samples, no drawing, never culled |

"Server" options are sent to clients by the server (`rate`, `rotation`, `buffer`, `extrapolate`, `keepAlive`, `maxSpeed`, `maxRise`, `maxFall`) or only
used there; set them on the server. `apply` is read on the client; set it on the client. Built-in
defaults are listed in [Bots and NPCs](/guide/entities#kinds).

```lua
Tide.kind("Ball", { rate = 60, rotation = "full", near = 150 })
```

### Tide.added

```lua
Tide.added(fn: (model: Instance, kind: string, owner: Player?) -> ()) -> Connection
```

Calls `fn` for each entity added after you connect. On a client, an entity whose model has not
streamed in yet is announced when the model arrives. Each call runs in its own thread. Returns a
connection with `:Disconnect()`.

```lua
Tide.added(function(model, kind, owner)
	print(model.Name, kind, owner and owner.Name or "server")
end)
```

### Tide.removed

```lua
Tide.removed(fn: (model: Instance, kind: string) -> ()) -> Connection
```

Calls `fn` when an entity is removed.

### Tide.latest

```lua
Tide.latest(target) -> CFrame?
```

The newest sample, with no interpolation delay. Server: the newest accepted sample (where a locked
character stands on the server). Client: the newest sample received (`nil` for your own entities,
which the server doesn't send back to you).

### Tide.at

```lua
Tide.at(target, t: number) -> CFrame?
```

The pose at server time `t`, interpolated from history. Holds the oldest sample before history begins
and the newest after it ends. `nil` if Tide doesn't know the target.

- **Server:** from the server's history (`Config.HistorySize` samples per entity). Use it for hit checks
  ([guide](/guide/time-and-rewind#hit-checks-with-tide-at)).
- **Client:** from the client's own buffer (`Config.ClientRing` samples). Useful for debugging and lag tools.

```lua
local cf = Tide.at(victim.Character, seenAt)
```

Code in another VM of the server (an Actor) rewinds through a [link](#links-other-vms).

### Tide.owner

```lua
Tide.owner(target) -> Player?
```

The player that owns the entity, or `nil` for server-owned (and unknown) entities. A client learns
owner changes with the reliable OWNER message.

### Tide.isMine

```lua
Tide.isMine(target) -> boolean
```

Whether this side samples the entity. Server: a registered server-owned entity. Client: an entity this
client owns and uploads (Tide doesn't draw it). `false` for unknown models.

```lua
if Tide.isMine(ball) then
	applyKick(ball) -- only the side that simulates the ball moves it
end
```

### Tide.play

```lua
Tide.play(model: Instance, animation: Animation | string, fade: number?, weight: number?, speed: number?) -> AnimationTrack?
```

[Animations](/guide/animations) only. Plays on the entity's `Animator` from the side that owns it (the
server for server-owned entities, the owning client for its own) and sends the exact `fade` (default
0.1) instead of a measured one. `animation` is an `Animation` or the name of one under
`Config.animationFolder` (an unknown name is an error). Tracks are loaded once per `Animator`. Returns
the track, or `nil` when this side doesn't own the entity or it has no `Animator`.

### Tide.stop

```lua
Tide.stop(model: Instance, animation: Animation | string, fade: number?)
```

Stops every playing track of that animation on the entity's `Animator` (owner side), sending the exact
`fade` (default 0.1).

### Tide.playing

```lua
Tide.playing(model: Instance, t: number?) -> { [string]: Info }?
```

What Tide knows the entity plays, keyed by the animation's name in `Config.animationFolder` (else its
`AnimationId`). `nil` when animations are off or the entity isn't animated by Tide.

- **Server:** from the events it accepted, at server time `t` (default now; up to a second back
  includes animations stopped since). `Info`: `id`, `name`, `since` (server time of the play),
  `timePosition` (at `t`, not wrapped to the length: the server doesn't load animations), `speed`,
  `weight`, `fade`, `priority`, `looped`, `stopping` / `stopT` (a stop arrived; faded out at `stopT`).
- **Client:** your own entities: what their `Animator` plays (`track` included). Other entities: what
  Tide plays for them at the time their body is drawn (`track` is the local track).

### Tide.animated

```lua
Tide.animated(fn: (model: Instance, op: string, name: string, info: { [string]: any }) -> ()) -> Connection
```

Calls `fn` for each animation event. `op` is `"play"`, `"stop"`, `"speed"`, `"weight"`, `"seek"` or
`"priority"`; `info` has `id`, `name`, `time` (the event's server time), `fade`, `weight`, `speed`,
`timePosition`, `priority`, `looped` (and `track` on a client). On a client it fires when the event is
applied to another entity, in step with its body; on the server when the event is accepted. Each call
runs in its own thread.

### Tide.state

```lua
Tide.state(kind: string, fields: { [string]: FieldOptions | string })
```

Declares the [timeline state](/guide/state) of a kind, in code both sides run. Each field is a table
of options, or just a type name. Fields get ids by name (at most 127). Errors on an unknown type or
option, a bad value, or, on the server, when entities of the kind already have state. The server's
declaration is sent to clients (a client's differing declaration is warned about, and the server's is
used). Options: `type` (`"bool"`, `"u8"`, `"u16"`, `"i16"`, `"f32"`, `"f64"`, `"time"`, `"ref"`,
`"enum"`, `"event"`, `"yaw"`, `"pos"`), `default`, `to` (`"all"`, `"owner"`, `"others"`, `"server"`),
`apply` (`"drawn"`, `"arrival"`), `values` (enum), `payload` (event), `mirror`, `mirrorOn`
(`"model"`, `"player"`), `mirrorNil`, `history`. See the
[field options](/guide/state#field-options).

### Tide.get

```lua
Tide.get(target, field: string) -> any
```

- **Server:** the field's current value (the change with the newest stamp).
- **Client:** the value as drawn: the newest change the client's clock for the entity has reached.

Refs read as models (on a client, the local model), `nil` once the entity is gone. Event fields return
the stamp of the latest fire and its payload. Unknown targets give `nil`; an unknown field is an error
(on a client, before the server's schema arrives, `nil`).

### Tide.timeOf

```lua
Tide.timeOf(target) -> number
```

The server time an entity is at. Server: now. Client: the time its body and its state are drawn at
(`now - Tide.delay(model)` for remote entities, now for your own, the [clock](#tide-clock) you gave for
state-only ones). Never goes back. Compare `time` fields against it.

### Tide.changed

```lua
Tide.changed(model: Instance, field: string, fn: (value, old, t: number) -> ()) -> Connection
```

Calls `fn` when that field of that model changes: on the server when it is set, on a client in the
frame it applies. Event fields call `fn(payload, nil, t)` on each fire. Works before the model is
registered.

### Tide.stateChanged

```lua
Tide.stateChanged(fn: (model: Instance, field: string, value, old, t: number) -> ()) -> Connection
```

The same for every field of every entity.

### Tide.stats

```lua
Tide.stats() -> { [string]: number }
```

A copy of the counters.

| Side | Counters |
|---|---|
| server | `packets`, `samples`, `badPacket`, `owner`, `stamp`, `nan`, `speed`, `rate`, `errors`, `relayBytes`, `relayPackets`, `budgetDropped`, `spacing` (uploads closer than half an interval), `teleportWait` (owner uploads dropped while a teleport is unacknowledged), `teleportIgnored`, `teleportFlagged` (server-owned samples flagged by `teleportDistance` or `markTeleport`), `inBytes` (all bytes received from clients), `inBytesPerSecond`, `relayBytesPerSecond` (both over the last second) |
| server, links | `linkUnknown` (intents for keys not linked: dropped), `linkBad` (intents that failed: unknown player, malformed, or never written) |
| server, animations | `animEvents` (accepted), `animBad` (malformed), `animRate`, `animOwner`, `animStamp` (older than the entity's previous event), `animUnknown` (unknown id or priority), `animDropped` (kind opted out), `animRegister` (refused id requests), `animIdsFull`, `animRelayBytes` |
| server, state | `stateSets` (changes recorded), `stateSame` (sets of the current value, skipped), `stateClamped` (stamps clamped), `stateSnaps`, `stateRelayBytes`, `stateRejected` (state messages from clients), `stateNoEntity` (sets on non-entities, ignored) |
| client | `packets`, `records`, `badPacket`, `unknownSlot`, `late`, `uploads`, `uploadBytes`, `uploadSkipped` (idle samples not uploaded), `applyErrors`, `modelsLost` (models dropped when streamed out, `rebindStreamed`), `modelsRebound` (re-streamed instances bound again) |
| client, animations | `animSent`, `animApplied`, `animSnaps`, `animIgnored`, `animOverflow` (applied early: queue full), `animDrift` (tracks put back on the render clock), `animUnknown`, `animBad`, `animSwapped`, `animSwapSkipped` (owner `Animator` already in use) |
| client, state | `stateApplied`, `stateLate` (arrived after its time), `stateStale` (older than the applied value, skipped), `stateOverflow` (applied early: queue full), `stateSnaps`, `stateBad` (malformed), `stateClockErrors`, `stateMirrorErrors` |

See [Security](/guide/security#reporting) for what the server counters mean.

### Tide.Config

The [Config](/reference/config) table. Change fields before `Tide.start()`, or pass them to it.

### Tide.isServer

`true` on the server, `false` on a client.

## Server

### Tide.add

```lua
Tide.add(model: Instance, kind: string?, owner: Player?) -> Handle
```

Registers a model. `kind` defaults to `"Bot"`. With no `owner` the server samples it; with an `owner`,
that player's client samples and uploads it (and it is [locked](/guide/players#the-lock) when
`Config.lockPlayers` is on). Adding a model that is already registered replaces it. Destroying the
model removes it. Errors if Tide hasn't started or the kind is unknown.

```lua
local bot = Tide.add(workspace.Bot)
Tide.add(character, "Player", player)
```

### Tide.remove

```lua
Tide.remove(target)
```

Stops replicating the target. Does nothing if it isn't registered.

### Tide.handle

```lua
Tide.handle(model: Instance) -> Handle?
```

The handle of a registered model, or `nil`. Use it to teleport player characters:

```lua
local handle = Tide.handle(player.Character)
if handle then
	handle:teleport(CFrame.new(0, 5, 0))
end
```

### Tide.set

```lua
Tide.set(target, field: string, value: any, stamp: number?)
```

Sets a [state](/guide/state) field. Stamped now, or at `stamp` clamped to `[now - Config.MaxBackdate,
now]` (on the 0.5 ms grid). `nil` sets the field's default. A stamp older than the field's newest change
only adds to the history. Setting the current value does nothing. Errors on an unknown field, an event
field, or a value of the wrong type (a ref must be a Tide entity, model or handle). Does nothing if the
target isn't registered.

```lua
Tide.set(ball, "Owner", character)
Tide.set(character, "SlideAt", pressAt, pressAt)
```

### Tide.fire

```lua
Tide.fire(target, field: string, payload: any?, stamp: number?)
```

Fires an event field, with its payload if the field declares one. Stamps as `Tide.set`.

### Tide.stateAt

```lua
Tide.stateAt(target, field: string, t: number) -> any
```

The value in effect at server time `t`: the newest change stamped at or before `t`, from the field's
history (`history` changes, default `Config.StateHistory`). Before its first change: the default. Refs
to entities that are gone read `nil`. Event fields: the stamp and payload of the latest fire at or
before `t`.

### Tide.changedAt

```lua
Tide.changedAt(target, field: string, t0: number, t1: number) -> number?
```

The stamp of the first change of the field in `(t0, t1]`, or `nil`.

### Tide.onSuspicious

```lua
Tide.onSuspicious(fn: (player: Player, reason: string) -> ())
```

Sets the one hook called when an upload fails a check. `reason` is `"badPacket"`, `"nan"`, `"speed"`,
or `"teleportIgnored"` (the owner did not confirm a server teleport after `Config.TeleportTries` sends).
With [animations](/guide/animations) on, also `"animRate"` (over `Config.AnimEventsPerSecond`),
`"animOwner"` (events for an entity the player doesn't own; events from the previous owner within
2 s of an owner change or removal are dropped without a report) and `"animRegister"` (an invalid
animation id, over 64 id requests a minute, over the player's share of new ids, or `Config.MaxAnimIds`
reached).
Rate limited to 4 calls per second per player; runs in its own thread.

### Tide.focus

```lua
Tide.focus(player: Player, target: BasePart | Model | Vector3 | nil)
```

Where a player without a `"Player"` entity (a spectator, a menu camera, a player watching another
match) is for [interest](/guide/interest#without-a-character): distances are measured from the part
or model (followed as it moves) or the point. While the player has a character entity, the character
wins. `nil` removes it. Without a character or a focus, a receiver gets everything as "far".

```lua
Tide.focus(player, stadium.CameraPart)
```

### Tide.velocity (server)

```lua
Tide.velocity(target) -> Vector3
```

Velocity in studs per second from the server's history (newest sample against the one about 50 ms
older, never across a teleport or an idle gap). Zero when the entity stands still or is unknown; right
after a teleport, the velocity given to it. A locked character's locker gets this velocity
(`AssemblyLinearVelocity`, plus `AssemblyAngularVelocity` for `rotation = "full"` kinds).

### Handle

```lua
handle:teleport(cf: CFrame, velocity: Vector3?)
handle:markTeleport(target: CFrame | Vector3 | nil)
handle:setOwner(player: Player?)
handle:owner() -> Player?
handle:setAudience(audience: ((player: Player) -> boolean) | { Player } | nil)
handle:setOrigin(origin: Vector3?)
handle:link(name: string?, key: string | number)
handle:remove()
handle:alive() -> boolean
handle.model -- the registered model
```

- `teleport`: server-owned entities move at once (the whole model, keeping the root's offset) and every
  client snaps. Client-owned entities: the target goes into the server's history at once (every client
  snaps, the lock holds the server copy there) and the owner is told to move there. Until the owner's
  flagged upload arrives within `Config.TeleportGrantRadius` of the target, its uploads are dropped;
  the command is resent every `Config.TeleportRetry` seconds, and after `Config.TeleportTries` sends
  `onSuspicious(player, "teleportIgnored")` is called once ([details](/guide/players#teleports)).
  `velocity`, if given, is set on the root (by the owner for client-owned entities). With
  `Config.teleportOnWrite`, server code that sets a client-owned root's `CFrame` or calls `PivotTo` on
  the model teleports it the same way.
- `markTeleport`: flags a jump of a server-owned entity that game code made itself (`PivotTo`, a CFrame
  write, another VM), so receivers snap instead of sweeping. No target: the entity is sampled now,
  flagged; call it after moving the model. A target: the first sample within
  `Config.TeleportGrantRadius` of it in the next second is flagged, for moves that land later. Does
  nothing for client-owned entities (use `teleport`). See also the kind option `teleportDistance`.
- `setOwner`: hands the entity to a player, or back to the server with `nil`. See
  [Config.ownerEase and ownerStart](/reference/config#owner-changes) for smoother changes.
- `owner`: the owning player, `nil` when server-owned or removed.
- `setAudience`: who receives the entity. `nil` (the default): every player. A list (or set) of
  players: only them. A function: asked for each player every `Config.InterestEvery` (0.1 s); an error
  counts in `errors` and means no. Players outside it get nothing of the entity (samples, animations,
  state), as if culled; coming back in, they get a state snapshot like any cull exit. An owner outside
  the audience still uploads. See [Interest](/guide/interest#audiences).
- `setOrigin`: the entity's own quantization origin (`nil`: `Config.origin`), snapped to
  `Config.origin`'s 1/64 grid. Packed positions cover ±1024 studs around it, so entities far from
  `Config.origin` (another arena, a far venue) keep the 10-byte record. Set it in the same frame as
  `Tide.add` (it travels with the ADD); a later change sends the entity's records in the absolute form
  (+12 B) for a second while clients learn it.
- `link`: mirrors the entity's history into the link `name` under `key` for code in other VMs (see
  [Links](#links-other-vms)). `nil` name unlinks. One entity per key: linking another entity under a
  taken key unlinks the first.
- `remove`: same as `Tide.remove`.
- `alive`: `false` once the entity is removed. Methods on a dead handle do nothing.

### Links (other VMs)

```lua
-- any VM of the server, e.g. a venue Actor's script
local Link = require(ReplicatedStorage.Tide.Shared.Link)
local venue = Link.open(name: string)
venue:has(key) -> boolean
venue:at(key, t: number) -> CFrame?
venue:latest(key) -> (CFrame?, number?)
venue:setOwner(key, userId: number?)
venue:teleport(key, cf: CFrame, velocity: Vector3?)
venue:markTeleport(key, target: CFrame | Vector3 | nil)
```

Tide's server runs in one VM (it owns the remotes). `handle:link(name, key)` in that VM mirrors the
entity's accepted samples into a `SharedTable` registered as `"Tide:" .. name` at the end of each frame.
In any other VM, `Link.open(name)` reads it:

- `at` and `latest` answer what `Tide.at` / `Tide.latest` answer in the Tide VM, from the same samples
  with the same interpolation, up to one Tide frame behind. `nil` for keys not linked. `latest` also
  returns the sample's server time.
- `setOwner`, `teleport` and `markTeleport` queue intents. The Tide VM applies them at the start of its
  next frame, in order, as `handle:setOwner` (by `UserId`; `nil` or `0` is the server), `handle:teleport`
  and `handle:markTeleport`. There is no reply and nothing is synchronous: read `Tide.owner` /
  `venue:latest` later to see the result. Intents for keys not linked then are dropped
  (`linkUnknown`); ones that fail are dropped too (`linkBad`).

Nothing is mirrored until something is linked. Each mirrored sample costs one `SharedTable` write (a
73-byte string) plus one for the entity's newest index. See
[Time and rewind](/guide/time-and-rewind#other-vms-actors) for an example and the limits.

## Client

### Tide.drawn

```lua
Tide.drawn(model: Instance) -> CFrame?
```

The CFrame Tide drew for this model this frame (also with `apply = "none"`). `nil` for your own
entities, unknown models, and entities with nothing drawn yet.

### Tide.delay

```lua
Tide.delay(model: Instance) -> number
```

How far behind server time this entity is drawn, in seconds. `0` for your own entities and unknown
models. `workspace:GetServerTimeNow() - Tide.delay(model)` is the server time of what you see.

### Tide.velocity

```lua
Tide.velocity(model: Instance) -> Vector3
```

The drawn velocity in studs per second (from frame to frame). Zero if not drawn.

### Tide.peek

```lua
Tide.peek(model: Instance, field: string) -> (any, number?)
```

The newest value of a state field this client has received (which may be ahead of the drawing), and
its stamp. Before anything arrived: the applied value and `nil`.

### Tide.clock

```lua
Tide.clock(model: Instance, fn: ((now: number) -> number)?)
```

Gives the clock a [state-only](/guide/state#state-only-entities) entity's state applies at, for things
your own code draws: `fn(now)` returns the server time the model is drawn at. `nil` removes it. Kept
monotonic per entity. (On the server it does nothing, so shared code may call it.)

### Tide.sampleInfo

```lua
Tide.sampleInfo(model: Instance, into: table?) -> table?
```

The health of an entity's stream, for lag displays. `nil` for your own entities, unknown models, and
before the first sample. Pass `into` to have the fields written into your table (no allocation).

| Field | Meaning |
|---|---|
| `newest` | server time of the newest sample |
| `count` | samples received so far |
| `buffered` | samples held (at most `Config.ClientRing`) |
| `age` | `now - newest`, seconds |
| `delay` | same as `Tide.delay` |
| `held` | `(now - delay) - newest`: above 0 when drawing past the newest sample |
| `interval` | mean gap between recent moving samples, seconds (0 if none) |
| `jitter` | standard deviation of those gaps |
| `idle` | the entity is at rest (its newest sample repeats the pose). Gaps up to the kind's `keepAlive` are then normal, not a stall. |
