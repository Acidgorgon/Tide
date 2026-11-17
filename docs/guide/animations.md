# Animations

Roblox replicates `Animator` tracks on its own clock. Tide draws other entities a little in the past
(`now - delay`, usually 50–100 ms) so their movement is smooth, which means a kick or a tackle anim can
start on your screen before the body that plays it gets there.

With the animation channel on, Tide replays animations on the **same timeline as the body**: the owner's
play / stop / speed / weight / seek / priority changes are stamped with server time, and every other
client applies each one when its render clock for that entity reaches the stamp. No game code changes:
Tide watches the `Animator` your code already plays on.

## Turning it on

```lua
-- server
Tide.start({
	players = true,
	animations = true,
	animationFolder = ReplicatedStorage.Assets.Animations, -- optional, see below
})

-- client (optional but recommended: lets the owner swap its Animator at spawn, see below)
Tide.start({ animations = true })
```

The switch is the server's: clients learn it when they join. Opt a kind out with
`Tide.kind("Ball", { animations = false })`; its animations stay Roblox's.

`animationFolder` is a folder of `Animation` instances both sides can see (anywhere under
`ReplicatedStorage`). Its animations get small ids up front, so events carry 2 bytes instead of the asset
URL, and `Tide.play(model, "Kick")` finds them by name. Animations outside the folder still work: the
first time an owner plays one, its id is registered with the server (once) and announced to everyone.

## What happens

**On the owner** (the client for a player's character, the server for a bot or NPC), Tide watches the
entity's `Animator` (under its `Humanoid` or `AnimationController`):

| Your code does | Tide sends |
|---|---|
| `track:Play(fade, weight, speed)` | PLAY, with the fade measured from the weight ramp |
| `track:Stop(fade)`, the track ends, or its weight goes to 0 | STOP, with the fade measured |
| `track:AdjustSpeed(s)` | SPEED |
| `track:AdjustWeight(w, fade)` | WEIGHT |
| `track.TimePosition = t` (a jump of more than 0.05 s) | SEEK |
| `track.Priority = p` | PRIORITY |

`AnimationTrack` doesn't expose fade times, so Tide measures them over the first step (within about
0.03 s). Small, frequent speed and weight changes (the default `Animate` script blends walk and run
every frame) are merged: a big change goes out at once, small ones at most every 0.2 s.

**On every other client**, each animated entity gets the client's own `Animator`. Roblox's replicated
one is destroyed on that client, so tracks Roblox replicates on its own clock no longer show. Events
wait until the entity's render time reaches them, then play on that `Animator`, with the time position
caught up to the render time. A client that joins late, or an entity that comes back inside its
[cull range](/guide/interest), gets a snapshot of what is playing.

**The owner's own Animator.** With `Config.animationsOwnerLocal` (on by default), the owner client
swaps its character's `Animator` for one it creates itself. Roblox doesn't replicate a client-created
`Animator`, so the owner's tracks stop costing bandwidth twice. The swap only happens while nothing
plays on the old `Animator` yet: if game code already plays on it when Tide gets there, Tide leaves it
alone (the stat `animSwapSkipped` counts this), Roblox keeps replicating those tracks, and other
clients still play Tide's copy. To swap at spawn, before the `Animate` script starts, pass
`animations = true` to the client's `Tide.start` too, and start Tide early (`ReplicatedFirst`).

## Exact fades

Fades are measured, so they're close but not exact. Where it matters, play through Tide on the owner
side and the exact fade is sent (and the play is sent once, not measured again):

```lua
-- server, for a bot; or the owning client, for its character
local track = Tide.play(bot, "Slide", 0.05)   -- name under animationFolder, or an Animation
Tide.stop(bot, "Slide", 0.2)
```

## Asking what plays

```lua
-- server: was the tackler in the slide anim when the client saw the hit?
local playing = Tide.playing(tackler, seenAt)
if playing and playing.Slide then
	print(playing.Slide.timePosition)
end

-- client: VFX exactly when the kick starts on this screen
Tide.animated(function(model, op, name, info)
	if op == "play" and name == "Kick" then
		spawnKickDust(model)
	end
end)
```

On a client, `Tide.animated` fires when an event is applied to another entity, in step with its body.
On the server it fires when an event is accepted.

## Limits

- **Rate:** `Config.AnimEventsPerSecond` (60) per player, burst 30. Events over it are dropped and
  reported to [`onSuspicious`](/reference/api#tide-onsuspicious) as `"animRate"`.
- **Ids:** `Config.MaxAnimIds` (1024) in total. A player may send 64 id requests a minute (new or
  already known ids) and register at most `MaxAnimIds / 8` (128) new ids over the server's life, each an
  asset URL (`rbxassetid://<digits>` or `http(s)://...`) of at most 100 characters.
- **Per entity:** 16 tracks tracked at once on the server, 64 events queued on a client;
  `Config.AnimApplyPerFrame` (64) events applied per frame overall.
- **Precision:** fades in 10 ms steps up to 2.55 s, weights in 1/100 up to 2.55, speeds in 1/256,
  time positions in milliseconds up to 65 s.
- Only the `Animator` under the entity's `Humanoid` or `AnimationController` is watched. Animations on
  other `Animator`s (tools, accessories) stay Roblox's.
- Removing an entity from Tide stops the tracks Tide played for it, but the client's own `Animator`
  stays (Roblox's was destroyed on that client).

## Check in Studio first

The mock Tide is tested against can't show some engine behaviour. Before turning this on in a live
game, check in a Studio test server with two clients:

- Other clients' characters animate, in step with their bodies, and nothing plays twice.
- A client-created `Animator` doesn't replicate: with `animationsOwnerLocal`, the server sees no tracks
  on your character.
- Destroying the replicated `Animator` on a client stops Roblox's tracks there, and the client's own
  `Animator` plays on a character it doesn't own.
- Your game code (and the `Animate` script) finds the swapped `Animator` (`Humanoid.Animator`,
  `WaitForChild("Animator")`). If it loads tracks before the swap, set
  `animationsOwnerLocal = false` (or start Tide earlier).
- Fades look right: the measurement assumes `WeightCurrent` ramps linearly.

As with the [lock](/guide/players#the-lock), roll out with the switch off first and compare.
