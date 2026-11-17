#!/usr/bin/env python3
"""Tide / Chrono replication benchmark runner.

Single variant:
    python3 run.py <sourceDir> <label> --adapter tide|chrono [options]

Several variants, runs interleaved A,B,A,B,... so machine drift hits all of them equally
(recommended for comparisons):
    python3 run.py --variant tide=tide:../src \\
                   --variant chrono=chrono:/path/to/chrono/src [options]

Options: --runs N (default 5)  --seconds S measured virtual seconds (default 10)
--warmup W virtual seconds before measuring (default 4)  --scenarios a,b
--modes interp,native  --jitters 0,20 (ms, uniform extra one-way delay per packet)
--drop P (unreliable drop rate, default 0)  --cpu N (taskset pin, -1 = off)

For every variant:
1. Build: adapters/<adapter>/build.sh <sourceDir> gen/<label> copies the library into
   gen/<label> (nothing is vendored into the repository).
2. Every (scenario, mode, jitter, run) runs in a fresh luau-bench process:
   interp = -O2 bytecode interpreter, native = -O2 --codegen.
3. results/<label>.json gets, per scenario / mode / jitter, the MEDIAN over runs of every
   metric (raw per-run JSON goes to results/raw/ when --keep-raw is given).

Then `python3 make_results.py` turns results/*.json into RESULTS.md.
"""

import argparse
import datetime
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LUAU_BENCH = os.path.join(HERE, "host", "build", "luau-bench")
MODES = {"interp": ["-O2"], "native": ["-O2", "--codegen"]}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def ensure_host():
    if os.path.exists(LUAU_BENCH):
        return
    if not os.path.exists(os.path.join(HERE, "third_party", "luau-0.700-src")):
        log("fetching Luau 0.700 sources ...")
        subprocess.check_call([os.path.join(HERE, "fetch_luau.sh")])
    log("building luau-bench host ...")
    build = os.path.join(HERE, "host", "build")
    subprocess.check_call(["cmake", "-S", os.path.join(HERE, "host"), "-B", build, "-DCMAKE_BUILD_TYPE=Release"])
    subprocess.check_call(["cmake", "--build", build, "-j4"])


class Variant:
    def __init__(self, label, adapter, source):
        self.label, self.adapter, self.source = label, adapter, os.path.abspath(source)
        self.out_dir = os.path.join(HERE, "gen", label)
        self.results = {}

    def build(self):
        script = os.path.join(HERE, "adapters", self.adapter, "build.sh")
        if not os.path.exists(script):
            raise SystemExit(f"unknown adapter {self.adapter!r}: {script} not found")
        log(f"== building {self.label} ({self.adapter} from {self.source})")
        subprocess.check_call([script, self.source, self.out_dir], stdout=sys.stderr)
        self.source_hash = tree_hash(self.source)


def tree_hash(path):
    """sha256 over every file under path (relative names + contents), to tie results to a source."""
    h = hashlib.sha256()
    for root, dirs, names in os.walk(path):
        dirs.sort()
        for name in sorted(names):
            full = os.path.join(root, name)
            h.update(os.path.relpath(full, path).encode() + b"\0")
            with open(full, "rb") as f:
                h.update(f.read())
    return h.hexdigest()[:16]


def run_once(variant, mode, scenario, args, jitter, seed, cpu):
    pin = ["taskset", "-c", str(cpu)] if cpu is not None and shutil.which("taskset") else []
    cmd = [*pin, LUAU_BENCH, *MODES[mode], os.path.join(HERE, "lib", "run_scenario.luau"),
           HERE, variant.adapter, scenario, variant.out_dir, str(args.seconds), str(args.warmup),
           str(jitter), str(args.drop), str(seed)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    last = res.stdout.strip().splitlines()[-1] if res.stdout.strip() else ""
    data = None
    if last.startswith("{"):
        try:
            data = json.loads(last)
        except json.JSONDecodeError:
            data = None
    if res.returncode != 0 or data is None:
        return None, (res.stderr or res.stdout)[-4000:]
    return data, None


def median_tree(runs):
    """Element-wise median over a list of equally shaped JSON trees."""
    first = runs[0]
    if isinstance(first, dict):
        return {k: median_tree([r[k] for r in runs if isinstance(r, dict) and k in r]) for k in first}
    if isinstance(first, bool) or not isinstance(first, (int, float)):
        return first
    return statistics.median(runs)


def summarize(runs):
    med = median_tree(runs)
    med["spread"] = {
        side: [min(r[side]["us_mean"] for r in runs), max(r[side]["us_mean"] for r in runs)]
        for side in ("server", "observer")
    }
    med["runs"] = len(runs)
    return med


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", nargs="?")
    ap.add_argument("label", nargs="?")
    ap.add_argument("--adapter", default="tide")
    ap.add_argument("--variant", action="append", default=[], metavar="LABEL=ADAPTER:SOURCE")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--warmup", type=float, default=4)
    ap.add_argument("--scenarios", default="")
    ap.add_argument("--modes", default="interp,native")
    ap.add_argument("--jitters", default="0,20")
    ap.add_argument("--drop", type=float, default=0)
    ap.add_argument("--seed", type=int, default=1, help="motion / network seed (same for every run)")
    ap.add_argument("--keep-raw", action="store_true", help="also write every run to results/raw/")
    ap.add_argument("--cpu", type=int, default=(os.cpu_count() or 1) - 1,
                    help="pin benchmark processes to this CPU with taskset (-1 to disable)")
    args = ap.parse_args()

    variants = []
    if args.source and args.label:
        variants.append(Variant(args.label, args.adapter, args.source))
    for spec in args.variant:
        label, rest = spec.split("=", 1)
        adapter, source = rest.split(":", 1)
        variants.append(Variant(label, adapter, source))
    if not variants:
        ap.error("give <sourceDir> <label> or at least one --variant")

    ensure_host()
    with open(os.path.join(HERE, "scenarios", "manifest.json")) as f:
        manifest = json.load(f)["scenarios"]
    if args.scenarios:
        wanted = args.scenarios.split(",")
        unknown = set(wanted) - {s["name"] for s in manifest}
        if unknown:
            ap.error(f"unknown scenarios: {', '.join(sorted(unknown))}")
        manifest = [s for s in manifest if s["name"] in wanted]
    modes = args.modes.split(",")
    jitters = [float(j) for j in args.jitters.split(",")]
    cpu = None if args.cpu < 0 else args.cpu

    for v in variants:
        v.build()

    raw_dir = os.path.join(HERE, "results", "raw")
    failures = 0
    for sc in manifest:
        name = sc["name"]
        for v in variants:
            v.results[name] = {"desc": sc["desc"]}
        for mode in modes:
            for jitter in jitters:
                key = f"jitter_{jitter:g}"
                runs = {v.label: [] for v in variants}
                dead = {}
                for r in range(args.runs):
                    for v in variants:  # interleave variants run by run
                        if v.label in dead:
                            continue
                        data, err = run_once(v, mode, name, args, jitter, args.seed, cpu)
                        if err:
                            dead[v.label] = err  # deterministic: do not repeat
                            continue
                        runs[v.label].append(data)
                        if args.keep_raw:
                            os.makedirs(raw_dir, exist_ok=True)
                            with open(os.path.join(raw_dir, f"{v.label}_{name}_{mode}_{key}_{r}.json"), "w") as f:
                                json.dump(data, f)
                for v in variants:
                    entry = v.results[name].setdefault(mode, {})
                    if v.label in dead:
                        failures += 1
                        entry[key] = {"error": dead[v.label]}
                        log(f"ERROR     {v.label:8s} {name} [{mode} {key}]:\n{dead[v.label]}")
                        continue
                    med = summarize(runs[v.label])
                    entry[key] = med
                    a, n = med["accuracy"]["all"], med["net"]
                    log(f"ok        {v.label:8s} {name:11s} [{mode:6s} j{jitter:<3g}] server {med['server']['us_mean']:7.1f} us"
                        f"  observer {med['observer']['us_mean']:6.1f} us  down {n['observer_down_kbps']:5.1f} KB/s"
                        f"  egress {n['server_egress_kbps']:6.1f} KB/s  err {a['err_mean']:.3f}  delay {a['delay_ms_mean']:5.1f} ms")

    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    for v in variants:
        out = {
            "label": v.label,
            "adapter": v.adapter,
            "source": v.source,
            "source_sha256": v.source_hash,
            "date": datetime.datetime.now().isoformat(timespec="seconds"),
            "host": {"machine": platform.machine(), "cpus": os.cpu_count(), "luau": "0.700 (luau-bench)"},
            "config": {"runs": args.runs, "seconds": args.seconds, "warmup": args.warmup, "modes": modes,
                       "jitters_ms": jitters, "drop": args.drop, "seed": args.seed, "cpu": cpu,
                       "interleaved_with": [o.label for o in variants if o is not v]},
            "scenarios": v.results,
        }
        path = os.path.join(HERE, "results", f"{v.label}.json")
        with open(path, "w") as f:
            json.dump(out, f, indent=1, sort_keys=True)
        log(f"wrote {path}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
