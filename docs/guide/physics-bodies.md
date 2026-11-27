# Balls and projectiles

A ball, a puck or a projectile is a **server-owned** entity that physics moves: it flies, bounces, spins,
and gets kicked. A position stream alone is not enough for it. A client that predicts the ball, or draws
it ahead of the bodies, needs the ball's **velocity and spin** at a known server time, and it needs to
hear about a kick in the same frame, not at the next 30 Hz tick.

A kind with `velocity = true` (v0.5) does that. It is opt-in: kinds without it send the same bytes as
before.

```lua
-- shared code, before Tide.start()
Tide.kind("Ball", {
	velocity = true,     -- every sample carries the linear velocity and the spin
	rotation = "full",   -- a ball's whole rotation, not just a heading
	rate = 30,
	near = math.huge,    -- every sample to everyone,
	farEvery = 1,        -- also to players without a character (see Interest below)
	apply = "none",      -- clients don't have Tide move the model: your renderer draws it
	lock = true,         -- Roblox stops replicating the body's motion (check in Studio first)
})
```

```lua
-- server
local ball = Tide.add(ballPart, "Ball")

-- a kick: change the motion, then tell Tide
ballPart.AssemblyLinearVelocity = kickVelocity
ballPart.AssemblyAngularVelocity = kickSpin
local stamp = Tide.bump(ballPart)             -- a sample now, with the new velocity
Tide.fire(ballPart, "Kick", { Position = ballPart.Position, Velocity = kickVelocity, By = character }, stamp)
```

```lua
-- client
local cf, velocity, spin, stamp = Tide.latest(ballPart)          -- the newest sample received
local cf, velocity, spin = Tide.at(ballPart, Tide.timeOf(body))  -- the ball at the time a body is drawn
```

## What a sample carries

The server samples the body on the kind's tick, on the same clock as every other entity: the pose (1/64
stud, the packed rotation), `AssemblyLinearVelocity` and `AssemblyAngularVelocity` of the root part.

| | Resolution | Range before the wide form |
|---|---|---|
| position | 1/64 stud | ±1024 studs around the origin (then +12 B) |
| velocity | 1/32 stud/s | ±1023 studs/s per axis (then 3 × `f32`) |
| spin | 1/64 rad/s | ±511 rad/s per axis (then 3 × `f32`) |

The server's history holds the values **as clients decode them**, so `Tide.at(ball, t)` on the server
and on a client start from the same numbers.

| Record | Bytes |
|---|---|
| in flight, full rotation, velocity and spin | **28** |
| in flight, yaw only | 24 |
| rolling without spin, or spinning in place (one of the two is zero) | 22 |
| at rest (velocity and spin zero), full rotation | 16 |

A ball at rest sends nothing but a keep-alive every `keepAlive` (0.5 s). A velocity that changes while
the pose stands still (a kick, before physics has moved the body) is a new sample.

## Stops: `restRepeats`

The stream is unreliable, and a receiver carries a body on at its last velocity when it hears nothing
(`extrapolate`, or your own renderer's projection). So the one packet that must not be lost is the one
that says the body stopped: without it the ball runs on until the next keep-alive and then comes back.

`restRepeats = n` sends that word again. On each of the next `n` ticks that find the body unchanged,
the relay sends its last three samples once more: the stop sample, the sample that brought the body to
rest (with its teleport and cut flags and its velocity), and the one before it (the last of the motion,
or the rest marker of a body that was bumped while it rested). They are the same samples at the same
times: a client that has them drops the copies before anything looks at them (no second `onSample`,
nothing stored, no effect on the delay), and a client that lost them stores them in their place.

It defaults to **2 for kinds with `velocity = true`** and 0 for every other kind. Measured in the mock
on a ball rolling at 25 studs/s that stops dead and stays still (60 Hz, `keepAlive = 1`, 1000 stops a
row, the worst error in the 0.4 s after the stop at the time Tide draws, and how many stops passed
0.25 studs):

| Loss | `restRepeats = 0` | 1 | 2 | 4 |
|---|---|---|---|---|
| 10 %, 60 ms | 2.09 studs (8) | 2.08 (2) | **0.11 (0)** | 0.10 (0) |
| 10 %, 200 ms | 2.09 (7) | 2.08 (2) | **0.09 (0)** | 0.10 (0) |
| 30 %, 60 ms | 2.09 (104) | 2.09 (40) | **2.08 (5)** | 0.51 (5) |
| 30 %, 200 ms | 2.09 (105) | 2.09 (40) | **2.08 (4)** | 0.53 (2) |

A stop is lost when every packet that carries it is lost: one stop in a hundred at 10 % loss without
repeats (a body that stops dead already sends two samples at rest), one in ten thousand with 2. Raise
it for links worse than that; 8 is the most. What is left with it is a tenth of a stud for a frame or
two: the sample of the stop itself was lost with its two copies, and the path bends into the stop
sample a tick later. A renderer of your own that draws closer behind arrivals than Tide does (one frame
behind, say) is past its newest sample for a frame whenever two packets in a row are lost, whatever is
sent afterwards: up to a frame of travel (0.42 studs here), with or without a stop.

The cost is two packets a stop: 140 B for that ball (the header and three records, 28 + 16 + 16 B,
twice), nothing in flight and nothing at rest. With repeats the keep-alive no longer has to be short to protect stops:
`keepAlive = 1` costs 26 B/s for a resting ball where `keepAlive = 0.1` cost 222 B/s.

Repeats go to every receiver that gets the entity at all (near, mid and far), are not thinned and not
held back by the [byte budget](/guide/interest) (they are charged to it), and never go to receivers
outside the entity's audience or beyond `cull`. Anything new ends them: a tick that finds the body
moved, a bump, a teleport, an owner change, a removal. Keep-alives are not repeated. Plain kinds may
set `restRepeats` too (a door, a platform that must not overshoot); client-owned entities are never
repeated (their owner's uploads have `Config.UploadRedundancy`).

Velocity kinds are server-owned. Giving such an entity an owner (`Tide.add(model, "Ball", player)`,
`handle:setOwner(player)`) is an error: uploads carry no velocity.

## Kicks: `Tide.bump`

```lua
Tide.bump(model) -> number?      -- or handle:bump()
```

Call it right after game code changed the body's motion abruptly: a kick, a catch, a bounce your own
code resolved, a reset. Tide samples the body **now** instead of at the kind's next tick, and for
velocity kinds marks the sample a **cut**: receivers draw a corner there instead of bending the path
through it.

It returns the sample's server time. Use it as the stamp of the `Tide.fire` or `Tide.set` that belongs
to the same moment, so the event and the ball's change of direction land on the same instant of the
timeline. `nil` for entities that are not server-owned motion entities. On a client `Tide.bump` exists
and returns `nil`, so shared code may call it.

When the sample is taken depends on where the call is made in the server's frame:

| Called from | Sampled | Returned stamp |
|---|---|---|
| a remote handler, a `Heartbeat` connection, a resumed thread (physics is not stepping) | at once, with the pose the last frame ended on and the velocity you just set | the last frame's time (1 ms after the entity's newest sample if it was already sampled that frame) |
| between `PreSimulation` and Tide's step of that frame (`Stepped`, `PreSimulation` connections) | at Tide's step of that frame, whatever the kind's tick, with the pose physics ends on | the time of the call (the sample's is within the frame after it) |

Nothing is sent if neither the pose nor the velocity changed since the newest sample. Bumping a kind
without `velocity` gives an out-of-tick sample in the usual record (no cut).

### Kicks made in `Heartbeat`: `Tide.flush`

Tide relays in its own step of the frame, on `PostSimulation`. A bump made after it (a `Heartbeat`
connection, a thread the scheduler resumes late in the frame) is sampled at once but would leave with
the next frame's packet: a frame late. `Tide.flush()` sends what was bumped since the last relay now:

```lua
RunService.Heartbeat:Connect(function()
	detectKicks()     -- sets velocities and calls Tide.bump(ball)
	Tide.flush()      -- once, after them
end)
```

It returns the number of entities it sent. Call it wherever it is convenient: with nothing bumped it
does nothing, in the physics window it does nothing (the frame's own relay is about to run), and
calling it twice sends nothing twice. Audiences, tiers and byte budgets apply as in a frame, and the
bytes are counted once. It is explicit rather than automatic because Tide cannot know when your
`Heartbeat` code has finished: a connection of Tide's own would run before some of yours and after
others. Measured in the mock at 40 ms one-way: a kick in `Heartbeat` reaches the client in 5 frames
without it and in 4 with it, the same as a kick made in `Stepped`.

::: tip Bounces off the world
Tide cannot see a bounce that physics resolves by itself, and you do not need to bump for it. Each
segment between two samples is drawn from the samples' own velocities when they explain the distance
covered; when they don't (the body bounced in between), Tide falls back to the positions alone. The path
then rounds the corner within that one segment. Measured on the mock (30 Hz, bounces and kicks, 30 ms
± 4 ms): never farther than 0.31 studs from the true path, 0.95 studs with 30 % packet loss. Bump the
bounces that matter if you resolve them in code.
:::

## Reading it on a client

```lua
Tide.latest(model) -> CFrame?, Vector3? velocity, Vector3? spin, number? stamp
Tide.at(model, t, extrapolate?) -> CFrame?, Vector3? velocity, Vector3? spin
```

- `Tide.latest` is the newest sample this client received, undelayed, with its server time. This is
  what a predictor starts from: integrate your own physics from `stamp` to the time you draw.
- `Tide.at` is the buffered path at any server time `t`: pose, velocity and spin, interpolated between
  the samples around `t` (a cubic through the samples' velocities, a corner at a cut). After the newest
  sample it holds that sample; pass `extrapolate` (seconds) to continue in a straight line at the
  sample's velocity for at most that long. Tide does not know your gravity, drag or Magnus force:
  predict from `Tide.latest` if you need them.
- Kinds without `velocity` return the `CFrame` alone from both, as before.

To get every sample as it arrives, without polling, set `onSample` on the client:

```lua
-- client
Tide.kind("Ball", {
	onSample = function(model, t, cframe, velocity, spin, cut)
		BallRenderer.push(model, t, cframe, velocity, spin, cut)
	end,
})
```

It runs inside the receive, once per accepted sample, in arrival order (a late packet can deliver an
older `t` after a newer one). `cut` is true for a bumped sample. Don't yield in it. An error is caught
and counted in `applyErrors`. Samples that arrive before the model has streamed in are stored but not
announced; read `Tide.latest` when `Tide.added` fires.

Measured on the mock (ball in flight, 30 Hz, 30 ms ± 4 ms one-way): `Tide.at` at the drawn time is within
0.013 studs and 0.09 studs/s of the true trajectory.

## Drawing it yourself

With `apply = "none"` Tide keeps the stream, the buffer and the clock, and moves nothing: it does not
set the model's CFrame and does not anchor it. For a velocity kind you can set this once in the
**server's** declaration (as above): it travels to clients with the kind, and a client that never set
`apply` for that kind uses it. A client's own `Tide.kind(name, { apply = ... })` still wins.

`Tide.drawn(model)` is still computed each frame (the pose Tide would have drawn at the entity's clock).

### Which clock?

Every entity is drawn at its own server time, and `Tide.timeOf(model)` tells you which:

| Entity | `Tide.timeOf` on a client |
|---|---|
| one this client owns (your character) | now |
| one with a clock from game code, `Tide.clock(model, fn)` | what `fn(now)` returns |
| another player's character | `now - Tide.delay(model)`: that player's own stream |
| a server-owned entity (a bot, the ball) | `now - Tide.delay(model)`: one delay per **kind** |

It never goes back. So there are three honest ways to draw a ball:

```lua
-- 1. On its own clock: the smoothest ball. Other bodies are drawn at slightly different times.
local cf, v, w = Tide.at(ball, Tide.timeOf(ball))

-- 2. On a body's clock: the ball sits exactly where it was when that body was where you see it
--    (a dribble, a catch). Use the body that matters for the frame.
local cf, v, w = Tide.at(ball, Tide.timeOf(carrier))

-- 3. Ahead of the buffer: predict from the newest sample with your own physics.
local cf, v, w, stamp = Tide.latest(ball)
local drawnAt = workspace:GetServerTimeNow() - myLead
local predicted = simulate(cf, v, w, drawnAt - stamp)
Tide.clock(ball, function(now) return now - myLead end) -- the ball's state now applies at that time
```

`Tide.clock` changes only what `Tide.timeOf(model)` answers and when the entity's
[timeline state](/guide/state) applies (a `Kick` event fires when your clock reaches its stamp). It does
not change what `Tide.at` and `Tide.latest` return, and it does not move anything.

## Roblox's own replication

For a server-owned part Roblox replicates its physics as usual. With Tide drawing it, there are then two
streams for the same body; clients that draw from Tide want only one.

`lock = true` on the kind adds a small non-replicated part (`TideLocker`, inside a `Camera` named
`TideLock` under the root, welded to it with a higher `RootPriority`) to each entity of the kind, and
sets the body's network owner to the server. The locker becomes the assembly root; since clients never
receive it, Roblox has no assembly root to replicate the motion against. This is the same trick as the
[player lock](/guide/players#the-lock), without moving anything: physics keeps simulating the body on
the server as before.

::: warning Check in Studio before relying on it
The mock Tide is tested on cannot show Roblox's replication. With a test server and two clients, check:

1. Clients get no native motion: with `apply = "none"` and nothing else drawing, the client's copy of the
   part stays where it was, while `Tide.latest(ball)` keeps moving.
2. The server's simulation is unchanged: rest height, bounce, roll distance, `AssemblyMass` (within
   0.001 of the value without the lock).
3. No `TideLock`, `TideLocker` or `TideWeld` appears under the part on any client.
4. `root:GetNetworkOwner()` stays `nil` on the server through play.
5. Server-side `Touched` and spatial queries against the body still fire and hit.
6. Welds and constraints you add later (a carry weld to a locked character): which part ends up the
   assembly root, and that the body still does not replicate natively.
7. The client's stale copy of the part: locally simulated characters collide with it where it stands.
   Turn its collisions off on clients, or move the copy yourself.
8. An anchored body moved by CFrame on the server: those writes still replicate (property replication,
   not physics).
9. Streaming: a client that streams the body in sees it at a stale pose until you draw it.
:::

Without the lock (the default), or if it does not hold up in your place, Roblox keeps replicating the
part on its own clock, and nothing breaks:

- With the default `apply = "cframe"`, Tide anchors the client's copy and sets its CFrame every frame,
  as it does for [bots](/guide/entities). What you see is Tide's stream.
- With `apply = "none"`, the client's copy of the part follows Roblox's stream. Draw your own visual
  from Tide and hide the replicated part locally (transparency and collisions set on the client), or
  set its CFrame yourself each frame.

Tide does not move the simulated body into a non-replicated container for you: clients bind an entity
by its model instance, so the registered model has to replicate.

## Interest and budget

[Tiers](/guide/interest) thin a stream: beyond `near`, a receiver gets every `farEvery`-th sample, and
a receiver over its byte budget loses mid and far records. Cuts always pass the thinning, and thinned
samples keep their velocity (the path is still drawn from velocities), but the budget can drop a cut
beyond `near`.

For a ball every player watches, set `near = math.huge`: within `near` a record is never thinned and
never dropped for the budget. A player who never had a character and has no
[focus](/guide/interest#without-a-character) has no position and gets everything as "far" whatever
`near` says, so also set `farEvery = 1` (nothing thinned), and give spectators a focus (so the budget
cannot drop the ball for them).

At 30 Hz the ball costs 30 × 28 B = 840 B/s per player in flight, and 32 B/s at rest. Stop repeats
([above](#stops-restrepeats)) reach mid and far receivers whatever the budget.

## Other VMs

A [linked](/guide/time-and-rewind#other-vms-actors) velocity entity mirrors its velocity and spin too:

```lua
local cf, velocity, spin = venue:at(key, t)
local cf, t, velocity, spin = venue:latest(key)
venue:bump(key)   -- Tide.bump, applied at the start of the Tide VM's next frame
```

## Limits

- A client that joins while the ball rests gets its first sample with the next keep-alive (within
  `keepAlive`, 0.5 s).
- Velocity is the root part's assembly velocity. A model without a part (pivot only) has none, and
  cannot be locked.
- A cut that is lost (unreliable stream), and a kick nobody bumped, degrade to the position-only path
  for that segment: bounded by the segment, never flung. A cut that is followed by rest (a placement, a
  catch) goes out again with the stop's repeats, as a cut.
- `Tide.flush` sends samples only. A `Tide.fire` / `Tide.set` made in the same `Heartbeat` connection
  leaves with the next frame's reliable message; stamped with the bump's time it still applies with
  the sample on clients that buffer.
- A sample a client first gets from a repeat arrives one to `restRepeats` ticks later than it would
  have. It is stored in its place in time; when it is the newest the client has, it can raise the
  measured delay a little, like any sample that arrives late. A client that holds nothing as old (it
  has only just met the entity) refuses it, as it refuses any sample older than its buffer (`late`).
- At the very end of a segment that ends in a cut, the reported velocity is the path's own slope, which
  carries the positions' quantization: up to (1/32 stud) / segment length per axis (0.94 studs/s at
  30 Hz, 1.9 at 60 Hz). A cut closer than 12.5 ms behind a sample reports that sample's velocity instead.
  Everywhere else the velocity is blended from the samples' own (1/32 stud/s).
