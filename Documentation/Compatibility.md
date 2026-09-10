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
| FixedFunctionTransform | All 21 upstream-implemented public styles, both directions, including parameterized ACES 2; 64 MSL compilation and LUT preparation cases passed Actions; numerical corrections await the next GPU run |
| GradingPrimaryTransform | Native primary controls in linear, log and video styles, both directions |
| GradingHueCurveTransform | Native arbitrary curves, HueFX periodic inverse, HSY controls/bypass and custom slopes; CPU-equivalent video luminance and inverse-bound corrections |
| GradingRGBCurveTransform | Native RGB/master curve spline evaluation and inversion |
| GradingToneTransform | Native tone regions in linear, log and video styles, both directions |
| GroupTransform | Recursive ordered children, reversed children and directions for inverse |
| LogAffineTransform | Per-channel affine logarithm, both directions |
| LogCameraTransform | Derived/authored linear segment and break, both directions |
| LogTransform | Arbitrary valid base, both directions |
| LookTransform | Process-space conversions, signed look lists, inverse order/directions |
| Lut1DTransform | Native file and in-memory LUT data; ordinary and half domains; forward and inverse |
| Lut3DTransform | Native file and in-memory LUT data; forward interpolation and tetrahedron inverse solving |
| MatrixTransform | Full RGBA 4×4 and offset, native inverse; singular inverse rejected |
| RangeTransform | Paired finite bounds, scale/offset, clamp/noClamp, both directions |

Actions run `34346626970` (commit `699ab26`) passed all 144 custom grading GPU
cases and their prepared-uniform comparisons using the developmental OCIO 2.5.2
oracle. FixedFunction's 64 generated MSL kernels and native ACES 2 lookup-table
comparisons also passed that run. Its numerical run exposed 12 Glow black NaNs,
29 PQ comparisons against approximate CPU power, and 3 neutral-gray JMh hue
comparisons. The source now branches before Glow division, uses precise CPU
reference power, and compares neutral JMh opponent coordinates when chroma is
below the unchanged absolute tolerance; nonneutral hue retains its original
angular tolerance modulo 360. These corrections still require a new Actions GPU
run. Exact pinned-source regeneration and full catalogue validation remain
separate release gates. The two legacy public GamutMap02/GamutMap07 enums are
also unimplemented by upstream and are rejected explicitly.

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
| CLF/CTF | Matrix, range, exponent/gamma, modern/legacy log, ASC CDL, exposure/contrast, fixed functions, grading, reference paths, LUT/InvLUT; integer normalization, halfDomain/rawHalfs, DW3 and two-entry IndexMap |
| Autodesk/Flame/Lustre `.3dl` | Native text parsing, shaper/domain normalization and 3D tables |
| Cinespace `.csp` | Native 1D/3D tables and nonuniform cubic pre-LUT resampling |
| Discreet `.lut` | Native channel tables, integer/float output scaling and 65536-entry half domains |
| Houdini `.lut` | Native 1D, 3D and combined shaper+3D tables |
| ICC profiles | Native RGB matrix/TRC profiles; curve gamma/tables and parametric types 0–4; D50/D65 adaptation and upstream direction conventions |
| Iridas `.itx`, `.look` | Native text/hex decoding and 3D tables |
| Pandora `.mga`, `.m3d` | Native indexed 3D tables and output normalization |
| Truelight `.cub` | Native shaper and 3D tables |
| Nuke `.vf` | Native indexed 3D tables |

Native LUT execution supports 1D linear/nearest and 3D trilinear/tetrahedral/nearest
interpolation using explicit Float32 texture reads and weights. Ordinary 1D inverse
flattens reversals and respects effective domains at flat endpoints. Half-domain
inverse separates positive/negative code ranges and interpolates actual half-value
distances. Inverse 3D searches the extrapolated cube's tetrahedra using a bounding
tree. These implementations require differential numerical validation, including
boundary and degenerate cases; implementation is not a blanket file-conformance claim.

The CPU reference policy preserves default optimizations except approximate
log/exp/pow and fast inverse LUT resampling. Inverse references therefore evaluate
the exact upstream inverse solver. Reference JSON records this policy and oracle
version. CTF CDL inverse-pair replacement follows the default upstream optimizer.
CTF Reference alias resolution and general file/version diagnostics remain incomplete.

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
