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
| `apply` | `"cframe"` \| `"none"` \| `(model, CFrame) -> ()` | `"cframe"` | client | how a client applies the drawn pose |
| `afterApply` | `false` \| `(model, CFrame) -> ()` | `false` | client | called each frame after the pose is applied (the default apply, anchoring included, still runs); errors count as `applyErrors` |

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

### Tide.stats

```lua
Tide.stats() -> { [string]: number }
```

A copy of the counters.

| Side | Counters |
|---|---|
| server | `packets`, `samples`, `badPacket`, `owner`, `stamp`, `nan`, `speed`, `rate`, `errors`, `relayBytes`, `relayPackets`, `budgetDropped`, `spacing` (uploads closer than half an interval), `teleportWait` (owner uploads dropped while a teleport is unacknowledged), `teleportIgnored`, `inBytes` (all bytes received from clients), `inBytesPerSecond`, `relayBytesPerSecond` (both over the last second) |
| client | `packets`, `records`, `badPacket`, `unknownSlot`, `late`, `uploads`, `uploadBytes`, `uploadSkipped` (idle samples not uploaded), `applyErrors` |

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

### Tide.onSuspicious

```lua
Tide.onSuspicious(fn: (player: Player, reason: string) -> ())
```

Sets the one hook called when an upload fails a check. `reason` is `"badPacket"`, `"nan"`, `"speed"`,
or `"teleportIgnored"` (the owner did not confirm a server teleport after `Config.TeleportTries` sends).
Rate limited to 4 calls per second per player; runs in its own thread.

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
handle:setOwner(player: Player?)
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
- `setOwner`: hands the entity to a player, or back to the server with `nil`.
- `remove`: same as `Tide.remove`.
- `alive`: `false` once the entity is removed. Methods on a dead handle do nothing.

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
