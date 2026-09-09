# Compatibility inventory

Source of truth: AcademySoftwareFoundation/OpenColorIO, commit
`5a808fb57a94c7229640a97835c420c9a1fbd1fe` (2.6.0-dev).
This document distinguishes implemented source paths from verified conformance.
Implementation alone is not evidence of equivalent results. The Actions logs and
generated validation reports establish which numerical comparisons actually ran.

## Meaning of “all color spaces”

OpenColorIO is a configuration-driven color management system. It does not have
a single finite list containing every possible color space. Its eight bundled
CG/studio configurations contain a finite set of authored spaces and aliases;
users may supply arbitrary `.ocio` configurations and external transform files.
Both scopes matter for a full native refactor. A bundled-space catalogue, even
with every pair exported, is not complete compatibility with arbitrary configs.

The native runtime executes Float32 Metal shaders and LUT textures. The product
does not load a C++ OCIO library, Python module, or dynamically linked OCIO
framework. Generation and differential validation may use the pinned upstream
implementation as an oracle.

## Configuration and graph implementation

| Area | Current implementation | Remaining conformance work |
| --- | --- | --- |
| YAML | Pure Swift block and flow mappings/sequences; OCIO tags; quoted strings and escapes; literal/folded strings; anchors, aliases and merge keys; duplicate keys rejected | General YAML specification conformance, unusual multiline/plain scalar and explicit-key forms |
| Config versions | Reads version 1 and 2 structure, preserving scalar text and unknown metadata | Every version-specific default, migration rule and upstream validation diagnostic |
| Color spaces | Scene/display reference spaces; names, aliases, roles, isdata and equality groups | Full upstream configuration API, mutability, serialization and interoperability matching |
| Context | Declared environment defaults/overrides; nested `$VAR`, `${VAR}`, `%VAR%`; search paths and working directory | OCIO environment-mode and unresolved-variable compatibility, platform edge cases and cache invalidation |
| Graph | Authored to/from-reference selection; inverse direction; scene/display reference bridge; groups; nested ColorSpaceTransform; named transforms; look sequences and named-look alternatives | File-failure-based look fallback, all bypass flags and metadata-driven optimizations |
| Displays | Displays/shared views; native forward/inverse view graphs; scene/display bridges, looks/named substitutions, bypass flags; retains active/inactive lists, viewing/file rules and virtual display metadata | Rule evaluation, automatic monitor/ICC discovery and virtual display instantiation |
| Error behavior | Unrecognized transform types and unavailable execution paths throw; no unknown transform is treated as identity | Full parity with upstream strict/non-strict parsing diagnostics |

`ConfigurationTests.testEveryUpstreamBuiltinConfigurationAndEveryPairPlan` reads
the eight unmodified upstream fixtures, resolves every alias/role, and constructs
all reference graph pairs. This proves parser/graph behavior only; Metal numerical
equivalence has separate tests and reference reports.

## Native custom transform implementation

The registry preserves every transform class declared in `OpenColorTransforms.h`.
The following table covers compilation of transforms authored in custom YAML.
Bundled configurations and built-in styles additionally use the exported shader
catalogue; that does not imply native compilation of every custom operation.

| Transform class | Native custom compilation |
| --- | --- |
| AllocationTransform | Uniform and log2 allocation, both directions |
| BuiltinTransform | Exact exported shader stages, both directions where upstream supports them |
| CDLTransform | Slope/offset/power/saturation, ASC clamp and no-clamp, both directions; singular inverse rejected |
| ColorSpaceTransform | Resolves graph recursively, both directions |
| DisplayViewTransform | Native scene/display/view/named/look graph compilation, both directions |
| ExponentTransform | Clamp, mirror, pass-through negatives, both directions |
| ExponentWithLinearTransform | Linear and mirror negatives, per-channel gamma/offset, both directions |
| ExposureContrastTransform | Linear, video and logarithmic equations, both directions; values compiled as snapshots |
| FileTransform | Native loaders listed below, context resolution, reverse operation order |
| FixedFunctionTransform | Implementation in progress; audit `FixedFunctions.swift` for exact supported styles |
| GradingPrimaryTransform | Pending native custom compilation |
| GradingHueCurveTransform | Pending native custom compilation |
| GradingRGBCurveTransform | Pending native custom compilation |
| GradingToneTransform | Pending native custom compilation |
| GroupTransform | Recursive ordered children, reversed children and directions for inverse |
| LogAffineTransform | Per-channel affine logarithm, both directions |
| LogCameraTransform | Derived/authored linear segment and break, both directions |
| LogTransform | Arbitrary valid base, both directions |
| LookTransform | Process-space conversions, signed look lists, inverse order/directions |
| Lut1DTransform | Native file LUT data path exists; direct custom YAML class compilation pending |
| Lut3DTransform | Native file LUT data path exists; direct custom YAML class compilation pending |
| MatrixTransform | Full RGBA 4×4 and offset, native inverse; singular inverse rejected |
| RangeTransform | Paired finite bounds, scale/offset, clamp/noClamp, both directions |

Live dynamic exposure/contrast/gamma and grading property updates, CPU processors,
packed/planar image descriptors, optimization flags, cache semantics, baking,
config merging, application helper APIs, C/C++/Python/Java ABI compatibility,
OpenGL/CUDA/OpenCL backends and command-line compatibility with every upstream
utility are not yet implemented. The Swift/Metal API intentionally has its own
types; API naming similarity is not an ABI compatibility claim.

## Native transform file inventory

Upstream inventory is from `src/OpenColorIO/fileformats/FileFormat*.cpp`.

| Format family | Current native implementation |
| --- | --- |
| Iridas/Resolve `.cube` | 1D, 3D, combined shaper+3D, domain/range headers, RGB data |
| SPI `.spi1d` | Version 1, 1/2/3 component tables, input domain |
| SPI `.spi3d` | Indexed RGB cube, duplicate/missing index checks, correct Metal texture order |
| SPI `.spimtx` | 3×4 matrix with 16-bit-normalized offsets |
| ASC `.cc`, `.ccc`, `.cdl` | Native XML parser; correction ID/index; SOP and saturation |
| CLF/CTF | Pending |
| Autodesk/Flame/Lustre `.3dl` | Pending |
| Cinespace `.csp` | Pending |
| Discreet `.lut` | Pending |
| Houdini `.lut` | Pending |
| ICC profiles | Pending |
| Iridas `.itx`, `.look` | Pending |
| Pandora `.mga`, `.m3d` | Pending |
| Truelight `.cub` | Pending |
| Nuke `.vf` | Pending |

Native LUT execution supports 1D linear/nearest and 3D trilinear/tetrahedral/nearest
interpolation. Inverse 1D currently requires monotonic nonconstant channels;
inverse 3D solving, nonmonotonic 1D inverse semantics, half-domain/raw-half LUTs,
hue adjustment, index maps and all file-specific edge cases remain incomplete.
Unsupported cases must remain explicit errors until implemented and verified.

## Completion gates

1. Swift 6 builds the debug CLI and the default static macOS framework in GitHub
   Actions, including importable Swift modules and bundled shader/LUT resources.
2. Every bundled config space, alias, role, directed pair, display/view transform,
   named transform and built-in style has an audited generated entry or a recorded
   upstream error; reachable operations cannot silently disappear.
3. Metal numerical tests compare the corresponding execution against upstream,
   including negative/zero/HDR values, alpha, LUT boundaries and inverse cases.
4. Arbitrary config YAML, every upstream transform class/style and every file
   format must be implemented and tested before claiming complete OpenColorIO
   replacement. Pending entries in this document are explicit incomplete work.
