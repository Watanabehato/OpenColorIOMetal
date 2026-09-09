#!/usr/bin/env python3
"""Reference the upstream legacy file readers, retaining actual file formats in tests."""
import json
from pathlib import Path
import PyOpenColorIO as ocio

root = Path(__file__).resolve().parents[1]
fixtures = root / "Tests/OpenColorIOConfigTests/Fixtures/Legacy"
inputs = [[0, 0, 0, 0], [.003, .04, .18, .5], [.18, .5, .8, 1], [.8, .25, .06, .3], [1, 1, 1, 1], [-.1, .2, 2, -.5]]
cases = []
for path in sorted(fixtures.iterdir()):
    for direction in ("forward", "inverse"):
        transform = ocio.FileTransform(src=str(path), interpolation=ocio.INTERP_LINEAR,
            direction=ocio.TRANSFORM_DIR_FORWARD if direction == "forward" else ocio.TRANSFORM_DIR_INVERSE)
        processor = ocio.Config.CreateRaw().getProcessor(transform).getDefaultCPUProcessor()
        expected = [str(float(value)) for pixel in inputs for value in processor.applyRGBA(pixel)]
        cases.append({"file": path.name, "direction": direction, "input": [v for p in inputs for v in p], "expected": expected})
target = fixtures.parent / "legacy-reference.json"
target.write_text(json.dumps({"oracleVersion": ocio.__version__, "cases": cases}, indent=2) + "\n")
print(f"Generated {len(cases)} direct legacy file references from OCIO {ocio.__version__}")
