"""Narrow corrections to upstream Hue MSL to match its canonical CPU evaluator.

The pinned OCIO source has two independently reproduced discrepancies:
* GradingHueCurveOpGPU uses multiplicative luminance for video; its CPU evaluator
  uses the additive log/video branch (only linear is multiplicative).
* AddShaderEvalRevHue omits the HueFX shift of the lower periodic y bound, which
  GradingBSplineCurve::evalCurveRevHue applies to both interval endpoints.

Corrections are confined to identifiable Hue operation/function bodies, preserve
arbitrary resource prefixes and static suffixes, and are safe to apply twice.
They are used by both catalogue export and native analytical template generation.
"""
import re


def _block_end(source, opening):
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    raise ValueError("Unbalanced upstream Hue shader body")


def correct_hue_shader(source):
    # The linear conversion markers remain present when RGB-to-HSY is disabled.
    # In contrast, RGB_TO_HSY_VID itself is absent in that supported mode.
    operations = list(re.finditer(r"// Add GradingHueCurve (forward|inverse) processing\s*\{", source))
    for match in reversed(operations):
        opening = source.index("{", match.start())
        end = _block_end(source, opening)
        body = source[opening:end]
        if "// Convert from lin to log." in body or "// Convert from log to lin." in body:
            continue
        if match.group(1) == "forward":
            pattern = r"\b(\w+)\.b\s*=\s*\1\.b\s*\*\s*hueLumGain\s*\*\s*satLumGain\s*;"
            replacement = r"\1.b = \1.b + (hueLumGain + satLumGain - 2.) * 0.1;"
        else:
            pattern = r"\b(\w+)\.b\s*=\s*\1\.b\s*/\s*max\(\s*0\.01\s*,\s*hueLumGain\s*\*\s*satLumGain\s*\)\s*;"
            replacement = r"\1.b = \1.b - (hueLumGain + satLumGain - 2.) * 0.1;"
        body = re.sub(pattern, replacement, body)
        source = source[:opening] + body + source[end:]

    helpers = list(re.finditer(r"\bfloat\s+\w*grading_huecurve_evalBSplineCurveRevHue\w*\s*\(", source))
    for match in reversed(helpers):
        opening = source.index("{", match.end())
        end = _block_end(source, opening)
        body = source[opening:end]
        if re.search(r"knStartY\s*=\s*\(curveIdx\s*==\s*7\)\s*\?\s*knStartY\s*\+\s*knStart", body):
            continue
        anchor = re.search(r"(?m)^([ \t]*)float knEndY;", body)
        if not anchor or "float knStartY =" not in body:
            raise ValueError("Unrecognized upstream inverse Hue periodic bounds")
        correction = (anchor.group(1) + "// Match the CPU HueFX lower periodic bound.\n" +
                      anchor.group(1) + "knStartY = (curveIdx == 7) ? knStartY + knStart : knStartY;\n")
        body = body[:anchor.start()] + correction + body[anchor.start():]
        source = source[:opening] + body + source[end:]
    return source
