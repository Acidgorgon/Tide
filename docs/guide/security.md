# Security

The only thing a client can send Tide is samples for entities **it owns**. Everything it sends is
checked on the server before it is stored or relayed, and the receive path never throws.

## What is checked

Each upload packet, in order:

| Check | Fails when | Result | Counter | `onSuspicious` |
|---|---|---|---|---|
| Byte caps | over `PlayerBytesPerSecond` (8 KB/s, token bucket) or `PlayerBytesPerFrame` (1 KB) | packet dropped | `rate` | no |
| Shape | not a buffer, wrong tag, 0 or more than `MaxUploadCount` (16) records, or truncated | packet dropped (bytes after the last record are counted too) | `badPacket` | `"badPacket"` |
| Owner | the slot is not an entity this player owns | record dropped | `owner` | no |
| Finite | NaN or infinite position, rotation or stamp | record dropped | `nan` | `"nan"` |
| Stamp | clamped to `[arrival - MaxBackdate, arrival + MaxAhead]`; dropped unless newer than the last sample | record dropped | `stamp` | no |
| Spacing | stamp less than half an upload interval (`0.5 / rate`) after the last accepted sample | record dropped | `spacing` | no |
| Speed | moved more than the kind's `maxSpeed` (horizontal, 120 studs/s), `maxRise` (up, 60 studs/s) or `maxFall` (down, 300 studs/s) allows since the last accepted sample (see below) | record dropped | `speed` | `"speed"` |

The time a move may use is the stamp gap, but never more than the server time since the last accepted
upload arrived plus 0.25 s of jitter credit (spent and earned back, not granted per record), and never
more than `max(2 × keepAlive, MaxBackdate)`. Going quiet, or holding stamps in the past and then
jumping to the present, banks no movement. On top of the limits there is a small tolerance (0.5 studs
horizontally and 0.5 vertically) that refills at 2 studs/s, so it absorbs quantization and physics
noise but adds at most 2 studs/s to a sustained speed. If an owner's uploads are rejected for speed
for `Config.SpeedResync` seconds in a row (1 s), the server teleports it back to its last accepted
pose, so an honest client that got flung is not locked out.

<a id="speed"></a>
A sample flagged as a teleport skips the speed check **only** while the server has a teleport pending
for that entity (`handle:teleport` or a server `CFrame`/`PivotTo` write) and it lands within
`TeleportGrantRadius` (4 studs) of the target. Until then the owner's uploads are dropped, and an
owner that ignores the command is reported as `"teleportIgnored"`. See [Players: teleports](/guide/players#teleports).

Positions are stored as the server quantized them, so what is relayed is exactly what was checked.

## Reporting

```lua
Tide.onSuspicious(function(player: Player, reason: string)
	-- reason is "badPacket", "nan", "speed" or "teleportIgnored"
	strikes[player] = (strikes[player] or 0) + 1
	if strikes[player] > 20 then
		player:Kick("Movement check failed")
	end
end)
```

The hook runs in its own thread and is rate limited to 4 calls per second per player (the counters
are not). A lagging but honest client can trip the speed check now and then, so count strikes over
time rather than kicking on the first.

`Tide.stats()` returns the server's counters:

```lua
print(Tide.stats())
-- { packets, samples, badPacket, owner, stamp, nan, speed, rate, errors,
--   relayBytes, relayPackets, budgetDropped }
```

`errors` counts anything that threw inside the receive handlers (it should stay 0).

## Other guarantees

- **Never throws.** Uploads and control messages are validated before they are read and run inside
  `pcall`. A bad packet is a counter, not an error in your output.
- **No client-to-server control besides "ready" and "resend".** Control packets over 512 bytes or with
  unknown tags are dropped. Clients can't add, remove or reassign entities.
- **The lock.** With `lockPlayers` on, Roblox's own position stream for owned characters is switched
  off, so the server's copy only moves to samples that passed these checks.
- **Server-owned entities** have no client input at all.

Tide checks movement, not game rules: it doesn't know about walls, stamina or speed boosts. Set
`maxSpeed` per kind to your game's real top speed, and do game checks (line of sight, cooldowns) in your
own hit handlers.
