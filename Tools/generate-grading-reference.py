#!/usr/bin/env python3
"""Regenerate analytical grading MSL templates using the development OCIO oracle.

No generated shader contains baked colour samples. Dynamic shader parameters
are supplied by the native Swift grading parameter and spline compiler.
"""
import argparse
import json
from pathlib import Path
import re
import math
import random
import PyOpenColorIO as ocio

MARKER = "// BEGIN GENERATED GRADING MSL TEMPLATES"


def uniform_value(value):
    kind = str(value.type).split(".")[-1]
    method = {"UNIFORM_DOUBLE": "getDouble", "UNIFORM_BOOL": "getBool", "UNIFORM_FLOAT3": "getFloat3",
              "UNIFORM_VECTOR_FLOAT": "getVectorFloat", "UNIFORM_VECTOR_INT": "getVectorInt"}[kind]
    result = getattr(value, method)()
    if hasattr(result, "tolist"):
        return result.tolist()
    if kind == "UNIFORM_FLOAT3":
        return list(result)
    return result


def shader_descriptor(transform):
    desc = ocio.GpuShaderDesc.CreateShaderDesc()
    desc.setLanguage(ocio.GPU_LANGUAGE_MSL_2_0)
    desc.setFunctionName("grading_transform")
    desc.setResourcePrefix("ocio_")
    ocio.Config.CreateRaw().getProcessor(transform).getDefaultGPUProcessor().extractGpuShaderInfo(desc)
    if len(desc.getTextures()) or len(desc.get3DTextures()):
        raise RuntimeError("Grading shader unexpectedly introduced sampled LUTs")
    return desc


def generate_templates():
    templates = {}
    classes = {"primary": ocio.GradingPrimaryTransform, "tone": ocio.GradingToneTransform,
               "rgb": ocio.GradingRGBCurveTransform, "hue": ocio.GradingHueCurveTransform}
    for kind, cls in classes.items():
        for style_name, style in (("log", ocio.GRADING_LOG), ("lin", ocio.GRADING_LIN), ("video", ocio.GRADING_VIDEO)):
            for direction_name, direction in (("forward", ocio.TRANSFORM_DIR_FORWARD), ("inverse", ocio.TRANSFORM_DIR_INVERSE)):
                variants = [""] + ([".bypass"] if kind == "rgb" and style_name == "lin" else []) + ([".draw"] if kind == "hue" else [])
                for variant in variants:
                    transform = cls(style)
                    transform.setDirection(direction)
                    if variant == ".bypass":
                        transform.setBypassLinToLog(True)
                    if variant == ".draw":
                        value = transform.getValue()
                        value.setDrawCurveOnly(True)
                        transform.setValue(value)
                    transform.makeDynamic()
                    desc = shader_descriptor(transform)
                    source = desc.getShaderText()
                    names = [name for name, _ in desc.getUniforms()]
                    lengths = []
                    for name in names:
                        match = re.search(r"\b" + re.escape(name) + r"\[(\d+)\]", source)
                        lengths.append(int(match.group(1)) if match else 0)
                    templates[f"{kind}.{style_name}.{direction_name}{variant}"] = {"source": source, "names": names, "lengths": lengths}
    return templates


def write_swift(path, templates):
    current = path.read_text(encoding="utf-8") if path.exists() else "import Foundation\n"
    prefix = current.split(MARKER)[0].rstrip()
    lines = [prefix, "", MARKER, f"// Generated using OpenColorIO {ocio.__version__}; regenerate with the pinned oracle.",
             "private func gradingShaderTemplate(_ key: String) -> GradingShaderTemplate? {", "    switch key {"]
    for key, template in sorted(templates.items()):
        lines.append(f"    case {json.dumps(key)}:")
        names = ", ".join(json.dumps(name) for name in template["names"])
        lengths = ", ".join(map(str, template["lengths"]))
        lines.append(f"        return GradingShaderTemplate(names: [{names}], lengths: [{lengths}], source: #\"\"\"")
        lines.append(template["source"].rstrip())
        lines.append('"""#)')
    lines.extend(["    default: return nil", "    }", "}", ""])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def generate_fixtures():
    import numpy as np
    rng = random.Random(5192)
    inputs = np.asarray([[0,0,0,0],[.18,.2,.1,.5],[1,0,0,1],[0,1,0,.7],[0,0,1,.2],
                         [-.03,.01,.1,1],[2,4,8,.4],[.001,.003,.03,.6]] +
                        [[rng.random(),rng.random(),rng.random(),rng.random()] for _ in range(16)], dtype=np.float32)
    cases = []
    for kind in ("GradingPrimaryTransform", "GradingToneTransform", "GradingRGBCurveTransform", "GradingHueCurveTransform"):
        for style in ("log", "lin", "video"):
            for variant in range(6):
                parameters = {"style": "linear" if style == "lin" else style}
                if variant and kind == "GradingPrimaryTransform":
                    for key in ("brightness", "contrast", "gamma", "offset", "exposure", "lift", "gain"):
                        base = 1 if key in ("contrast", "gamma", "gain") else 0
                        scale = .35 if base else .08
                        parameters[key] = {"rgb": [base+rng.uniform(-scale,scale) for _ in range(3)], "master":base+rng.uniform(-scale,scale)}
                    parameters["saturation"] = [0,.7,1,1.25,1.4][variant-1]
                    parameters["pivot"] = {"contrast": -.15 if style == "log" else .27, "black": -.1, "white":1.1}
                    if variant == 4: parameters["clamp"] = {"black": -.05, "white": 1.4}
                elif variant and kind == "GradingToneTransform":
                    defaults = {"log":[[.4,.4],[.5,0],[.4,.6],[.3,1],[.4,.5]],
                                "lin":[[0,4],[2,-7],[0,8],[-2,9],[0,8]],
                                "video":[[.4,.4],[.6,0],[.4,.7],[.2,1],[.5,.5]]}[style]
                    for i,key in enumerate(("blacks","shadows","midtones","highlights","whites")):
                        parameters[key] = {"rgb":[rng.uniform(.4,1.6) for _ in range(3)], "master":rng.uniform(.4,1.6),
                                           "center" if i == 2 else "start": defaults[i][0],
                                           "pivot" if i in (1,3) else "width":defaults[i][1]}
                    parameters["s_contrast"] = [.5,.8,1,1.2,1.8][variant-1]
                elif variant and kind == "GradingRGBCurveTransform":
                    for key in ("red","green","blue","master"):
                        xs = [-7,-1,2,7] if style == "lin" else [-.1,.2,.6,1.2]
                        ys = [x+rng.uniform(-.08,.08) for x in xs]
                        parameters[key] = {"control_points":[value for point in zip(xs,ys) for value in point]}
                        if variant == 3: parameters[key]["slopes"] = [.7,1.2,.6,1.4]
                    if style == "lin" and variant == 5: parameters["lintolog_bypass"] = True
                elif variant and kind == "GradingHueCurveTransform":
                    for key in ("hue_hue","hue_sat","hue_lum","lum_sat","sat_sat","lum_lum","sat_lum","hue_fx"):
                        xs = [.03,.27,.53,.79] if key.startswith("hue_") else [-7,-1,2,7] if style == "lin" and key.startswith("lum_") else [0,.3,.65,1]
                        if key in ("hue_hue","sat_sat","lum_lum"): ys = [x+rng.uniform(-.05,.05) for x in xs]
                        else: ys = [(0 if key == "hue_fx" else 1)+rng.uniform(-.2,.2) for _ in xs]
                        parameters[key] = {"control_points":[v for point in zip(xs,ys) for v in point]}
                        if variant == 3: parameters[key]["slopes"] = [.1,.4,.2,.5]
                for inverse in (False,True):
                    current = dict(parameters)
                    if inverse: current["direction"] = "inverse"
                    transform_yaml = f"!<{kind}> " + json.dumps(current)
                    yaml = ("ocio_profile_version: 2.5\nroles: {default: Linear}\ncolorspaces:\n"
                            "  - !<ColorSpace> {name: Linear}\n  - !<ColorSpace>\n    name: Input\n"
                            "    to_scene_reference: " + transform_yaml + "\n")
                    config = ocio.Config.CreateFromStream(yaml)
                    transform = config.getColorSpace("Input").getTransform(ocio.COLORSPACE_DIR_TO_REFERENCE)
                    transform.makeDynamic()
                    desc = shader_descriptor(transform)
                    uniforms = {}
                    for name,value in desc.getUniforms():
                        field = re.sub(r"^ocio_grading_(primary|tone|rgbcurve|huecurve)_", "", name)
                        val = uniform_value(value)
                        uniforms[field] = {"kind":"boolean" if isinstance(val,bool) else "vector" if isinstance(val,list) else "scalar",
                                           "values": [float(val)] if not isinstance(val,list) else val}
                    expected = inputs.copy()
                    ocio.Config.CreateRaw().getProcessor(transform).getDefaultCPUProcessor().applyRGBA(expected)
                    cases.append({"name":f"{kind}.{style}.{variant}.{'inverse' if inverse else 'forward'}", "type":kind,
                                  "inverse":inverse, "parameters":json.dumps(parameters), "uniforms":uniforms, "yaml":yaml,
                                  "input":inputs.reshape(-1).tolist(),
                                  "expected":[str(float(v)) for v in expected.reshape(-1)]})
    return {"schemaVersion":1,"oracleVersion":ocio.__version__,"cases":cases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, default=Path("Sources/OpenColorIOConfig/Grading.swift"))
    parser.add_argument("--template-json", type=Path)
    parser.add_argument("--fixtures", type=Path)
    args = parser.parse_args()
    templates = generate_templates()
    write_swift(args.swift, templates)
    if args.template_json:
        args.template_json.parent.mkdir(parents=True, exist_ok=True)
        args.template_json.write_text(json.dumps(templates), encoding="utf-8")
    if args.fixtures:
        args.fixtures.parent.mkdir(parents=True, exist_ok=True)
        fixtures = generate_fixtures()
        args.fixtures.write_text(json.dumps(fixtures, allow_nan=False), encoding="utf-8")
        print(f"Generated {len(fixtures['cases'])} arbitrary-control CPU/uniform reference cases")
    print(f"Generated {len(templates)} analytical grading templates from OCIO {ocio.__version__}")


if __name__ == "__main__":
    main()
