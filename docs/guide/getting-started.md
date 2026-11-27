# Getting started

Tide replicates things that move: player characters, bots and NPCs. Clients upload their own
character, the server samples the entities it owns, and every player gets compact records it draws on
one shared timeline. This page gets a game running with Tide in a few minutes.

## Install

Tide is one ModuleScript named `Tide` with three folders of child modules. Both the server and the
client require it, so it goes in `ReplicatedStorage`.

::: code-group

```text [Studio]
ReplicatedStorage
└─ Tide              ← the src/ folder as a ModuleScript (init.luau)
   ├─ Client         (Buffer, Client, Receive, Render, State, Upload)
   ├─ Server         (Lock, Receive, Relay, Server, State, Ticker)
   └─ Shared         (Codec, Config, Control, Interp, Kinds, Rig, Ring, Signal)
```

```json [default.project.json (Rojo)]
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Tide": { "$path": "Packages/Tide/src" }
    }
  }
}
```

:::

- **Name it `Tide`.** Any name works for `require`, but the examples on this site use `ReplicatedStorage.Tide`.
- **No package manager yet.** Like Ripple and Anchor, Tide is not on Wally or pesde yet: copy `src/`
  from the [repository](https://github.com/Acidgorgon/Tide) (a git submodule works well with Rojo).
- **Remotes are made for you.** `Tide.start()` on the server creates two remotes inside the module,
  `TideU` (unreliable, positions) and `TideR` (reliable, control). The client waits for them.

## Start the server

```lua
-- ServerScriptService/Tide.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tide = require(ReplicatedStorage.Tide)

Tide.start({ players = true })
```

`players = true` registers every character as the built-in kind `"Player"`, owned by its player, as
soon as it spawns (and removes it when it despawns or the player leaves). Without it, Tide only
replicates what you [`Tide.add`](/reference/api#tide-add) yourself.

Any [Config](/reference/config) field can go in the same table:

```lua
Tide.start({
	players = true,
	origin = Vector3.new(0, 0, 0), -- centre of your map (see the wire format)
	lockPlayers = true,            -- the default
})
```

## Start the client

```lua
-- StarterPlayerScripts/Tide.client.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tide = require(ReplicatedStorage.Tide)

Tide.start()
```

That is the whole setup. The client now uploads its own character, and draws everyone else's.
Other players' characters (and server bots) have their root part anchored on this client and moved
by Tide every frame, just before rendering.

::: tip Connect listeners first
`Tide.added` only fires for entities that arrive after you connect. Connect it before `Tide.start()`
if you want to see every entity, including the ones that already exist when you join.
:::

## Add a bot

```lua
local bot = Tide.add(workspace.Bots.Goalkeeper, "Bot")

-- move it however you like on the server: physics, Humanoid:MoveTo, PivotTo...
bot:teleport(CFrame.new(0, 3, -40)) -- a snap that everyone sees as a snap
bot:remove()                       -- or destroy the model: Tide removes it for you
```

See [Bots and NPCs](/guide/entities) for kinds, rates and handing an entity to a player.

## Read what is drawn

On the client, Tide can tell you exactly where it drew something this frame and how far behind
server time it is drawing it:

```lua
local cf = Tide.drawn(otherCharacter)    -- CFrame drawn this frame, or nil
local delay = Tide.delay(otherCharacter) -- seconds behind server time
local vel = Tide.velocity(otherCharacter)
```

Next: [Players](/guide/players), [Bots and NPCs](/guide/entities),
[Balls and projectiles](/guide/physics-bodies) or [Time and rewind](/guide/time-and-rewind).
