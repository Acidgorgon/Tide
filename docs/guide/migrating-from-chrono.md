# Migrating from Chrono

Tide covers the same ground as [Chrono](https://github.com/Parihsz/Chrono) for characters and
server-moved entities: client-owned characters, server-owned entities, interpolation buffers, distance
tiers and a lock on Roblox's own replication. The concepts map closely; the names and the time base
differ. This page lists the mapping, then what Tide v0.1 does not have.

## Concept mapping

| Chrono 2.x | Tide |
|---|---|
| `Chrono.Start(configModule)` | `Tide.start(opts)` on the server and on the client |
| `Config.SetConfig("PLAYER_REPLICATION", "AUTOMATIC")` | `Tide.start({ players = true })` |
| `Config.RegisterEntityType(name, { TICK_RATE, BUFFER, FULL_ROTATION, ... })` | `Tide.kind(name, { rate, buffer, rotation = "full", ... })` |
| `TICK_RATE` (seconds between ticks) | `rate` (ticks per second): `rate = 1 / TICK_RATE` |
| `NORMAL_TICK_DISTANCE`, `HALF_TICK_DISTANCE` | `near`, `far` (+ `cull`, `farEvery`) |
| `MIN_BUFFER` / `BUFFER`, `MAX_BUFFER` | kind `buffer`, `Config.MaxBuffer` |
| `SMART_BUFFER`, `STEADY_SEND` | always on |
| `MAX_TOTAL_BYTES_PER_FRAME_PER_PLAYER` | `Config.ReceiverBytesPerSecond` (per second, far records dropped first) |
| `Chrono.Entity.new(type, model)` | `Tide.add(model, kind, owner?)`, returns a handle |
| `entity:SetNetworkOwner(player)` | `handle:setOwner(player)` |
| `entity:SetCFrame(cf)` | `handle:teleport(cf, velocity?)`, or just set the root's `CFrame` on the server (`teleportOnWrite`) |
| `entity:Destroy()` | `handle:remove()`, `Tide.remove(model)`, or destroy the model |
| `entity:GetAt(t)` | `Tide.at(model, t)` (server time) |
| `entity:GetTargetRenderTime()` | `workspace:GetServerTimeNow() - Tide.delay(model)` |
| `Events.EntityAdded` / `EntityRemoved` | `Tide.added(fn)` / `Tide.removed(fn)` |
| `MODEL_REPLICATION_MODE` with a lock | `Config.lockPlayers`, `Config.lockMode` |
| `Stats` | `Tide.stats()` |

## Things to change

- **Times are server time.** Every stamp in Tide, and every argument to `Tide.at`, is
  `workspace:GetServerTimeNow()`. If your hit checks convert a client clock to a server clock, drop
  that step: send `GetServerTimeNow() - Tide.delay(target)` and pass it to `Tide.at`
  ([example](/guide/time-and-rewind#hit-checks-with-tide-at)).
- **Rates are in Hz.** Convert `TICK_RATE = 1/30` to `rate = 30`.
- **Teleport players from the server.** `Tide.handle(character):teleport(cf)`, or a plain server
  `CFrame`/`PivotTo` write (`teleportOnWrite`); a client that moves itself far without one fails the
  speed check.
- **Delays are per entity.** Read `Tide.delay(model)` for the entity you care about, not one global
  value.
- **Roll out with `lockPlayers = false`** first, then turn the lock on once your game is happy.

## Not in Tide v0.1

If you use any of these Chrono features, keep them in your own code or wait for a later Tide:

- Mounts (`SetMount` / `ClearMount`).
- Custom per-entity data (`SetData` / `GetData`) and entity events. Use Ripple or Current for data.
- Death and CFrame-setter replication options (`REPLICATE_DEATHS`, `REPLICATE_CFRAME_SETTERS`).
- Pushing samples by hand (`AUTO_UPDATE_POSITION = false` + `Entity.Push`) and pausing replication.
- `ALIGN` interpolation mode (AlignPosition / AlignOrientation). Tide sets CFrames, or calls your
  `apply` function.
- Per-entity broad-phase sizes for the interest grid.

## Measuring the switch

The repository's `bench/` runs both libraries through the same scenarios on a Roblox mock and
reports CPU, allocations, bytes and drawn accuracy. Results are on the [Benchmarks](/benchmarks) page.
