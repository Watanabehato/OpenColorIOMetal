#!/usr/bin/env python3
"""Independently audit archive completeness, direct pair coverage and resource integrity.

This is structural evidence, not a substitute for executing Metal against the
CPU oracle using `ocio-metal validate` on a machine with a Metal device.
"""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import re


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def audit(root, require_release=True, compare_registry=False):
    root = Path(root).resolve()
    manifest = read_json(root / "manifest.json")
    coverage = read_json(root / "coverage.json")
    validation = read_json(root / "validation.json")
    def check(condition, message):
        if not condition:
            raise ValueError(message)
    check(manifest["schemaVersion"] == coverage["schemaVersion"] == validation["schemaVersion"] == 1,
          "Unsupported schema")
    check(coverage["complete"] and not coverage["failures"], "Export reported missing conversions")
    check(not require_release or coverage["releaseEligible"], "Development oracle may not be released")
    check(manifest["upstream"] == coverage["upstream"], "Provenance mismatch")
    checked_files = set()
    def resource(path, expected_size=None):
        resolved = (root / path).resolve()
        check(resolved.is_relative_to(root), f"Resource escapes archive: {path}")
        check(resolved.is_file(), f"Missing resource: {path}")
        if expected_size is not None:
            check(resolved.stat().st_size == expected_size, f"Resource byte count mismatch: {path}")
        if path not in checked_files:
            digest = hashlib.sha256(resolved.read_bytes()).hexdigest()
            check(resolved.stem == digest, f"Resource content hash mismatch: {path}")
            checked_files.add(path)
        return resolved
    definitions = {}
    for transform in manifest["transforms"]:
        check(transform["id"] not in definitions, "Duplicate transform ID")
        definition = {key: value for key, value in transform.items() if key != "id"}
        encoded = json.dumps(definition, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        check(hashlib.sha256(encoded).hexdigest() == transform["id"], "Transform hash mismatch")
        definitions[transform["id"]] = transform
        source = resource(transform["shader"]).read_text(encoding="utf-8")
        check("kernel void ocio_kernel(" in source, "Missing compute entry point")
        slots = re.findall(r"\[\[texture\((\d+)\)\]\]", source)
        check(list(map(int, slots)) == list(range(len(transform["textures"]))), "Texture binding mismatch")
        for index, texture in enumerate(transform["textures"]):
            check(texture["bindingIndex"] == index, "Nonsequential texture binding")
            check(texture["dimension"] in (1, 2, 3), "Invalid texture dimension")
            check(texture["channels"] in (1, 3, 4), "Invalid texture channels")
            check(texture["interpolation"] in ("nearest", "linear"), "Invalid texture interpolation")
            resource(texture["data"], 4 * texture["width"] * texture["height"] * texture["depth"] * texture["channels"])
    case_pipelines = {}
    configurations = {}
    def add_case(name, pipeline):
        check(name not in case_pipelines, f"Duplicate case {name}")
        check(all(t in definitions for t in pipeline), f"Unknown transform in {name}")
        case_pipelines[name] = pipeline
    total_pairs = 0
    for config in manifest["configurations"]:
        identifier = config["id"]
        check(identifier not in configurations, "Duplicate config ID")
        configurations[identifier] = config
        names = {space["name"] for space in config["colorSpaces"]}
        check(len(names) == len(config["colorSpaces"]), "Duplicate color-space name")
        check(set(config["roleAliases"].values()) <= names, "Role references missing space")
        expected_pairs = set(itertools.product(names, repeat=2))
        actual_pairs = {(p["source"], p["destination"]) for p in config["conversions"]}
        check(actual_pairs == expected_pairs and len(config["conversions"]) == len(expected_pairs),
              f"Incomplete/duplicate ordered pairs in {identifier}")
        total_pairs += len(actual_pairs)
        for pair in config["conversions"]:
            add_case(f"pair|{identifier}|{pair['source']}|{pair['destination']}", pair["pipeline"])
        for view in config["displayViews"]:
            check(view["source"] in names, "View references unknown input")
            check(view["direction"] in ("forward", "inverse"), "Invalid view direction")
            add_case(f"display|{identifier}|{view['source']}|{view['display']}|{view['view']}|{view['direction']}", view["pipeline"])
    check(manifest["defaultConfiguration"] in configurations, "Missing default config")
    for builtin in manifest["builtins"]:
        for direction in ("forward", "inverse"):
            add_case(f"builtin|{builtin['name']}|{direction}", builtin[direction])
    check(len(manifest["builtins"]) == coverage["expectedBuiltinCount"], "Missing builtin transform")
    check(total_pairs == coverage["expected"]["pairs"], "Pair coverage count mismatch")
    expected_size = len(validation["input"]) * 4
    check(expected_size > 0 and len(validation["input"]) % 4 == 0, "Invalid RGBA input vectors")
    seen_cases = set()
    for case in validation["cases"]:
        check(case["name"] not in seen_cases, "Duplicate oracle case")
        check(case["name"] in case_pipelines, f"Unknown oracle case {case['name']}")
        check(case["pipeline"] == case_pipelines[case["name"]], "Oracle pipeline differs from manifest")
        check(case["absoluteTolerance"] > 0 and case["relativeTolerance"] > 0, "Invalid oracle tolerance")
        resource(case["expected"], expected_size)
        seen_cases.add(case["name"])
    check(seen_cases == set(case_pipelines), "Missing direct CPU reference vectors")
    check(len(seen_cases) == coverage["validationCaseCount"] == sum(coverage["expected"].values()), "Coverage case count mismatch")
    check(len(definitions) == coverage["uniqueTransformCount"], "Transform count mismatch")
    if compare_registry:
        import PyOpenColorIO as ocio
        expected_configs = set(ocio.BuiltinConfigRegistry())
        check(expected_configs <= configurations.keys(), "Missing upstream registry configuration")
        check({b["name"] for b in manifest["builtins"]} == set(ocio.BuiltinTransformRegistry()), "Builtin registry mismatch")
        for identifier in expected_configs:
            config = ocio.Config.CreateFromBuiltinConfig(identifier)
            spaces = set(config.getColorSpaceNames(ocio.SEARCH_REFERENCE_SPACE_ALL, ocio.COLORSPACE_ALL))
            check(spaces == {s["name"] for s in configurations[identifier]["colorSpaces"]}, "Color-space registry mismatch")
            expected_views = set()
            for display in config.getDisplaysAll():
                views = set(config.getViews(ocio.VIEW_SHARED, display)) | set(config.getViews(ocio.VIEW_DISPLAY_DEFINED, display))
                expected_views.update(itertools.product(spaces, [display], views, ["forward", "inverse"]))
            actual_views = {(v["source"], v["display"], v["view"], v["direction"]) for v in configurations[identifier]["displayViews"]}
            check(actual_views == expected_views, f"Display/view registry mismatch {identifier}")
    return {"passed": True, "configurations": len(configurations), "pairs": total_pairs,
            "validationCases": len(seen_cases), "transforms": len(definitions), "filesVerified": len(checked_files),
            "metalExecutionVerified": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalogue", type=Path)
    parser.add_argument("--allow-development", action="store_true")
    parser.add_argument("--compare-registry", action="store_true")
    args = parser.parse_args()
    print(json.dumps(audit(args.catalogue, not args.allow_development, args.compare_registry), sort_keys=True))
