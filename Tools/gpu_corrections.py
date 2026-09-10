"""Narrow corrections to upstream MSL to match its canonical CPU evaluator.

The pinned OCIO source has two independently reproduced discrepancies:
* GradingHueCurveOpGPU uses multiplicative luminance for video; its CPU evaluator
  uses the additive log/video branch (only linear is multiplicative).
* AddShaderEvalRevHue omits the HueFX shift of the lower periodic y bound, which
  GradingBSplineCurve::evalCurveRevHue applies to both interval endpoints.
* ACES Glow uses arithmetic mix on an inactive 0/0 expression at black. Actual
  scalar branches retain the CPU piecewise definition and its finite result.
* PQ's sign(0) loses the small nonzero encoding of linear zero. copysign matches
  the CPU definition, including signed zero.

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


def correct_fixed_shader(source):
    operations = list(re.finditer(r"// Add FixedFunction '(ACES_Glow(?:03|10) \((?:Forward|Inverse)\)|(?:PQ_TO_Lin|Lin_TO_PQ))' processing\s*\{", source))
    for match in reversed(operations):
        opening = source.index("{", match.start())
        end = _block_end(source, opening)
        body = source[opening:end]
        if match.group(1).startswith("ACES_Glow"):
            if "float glowGainOut = mix(" not in body:
                continue
            inverse = "Inverse" in match.group(1)
            baseline = "-GlowGain / (1. + GlowGain)" if inverse else "GlowGain"
            threshold = "(1. + GlowGain) * GlowMid * 2. / 3." if inverse else "GlowMid * 2. / 3."
            middle = "GlowGain * (GlowMid / YC - 0.5)"
            if inverse:
                middle += " / (GlowGain * 0.5 - 1.)"
            def replacement(found):
                indent = found.group(1)
                return (indent + "// Branch before division: an inactive 0/0 must not contaminate black.\n" +
                        indent + "float glowGainOut;\n" +
                        indent + "if (YC >= GlowMid * 2.) { glowGainOut = 0.; }\n" +
                        indent + f"else if (YC <= {threshold}) {{ glowGainOut = {baseline}; }}\n" +
                        indent + f"else {{ glowGainOut = {middle}; }}")
            body, count = re.subn(r"(?m)^([ \t]*)float glowGainOut = mix\([^\n]+;\s*glowGainOut = mix\([^\n]+;", replacement, body)
            if count != 1:
                raise ValueError("Unrecognized upstream ACES Glow gain expression")
            body = re.sub(r"(\w+\.rgb) = \1 \* glowGainOut \+ \1;", r"\1 *= (1. + glowGainOut);", body)
        else:
            body = re.sub(r"float3 sign3 = sign\((\w+\.rgb)\);", r"float3 sign3 = copysign(float3(1.), \1);", body)
        source = source[:opening] + body + source[end:]
    return source
