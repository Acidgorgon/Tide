# Benchmarks

Tide and Strike's patched Chrono 2.2.0 run through the same scenarios on a Roblox mock: a Luau 0.700
host (native codegen) with a multi-machine Roblox mock on a virtual clock. The server runs at
60 Hz and the clients at 144 fps. Each cell is the median of 5 runs of 10 measured seconds, with
the libraries interleaved run by run. The full tables, with interpreter mode, 20 ms jitter, the
10 and 16 player scenarios and the phase splits, are in
[bench/RESULTS.md](https://github.com/Acidgorgon/Tide/blob/main/bench/RESULTS.md).

Tide is measured in two configurations:

- **Tide (matched)** uses the interest settings Strike gives Chrono:
  - Players: every sample within 70 studs (10 studs hysteresis), every 3rd sample beyond that
    (32.6 Hz, against Chrono's 30 Hz far relay), never culled.
  - Bots and NPCs: every sample within 150 studs, every 2nd sample out to 400, nothing beyond.
  - Use this column to compare bytes.
- **Tide (defaults)** uses Tide's own tiers:
  - Players and bots: near 100, far 250.
  - NPCs: near 60, far 200, cull 400.

Every library sends at the scenario's rates: players 97.8 Hz, bots 30 Hz, NPCs 20 Hz.

## Results

Native codegen, no jitter. Bytes include 12 B of overhead per remote call. KB = 1024 B.

| Scenario | Metric | Tide (matched) | Tide (defaults) | Chrono |
|---|---|---:|---:|---:|
| `players_22` | bytes per client per second | 13.8 KB/s | 17.3 KB/s | 20.2 KB/s ¹ |
| `players_22` | server egress | 243 KB/s | 336 KB/s | 392 KB/s ¹ |
| `players_22` | server CPU per frame | 171 µs | 167 µs | 689 µs |
| `players_22` | client CPU per frame | 55 µs | 59 µs | 152 µs |
| `bots_22` | bytes per client per second | 5.6 KB/s | 4.4 KB/s | 6.6 KB/s |
| `bots_22` | server CPU per frame | 49 µs | 52 µs | 187 µs |
| `npcs_150` | bytes per client per second | 19.5 KB/s | 16.1 KB/s | 24.2 KB/s |
| `npcs_150` | server CPU per frame | 194 µs | 216 µs | 569 µs |
| `npcs_150` | client CPU per frame | 208 µs | 201 µs | 746 µs |
| `players_22` | allocations per frame, server / client ² | 1.6 KB / 1.5 KB | 1.6 KB / 1.5 KB | 126 KB / 11 KB |
| `npcs_150` | allocations per frame, server / client ² | 0.1 KB / 11 KB | 0.1 KB / 11 KB | 118 KB / 36 KB |
| `players_22` | drawn position error (mean) | 0.009 studs | 0.006 studs | 0.006 studs |
| `bots_22` | drawn position error (mean) | 0.015 studs | 0.019 studs | 0.057 studs |
| `npcs_150` | drawn position error (mean) | 0.008 studs | 0.009 studs | 0.017 studs |
| `players_22` | render delay (mean) | 123 ms | 115 ms | 131 ms |
| `bots_22` | render delay (mean) | 95 ms | 96 ms | 98 ms |
| `npcs_150` | render delay (mean) | 102 ms | 102 ms | 128 ms |

¹ This is only Chrono's own remotes. Chrono's characters use NATIVE mode, where positions also
travel over Roblox's physics replication. The mock does not simulate that stream, so its bytes and
its engine-side CPU are not counted. Tide carries characters entirely on its own remotes, and all
of those bytes are counted.

² Allocations are Roblox-adjusted: each mock CFrame (a 240 B table) is counted at the size of a
Roblox CFrame (about 72 B). Garbage collection is excluded from CPU.

With 20 ms of jitter, Tide's error stays the same (0.006-0.009 studs in the player scenarios). In
the same scenarios Chrono's error roughly doubles to 0.013 studs. In the player scenarios Tide's
delay grows by about 29 ms and Chrono's by about 35 ms.

### Decode accuracy

The harness checks every record the observer decodes against the pose the sender actually sampled,
separately from interpolation. Tide's positions are quantized to 1/64 stud:

- **Position:** mean error 0.006 studs, max 0.012. All records are within 1/64 stud.
- **Heading:** mean error 0.09°, max 0.18°. All records are within 0.5°.

Chrono sends 32-bit float positions and 16-bit angles, so its records decode almost exactly.
That costs more bytes per record.

## How to read the numbers

- **Bytes per client per second** is what one player's client downloads: the observer, a player
  near the ball.
- **Drawn position error** compares where the observer draws each moving entity with where that
  entity truly was at the library's own render time (now − delay).
- **Render delay** is how far in the past the drawn pose is. Error measured at the present moment
  is mostly delay × speed, so delay is the number to compare for latency.
- In `bots_22` and `npcs_150`, the 10 spectators stand still. Tide sends only keep-alives for
  them, and Chrono sends nothing.

The mock has limits that can move these numbers:

- Property reads and writes are interpreted Luau, not Roblox's C++ bridge.
- The clock does not advance inside a frame, so Chrono's time-sliced grid never slices.
- Remotes are delivered at frame boundaries.
- Welds and physics are inert.
- Strike's game code on top of Chrono (StallDraw, LookAhead, HonestView) is not included.

Treat the CPU columns as relative. In-game numbers will differ.

## Running them

```sh
cd bench
./fetch_luau.sh
python3 run.py --variant tide=tide:../src \
               --variant tide-defaults=tide-defaults:../src \
               --variant chrono=chrono:/path/to/chrono/src
python3 make_results.py    # results/*.json -> RESULTS.md
```

`bench/README.md` lists the options and describes each scenario.
`bench/adapters/tide/adapter.luau` documents how the Chrono settings map onto Tide's tiers.
