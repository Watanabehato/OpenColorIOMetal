#!/usr/bin/env python3
"""Export a compact custom-config archive for actual CPU/Metal regression tests.

The shipped catalogue contains standard OCIO spaces. This separate development
archive exercises custom Hue curves, video luminance, inverse periodic HueFX,
HSY bypass, custom slopes, mixed linear/video groups, and every direct space pair.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import PyOpenColorIO as ocio
from audit_catalogue import audit
from export_catalogue import Exporter, verify_oracle, write_json

FIXTURE = Path(__file__).parent / "Fixtures" / "hue-regression.ocio"


def generate(output, upstream):
    output = Path(output)
    exporter = Exporter(output, ocio, np)
    config = ocio.Config.CreateFromFile(str(FIXTURE.resolve()))
    identifier = "test://hue-regression"
    configuration = exporter.configuration(identifier, "Hue regression", False, config)
    if exporter.failures:
        raise RuntimeError(exporter.failures)
    manifest = {"schemaVersion": 1, "upstream": upstream, "defaultConfiguration": identifier,
                "configurations": [configuration], "builtins": [],
                "transforms": sorted(exporter.transforms.values(), key=lambda item: item["id"])}
    coverage = {"schemaVersion": 1, "upstream": upstream, "releaseEligible": False,
                "complete": True, "failures": [], "configurationCount": 1, "builtinCount": 0,
                "expectedBuiltinCount": 0, "colorSpaceCount": len(configuration["colorSpaces"]),
                "expected": exporter.counts, "validationCaseCount": len(exporter.cases),
                "uniqueTransformCount": len(exporter.transforms), "metalExecutionVerified": False,
                "scope": "Development-only custom Hue shader differential archive"}
    write_json(output / "manifest.json", manifest)
    write_json(output / "coverage.json", coverage)
    write_json(output / "validation.json", {"schemaVersion": 1, "input": exporter.inputs.reshape(-1).tolist(),
                                           "cases": exporter.cases})
    return audit(output, require_release=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--upstream-source", type=Path, required=True)
    parser.add_argument("--oracle-build-root", type=Path)
    parser.add_argument("--allow-unpinned-oracle", action="store_true")
    args = parser.parse_args()
    args.upstream_sha = json.loads((Path(__file__).parent.parent / "UPSTREAM.json").read_text())["commit"]
    upstream, _ = verify_oracle(args, ocio)
    print(json.dumps(generate(args.output, upstream), sort_keys=True))


if __name__ == "__main__":
    main()
