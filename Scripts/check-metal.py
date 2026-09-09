#!/usr/bin/env python3
"""Compile every unique shader using Apple's offline compiler; never claim GPU parity."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("archive", type=Path)
parser.add_argument("--report", type=Path, default=Path("dist/metal-compilation.json"))
parser.add_argument("--workers", type=int, default=3)
args = parser.parse_args()
manifest = json.loads((args.archive / "manifest.json").read_text())
shaders = sorted({entry["shader"] for entry in manifest["transforms"]})
started = time.monotonic()

def compile_shader(shader):
    result = subprocess.run(["xcrun", "-sdk", "macosx", "metal", "-std=metal3.0", "-fsyntax-only", str(args.archive / shader)],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return {"shader": shader, "exitCode": result.returncode, "diagnostics": result.stdout} if result.returncode else None

failures = []
with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
    for index, result in enumerate(executor.map(compile_shader, shaders), 1):
        if result:
            failures.append(result)
            print(json.dumps(result), flush=True)
        if index % 100 == 0 or index == len(shaders):
            print(f"Metal syntax checked {index}/{len(shaders)}, failures={len(failures)}", flush=True)
report = {"kind": "offline-metal-compilation", "gpuExecution": False, "upstream": manifest["upstream"],
          "shadersChecked": len(shaders), "failed": len(failures), "failures": failures,
          "elapsedSeconds": time.monotonic() - started}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, indent=2))
sys.exit(bool(failures))
