#!/usr/bin/env python3
"""Deterministic LUT fixtures for boundary, inverse and CLF semantics tests."""
import math
import struct
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "Tests/OpenColorIOConfigTests/Fixtures/NativeFiles"


def write_lut(name, rows, dimension=1, attributes="", index_map="", bit_depth="32f"):
    size = len(rows) if dimension == 1 else round(len(rows) ** (1 / 3))
    dims = f"{size} 3" if dimension == 1 else f"{size} {size} {size} 3"
    body = "\n".join(" ".join(format(x, ".9g") for x in row) for row in rows)
    text = (f'<ProcessList id="{name}" version="1.7">\n'
            f'<LUT{dimension}D inBitDepth="{bit_depth}" outBitDepth="32f" {attributes}>\n'
            f'{index_map}<Array dim="{dims}">\n{body}\n</Array>\n'
            f'</LUT{dimension}D>\n</ProcessList>\n')
    (FIXTURES / (name + ".ctf")).write_text(text, encoding="utf-8")


def main():
    FIXTURES.mkdir(parents=True, exist_ok=True)
    write_lut("edge-flat-and-reversal", [[x, y, z] for x, y, z in zip(
        [0, 0, .3, .2, .7, 1, 1], [1, 1, .7, .8, .3, 0, 0], [.4] * 7)])
    write_lut("edge-hue-adjust", [[x * x, x * x, x * x] for x in [0, .1, .3, .6, 1]], attributes='hueAdjust="dw3"')
    write_lut("edge-raw-halfs", [[x, x, x] for x in [0, 11878, 14336, 15360]], attributes='rawHalfs="true"')
    write_lut("edge-index-map", [[x, x, x] for x in [0, .2, .8, 1]], index_map='<IndexMap dim="2">64 @ 0 940 @ 3</IndexMap>\n', bit_depth="10i")
    write_lut("edge-packed-1d", [[(i / 8192) ** 2] * 3 for i in range(8193)])
    half_rows = []
    for bits in range(65536):
        value = struct.unpack('<e', struct.pack('<H', bits))[0]
        if not math.isfinite(value):
            value = -65504 if bits & 32768 else 65504
        mapped = math.copysign(math.log2(1 + abs(value)) / 16, value)
        half_rows.append([mapped] * 3)
    write_lut("edge-half-domain", half_rows, attributes='halfDomain="true"')
    # CLF stores blue fastest. A coupled transform exercises tetrahedron axes.
    cube = []
    for r in [0, .5, 1]:
        for g in [0, .5, 1]:
            for b in [0, .5, 1]:
                cube.append([.04 + .82 * r + .06 * g + .02 * b,
                             .02 + .04 * r + .86 * g + .04 * b,
                             .03 + .03 * r + .05 * g + .83 * b])
    write_lut("edge-coupled-3d", cube, dimension=3, attributes='interpolation="tetrahedral"')
    print("Generated seven LUT edge fixtures")


if __name__ == "__main__":
    main()
