# Tide benchmarks

Runs Tide and Strike's patched Chrono 2.2.0 through the same scenarios on a Roblox mock and
compares CPU, allocations, bytes and drawn accuracy. Results: [RESULTS.md](RESULTS.md).

## Running

```sh
cd bench
./fetch_luau.sh            # Luau 0.700 sources -> third_party/ (symlink or crates.io download)
python3 run.py --variant tide=tide:../src \
               --variant tide-defaults=tide-defaults:../src \
               --variant chrono=chrono:/path/to/parihsz_chrono@2.2.0/chrono/src
python3 make_results.py    # results/*.json -> RESULTS.md
```

`run.py` builds the host (`host/build/luau-bench`, CMake) on first use. Options: `--runs 5`,
`--seconds 10` (measured virtual seconds), `--warmup 4`, `--scenarios players_22,bots_22`,
`--modes interp,native`, `--jitters 0,20`, `--drop 0.0`, `--seed 1`, `--cpu N` (taskset pin,
`-1` = off), `--keep-raw` (per-run JSON to `results/raw/`). Variants are interleaved run by run
and every cell is the median over runs. A full default run (3 variants, 5 scenarios, 2 modes,
2 jitters, 5 runs) takes about 30 minutes.

Adapters: `tide` (Tide with Strike's Chrono interest settings mapped onto its tiers, so bytes
compare like for like), `tide-defaults` (Tide's own tier defaults), `chrono` (configured like
Strike). The mapping is documented at the top of `adapters/tide/adapter.luau`.

One run by hand (prints a JSON line):

```sh
host/build/luau-bench -O2 [--codegen] lib/run_scenario.luau . <adapter> <scenario> gen/<label> \
    [seconds=10] [warmup=4] [jitterMs=0] [dropRate=0] [seed=1] [syncErrorMs=0]
```

Chrono is never copied into this repository: `adapters/chrono/build.sh <chronoSrc> <out>` copies
it into `gen/` (gitignored) and adds the files Strike's wally copy lacks (Remotes folder,
`Warn`, `_CUSTOM_MODEL_REP`) from `adapters/chrono/shims/`.

## Layout

- `host/`: the Luau 0.700 host from Ripple's bench (`-O2`, `--codegen`, allocation counters,
  `__gc` control) plus `__setvectormt` (Vector3 methods on native vectors).
- `lib/roblox.luau`: CFrame / Vector3 / Enum / Color3 / Random value types.
- `lib/mock.luau`: a multi-machine Roblox mock on a virtual clock: one server and N clients,
  each with its own instance tree, `os.clock` offset, `task` scheduler and RunService signals;
  eager instance replication; `RemoteEvent` / `UnreliableRemoteEvent` with per-link latency,
  jitter, drop rate, 1000 B unreliable limit and buffer copy at fire time;
  `workspace:GetServerTimeNow`, `BulkMoveTo`, CollectionService, attributes,
  `GetPropertyChangedSignal`, Players with character models (HumanoidRootPart, Humanoid stub,
  Motor6D, welds), `Camera`.
- `lib/motion.luau`: deterministic 480 Hz ground-truth tracks (football players, walkers).
- `lib/run_scenario.luau`: runs one scenario: the server at 60 Hz, clients at 144 fps with
  per-client phase, moves owners' characters along their tracks, times each machine's frame
  phases, counts bytes per link, and scores what the observer draws against the truth.
- `scenarios/`: `players_10/16/22` (client-owned, 97.8 Hz from 144 fps clients, football
  movement on a 360 x 230 pitch, near / mid / far groups around the ball), `bots_22`
  (server-owned 30 Hz, football movement, 10 idle spectators), `npcs_150` (server-owned 20 Hz
  walkers in 500 x 400, 10 idle spectators).
- `adapters/<name>/`: `build.sh <src> <out>` and `adapter.luau` (`startServer(env, rates)`
  returns `{ add(model, kind) }`; `startClient(env, rates)` returns
  `{ renderInfo(model) -> renderTime, domain, latestInfo(model) -> cframe, stamp, domain }`;
  `latestInfo` is optional and feeds the decode check).

## Metrics

See "How to read this" and "Mock biases" in RESULTS.md (written by `make_results.py`). In short:
CPU per frame for the server and one observer client (GC excluded), allocations (raw and with the
mock's CFrame overhead swapped for Roblox's), bytes as payload + 12 B per call, and the drawn
HumanoidRootPart position's error against the truth at the library's own render time, with that
render delay, under 0 and 20 ms jitter. A separate decode check compares each newest decoded
record with the pose the sender sampled (position within 1/64 stud, yaw within 0.5 degrees). Chrono's characters use NATIVE mode (Roblox physics
replication), which the mock does not simulate: Chrono's reported bytes are its own remotes only.
