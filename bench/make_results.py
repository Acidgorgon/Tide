#!/usr/bin/env python3
"""Writes RESULTS.md from results/<label>.json (as written by run.py).

    python3 make_results.py [label ...]     (default: every results/*.json: tide, tide-defaults, others)
"""

import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCENARIOS = ["players_10", "players_16", "players_22", "bots_22", "npcs_150"]

NOTES = """\
## How to read this

- **CPU** is wall time per frame of the library's own callbacks on one machine (server: 60 Hz
  frames; clients: 144 fps frames), mean over the measured seconds, then the median over runs.
  "Observer" is client 1, a player in the near group (bots / NPC scenarios: an idle spectator).
  GC is paused inside timed sections and stepped between frames, so CPU excludes collection.
- **Alloc** is bytes allocated per frame inside the timed sections. "Roblox" subtracts the mock's
  CFrame overhead (a mock CFrame is a 12-slot table, 240 B in 2 allocations; a Roblox CFrame is a
  ~72 B userdata) using the count of CFrames created in those sections.
- **Bytes** are payload + 12 B per remote call (both reliable and unreliable). KB = 1024 B.
  "Down" is what the observer receives; "egress" is everything the server sends.
- **Error** is the distance (studs) between the HumanoidRootPart position the observer draws and
  the ground-truth position at the library's own render time (now - delay), scored once per
  observer frame for every moving entity. **Delay** is now minus that render time, i.e. how far
  in the past the drawn pose is. Error at `now` is mostly delay x speed and is in the JSON
  (`err_now_mean`). Near / far splits at 70 studs from the observer.
- Jitter is a uniform 0..J ms extra one-way delay per packet on every link, on top of a fixed
  one-way latency (observer 40 ms, others 25-60 ms). Reliable remotes stay in order; unreliable
  ones can reorder.
- bots_22 and npcs_150 also have 10 idle client-owned spectators (static characters, not scored).
  Bytes a library spends on them appear in those scenarios' "client up" and "down" columns
  (Chrono sends nothing for an unchanged CFrame).

## Mock biases (read before trusting a number)

- Chrono's PLAYER type runs in NATIVE mode: positions of characters normally reach the server and
  the other clients through Roblox physics replication, which the mock does not simulate. The
  harness writes each owner's position onto the server's root after the owner's c2s latency (so
  Chrono's interest grid works), and observers' replicas only move through what Chrono sends.
  **Chrono's bytes are its own remotes only**; on Roblox, physics replication adds its own
  traffic and CPU (in the engine, not Luau) on top. Tide carries characters entirely on its own
  remotes, and every byte is counted.
- Interpreted mock property access (CFrame / Parent / attribute reads, `GetPivot`, `BulkMoveTo`
  bookkeeping) costs more than Roblox's C++ property bridge for cheap reads and less for writes
  that trigger engine work (Roblox's CFrame write moves physics / render state). Libraries that
  touch many instance properties per frame are penalised relative to buffer-only work.
- The virtual clock is constant within a frame, so time-sliced work (Chrono's EntityGrid budget)
  never slices; remotes are delivered at frame boundaries, and instance property replication is
  instant (no Roblox replication batching).
- Welds and physics are inert: anchoring, welds to lockers and `Humanoid` state have no effect.
- Strike's StallDraw / LookAhead / HonestView game code on top of Chrono is not ported.
  Chrono's CHECK_NEW_VERSION stays on (its HttpService call errors inside a pcall at start).
- Rates follow the scenarios for every variant (players 97.8 Hz, bots 30 Hz, NPCs 20 Hz).
  Chrono is configured like Strike. **tide** maps Strike's Chrono interest settings onto Tide's
  tiers: players near 70 with 10 studs hysteresis, every 3rd sample beyond (32.6 Hz; Chrono's far
  relay forwards the newest sample every 2nd server frame = 30 Hz), never culled; bots / NPCs
  every sample within 150, every 2nd to 400, nothing beyond; 96000 B/s per-receiver budget
  (Chrono's 1600 B/frame). Tide's hysteresis is global, so it also applies at 150 / 400 where
  Chrono has none. **tide-defaults** uses Tide's own tiers (players near 100 / far 250,
  bots 100 / 250, NPCs 60 / 200 / cull 400, every 2nd sample beyond near). Buffers are each
  library's own.
- **Decode** compares the newest decoded record (once per new record, at the observer) with the
  pose the sender sampled: the record's stamp is snapped to the sender's frame grid, so wire time
  quantization is not counted as position error. It is separate from the interpolation error.
"""


def load(labels):
    if not labels:
        paths = sorted(glob.glob(os.path.join(HERE, "results", "*.json")))
        labels = [os.path.splitext(os.path.basename(p))[0] for p in paths]
        order = {"tide": 0, "tide-defaults": 1}
        labels.sort(key=lambda l: (order.get(l, 2), l))
    out = []
    for label in labels:
        with open(os.path.join(HERE, "results", f"{label}.json")) as f:
            out.append(json.load(f))
    return out


def get(d, *keys):
    for k in keys:
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d


def fmt(v, digits=1):
    if v is None:
        return "-"
    if isinstance(v, str):
        return v
    return f"{v:.{digits}f}"


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join("---" if i == 0 else "---:" for i in range(len(header))) + "|"]
    for r in rows:
        lines.append("| " + " | ".join(r) + " |")
    return "\n".join(lines)


def run_cell(res, scenario, mode, jitter):
    return get(res, "scenarios", scenario, mode, f"jitter_{jitter:g}")


def main():
    results = load(sys.argv[1:])
    if not results:
        raise SystemExit("no results/*.json")
    cfg = results[0]["config"]
    modes = cfg["modes"]
    jitters = cfg["jitters_ms"]
    j0 = jitters[0]
    acc_mode = "native" if "native" in modes else modes[0]
    out = []
    out.append("# Benchmark results\n")
    out.append(
        f"Generated by `make_results.py` from {', '.join('`results/' + r['label'] + '.json`' for r in results)}. "
        f"{cfg['runs']} runs per cell (median), {cfg['seconds']:g} measured virtual seconds after "
        f"{cfg['warmup']:g} s warm-up, variants interleaved run by run; Luau 0.700, "
        f"{results[0]['host']['machine']}, {results[0]['date']}.\n")
    for r in results:
        sha = f" (tree sha256 `{r['source_sha256']}`)" if r.get("source_sha256") else ""
        out.append(f"- **{r['label']}**: adapter `{r['adapter']}`, source `{r['source']}`{sha}")
    out.append("")
    names = " / ".join(r["label"] for r in results)
    out.append(f"## Headline ({acc_mode}, jitter {j0:g} ms)\n")
    out.append(f"Each cell: {names}.\n")
    def cells(sc, *path, digits=1, scale=1.0):
        vals = []
        for r in results:
            v = get(run_cell(r, sc, acc_mode, j0), *path)
            vals.append(fmt(None if v is None else v * scale, digits))
        return " / ".join(vals)
    rows = []
    for sc in ["players_22", "bots_22", "npcs_150"]:
        rows.append([sc, "bytes per client per second (observer down, KB/s)", cells(sc, "net", "observer_down_kbps")])
        rows.append([sc, "server egress (KB/s)", cells(sc, "net", "server_egress_kbps")])
        rows.append([sc, "server CPU per frame (us)", cells(sc, "server", "us_mean")])
        rows.append([sc, "client CPU per frame (us)", cells(sc, "observer", "us_mean")])
        rows.append([sc, "allocations per frame, server / client (B, Roblox-adjusted)",
                     " / ".join(f"{fmt(get(run_cell(r, sc, acc_mode, j0), 'server', 'alloc_bytes_roblox'), 0)}"
                                f" + {fmt(get(run_cell(r, sc, acc_mode, j0), 'observer', 'alloc_bytes_roblox'), 0)}"
                                for r in results)])
        rows.append([sc, "drawn position error, mean (studs)", cells(sc, "accuracy", "all", "err_mean", digits=3)])
        rows.append([sc, "render delay, mean (ms)", cells(sc, "accuracy", "all", "delay_ms_mean")])
    out.append(table(["scenario", "metric", names], rows))
    out.append("")
    out.append(NOTES)

    # CPU
    out.append(f"## CPU per frame (us, jitter {j0:g} ms)\n")
    header = ["scenario", "library"]
    for m in modes:
        header += [f"server {m}", f"server p95 {m}", f"observer {m}", f"observer p95 {m}"]
    rows = []
    for sc in SCENARIOS:
        for r in results:
            row = [sc, r["label"]]
            for m in modes:
                c = run_cell(r, sc, m, j0)
                row += [fmt(get(c, "server", "us_mean")), fmt(get(c, "server", "us_p95")),
                        fmt(get(c, "observer", "us_mean")), fmt(get(c, "observer", "us_p95"))]
            rows.append(row)
    out.append(table(header, rows))
    out.append("")
    out.append(f"Phase split ({acc_mode}, us/frame): server receive / simulate+send; observer receive / render / sim+heartbeat.\n")
    rows = []
    for sc in SCENARIOS:
        for r in results:
            c = run_cell(r, sc, acc_mode, j0)
            rows.append([sc, r["label"], fmt(get(c, "server", "recv_us")), fmt(get(c, "server", "sim_us")),
                         fmt(get(c, "observer", "recv_us")), fmt(get(c, "observer", "render_us")),
                         fmt(get(c, "observer", "sim_us"))])
    out.append(table(["scenario", "library", "srv recv", "srv sim", "obs recv", "obs render", "obs sim"], rows))
    out.append("")

    # Allocations
    out.append(f"## Allocations per frame ({acc_mode}, jitter {j0:g} ms)\n")
    rows = []
    for sc in SCENARIOS:
        for r in results:
            c = run_cell(r, sc, acc_mode, j0)
            rows.append([sc, r["label"],
                         fmt(get(c, "server", "alloc_bytes"), 0), fmt(get(c, "server", "alloc_bytes_roblox"), 0),
                         fmt(get(c, "server", "allocs"), 1),
                         fmt(get(c, "observer", "alloc_bytes"), 0), fmt(get(c, "observer", "alloc_bytes_roblox"), 0),
                         fmt(get(c, "observer", "allocs"), 1)])
    out.append(table(["scenario", "library", "server B", "server B (Roblox)", "server allocs",
                      "observer B", "observer B (Roblox)", "observer allocs"], rows))
    out.append("")

    # Network
    for jitter in jitters:
        out.append(f"## Bandwidth (KB/s, jitter {jitter:g} ms)\n")
        rows = []
        for sc in SCENARIOS:
            for r in results:
                n = get(run_cell(r, sc, acc_mode, jitter), "net")
                rows.append([sc, r["label"], fmt(get(n, "observer_down_kbps")), fmt(get(n, "client_down_kbps_mean")),
                             fmt(get(n, "server_egress_kbps")), fmt(get(n, "client_up_kbps_mean")),
                             fmt(get(n, "s2c_calls_per_s"), 0)])
        out.append(table(["scenario", "library", "observer down", "client down (mean)", "server egress",
                          "client up (mean)", "s2c calls/s"], rows))
        out.append("")

    # Accuracy
    for jitter in jitters:
        out.append(f"## Accuracy (jitter {jitter:g} ms)\n")
        rows = []
        for sc in SCENARIOS:
            for r in results:
                a = get(run_cell(r, sc, acc_mode, jitter), "accuracy")
                rows.append([sc, r["label"],
                             fmt(get(a, "all", "err_mean"), 3), fmt(get(a, "all", "err_p95"), 3),
                             fmt(get(a, "all", "err_max"), 2),
                             fmt(get(a, "near", "err_mean"), 3), fmt(get(a, "far", "err_mean"), 3),
                             fmt(get(a, "all", "yaw_err_mean_deg"), 2),
                             fmt(get(a, "all", "delay_ms_mean"), 1), fmt(get(a, "all", "delay_ms_p95"), 1),
                             fmt(get(a, "near", "delay_ms_mean"), 1), fmt(get(a, "far", "delay_ms_mean"), 1),
                             fmt(get(a, "drawn_fraction"), 3)])
        out.append(table(["scenario", "library", "err mean", "err p95", "err max", "err near", "err far",
                          "yaw err (deg)", "delay mean (ms)", "delay p95", "delay near", "delay far", "drawn"], rows))
        out.append("")

    out.append(f"## Decode accuracy ({acc_mode}, jitter {j0:g} ms)\n")
    rows = []
    for sc in SCENARIOS:
        for r in results:
            d = get(run_cell(r, sc, acc_mode, j0), "accuracy", "decode")
            rows.append([sc, r["label"], fmt(get(d, "records"), 0), fmt(get(d, "pos_err_mean"), 4),
                         fmt(get(d, "pos_err_p99"), 4), fmt(get(d, "pos_err_max"), 4),
                         fmt(get(d, "pos_within_1_64"), 3), fmt(get(d, "yaw_err_mean_deg"), 3),
                         fmt(get(d, "yaw_err_max_deg"), 3), fmt(get(d, "yaw_within_half_deg"), 3)])
    out.append(table(["scenario", "library", "records", "pos err mean", "pos err p99", "pos err max",
                      "within 1/64 stud", "yaw err mean (deg)", "yaw err max", "within 0.5 deg"], rows))
    out.append("")

    errors = []
    for r in results:
        for sc, entry in r["scenarios"].items():
            for m in modes:
                for jk, cell in (entry.get(m) or {}).items():
                    if isinstance(cell, dict) and "error" in cell:
                        errors.append(f"- {r['label']} {sc} {m} {jk}: `{cell['error'].strip().splitlines()[-1]}`")
                    elif isinstance(cell, dict) and cell.get("warnings"):
                        errors.append(f"- {r['label']} {sc} {m} {jk}: {cell['warnings']:g} warnings")
    if errors:
        out.append("## Errors and warnings\n")
        out.extend(errors)
        out.append("")

    path = os.path.join(HERE, "RESULTS.md")
    with open(path, "w") as f:
        f.write("\n".join(out))
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
