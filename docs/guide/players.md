# Players

Player characters are **client-owned**: each client samples its own character and uploads it, the
server checks every sample and relays it, and every other client draws it. The owner never receives
its own character back.

## Turning it on

```lua
-- server
Tide.start({ players = true })
```

With `players = true`, Tide listens to `CharacterAdded` on every player, waits for the
`HumanoidRootPart` (up to 10 s), and calls `Tide.add(character, "Player", player)`. When the
character is removed, or the player leaves, the entity goes with it.

If you spawn characters yourself, leave `players` off and add them when you are ready:

```lua
player.CharacterAdded:Connect(function(character)
	character:WaitForChild("HumanoidRootPart")
	Tide.add(character, "Player", player)
end)
```

Use the kind name `"Player"` for characters: Tide uses each player's own `"Player"` entity as the
centre of their [interest](/guide/interest) (who is near, who is far).

## What the client does

- **Uploads** its own character at the kind's `rate` (60 Hz for `"Player"`) on a steady schedule (at most one
  sample per frame), so a 144 fps client sends 60 samples a second, not 144. Samples are stamped with
  `workspace:GetServerTimeNow()`.
- **Draws** everyone else at `now - delay`, where `delay` is picked per player from the gaps it actually
  sees (the p95 of recent arrival gaps, never below the kind's `buffer`). See
  [Time and rewind](/guide/time-and-rewind).
- **Anchors** the root part of every remote character on that client (`Config.ClientAnchor`) and moves
  them all with one `BulkMoveTo` per frame. Animations still play: the `Animator` is Roblox's as usual,
  or, with [animations](/guide/animations) on, Tide replays them in step with the body.

Your own character is never touched by Tide on your client: `Tide.drawn(myCharacter)` is `nil`.

## The lock

Roblox replicates a character's position on its own. With Tide also sending it, every client would get
two position streams. So by default the server **locks** client-owned entities (`Config.lockPlayers = true`):
Roblox stops replicating the character's position, and the server's copy of the character follows the
newest sample Tide accepted. Server-side hitboxes, `Touched` and raycasts then see the same positions
Tide relays.

`Config.lockMode` picks how:

| `lockMode` | How it works |
|---|---|
| `"root"` (default) | An invisible, near-massless locker part inside a non-replicated `Camera` under the root part becomes the assembly root, so Roblox stops replicating the assembly while the owner keeps simulating its own copy. The server moves the locker each frame. |
| `"anchored"` | An anchored locker under the server's camera, welded to the root, moved with one `BulkMoveTo`. Simpler, but anchoring the assembly can take network ownership away from the owner. A fallback. |

Optional: `Config.lockHumanoidStates` takes a list of `Enum.HumanoidStateType` to disable on the
**server's** Humanoid while locked, if you see the server Humanoid fight the lock.

::: warning Roll out with the lock off first
Set `lockPlayers = false` to run Tide next to Roblox's own replication. Everything else works the same
(clients draw Tide's stream), so you can compare before you switch Roblox's stream off.
:::

## Teleports

Players move their own characters, so a server teleport is a request to the owner. Always teleport a
Tide character through its **handle** on the server:

```lua
local handle = Tide.handle(player.Character)
if handle then
	handle:teleport(spawnPad.CFrame + Vector3.new(0, 3, 0))
end
```

A plain server write works too: with `Config.teleportOnWrite` (on by default), setting a client-owned
root's `CFrame` or calling `PivotTo` on the model turns into the same teleport, so existing set-piece
or respawn code keeps working. Writes that land on the pose Tide already holds are ignored.

What happens:

1. The server puts the target into the entity's history at once, flagged as a teleport, so every other
   client snaps instead of sliding across the map, and the lock holds the server copy there.
2. It sends the owner a teleport command (with an optional velocity: `handle:teleport(cf, velocity)`).
   The owner moves its character there and flags its uploads for `Config.TeleportAckTime` (0.3 s).
3. Until a flagged upload arrives within `Config.TeleportGrantRadius` (4 studs) of the target, the
   owner's uploads are dropped. The command is resent every `Config.TeleportRetry` (1 s); after
   `Config.TeleportTries` (3) sends, `onSuspicious(player, "teleportIgnored")` fires once and the server
   keeps holding the target.

A client that moves its own character far without a server teleport fails the
[speed check](/guide/security#speed): those samples are dropped (and reported) until the time since its
last accepted sample covers the distance at `maxSpeed`.

## Respawns and leaving

- **Respawn:** the old character is removed (its lock with it) and the new one is added and locked.
- **Leave:** the player's `"Player"` entity is removed. Any other entity the player owned (see
  [handing an entity to a player](/guide/entities#ownership)) goes back to the server.

## Streaming

With StreamingEnabled, a model may not have reached a client when its entity arrives; the client asks
for it again every `Config.ModelRetry` (1 s) until it does. One ask names up to 64 entities; with more
missing, each ask takes the next 64 (wrapping around), so every missing model is asked for at least
every `ceil(missing / 64)` asks, even when the server won't answer for some of them (entities whose
[audience](/guide/interest#audiences) leaves the player out). When Roblox streams a model **out**, the
client's instance leaves the DataModel and a new instance arrives when it streams back in. By default
(v0.3) Tide keeps driving the old instance. With `Config.rebindStreamed = true` (a server setting, sent
to clients) a model whose `Parent` became `nil` is dropped (`Tide.removed` fires), asked for again, and
the new instance is bound to the same entity without restarting its stream (`Tide.added` fires for it).

## Tuning the kind

The built-in `"Player"` kind can be changed like any other, before `Tide.start()`:

```lua
Tide.kind("Player", {
	rate = 30,        -- uploads per second (default 60)
	buffer = 0.03,    -- minimum interpolation delay, seconds (default 0.02)
	maxSpeed = 80,    -- studs/s horizontally for the speed check (default 120)
})
```

All options are in [`Tide.kind`](/reference/api#tide-kind).
