#!/usr/bin/env python3
"""Generate custom-config Metal comparison cases with the installed OCIO oracle."""
import json
from pathlib import Path
import PyOpenColorIO as ocio

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests" / "OpenColorIOConfigTests" / "Fixtures"
PIXELS = [
    [-0.125, -0.001, 0.0, 0.25],
    [0.0031308, 0.018, 0.18, 0.5],
    [0.5, 1.0, 2.0, 0.75],
    [4.0, 16.0, 100.0, 1.0],
    [0.25, 0.6, 0.8, 0.0],
]
TRANSFORMS = {
    "matrix": "!<MatrixTransform> {matrix: [1.2, 0.1, -0.05, 0.03, 0.02, 0.9, 0.1, 0, -0.01, 0.2, 1.1, 0, 0, 0, 0, 1], offset: [0.02, -0.03, 0.04, 0]}",
    "range-clamp": "!<RangeTransform> {min_in_value: -0.1, max_in_value: 1.2, min_out_value: 0.05, max_out_value: 0.95}",
    "range-unclamped": "!<RangeTransform> {style: noClamp, min_in_value: -0.1, max_in_value: 1.2, min_out_value: 0.05, max_out_value: 0.95}",
    "range-min": "!<RangeTransform> {min_in_value: 0.1, min_out_value: 0.1}",
    "range-max": "!<RangeTransform> {max_in_value: 1.0, max_out_value: 1.0}",
    "exponent": "!<ExponentTransform> {value: [2.2, 1.8, 2.4, 1]}",
    "exponent-mirror": "!<ExponentTransform> {value: 2.2, style: mirror}",
    "exponent-pass": "!<ExponentTransform> {value: 2.2, style: pass_thru}",
    "gamma-linear": "!<ExponentWithLinearTransform> {gamma: 2.4, offset: 0.055}",
    "gamma-mirror": "!<ExponentWithLinearTransform> {gamma: [2.4, 2.2, 1.8, 1], offset: [0.055, 0.04, 0.01, 0], style: mirror}",
    "log2": "!<LogTransform> {base: 2}",
    "log10": "!<LogTransform> {base: 10}",
    "log-affine": "!<LogAffineTransform> {base: 10, lin_side_slope: [1.2, 0.9, 1.1], lin_side_offset: [0.02, 0.03, 0.04], log_side_slope: [0.3, 0.4, 0.5], log_side_offset: [0.6, 0.5, 0.4]}",
    "log-camera": "!<LogCameraTransform> {base: 10, lin_side_break: 0.01, lin_side_slope: 5.55, lin_side_offset: 0.052, log_side_slope: 0.247, log_side_offset: 0.385}",
    "log-camera-authored-slope": "!<LogCameraTransform> {base: 10, lin_side_break: 0.01, linear_slope: 5, lin_side_slope: 5.55, lin_side_offset: 0.052, log_side_slope: 0.247, log_side_offset: 0.385}",
    "cdl": "!<CDLTransform> {slope: [1.1, 0.9, 1.2], offset: [0.01, -0.01, 0.02], power: [1.2, 0.8, 1.1], sat: 0.8}",
    "cdl-asc": "!<CDLTransform> {slope: [1.1, 0.9, 1.2], offset: [0.01, -0.01, 0.02], power: [1.2, 0.8, 1.1], sat: 0.8, style: asc}",
    "ec-linear": "!<ExposureContrastTransform> {style: linear, exposure: 1.25, contrast: 1.1, gamma: 0.9, pivot: 0.18}",
    "ec-video": "!<ExposureContrastTransform> {style: video, exposure: -0.5, contrast: 1.3, gamma: 1.1, pivot: 0.2}",
    "ec-log": "!<ExposureContrastTransform> {style: log, exposure: 1.25, contrast: 1.1, gamma: 0.9, pivot: 0.18}",
    "allocation": "!<AllocationTransform> {allocation: uniform, vars: [-0.25, 1.5]}",
    "allocation-lg2": "!<AllocationTransform> {allocation: lg2, vars: [-10, 6, 0.001]}",
    "group-inverse": "!<GroupTransform> {direction: inverse, children: [!<MatrixTransform> {offset: [0.1, 0.2, 0.3, 0]}, !<ExponentTransform> {value: 2.2, style: mirror}]}",
}


def main():
    FIXTURES.mkdir(parents=True, exist_ok=True)
    cases = []
    for name, transform in TRANSFORMS.items():
        yaml = (
            "ocio_profile_version: 2.5\n"
            "environment: {}\n"
            "roles: {default: Linear}\n"
            "colorspaces:\n"
            "  - !<ColorSpace> {name: Linear}\n"
            "  - !<ColorSpace>\n"
            "    name: Encoded\n"
            f"    to_scene_reference: {transform}\n"
        )
        config = ocio.Config.CreateFromStream(yaml)
        for direction, source, destination in [("forward", "Encoded", "Linear"), ("inverse", "Linear", "Encoded")]:
            processor = config.getProcessor(source, destination).getDefaultCPUProcessor()
            inputs = PIXELS
            # Exponentiation overflow does not inform finite numerical accuracy.
            if (name.startswith("log") or name == "allocation-lg2") and direction == "inverse":
                inputs = [[-0.1, 0.0, 0.01, 0.25], [0.1, 0.3, 0.6, 0.5], [0.4, 0.5, 0.8, 1.0]]
            expected = [processor.applyRGBA(pixel) for pixel in inputs]
            cases.append({"name": name + "-" + direction, "yaml": yaml, "source": source, "destination": destination, "input": inputs, "expected": expected})
    output = {"schemaVersion": 1, "oracleVersion": ocio.__version__, "cases": cases}
    target = FIXTURES / "native-reference.json"
    target.write_text(json.dumps(output, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(f"Wrote {len(cases)} custom transform references with OCIO {ocio.__version__}: {target}")


if __name__ == "__main__":
    main()
