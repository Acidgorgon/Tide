# Config

`Tide.Config` holds every setting. Change fields before `Tide.start()`, or pass them in the start
options (each value must have the type of the default; unknown names are errors):

```lua
Tide.Config.HistorySize = 256
Tide.start({ players = true, lockMode = "anchored" })
```

**Side** says where a field is read. Server fields marked *sent* are sent to clients when they join,
so clients use the server's value.

## Wire

| Field | Default | Side | Meaning |
|---|---|---|---|
| `origin` | `Vector3.new(0, 0, 0)` | server, sent | Centre of position quantization. Packed positions cover ±1024 studs per axis around it; further out a record carries a 12-byte absolute position. |
| `MaxPacket` | `900` | server | Bytes per unreliable relay packet (Roblox drops unreliable payloads over 1000 B). |
| `UploadRedundancy` | `1` | server, sent | `2` makes each upload also resend the previous sample, to survive a dropped packet. |

## Server receive

| Field | Default | Meaning |
|---|---|---|
| `MaxBackdate` | `1.0` | Seconds a client stamp may lie before its arrival (older stamps are clamped). |
| `MaxAhead` | `0.005` | Seconds a client stamp may lie after its arrival (clamped). |
| `PlayerBytesPerSecond` | `8192` | Upload byte cap per player (token bucket). |
| `PlayerBytesPerFrame` | `1024` | Upload byte cap per player per server frame. |
| `MaxUploadCount` | `16` | Records per upload packet. |
| `TeleportGrantRadius` | `4.0` | Studs between a server teleport's target and the owner's flagged sample that confirms it. Until then the owner's uploads are dropped. |
| `TeleportRetry` | `1.0` | Seconds before an unconfirmed teleport command is sent to the owner again. |
| `TeleportTries` | `3` | Sends before `onSuspicious(player, "teleportIgnored")` (called once; the server keeps holding the target and resending). |
| `SpeedResync` | `1.0` | Seconds of continuous speed rejections before the owner is teleported back to the server's pose (`0`: never). |
| `teleportOnWrite` | `true` | Server writes to a client-owned root's `CFrame` (`root.CFrame =`, `model:PivotTo`) become teleports. Writes onto the held pose are ignored. Verify in Studio that `PivotTo` fires the root's `CFrame` changed signal in your setup. |
| `teleportOnWriteVelocity` | `"zero"` | Velocity of those teleports: `"zero"` stops the character (a server `AssemblyLinearVelocity` write never reaches a locked owner), `"keep"` leaves the owner's velocity. |

## Server history and relay

| Field | Default | Meaning |
|---|---|---|
| `HistorySize` | `128` | Samples kept per entity for `Tide.at` / `Tide.latest`. |
| `ReceiverBytesPerSecond` | `40960` | Relay budget per receiving player; far records are dropped first. |
| `InterestEvery` | `0.1` | Seconds between distance tier recomputes. |
| `Hysteresis` | `4` | Studs of hysteresis around the `near` / `far` / `cull` boundaries. |
| `SlotQuarantine` | `2.0` | Seconds before a freed entity slot is reused. |

## Lock

| Field | Default | Side | Meaning |
|---|---|---|---|
| `lockPlayers` | `true` | server, sent | Stop Roblox replicating the position of client-owned entities; the server's copy follows Tide's samples. |
| `lockMode` | `"root"` | server | `"root"`: non-replicated locker inside the root part. `"anchored"`: anchored locker in the server camera (fallback). Anything else is an error at start. |
| `lockHumanoidStates` | `false` | server | Or a list of `Enum.HumanoidStateType` disabled on the server's Humanoid while locked. |

See [Players: the lock](/guide/players#the-lock).

## Client

| Field | Default | Meaning |
|---|---|---|
| `ClientRing` | `64` | Samples kept per entity on the client. |
| `MaxBuffer` | `0.5` | Largest interpolation delay, seconds. |
| `BufferMargin` | `0.002` | Added to the p95 of measured need. |
| `NeedGapMax` | `0.25` | Sample gaps longer than this are idle or keep-alive gaps: not counted as need, and not used for extrapolation velocity. |
| `SnapGap` | `1.0` | Sample gaps longer than this are treated as teleports (no sweep across). |
| `DelaySnap` | `0.1` | Delay changes larger than this snap; smaller ones ease. |
| `CorrectionTime` | `0.1` | Seconds to blend away a correction. |
| `SnapDistance` | `16` | Corrections larger than this (studs) snap instead of blending. |
| `ClientAnchor` | `true` | Anchor the root of remotely-driven entities on the client (moved with `BulkMoveTo`). |
| `ModelRetry` | `1.0` | Seconds between asks for models that haven't arrived (StreamingEnabled). An ask names up to 64; with more missing, each ask takes the next 64. |
| `rebindStreamed` | `false` | *Server, sent.* A model whose `Parent` became `nil` (streamed out) is dropped (`removed` fires) and asked for again; the re-streamed model, a new instance, is bound to the same entity and keeps its stream. A model the game parents back itself is bound again. Off (v0.3): Tide keeps driving the detached instance and never binds the new one. |
| `TeleportAckTime` | `0.3` | Seconds after a server teleport during which the owner flags its uploads (and never skips idle ones). |
| `startTimeout` | `30` | Seconds `Tide.start()` waits for the server's remotes before warning and returning `false`. |

`NeedGapMax` and `SnapGap` are also read by the server's `Tide.at` interpolation.

## Owner changes

Both are server fields, sent to clients. Defaults behave as v0.3.

| Field | Default | Meaning |
|---|---|---|
| `ownerEase` | `false` | An owner change keeps each receiver's render clock for the entity: the new source starts at the old delay and eases to its own (the clock runs at 0.75x..1.1x of real time meanwhile) instead of jumping to it. The old owner blends from its own pose instead of jumping back. Measured (20 studs/s, owner flipping every 0.75 s, a third client watching): worst one-frame step 1.00 / 2.32 / 4.72 studs at 30 / 60 / 100 ms one-way without it, 0.19 / 0.24 / 0.33 with it. |
| `ownerStart` | `"drawn"` | Where the new owner's copy starts. `"drawn"`: where Tide drew it (v0.3; the copy is a render delay behind, so the server's history steps back). `"latest"`: the newest sample it received, carried to now. `"server"`: the server's pose at the change (the live model for a server-owned entity, else its newest sample), sent with the OWNER message, carried to now. Tide moves the copy with `PivotTo`; the owner's physics carries on from there. |

## Animations

| Field | Default | Side | Meaning |
|---|---|---|---|
| `animations` | `false` | server, sent | Replay `Animator` events at each receiver's render time ([guide](/guide/animations)). Off: Roblox replicates animations as before and no animation bytes are sent. Set it on a client too to swap the owner's `Animator` at spawn. |
| `animationsOwnerLocal` | `true` | server, sent | The owner client swaps its character's `Animator` for a client-created one (not replicated by Roblox), if nothing plays on the old one yet. |
| `animationFolder` | `nil` | both | A folder of `Animation` instances that get ids up front (no bytes) and can be played by name. The server sends its folder to clients when they join. |
| `animationFade` | `0.1` | both | Fade (seconds) used when one cannot be measured. |
| `MaxAnimIds` | `1024` | server | Animation ids in total (folder and runtime). |
| `AnimEventsPerSecond` | `60` | server | Animation events per player per second (burst 30); more are dropped and reported as `"animRate"`. |
| `AnimApplyPerFrame` | `64` | client | Animation events applied per frame at most. |

## Timeline state

On for kinds with a [`Tide.state`](/reference/api#tide-state) declaration; without one, nothing changes.

| Field | Default | Side | Meaning |
|---|---|---|---|
| `StateHistory` | `32` | server | Changes kept per entity per field for `Tide.stateAt` (the field option `history` overrides it). |
| `StateReplay` | `1.0` | server | A snapshot (late join, back in range) carries the values in effect this many seconds ago, then every change since. |
| `StateApplyPerFrame` | `128` | client | State changes applied per frame at most. |

`MaxBackdate` (1 s) also bounds how far back a `Tide.set` stamp may go.
