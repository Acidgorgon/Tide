---
layout: home

hero:
  name: Tide
  text: Motion that keeps time
  tagline: Replication for things that move on Roblox. Player characters, bots and NPCs travel in 10-byte records on one server timeline, so what players see is what the server rewinds to.
  image:
    src: /family/tide.svg
    alt: Tide
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: Benchmarks
      link: /benchmarks
    - theme: alt
      text: GitHub
      link: https://github.com/Acidgorgon/Tide

features:
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12c2.5 0 2.5-3 5-3s2.5 3 5 3 2.5-3 5-3 2.5 3 5 3"/><path d="M2 18c2.5 0 2.5-3 5-3s2.5 3 5 3 2.5-3 5-3 2.5 3 5 3"/><path d="M2 6c2.5 0 2.5-3 5-3s2.5 3 5 3 2.5-3 5-3 2.5 3 5 3"/></svg>
    title: 10 bytes per update
    details: "A position (1/64 stud) and a heading packed into 8 bytes, plus a slot and a timestamp: 10 B per record. Each sample is encoded once per frame and copied to every player who should see it."
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>
    title: One timeline
    details: Every sample is stamped in server time. The server keeps the exact samples clients draw, so Tide.at(character, t) answers "where did the shooter see them?" without clock conversions.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/></svg>
    title: Checked, never thrown
    details: Uploads are checked for ownership, NaN, time stamps, speed and byte caps. Bad packets are counted and dropped, never thrown, and onSuspicious tells you who sent them.
---

::: tip Made with Claude
Most of Tide was written with [Claude](https://claude.ai), Anthropic's AI, to speed up my own Roblox workflow. Issues and pull requests are welcome.
:::

## Install

Copy the `src` folder into `ReplicatedStorage` and name it `Tide`. Then start it on both sides:

::: code-group

```lua [server.server.luau]
local Tide = require(game.ReplicatedStorage.Tide)

Tide.start({ players = true })          -- every character is replicated by Tide
local bot = Tide.add(workspace.Bot)     -- a server-owned entity (kind "Bot", 30 Hz)
bot:teleport(CFrame.new(0, 5, 0))       -- snaps for everyone

-- later, in a hit check: where was this character at server time t?
local cf = Tide.at(victim.Character, t)
```

```lua [client.client.luau]
local Tide = require(game.ReplicatedStorage.Tide)

Tide.start()
print(Tide.drawn(someCharacter), Tide.delay(someCharacter))
```

:::

That's all it takes. [Getting started](/guide/getting-started) walks through it, [Players](/guide/players)
explains what happens to characters, and [Time and rewind](/guide/time-and-rewind) shows a hit check.
