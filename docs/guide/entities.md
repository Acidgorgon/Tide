# Bots and NPCs

Anything the server moves (bots, NPCs, a ball, a platform) is a **server-owned** entity. The server
samples it at its kind's rate and relays the samples; clients draw it exactly like a player.

## Adding one

```lua
local Tide = require(game.ReplicatedStorage.Tide)

local bot = Tide.add(model)          -- kind "Bot"
local npc = Tide.add(villager, "Npc")
```

`model` can be a `Model` or a single `BasePart`. Tide reads the pose from, in order: the part itself,
the model's `PrimaryPart`, a child named `HumanoidRootPart`, or the model's pivot. Parts welded to that
root follow it on clients.

Move the model on the server any way you like (physics, `Humanoid:MoveTo`, `PivotTo`, tweens). Each
server frame Tide samples the entities whose kind is due. A sample that did not change is skipped, with
a keep-alive every `keepAlive` seconds (0.5 s) so clients can tell "standing still" from "packets lost".

Adding a model that is already registered replaces its registration. Destroying the model removes it.

::: info Roblox still replicates the server's copy
The [lock](/guide/players#the-lock) is only for client-owned entities. For a server-owned model Roblox
replicates the server's parts as usual; on each client Tide anchors the root and draws over it every
frame, so what you see is Tide's stream.
:::

## The handle

`Tide.add` returns a handle. You can also get it later with `Tide.handle(model)`.

```lua
bot:teleport(CFrame.new(0, 3, 0)) -- move now and snap on every client (no slide)
bot:setOwner(player)              -- hand it to a player (see below)
bot:alive()                       -- false once removed
bot:remove()
```

A handle stays safe to call after the entity is gone: its methods do nothing.

### Jumps you make yourself

`teleport` flags the move, so every client snaps. A jump made some other way (`model:PivotTo` in game
code, another VM) is sampled like any motion, and clients sweep across it. Two ways to flag it:

```lua
model:PivotTo(spawn)
bot:markTeleport()               -- after the move: sampled now, flagged

bot:markTeleport(spawn)          -- the first sample near spawn in the next second is flagged
Tide.kind("Bot", { teleportDistance = 30 }) -- any jump over 30 studs between two samples
```

## Kinds

A kind is a named set of options shared by many entities. Three are built in:

| Kind | Owner | `rate` | `near` | `far` | `cull` | `buffer` |
|---|---|---|---|---|---|---|
| `"Player"` | client | 60 Hz | 100 | 250 | never | 0.02 s |
| `"Bot"` | server | 30 Hz | 100 | 250 | never | 0.04 s |
| `"Npc"` | server | 15 Hz | 60 | 200 | 400 | 0.07 s |

All three use `rotation = "yaw"`, `farEvery = 2`, `extrapolate = 0.1`. Distances are in studs from the
receiving player's character; see [Interest](/guide/interest).

Make your own (or change a built-in) with `Tide.kind`, on the server, before you add entities of that kind:

```lua
Tide.kind("Ball", {
	rate = 60,
	rotation = "full",  -- send the whole rotation, not just the heading (+4 B per record)
	near = 150,
	far = 400,
	extrapolate = 0.05,
})

Tide.add(ball, "Ball")
```

The server sends each kind's network settings (`rate`, `rotation`, `buffer`, `extrapolate`) to clients,
so you don't repeat them there. Kinds defined after `Tide.start()` are sent to clients too.

### Drawing it yourself

By default a client sets the root's CFrame (`apply = "cframe"`). `apply` is a client-side option, so set
it with `Tide.kind` on the **client**:

```lua
-- client
Tide.kind("Ball", {
	apply = function(model, cf)
		model.CFrame = cf * spinOffset
	end,
})

Tide.kind("Marker", { apply = "none" }) -- Tide moves nothing; read Tide.drawn(model) yourself
```

With a function or `"none"`, Tide does not anchor the root on that client. Errors in your function are
caught and counted in `Tide.stats().applyErrors`.

## Ownership

Any entity can be handed to a player, who then simulates and uploads it like their character (with the
same checks), and handed back:

```lua
ballHandle:setOwner(striker) -- striker's client now uploads the ball
ballHandle:setOwner(nil)     -- back to the server
```

Tide does not change Roblox network ownership. The owning client uploads the pose of *its own copy*, so
make sure that client is the one moving it (for physics, `part:SetNetworkOwner(player)`).

`Tide.owner(model)` and `handle:owner()` say who owns it; `Tide.isMine(model)` says whether this side
simulates it (on the server: server-owned; on a client: owned by this client).

At an owner change, each other client switches the entity to a new source, which by default jumps its
drawing to the new source's delay, and the new owner starts from where Tide drew its copy, a render
delay behind. For entities that change hands often (a ball), turn on `Config.ownerEase` (receivers keep
their clock and ease) and set `Config.ownerStart` to `"latest"` or `"server"` (the new owner starts from
the newest sample or the server's pose). See [Config](/reference/config#owner-changes).

If the owner leaves, the entity goes back to the server automatically. While a player owns it, it is
[locked](/guide/players#the-lock) like a character (when `lockPlayers` is on), and a server
`teleport` goes through the owner as described in [Players](/guide/players#teleports).
