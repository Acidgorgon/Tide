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
tiers every recompute. A receiver whose character is gone (dead, respawning) is measured from where it
last was; one that never had a character and has no [focus](#without-a-character) gets everything as
far (thinned, and dropped first when over budget). An owner never receives its own entities.

```lua
Tide.kind("Npc", {
	near = 80,      -- full rate within 80 studs
	far = 200,      -- every 3rd sample up to 200
	farEvery = 3,
	cull = 350,     -- nothing beyond 350
})
```

`far` is raised to at least `near`, and `cull` to at least `far`.

## Without a character

Spectators, menu cameras and players watching another match have no `"Player"` entity. Give them a
**focus** on the server, and distances are measured from it:

```lua
Tide.focus(player, match.Camera)          -- a BasePart or Model, followed as it moves
Tide.focus(player, Vector3.new(0, 0, 0))  -- a fixed point
Tide.focus(player, nil)                   -- none
```

A character entity, while the player has one, still wins.

## Audiences

Some entities matter to only some players: the bodies of one match on a server running several. Give
the entity an **audience**, and everyone else gets nothing of it (samples, animations, state), as if it
were culled:

```lua
local body = Tide.add(model, "Body")
body:setAudience(match.players)                       -- a list (or set) of Players
body:setAudience(function(player)                     -- or asked every Config.InterestEvery
	return player:GetAttribute("Match") == match.id
end)
body:setAudience(nil)                                 -- everyone again (the default)
```

A function is called for each receiver every `Config.InterestEvery` (0.1 s), so keep it cheap; an error
is counted in `errors` and means no. A player coming into an audience gets the entity like after a
cull: its state snapshot, then its samples. An owner always uploads its entity, audience or not.

On the mock, 4 matches of 22 bodies with 8 viewers each went from 70.9 KB/s per player (everyone gets
everything) to 17.8 KB/s with each match's bodies limited to its viewers.

## Far from the origin

Positions pack into ±1024 studs around `Config.origin` at 1/64 stud; further out a record carries a
12-byte absolute position. For venues spread far apart, give each entity an origin near it:

```lua
local body = Tide.add(model, "Body")
body:setOrigin(venue.Centre.Position) -- in the same frame as Tide.add
```

Records and the server's history then quantize around it, so the entity keeps the compact record.
Changing it later is fine: the entity's records go out in the absolute form for a second while clients
learn the new origin.

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
