#!/usr/bin/env python3
"""Export OCIO's complete built-in catalogue to a pure Metal resource archive.

PyOpenColorIO and NumPy are build-time reference tools only. Every colour-space
pair is requested directly from OCIO; reference-space round-trip composition is
deliberately avoided because it changes data bypass, equality-group, inverse
cancellation and range-clamping semantics. Analytical operations stay in MSL.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

REPOSITORY = "https://github.com/AcademySoftwareFoundation/OpenColorIO"


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(canonical_json(value) + "\n", encoding="utf-8")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def blob(root, folder, suffix, data):
    relative = f"{folder}/{sha256(data)}.{suffix}"
    target = root / relative
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    return relative


def validation_input(np):
    # Deliberately asymmetric colours detect channel/texture-axis swaps. Include
    # negative values, HDR values, logarithm toes and alpha preservation.
    rows = [[0, 0, 0, 0], [1, 1, 1, 1], [.18, .18, .18, .5],
            [1, 0, 0, .2], [0, 1, 0, .4], [0, 0, 1, .6],
            [.01, .2, .8, 1], [.8, .01, .2, 0], [.2, .8, .01, .5],
            [-.01, -.1, -.001, 1], [-.2, .18, 1.2, .75],
            [2, 4, 16, 1], [16, 2, 4, .3], [.00001, .0001, .001, 1],
            [.0031308, .04045, .081, .25], [.5, .25, .75, -1]]
    rng = np.random.default_rng(0x0C10)
    rows.extend(np.column_stack((rng.uniform(0, 1, (24, 3)), rng.uniform(0, 1, 24))).tolist())
    return np.asarray(rows, dtype=np.float32)


def verify_oracle(args, ocio):
    source = args.upstream_source.resolve()
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != args.upstream_sha:
        raise RuntimeError(f"Pinned upstream mismatch: expected {args.upstream_sha}, found {actual}")
    dirty = subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"], text=True)
    if dirty.strip():
        raise RuntimeError("Pinned upstream has modified tracked source files")
    cmake = (source / "CMakeLists.txt").read_text(encoding="utf-8")
    version = re.search(r"project\(OpenColorIO\s+VERSION\s+([0-9.]+)", cmake).group(1)
    module = Path(ocio.__file__).resolve()
    release_eligible = True
    if not ocio.__version__.startswith(version):
        release_eligible = False
    if args.oracle_build_root is None or not module.is_relative_to(args.oracle_build_root.resolve()):
        release_eligible = False
    if not release_eligible and not args.allow_unpinned_oracle:
        raise RuntimeError("Oracle must be compiled from the pinned source and imported from --oracle-build-root. "
                           "A release wheel is only permitted with --allow-unpinned-oracle for development probes.")
    return {"repository": REPOSITORY, "commit": actual, "version": ocio.__version__}, release_eligible


def wrap_kernel(shader, textures):
    """Wrap upstream's MSL free function, preserving its documented argument order."""
    declarations = ["device const float4 *input [[buffer(0)]]",
                    "device float4 *output [[buffer(1)]]",
                    "constant uint &count [[buffer(2)]]"]
    body, call_args = [], []
    for texture in textures:
        index, dimension = texture["bindingIndex"], texture["dimension"]
        name, sampler = texture["name"], texture["samplerName"]
        declarations.append(f"texture{dimension}d<float, access::sample> {name} [[texture({index})]]")
        filt = "nearest" if texture["interpolation"] == "nearest" else "linear"
        body.append(f"    constexpr sampler {sampler}(coord::normalized, address::clamp_to_edge, filter::{filt});")
        call_args.extend((name, sampler))
    declarations.append("uint gid [[thread_position_in_grid]]")
    call_args.append("input[gid]")
    return ("#include <metal_stdlib>\nusing namespace metal;\n" + shader +
            "\nkernel void ocio_kernel(\n    " + ",\n    ".join(declarations) + ") {\n"
            "    if (gid >= count) return;\n" + "\n".join(body) +
            "\n    output[gid] = ocio_transform(" + ", ".join(call_args) + ");\n}\n")


class Exporter:
    def __init__(self, root, ocio, np):
        self.root, self.ocio, self.np = root, ocio, np
        self.transforms = {}
        self.processor_cache = {}
        self.inputs = validation_input(np)
        self.cases, self.failures = [], []
        self.counts = {"pairs": 0, "displayViewDirections": 0, "builtinDirections": 0,
                       "namedTransformDirections": 0, "lookDirections": 0}

    def texture(self, texture, dimension, binding_index):
        ocio = self.ocio
        if dimension == 3:
            width = height = depth = texture.edgeLen
            channels = 3
        else:
            width, height, depth = texture.width, texture.height, 1
            channels = 1 if texture.channel == ocio.GpuShaderDesc.TEXTURE_RED_CHANNEL else 3
        # Values returned by the GPU descriptor are already in GPU storage order:
        # x/blue fastest, then y/green, then z/red. The generated MSL samples
        # with .zyx coordinates. Do not transpose samples or remove that swizzle.
        values = self.np.asarray(texture.getValues(), dtype="<f4").reshape(-1)
        if values.size != width * height * depth * channels:
            raise RuntimeError("LUT size disagrees with upstream texture descriptor")
        interpolation = "nearest" if texture.interpolation == ocio.INTERP_NEAREST else "linear"
        if texture.interpolation not in (ocio.INTERP_NEAREST, ocio.INTERP_LINEAR):
            raise RuntimeError(f"Unexpected GPU texture interpolation {texture.interpolation}")
        return {"name": texture.textureName, "samplerName": texture.samplerName,
                "dimension": dimension, "width": width, "height": height, "depth": depth,
                "channels": channels, "interpolation": interpolation, "bindingIndex": binding_index,
                "data": blob(self.root, "textures", "f32", values.tobytes())}

    def pipeline(self, processor):
        key = processor.getCacheID()
        if key in self.processor_cache:
            return self.processor_cache[key]
        ocio = self.ocio
        # Freeze dynamic controls at the configured default. They are represented
        # analytically in the generated MSL, never by uniform-layout guesses.
        flags = ocio.OptimizationFlags(ocio.OPTIMIZATION_DEFAULT | ocio.OPTIMIZATION_NO_DYNAMIC_PROPERTIES)
        gpu = processor.getOptimizedGPUProcessor(flags)
        if gpu.isNoOp():
            result = []
        else:
            desc = ocio.GpuShaderDesc.CreateShaderDesc()
            desc.setLanguage(ocio.GPU_LANGUAGE_MSL_2_0)
            desc.setFunctionName("ocio_transform")
            desc.setResourcePrefix("ocio_")
            desc.setTextureMaxWidth(4096)
            desc.setAllowTexture1D(True)
            gpu.extractGpuShaderInfo(desc)
            if len(desc.getUniforms()):
                raise RuntimeError("Unexpected uniforms after OPTIMIZATION_NO_DYNAMIC_PROPERTIES")
            textures = []
            for texture in desc.get3DTextures():
                textures.append(self.texture(texture, 3, len(textures)))
            for texture in desc.getTextures():
                # Dimensions, rather than height, distinguishes a 1xN 2D texture.
                dimension = 1 if texture.dimensions == ocio.GpuShaderDesc.TEXTURE_1D else 2
                textures.append(self.texture(texture, dimension, len(textures)))
            source = wrap_kernel(desc.getShaderText(), textures)
            shader = blob(self.root, "shaders", "metal", source.encode("utf-8"))
            definition = {"shader": shader, "kernel": "ocio_kernel", "textures": textures}
            transform_id = sha256(canonical_json(definition).encode("utf-8"))
            self.transforms[transform_id] = {"id": transform_id, **definition}
            result = [transform_id]
        self.processor_cache[key] = result
        return result

    def capture(self, name, kind, make_processor):
        self.counts[kind] += 1
        try:
            processor = make_processor()
            pipeline = self.pipeline(processor)
            # CPU oracle is the direct optimized pair, not a reference composed
            # from the exported stages. Always evaluate even for dedup shaders.
            reference = self.inputs.copy()
            processor.getDefaultCPUProcessor().applyRGBA(reference)
            expected = blob(self.root, "validation", "f32", reference.astype("<f4").tobytes())
            self.cases.append({"name": name, "pipeline": pipeline, "expected": expected,
                               "absoluteTolerance": 0.0005, "relativeTolerance": 0.0002})
            return pipeline
        except Exception as error:
            self.failures.append({"name": name, "kind": kind, "error": str(error)})
            if len(self.failures) <= 10:
                print(f"FAILED {name}: {error}", file=sys.stderr, flush=True)
            return None

    def configuration(self, config_id, ui_name, recommended, configuration=None):
        ocio = self.ocio
        config = configuration or ocio.Config.CreateFromBuiltinConfig(config_id)
        config.validate()
        # Config normally retains every requested processor and its large ACES
        # lookup tables. Exhaustive enumeration must not retain O(N^2) native
        # processors; our small digest cache already deduplicates shader export.
        config.setProcessorCacheFlags(ocio.PROCESSOR_CACHE_OFF)
        active = set(config.getColorSpaceNames())
        spaces = list(config.getColorSpaces(ocio.SEARCH_REFERENCE_SPACE_ALL, ocio.COLORSPACE_ALL))
        metadata = []
        for space in spaces:
            metadata.append({"name": space.getName(), "aliases": list(space.getAliases()),
                             "family": space.getFamily(), "description": space.getDescription(),
                             "isData": space.isData(), "isActive": space.getName() in active,
                             "referenceSpace": "scene" if space.getReferenceSpaceType() == ocio.REFERENCE_SPACE_SCENE else "display",
                             "equalityGroup": space.getEqualityGroup()})
        pairs, display_views = [], []
        names = [space.getName() for space in spaces]
        for source in names:
            for destination in names:
                pipeline = self.capture(f"pair|{config_id}|{source}|{destination}", "pairs",
                                        lambda: config.getProcessor(source, destination))
                if pipeline is not None:
                    pairs.append({"source": source, "destination": destination, "pipeline": pipeline})
        # Explicit view-type enumeration includes inactive and shared views.
        # getViews(display) alone only returns active display views.
        for display in config.getDisplaysAll():
            views = list(dict.fromkeys(list(config.getViews(ocio.VIEW_DISPLAY_DEFINED, display)) +
                                       list(config.getViews(ocio.VIEW_SHARED, display))))
            for view in views:
                for source in names:
                    for direction, enum in (("forward", ocio.TRANSFORM_DIR_FORWARD), ("inverse", ocio.TRANSFORM_DIR_INVERSE)):
                        transform = ocio.DisplayViewTransform(src=source, display=display, view=view)
                        pipeline = self.capture(f"display|{config_id}|{source}|{display}|{view}|{direction}",
                                                "displayViewDirections", lambda: config.getProcessor(transform, enum))
                        if pipeline is not None:
                            display_views.append({"source": source, "display": display, "view": view,
                                                  "direction": direction, "pipeline": pipeline})
        print(f"{config_id}: {len(spaces)} spaces, {len(pairs)}/{len(names)**2} pairs, "
              f"{len(display_views)} display/view directions", flush=True)
        named, looks = self.config_operations(config_id, config)
        return {"id": config_id, "name": ui_name, "description": config.getDescription(),
                "isRecommended": recommended,
                "roleAliases": {role: config.getCanonicalName(space) for role, space in config.getRoles()},
                "colorSpaces": metadata, "conversions": pairs, "displayViews": display_views,
                "namedTransforms": named, "looks": looks}

    def config_operations(self, config_id, config):
        ocio = self.ocio
        named, looks = [], []
        for transform in config.getNamedTransforms(ocio.NAMEDTRANSFORM_ALL):
            definition = {"name": transform.getName(), "description": transform.getDescription(),
                          "aliases": list(transform.getAliases())}
            for direction, enum in (("forward", ocio.TRANSFORM_DIR_FORWARD), ("inverse", ocio.TRANSFORM_DIR_INVERSE)):
                definition[direction] = self.capture(f"named|{config_id}|{transform.getName()}|{direction}",
                    "namedTransformDirections", lambda: config.getProcessor(transform, enum))
            if definition["forward"] is not None and definition["inverse"] is not None:
                named.append(definition)
        for look in config.getLooks():
            process_space = config.getCanonicalName(look.getProcessSpace())
            definition = {"name": look.getName(), "description": look.getDescription(), "processSpace": process_space}
            transform = ocio.LookTransform(src=process_space, dst=process_space, looks=look.getName())
            for direction, enum in (("forward", ocio.TRANSFORM_DIR_FORWARD), ("inverse", ocio.TRANSFORM_DIR_INVERSE)):
                definition[direction] = self.capture(f"look|{config_id}|{look.getName()}|{direction}",
                    "lookDirections", lambda: config.getProcessor(transform, enum))
            if definition["forward"] is not None and definition["inverse"] is not None:
                looks.append(definition)
        return named, looks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--upstream-source", required=True, type=Path)
    parser.add_argument("--upstream-sha", required=True)
    parser.add_argument("--oracle-build-root", type=Path)
    parser.add_argument("--allow-unpinned-oracle", action="store_true", help="Development probe only; releaseEligible is false")
    parser.add_argument("--config", action="append", default=[], type=Path, help="Additional custom .ocio files; built-in configs are always exported")
    args = parser.parse_args()
    import numpy as np
    import PyOpenColorIO as ocio
    upstream, release_eligible = verify_oracle(args, ocio)
    # Active filtering is process-global in OCIO. Remove it before any registry
    # or config creation so user's environment cannot shrink archive coverage.
    for variable in ("OCIO_ACTIVE_DISPLAYS", "OCIO_ACTIVE_VIEWS", "OCIO_INACTIVE_COLORSPACES"):
        os.environ.pop(variable, None)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    exporter = Exporter(output, ocio, np)
    registry = list(ocio.BuiltinConfigRegistry().getBuiltinConfigs())
    configurations = [exporter.configuration(name, ui, recommended) for name, ui, recommended, _ in registry]
    for path in args.config:
        configurations.append(exporter.configuration(str(path), path.stem, False, ocio.Config.CreateFromFile(str(path.resolve()))))
    raw = ocio.Config.CreateRaw()
    raw.setProcessorCacheFlags(ocio.PROCESSOR_CACHE_OFF)
    builtins = []
    for name, description in ocio.BuiltinTransformRegistry().getBuiltins():
        definition = {"name": name, "description": description}
        for direction, enum in (("forward", ocio.TRANSFORM_DIR_FORWARD), ("inverse", ocio.TRANSFORM_DIR_INVERSE)):
            transform = ocio.BuiltinTransform(style=name)
            definition[direction] = exporter.capture(f"builtin|{name}|{direction}", "builtinDirections",
                                                      lambda: raw.getProcessor(transform, enum))
        if definition["forward"] is not None and definition["inverse"] is not None:
            builtins.append(definition)
    default = next((name for name, _, _, is_default in registry if is_default), registry[0][0])
    manifest = {"schemaVersion": 1, "upstream": upstream, "defaultConfiguration": default,
                "configurations": configurations, "builtins": builtins,
                "transforms": sorted(exporter.transforms.values(), key=lambda item: item["id"])}
    validation = {"schemaVersion": 1, "input": exporter.inputs.reshape(-1).tolist(), "cases": exporter.cases}
    coverage = {"schemaVersion": 1, "upstream": upstream, "releaseEligible": release_eligible,
                "complete": not exporter.failures, "failures": exporter.failures,
                "configurationCount": len(configurations), "builtinCount": len(builtins),
                "expectedBuiltinCount": len(ocio.BuiltinTransformRegistry()),
                "colorSpaceCount": sum(len(c["colorSpaces"]) for c in configurations),
                "expected": exporter.counts, "validationCaseCount": len(exporter.cases),
                "uniqueTransformCount": len(exporter.transforms),
                "elapsedSeconds": round(time.monotonic() - started, 3),
                "scope": "All registry built-in configs, active/inactive scene/display/data spaces; every ordered pair; all display/view directions; every built-in/named transform and look direction",
                "metalExecutionVerified": False}
    write_json(output / "manifest.json", manifest)
    write_json(output / "validation.json", validation)
    write_json(output / "coverage.json", coverage)
    print(canonical_json({key: value for key, value in coverage.items() if key != "failures"}), flush=True)
    if exporter.failures:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
