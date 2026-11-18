# Time and rewind

## One clock

Every time in Tide is **server time**: `workspace:GetServerTimeNow()`, on the server and on every client.

- A client stamps each upload with its server time. The server clamps the stamp to
  `[arrival - MaxBackdate, arrival + MaxAhead]` (1 s back, 5 ms ahead) and drops it unless it is newer
  than the entity's last sample.
- The server stamps the samples of entities it owns with its own server time.
- Relay records carry their sample time (to 0.5 ms), so every client gets the same stamps the server
  stored.

The server keeps the last `Config.HistorySize` samples (128) of every entity, **quantized exactly as
clients decode them**. So the server's history and what clients draw are the same points on the same
clock.

## How far behind clients draw

Each client draws an entity at `now - delay`. The delay is chosen per **source**: per entity for
client-owned entities (each player has their own connection), and per kind for server-owned ones.

On every packet, the client measures how far behind "now" it would have had to draw for a sample to
still be ahead of it. The target delay is the p95 of the last 128 of those, plus `Config.BufferMargin`
(2 ms), clamped between the kind's `buffer` and `Config.MaxBuffer` (0.5 s). The drawn delay eases toward
the target (it snaps only for changes over `Config.DelaySnap`, 0.1 s), so a steady connection gets a
small, steady delay and a jittery one gets just enough.

Between samples, Tide draws a cubic (Hermite) curve. Past the newest sample it extrapolates with the
last velocity for up to the kind's `extrapolate` (0.1 s), then holds. When late samples change the
path, the difference is blended away over `Config.CorrectionTime` (0.1 s), or snapped if it is over
`Config.SnapDistance` (16 studs). A teleport flag always snaps.

```lua
-- client
Tide.delay(model)    -- current delay for this entity, seconds (0 for your own)
Tide.drawn(model)    -- the CFrame drawn this frame
Tide.velocity(model) -- drawn velocity, studs/s
Tide.latest(model)   -- newest sample received, no delay
Tide.at(model, t)    -- pose at server time t from this client's buffer
```

## Hit checks with `Tide.at`

The question a hit check asks is "was the target where the shooter saw it?". The shooter saw the target at
server time `now - Tide.delay(target)`, so send that time with the shot:

::: code-group

```lua [client]
local function onFire(target: Model, origin: Vector3, direction: Vector3)
	local seenAt = workspace:GetServerTimeNow() - Tide.delay(target)
	Net.Shoot.Fire(target, seenAt, origin, direction)
end
```

```lua [server]
local MAX_REWIND = 0.5 -- seconds you allow; never trust the client's time blindly

Net.Shoot.On(function(player, target, seenAt, origin, direction)
	local now = workspace:GetServerTimeNow()
	seenAt = math.clamp(seenAt, now - MAX_REWIND, now)

	local cf = Tide.at(target, seenAt) -- CFrame of the target's root at that time
	if cf and hitsBox(origin, direction, cf, Vector3.new(4, 5, 2)) then
		damage(target)
	end
end)
```

:::

`Tide.at(target, t)` on the server takes a model or a handle and returns the root's CFrame at server
time `t`, using the same interpolation clients draw with. Before the oldest sample in history it returns
the oldest; after the newest it returns the newest (no extrapolation on the server). It returns `nil`
only for something Tide doesn't know.

`Tide.latest(target)` returns the newest accepted sample: for a locked player that is also where the
server's copy of the character stands.

::: tip How much history is there?
128 samples per entity: about 2 s for a 60 Hz player, 4 s for a 30 Hz bot (longer when it stands still,
since unchanged samples are skipped). Keep `MAX_REWIND` well inside that; `Config.MaxBackdate` (1 s) is a
good upper bound.
:::

The client's draw is the server's curve plus a short correction blend and bounded extrapolation, so
the two can differ by a fraction of a stud while a correction is blending out. Give your hitboxes
that much slack.

## Other VMs (Actors)

Tide's server runs in one Luau VM, the one that called `Tide.start` (it owns the remotes). Code in
another VM, such as a venue's Actor, can't call `Tide.at` there. Link the entities it needs instead:

::: code-group

```lua [Tide's VM]
local body = Tide.add(model, "Body")
body:link("Venue1", playerId) -- mirrored into the link "Venue1" under this key (a string or number)
```

```lua [the venue's Actor]
local Link = require(ReplicatedStorage.Tide.Shared.Link)
local venue = Link.open("Venue1")

local cf = venue:at(playerId, seenAt)  -- what Tide.at(model, seenAt) answers in Tide's VM
local newest, t = venue:latest(playerId)

venue:setOwner(playerId, player.UserId) -- applied by Tide's VM at the start of its next frame
venue:teleport(playerId, kickoffSpot)
venue:markTeleport(playerId, spot)      -- for a move this VM makes itself
```

:::

How it works: at the end of each frame Tide's VM copies the new history samples of linked entities into
a `SharedTable` (registered as `"Tide:Venue1"`). The reader copies each sample once into its own ring
and interpolates with the same code as `Tide.at`, so the same samples give the same answer. Intents go
into a queue in the same `SharedTable`, applied in order at the start of Tide's next frame.

Limits:

- A reader sees samples up to one Tide frame later than `Tide.at` would.
- Intents are applied a frame later, with no reply. Read the result back (`Tide.owner` in Tide's VM,
  `venue:latest` here) instead of assuming it. Intents for keys not linked at that time are dropped and
  counted (`linkUnknown`), as are ones that fail (`linkBad`).
- Each mirrored sample costs one `SharedTable` write (a 73-byte string) plus one for the entity's
  newest index; link only what other VMs read.
- `SharedTable`'s cross-VM behaviour (atomic `increment`, what a parallel phase sees of writes made in
  the serial phase) is taken from Roblox's documentation and has not been checked in Studio yet.
