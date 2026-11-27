# Profiling with Lighthouse

[Lighthouse](https://acidgorgon.github.io/Lighthouse/) is the family's profiler. Tide has its hooks
built in: require Lighthouse and start it on the server and the client, and Tide's bytes and frame
work show up in its overlay under **Tide** with no other setup.

```lua
local Lighthouse = require(ReplicatedStorage.Lighthouse)
Lighthouse.start()
```

Tide reads `shared.Lighthouse` once per frame on each side. Without Lighthouse that lookup and an
`if` at each send and receive are all it costs (no counters, no allocations).

## Network channels

One `net` report per packet; on the server each report carries the player it went to or came from,
so the overlay's top players by bytes include Tide's traffic.

| Channel | Direction | What |
|---|---|---|
| `Relay` | server out, client in | sample packets (`TideU`), one per receiver per frame |
| `Upload` | client out, server in | a client's samples for the entities it owns (`TideU`) |
| `Control` | both ways | adds, removes, owners, teleports, hello and resends (`TideR`) |
| `Anim` | out | animation tables, id replies, play events (v0.2) and timeline state (v0.3), sent together in one reliable message per receiver per frame. Incoming animation messages arrive on `TideR` and count as `Control` |

## Probes

| Probe | Side | Covers |
|---|---|---|
| `Tide.Sample` | server | sampling server-owned entities, teleport retries, the lock |
| `Tide.Relay` | server | encoding new samples and building every receiver's packets |
| `Tide.Receive` | both | one upload (server) or one relay packet (client) |
| `Tide.Upload` | client | sampling and sending the entities this client owns |
| `Tide.Render` | client | drawing remote entities (PreRender) |

## Counters

For [velocity kinds](/guide/physics-bodies) (v0.5), through `Lighthouse.count`. Nothing is counted for
games without one.

| Counter | Side | Counts |
|---|---|---|
| `Tide.Velocity.samples` | server | samples of velocity kinds encoded this frame |
| `Tide.Velocity.samples` | client | velocity records received |
| `Tide.Velocity.bytes` | server | bytes of those records sent, over all receivers (part of the `Relay` channel's total, not on top of it) |
| `Tide.Bump` | server | `Tide.bump` calls |
| `Tide.Flush` | server | `Tide.flush` calls that sent something |

`Tide.stats()` keeps working as before and counts the same bytes (`relayBytes`, `inBytes`,
`uploadBytes`), and the same things as these counters (`velocitySamples`, `velocityBytes`, `bumps`,
`bumpsDeferred` on the server, `velocityRecords` on a client).
