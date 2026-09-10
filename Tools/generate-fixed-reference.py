#!/usr/bin/env python3
"""Regenerate native fixed-function MSL equations and CPU/LUT references from the installed exact OCIO build.

This is an offline maintenance/oracle tool; the framework never imports or executes Python/OpenColorIO.
"""
import argparse
import json
import math
import random
import re
from pathlib import Path

import numpy as np
import PyOpenColorIO as ocio
from gpu_corrections import correct_fixed_shader
from oracle_helpers import CPU_REFERENCE_METADATA, cpu_reference

ROOT = Path(__file__).resolve().parents[1]
PARAMETERLESS = [
    "ACES_RED_MOD_03", "ACES_RED_MOD_10", "ACES_GLOW_03", "ACES_GLOW_10", "ACES_DARK_TO_DIM_10",
    "RGB_TO_HSV", "XYZ_TO_xyY", "XYZ_TO_uvY", "XYZ_TO_LUV", "LIN_TO_PQ",
    "RGB_TO_HSY_LIN", "RGB_TO_HSY_LOG", "RGB_TO_HSY_VID",
]
AP0 = [0.7347, 0.2653, 0, 1, 0.0001, -0.077, 0.32168, 0.33767]
REC709 = [0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.329]
P3 = [0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329]
REC2020 = [0.708, 0.292, 0.17, 0.797, 0.131, 0.046, 0.3127, 0.329]


def descriptor(processor):
    shader = ocio.GpuShaderDesc.CreateShaderDesc()
    shader.setLanguage(ocio.GPU_LANGUAGE_MSL_2_0)
    shader.setFunctionName("native_fixed")
    shader.setPixelName("pixel")
    processor.getDefaultGPUProcessor().extractGpuShaderInfo(shader)
    return shader


def regenerate_parameterless(target):
    result = "    private static func parameterlessFixedFunction(style: String, inverse: Bool) -> String? {\n        switch style {\n"
    for short in PARAMETERLESS:
        style = getattr(ocio, "FIXED_FUNCTION_" + short)
        name = ocio.FixedFunctionStyleToString(style).lower()
        result += f'        case "{name}":\n'
        for inverse in [True, False]:
            transform = ocio.FixedFunctionTransform(style)
            transform.setDirection(ocio.TRANSFORM_DIR_INVERSE if inverse else ocio.TRANSFORM_DIR_FORWARD)
            shader = descriptor(ocio.Config.CreateRaw().getProcessor(transform))
            if list(shader.getTextures()) or list(shader.get3DTextures()) or list(shader.getUniforms()):
                raise RuntimeError(f"Parameterless {name} gained external shader dependencies; update native port")
            source = correct_fixed_shader(shader.getShaderText())
            body = source.split("float4 pixel = inPixel;", 1)[1].split("return pixel;", 1)[0].strip()
            if '\\' in body or '"""' in body:
                raise RuntimeError("Shader requires explicit Swift string escaping")
            indent = "                " if inverse else "            "
            result += '            if inverse {\n                return """\n' if inverse else '            return """\n'
            result += "\n".join(indent + line for line in body.splitlines()) + "\n" + indent + '"""\n'
            if inverse:
                result += "            }\n"
    result += "        default: return nil\n        }\n    }"
    original = target.read_text(encoding="utf-8")
    start = original.index("    private static func parameterlessFixedFunction(")
    end = original.index("\n}\n\nextension OCIONativeCompiler {", start)
    updated = original[:start] + result + original[end:]
    updated = re.sub(r"// Parameterless MSL equations (?:extracted verbatim|adapted) from OpenColorIO .*\.",
                     f"// Parameterless MSL equations adapted from OpenColorIO {ocio.__version__}; CPU-equivalent Glow/PQ corrections.", updated)
    target.write_text(updated, encoding="utf-8")


def definitions():
    result = [(short, short, []) for short in PARAMETERLESS]
    result += [(f"REC2100-{gamma}", "REC2100_SURROUND", [gamma]) for gamma in [0.8, 1.2, 1.7]]
    result += [
        ("gamut13-aces", "ACES_GAMUT_COMP_13", [1.147, 1.264, 1.312, 0.815, 0.803, 0.880, 1.2]),
        ("gamut13-custom", "ACES_GAMUT_COMP_13", [1.25, 1.4, 1.6, 0.7, 0.75, 0.8, 2.3]),
        ("gamma-log-hlg", "LIN_TO_GAMMA_LOG", [0, 0.25, 0.5, 1, 0, math.e, 0.17883277, 0.807825590164, 1, -0.07116723]),
        ("double-log", "LIN_TO_DOUBLE_LOG", [10, 0.1, 0.5, -1, -1, -1, 0.2, 1, 1, 1, 0.5, 1, 0]),
    ]
    result += [("JMh-" + name, "ACES_RGB_TO_JMH_20", primaries) for name, primaries in [("AP0", AP0), ("709", REC709), ("P3", P3)]]
    result += [("tone-" + str(peak), "ACES_TONESCALE_COMPRESS_20", [peak]) for peak in [100, 1000, 4000]]
    for peak, primaries, name in [(100, P3, "100-P3"), (1000, REC2020, "1000-2020"), (4000, REC709, "4000-709")]:
        result += [("gamut20-" + name, "ACES_GAMUT_COMPRESS_20", [peak] + primaries),
                   ("output20-" + name, "ACES_OUTPUT_TRANSFORM_20", [peak] + primaries)]
    return result


def test_input(style, inverse):
    rng = random.Random(260909)
    if style in ("ACES_TONESCALE_COMPRESS_20", "ACES_GAMUT_COMPRESS_20") or (style == "ACES_RGB_TO_JMH_20" and inverse):
        return [[0, 0, 0, 1], [50, 0, 359, 0.5], [20, 15, 30, 0], [75, 40, 90, -0.25]] + [
            [rng.uniform(5, 95), rng.uniform(1, 60), rng.uniform(-180, 540), rng.random()] for _ in range(24)
        ]
    if inverse and style in ("LIN_TO_PQ", "LIN_TO_GAMMA_LOG", "LIN_TO_DOUBLE_LOG"):
        return [[0, 0.18, 0.5, 1], [-0.1, 0.001, 0.9, 0.5], [0.1, 0.3, 0.8, 0]] + [
            [rng.uniform(-0.1, 1), rng.uniform(0, 1), rng.uniform(0, 1), rng.random()] for _ in range(24)
        ]
    return [[0, 0, 0, 1], [0.18, 0.18, 0.18, 0.5], [1, 0.2, 0.02, 0], [-0.1, 0.4, 2, -0.25]] + [
        [rng.uniform(-0.1, 3), rng.uniform(0.001, 3), rng.uniform(0.001, 3), rng.random()] for _ in range(24)
    ]


def texture_references(shader):
    values = []
    for texture in shader.getTextures():
        channels = 1 if texture.channel == ocio.GpuShaderDesc.TEXTURE_RED_CHANNEL else 3
        values.append({"channels": channels, "width": texture.width, "height": texture.height,
                       "values": np.asarray(texture.getValues(), dtype=np.float32).reshape(-1).tolist()})
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-templates", action="store_true", help="Only regenerate CPU/LUT fixtures")
    args = parser.parse_args()
    supported = {"FIXED_FUNCTION_" + style for _, style, _ in definitions()}
    upstream_unimplemented = {"FIXED_FUNCTION_ACES_GAMUTMAP_02", "FIXED_FUNCTION_ACES_GAMUTMAP_07"}
    declared = {name for name in dir(ocio) if name.startswith("FIXED_FUNCTION_")}
    if declared != supported | upstream_unimplemented:
        raise RuntimeError(f"Fixed-function registry changed; port added/missing styles before release: {declared ^ (supported | upstream_unimplemented)}")
    if not args.skip_templates:
        regenerate_parameterless(ROOT / "Sources/OpenColorIOConfig/FixedFunctions.swift")
    cases = []
    for name, short, params in definitions():
        style = ocio.FixedFunctionStyleToString(getattr(ocio, "FIXED_FUNCTION_" + short))
        transform = f"!<FixedFunctionTransform> {{style: {style}"
        if params:
            transform += ", params: " + json.dumps(params)
        transform += "}"
        yaml = ("ocio_profile_version: 2.5\nenvironment: {}\nroles: {default: Linear}\ncolorspaces:\n"
                "  - !<ColorSpace> {name: Linear}\n  - !<ColorSpace>\n    name: Encoded\n"
                f"    to_scene_reference: {transform}\n")
        config = ocio.Config.CreateFromStream(yaml)
        for inverse in [False, True]:
            source, destination = ("Linear", "Encoded") if inverse else ("Encoded", "Linear")
            processor = config.getProcessor(source, destination)
            cpu = cpu_reference(processor)
            inputs = test_input(short, inverse)
            expected = [cpu.applyRGBA(pixel) for pixel in inputs]
            if not np.isfinite(expected).all():
                raise RuntimeError(f"Nonfinite fixed reference {name}, inverse={inverse}; choose a meaningful finite-domain fixture")
            cases.append({"name": name + ("-inverse" if inverse else "-forward"), "style": style,
                          "yaml": yaml, "source": source, "destination": destination,
                          "input": inputs, "expected": expected, "textures": texture_references(descriptor(processor)),
                          "absoluteTolerance": 0.001 if short.startswith("ACES_") else 0.0001,
                          "relativeTolerance": 0.0005})
    target = ROOT / "Tests/OpenColorIOConfigTests/Fixtures/fixed-reference.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = {"schemaVersion": 1, "oracleVersion": ocio.__version__, "cpuReference": CPU_REFERENCE_METADATA,
               "validationMetrics": {"neutralJMh": "When M <= absoluteTolerance, compare M*cos(h) and M*sin(h) with unchanged color-coordinate tolerances; hue is undefined at M=0.",
                                     "nonneutralJMh": "Compare hue in degrees modulo 360 with the original angular tolerance."},
               "supportedStyleCount": len(supported),
               "cases": cases}
    target.write_text(json.dumps(payload, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(f"Generated {len(cases)} fixed-function CPU/LUT cases from OCIO {ocio.__version__}: {target}")


if __name__ == "__main__":
    main()
