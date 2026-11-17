# Interest and bandwidth

Every player does not need every sample of every entity. Tide sorts entities into **tiers** per
receiving player by distance, and keeps each player under a **byte budget**.

## Tiers

Distances are measured from the receiver's own `"Player"` entity (its newest sample) to the entity's
newest sample, every `Config.InterestEvery` (0.1 s).

| Tier | Distance | What is sent |
|---|---|---|
| near | up to the kind's `near` | every sample |
| mid | up to `far` | every `farEvery`-th sample (teleports always) |
| far | up to `cull` | as mid, and dropped first when over budget |
| culled | beyond `cull` | nothing |

With the built-in `"Player"` kind (60 Hz, `farEvery = 2`), a character within 100 studs arrives at
60 Hz, and beyond that at 30 Hz. Players are never culled (`cull = math.huge`); `"Npc"` is culled
beyond 400 studs.

Boundaries have `Config.Hysteresis` (4 studs) of hysteresis, so an entity on the line doesn't flip
tiers every recompute. A receiver with no character (loading, dead, spectating) gets everything as near.
An owner never receives its own entities.

```lua
Tide.kind("Npc", {
	near = 80,      -- full rate within 80 studs
	far = 200,      -- every 3rd sample up to 200
	farEvery = 3,
	cull = 350,     -- nothing beyond 350
})
```

`far` is raised to at least `near`, and `cull` to at least `far`.

## Byte budget

Each receiver has a budget of `Config.ReceiverBytesPerSecond` (40 KB/s) with up to half a second of
burst. Near records are always sent (and count against the budget). Mid records go next, then far,
while budget remains. What doesn't fit this frame is skipped and counted in `Tide.stats().budgetDropped`.

To see what that budget buys: 21 other players at 60 Hz, all near, is
`21 × 60 × 10 B ≈ 12.6 KB/s` plus a 10-byte header per packet, about a third of the default budget.

## Packets

Every frame, each new sample is encoded **once** into a shared scratch buffer. For each receiver, Tide
copies the byte ranges it should get into its own packet with `buffer.copy`, splitting at
`Config.MaxPacket` (900 B, under Roblox's 1000 B limit for unreliable remotes), and fires one
`UnreliableRemoteEvent` call per packet. Usually that is one call per player per frame.

See the [wire format](/reference/wire-format) for the exact bytes.
