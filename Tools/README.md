# Development-time OCIO oracle

The shipped library and CLI use Swift 6 and Metal. These Python tools run only
during migration and verification. They do not ship a Python interpreter,
OpenColorIO C++ library, dynamic bridge, or Python runtime dependency.

`export_catalogue.py` expects PyOpenColorIO compiled from the exact commit in
`UPSTREAM.json`. The workflow builds and installs that reference oracle before
running the exporter. NumPy is needed for lossless float32 texture and CPU vector
transport. A released OCIO wheel is permitted only with
`--allow-unpinned-oracle`, which marks `coverage.json.releaseEligible=false`;
`audit_catalogue.py` rejects such archives by default.

```sh
python Tools/export_catalogue.py \
  --upstream-source work/upstream \
  --upstream-sha "$UPSTREAM_COMMIT" \
  --oracle-build-root work/oracle-install \
  --output Sources/OpenColorIOMetal/Resources/Catalogue
python Tools/audit_catalogue.py Sources/OpenColorIOMetal/Resources/Catalogue --compare-registry
python -m unittest discover -s Tools -p test_export_catalogue.py -v
```

Additional `--config /path/to/config.ocio` options export custom configurations
alongside the complete built-in catalogue. Their FileTransforms are resolved by
the development oracle relative to the config and its declared search paths.
An unsupported file, missing external asset, invalid processor, unexpected GPU
uniform or unsupported GPU interpolation makes export fail with a nonzero exit
status. Exceptions are recorded individually in `coverage.json.failures`.

Every ordered colour-space pair is requested directly from OCIO. This includes
inactive spaces, aliases, role metadata, data spaces, scene references and
display references. Direct processor extraction preserves equality-group,
same-space, data-bypass, inverse cancellation and clamping semantics. It does
not assume that a source → reference → destination round trip has the same
behaviour. All declared active/inactive display views, named transforms, looks
and registry built-in transform directions are also exported. Shader and LUT
resource contents are deduplicated using SHA-256, so equivalent processors
share resource data without sharing incorrect pair-resolution assumptions.

Analytical operations remain analytical MSL. Only textures requested by OCIO's
GPU backend become LUT resources. Dynamic OCIO controls are frozen at their
configured default using `OPTIMIZATION_NO_DYNAMIC_PROPERTIES`; runtime user
controls are represented separately by the native Swift transform API.

## Archive schema 1

`manifest.json` contains `upstream`, `defaultConfiguration`, `configurations`,
`builtins`, and `transforms`. All identifiers and names preserve upstream case.
Configuration `colorSpaces` retain aliases, family, description, active/data
flags, equality group and scene/display reference type. `roleAliases` maps roles
to canonical colour-space names. `conversions` lists source/destination and a
`pipeline` of transform IDs; identity is an explicitly exported empty pipeline.
`displayViews` also specifies display, view and forward/inverse direction.
`namedTransforms` and `looks` carry forward/inverse pipelines; looks additionally
declare the input/output `processSpace`. Registry `builtins` carry a name,
description and forward/inverse pipelines.

Each transform declares `id`, `shader`, `kernel` (`ocio_kernel`) and `textures`.
Every `.metal` is a complete compute program with float4 input buffer 0, float4
output buffer 1, a uint pixel-count constant buffer 2 and sequential texture
slots starting at 0. Shaders check the dispatch bounds. Texture descriptors
declare name, samplerName, dimension (1, 2 or 3), width, height, depth, channels
(1 or 3), interpolation (`nearest` or `linear`), bindingIndex and data path.

Textures are little-endian IEEE-754 float32, with x varying fastest. A 3D OCIO
LUT uses x=blue, y=green, z=red and the original MSL samples `.zyx` coordinates.
The native loader must upload without transposing and expand RGB samples to
RGBA storage. Tetrahedral interpolation is performed analytically in the
shader with a nearest sampler. Samplers clamp to edge; they are embedded in the
kernel. Constructor arguments follow upstream's 3D texture/sampler pairs first,
then its 1D/2D texture/sampler pairs. Freezing dynamic properties eliminates
uniform arguments and the need to infer a buffer layout.

`validation.json` contains shared flattened RGBA `input` and `cases`. Each case
has a human-readable `name`, its exact manifest `pipeline`, an `expected` path
to little-endian float32 RGBA results, and absolute/relative tolerances. Each
pair or direction has a direct CPU-oracle case, even if the GPU pipeline is
deduplicated. Nonfinite CPU results remain representable in binary. Numerical
validation compares NaNs by class and infinities by sign. Shader compilation or
metadata validation alone does not establish Metal numerical equivalence.

`coverage.json` records exact expected counts, captured cases, failures and
oracle provenance. Its `metalExecutionVerified` is always false: only a
separate successful native Metal validation report can establish that claim.
`audit_catalogue.py --compare-registry` independently checks registry sets,
every ordered pair, every display/view direction, all case mappings, resource
sizes and SHA-256 hashes. Missing cases fail the gate.
