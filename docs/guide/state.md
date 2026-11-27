# Timeline state

Gameplay state such as "who owns the ball", "the i-frame window ends at t" or "this player is
sliding" usually travels as Roblox attributes. Attributes replicate on Roblox's own clock, so they
show up on a client the moment they arrive. Tide draws other entities a little in the past
(`now - delay`, usually 50–150 ms), so on your screen the ball's owner can change before the drawn
ball reaches the new owner's feet, and an i-frame window can close before the touch that opened it
has been drawn.

Timeline state puts these values on the **same timeline as the body**. The server sets a field, and the
change is stamped with server time. Each client applies it when its clock for that entity reaches the
stamp: the same clock its body and its [animations](/guide/animations) are drawn at. The server keeps
a short history of every field, so a hit check can ask what the value was at the time the player saw.

## Declaring state

Declare the fields of a kind once, in a module both sides require before `Tide.start()`:

```lua
-- ReplicatedStorage/GameState.luau
local Tide = require(ReplicatedStorage.Tide)

Tide.kind("Ball", { motion = false, buffer = 0.1 }) -- state only, see below

Tide.state("Ball", {
	Owner       = { type = "ref", mirror = "Owner", mirrorNil = "" },
	IFrameUntil = { type = "time", mirror = "InteractionIFrameUntil" },
	ShotAt      = "time",                      -- a type name is enough
	SavePressAt = { type = "time", to = "server" },
	Trail       = { type = "event" },
})

Tide.state("Player", {
	SlideAt     = "time",
	Shielding   = { type = "bool", mirror = "Shielding" },
	TackleHitAt = { type = "time", to = "owner" },
})
```

The server's declaration is the one that counts. It is sent to every client when it joins, so a
client decodes exactly what the server encodes, even when it runs older code. If a client declares a
kind differently, Tide warns once and uses the server's version. Kinds without a declaration pay
nothing.

## Setting and reading

Only the server writes. Clients never send state; a client that tries is counted and reported as
`"stateFromClient"`.

```lua
-- server
Tide.set(ball, "Owner", character)               -- stamped now
Tide.set(character, "SlideAt", pressAt, pressAt) -- 4th argument: the stamp
Tide.set(ball, "Owner", nil)                     -- back to the field's default
Tide.fire(ball, "Trail")                         -- an event field
Tide.get(ball, "Owner")                          -- current value
```

A given stamp is clamped to `[now - Config.MaxBackdate, now]` (1 s back). Stamps don't have to be in
order. A stamp older than the field's newest change goes into the history only and doesn't change the
current value. Setting the value a field already has does nothing. Consecutive sets of one entity
with the same stamp travel as one group.

On a client, `Tide.get` returns the value **as drawn**:

```lua
-- client
Tide.get(ball, "Owner")          -- the owner at the time the ball is drawn
Tide.timeOf(ball)                -- the server time the ball (and its state) is drawn at
Tide.peek(ball, "Owner")         -- the newest value received, ahead of the drawing, and its stamp
```

**Compare times against `Tide.timeOf`, not `GetServerTimeNow()`.** Time fields hold absolute server
times. `GetServerTimeNow()` is the server's present, but the entity on your screen is in the past:

```lua
-- before: the window looks closed while the touch that opened it is still being drawn
local protected = ball:GetAttribute("InteractionIFrameUntil") > workspace:GetServerTimeNow()

-- after
local protected = (Tide.get(ball, "IFrameUntil") or 0) > Tide.timeOf(ball)
```

On the server, `Tide.timeOf` is now.

## When a change applies

| Entity, field | Applied |
|---|---|
| another player's character, a bot, an NPC | when `now - Tide.delay(model)` reaches the stamp: with the body |
| an entity with a [clock from game code](#state-only-entities) | when that clock reaches the stamp |
| a state-only entity without a clock | when `now - kind.buffer` reaches the stamp |
| your own entity (your character) | on arrival: its body is drawn at `now` |
| a field with `apply = "arrival"` | on arrival |
| a field with `to = "owner"` | on arrival (only the owner gets it) |

A client's clock for an entity never goes back, so a value it applied is never undone. A change that
arrives after its time has passed applies on the next frame (counted as `stateLate`). A change older
than the value already applied for that field is skipped (`stateStale`). Event fields always fire.

## Field options

| Option | Values | Default | Meaning |
|---|---|---|---|
| `type` | see below | (required) | how the value is stored and sent |
| `default` | a value of the type | `false`, `0`, or `nil` | the value before the first set and after `set(nil)` (not for `ref` and `event`) |
| `to` | `"all"`, `"owner"`, `"others"`, `"server"` | `"all"` | who receives it. `"server"` keeps it on the server only (history and `Tide.get`) |
| `apply` | `"drawn"`, `"arrival"` | `"drawn"` | `"arrival"`: apply as soon as it arrives (for windows whose readers pick their own time) |
| `mirror` | attribute name | none | the client sets this attribute when a change applies ([mirror mode](#mirror-mode)) |
| `mirrorOn` | `"model"`, `"player"` | `"model"` | mirror on the owning `Player` instead of the model |
| `mirrorNil` | string, number or boolean | `nil` | the attribute value written when the field is `nil` |
| `values` | list of strings | | the values of an `enum` (or of an event's `enum` payload) |
| `payload` | a type name, or a table of named members | none | an event's payload ([events](#events)) |
| `history` | number | `Config.StateHistory` (32) | changes of this field kept per entity for `Tide.stateAt` |

| Type | Value | Bytes |
|---|---|---|
| `bool` | boolean | 1 |
| `u8`, `u16`, `i16` | integer in range | 1, 2, 2 |
| `f32`, `f64` | number | 4, 8 |
| `time` | server time | 2 (to 0.5 ms within ±16 s of the change's stamp; else 10) |
| `ref` | another Tide entity (model or handle), or `nil` | 2 |
| `enum` | one of `values`, or `nil` | 1 |
| `yaw` | a horizontal direction (`Vector3`, or an angle in radians) | 2 (0.0055°) |
| `pos`, `vector` | `Vector3` (two names for one type: a position, a velocity, any vector) | 12 |
| `cframe` | `CFrame` (position as `f32`, rotation to under 0.1°) | 16 |
| `event` | no value: `Tide.fire` pulses it, with an optional payload | 0 + payload |

A field's value at its default costs no value bytes. Values are stored on the server exactly as
clients decode them (`f32` rounded, times on the 0.5 ms grid), so `Tide.get` gives the same number on
both sides.

**Refs** must point at Tide entities. On a client a ref reads as the local model. When the referenced
entity goes (`Tide.remove`, the player leaves), every ref to it is set to `nil`, and its history
entries read `nil`.

## Mirror mode

Mirror mode moves existing code over without rewriting its reads. For a field with `mirror`, the client
calls `instance:SetAttribute(mirror, value)` itself when the change applies. A client-side attribute
doesn't replicate, so existing `GetAttribute` and `GetAttributeChangedSignal` code keeps working, and
now sees the value at the drawn time.

- Refs mirror as the referenced model's `Name` (a character's name is its player's name);
  `mirrorNil` gives the value for `nil` (for example `""`).
- Event fields mirror the time of the latest fire.
- **The server must stop writing that attribute.** A server write replicates and overwrites the
  client's value. Server code reads `Tide.get` instead.
- Mirroring is done on the client only. The server never writes attributes for you.

## History

```lua
-- server: was the dribbler protected at the time the tackler saw the ball?
local seen = pressTime - ballViewLag
local untilT = Tide.stateAt(ball, "IFrameUntil", seen)
local framed = untilT ~= nil and seen < untilT
local owner = Tide.stateAt(ball, "Owner", seen)

-- did the shot land on the ball's timeline before the keeper's press?
local shotAt = Tide.changedAt(ball, "ShotAt", keeperSeen, now)
```

`Tide.stateAt(model, field, t)` is the value in effect at server time `t`: the newest change stamped at
or before `t`. Each field keeps its last `history` changes (32 by default). When a change is pushed out,
its value is kept as the base, so answers stay exact back to the oldest change that was pushed out.
`Tide.changedAt(model, field, t0, t1)` returns the stamp of the first change in `(t0, t1]`, or `nil`.

## Events

An `event` field has no value: `Tide.fire` sends a pulse that plays on each client at its stamp, like
an animation event. Use it for things that happen at a moment, such as a trail starting with the drawn
touch.

```lua
Tide.state("Ball", { Trail = { type = "event" }, Skill = { type = "event", payload = "u16" } })

-- server
Tide.fire(ball, "Trail")
Tide.fire(ball, "Skill", skillId)

-- client: in the frame the ball is drawn at the touch
Tide.changed(ball, "Skill", function(skillId, _, t)
	playSkillVfx(ball, skillId)
end)
```

`Tide.get` and `Tide.stateAt` of an event field return the stamp of the latest fire and its payload.

### Payloads with several values

One event often needs more than one value: a kick has a position, a velocity and a kicker. Give the
payload **named members** (v0.5), each a type name or `{ type = "enum", values = { ... } }`:

```lua
Tide.state("Ball", {
	Kick = {
		type = "event",
		payload = {
			Position = "pos",
			Velocity = "vector",
			By = "ref",
			Kind = { type = "enum", values = { "pass", "shot", "header" } },
			PressAt = "time",
		},
	},
})

-- server: the stamp Tide.bump returns puts the event on the ball's change of direction
local stamp = Tide.bump(ball)
Tide.fire(ball, "Kick", { Position = p, Velocity = v, By = character, Kind = "shot" }, stamp)

-- client: when the ball's clock reaches the kick
Tide.changed(ball, "Kick", function(kick, _, t)
	playKickVfx(kick.Position, kick.Velocity, kick.By, kick.Kind)
end)
```

- Members can be any value type (`bool`, the numbers, `time`, `ref`, `enum`, `yaw`, `pos` / `vector`,
  `cframe`); 1 to 32 per payload, no nesting.
- A member you leave out of a fire is its type's default: `false`, `0`, or `nil` (`time`, `ref`, `enum`,
  `yaw`, `pos`, `cframe`), and costs no bytes. An unknown member name or a wrong type is an error.
- Listeners, `Tide.get` and `Tide.stateAt` get a frozen table. `ref` members read as models, and as
  `nil` once that entity is gone; `time` members are absolute server times on the 0.5 ms grid.
- On the wire: 1 byte of presence bits (2 for 9 to 16 members, 4 above), then the values present. The
  kick above with `Position`, `Velocity` and `By` is a 33-byte group (5 header, 1 field, 1 presence,
  12 + 12 + 2).

## Listening

```lua
Tide.changed(model, "Owner", function(value, old, t) end)       -- one field of one model
Tide.stateChanged(function(model, field, value, old, t) end)    -- everything
```

On a client these fire in the frame a change applies. On the server they fire when it is set. Each
call runs in its own thread.

## State-only entities

An entity of a kind with `motion = false` has state but no motion. Tide sends no samples for it,
doesn't draw or anchor it, and never culls it. Use it for something whose motion travels some other
way. (A ball the server simulates can travel with Tide since v0.5, state included: see
[Balls and projectiles](/guide/physics-bodies). `Tide.clock` works for those entities too.)

```lua
-- server
Tide.add(ball, "Ball")

-- client: the ball's state applies at the time your ball renderer draws it
Tide.clock(ball, function(now)
	return now - BallRenderer.drawnLag(ball)
end)
```

Without a clock, state applies at `now - kind.buffer`. `Tide.clock(model, nil)` removes the clock. A
clock that errors or returns no number falls back to the default and is counted as `stateClockErrors`.
Owned by a client (`handle:setOwner(player)`), a state-only entity's state applies on arrival there,
and it uploads nothing.

## Joining, interest and owners

A client that joins late gets a **snapshot** of every entity with state: the values in effect
`Config.StateReplay` (1 s) ago, then every change since. It applies these on its own clocks, so it holds
the same timeline as everyone else. Events from that last second play once.

An entity beyond a client's [cull range](/guide/interest) sends it nothing, state included. When it
comes back in range, the client gets the changes it missed, each once. Any field whose missed changes
are older than `StateReplay` is brought up to date by its value at that time. Interest tiers (near,
mid, far) don't thin state.

When an entity's owner changes, the new owner gets its `to = "owner"` fields, and the old owner gets
its `to = "others"` fields.

## Wire and cost

State goes on the reliable remote (`TideR`), in the **same message** as the frame's animation events:
one call per receiver per frame with anything to say. A change is a 5-byte group header (entity, stamp,
count) plus 1 byte per field and its value. For example, an owner change with its i-frame window
(`Owner`, `IFrameFrom`, `IFrameUntil`, `IFrameBy`) is 5 + 4 × 3 = 17 bytes. See
[Wire format](/reference/wire-format#timeline-state-tider-reliable).

Reliable means a lost packet holds later messages back by about one round trip. Every change carries
its stamp, though, so a late one applies as soon as it arrives instead of at a wrong time.

Sets and the flush on the server, and receiving and applying on a client, allocate nothing in steady
state for refs, numbers, booleans, times and events (`yaw`, `pos` and `cframe` values are `Vector3`s
and `CFrame`s; a payload with members is one table per fire on the server and per receive on a client).

## Limits

- 127 fields per kind; names of 1 to 64 characters; enums of up to 255 values; 32 members per payload.
- 64 changes queued per entity on a client (when full, the oldest applies early: `stateOverflow`);
  `Config.StateApplyPerFrame` (128) applied per frame.
- Stamps: 0.5 ms; `time` values to 0.5 ms within ±16 s of their stamp (else exact, 10 bytes).
- `Tide.set` on something that isn't a Tide entity does nothing (counted as `stateNoEntity`). An
  unknown field or a value of the wrong type is an error.

## Check in Studio first

The mock Tide is tested against can't show some engine behaviour. Before relying on state in a live game,
check in a Studio test server with two clients:

- A client-side `SetAttribute` on a replicated instance doesn't replicate, isn't overwritten while the
  server leaves that attribute alone, and fires `GetAttributeChangedSignal` on that client.
- With a mirrored field, no server script still writes the attribute.
- A `Tide.clock` that reads your renderer's lag gives the time you expect. Tide applies state in
  `PreRender`, so if your renderer updates its lag later in the frame, the clock sees the value from the
  previous frame.
- Bytes in the network stats look like the estimate above.

Roll out behind a switch, as with the [lock](/guide/players#the-lock) and animations, and compare.
