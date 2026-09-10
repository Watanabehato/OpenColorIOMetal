"""CPU references disable approximate powers and resampled inverse LUTs.

For example, PQ inverse at 0.9 is 39.0564465 by the ST 2084 equations, but
OCIO's default SSE approximate power returns 38.998226. Reference accuracy must
not be limited by this optional speed optimization. Likewise LUT_INV_FAST bakes
inverse LUTs into sampled forward tables, moving plateau boundaries. Disable
both approximations while retaining the other default optimization semantics.
"""
import PyOpenColorIO as ocio


CPU_OPTIMIZATION_FLAGS = ocio.OptimizationFlags(
    int(ocio.OPTIMIZATION_DEFAULT) & ~(int(ocio.OPTIMIZATION_FAST_LOG_EXP_POW) | int(ocio.OPTIMIZATION_LUT_INV_FAST))
)
CPU_REFERENCE_METADATA = {
    "optimizationFlags": int(CPU_OPTIMIZATION_FLAGS),
    "optimizationPolicy": "OPTIMIZATION_DEFAULT with OPTIMIZATION_FAST_LOG_EXP_POW and OPTIMIZATION_LUT_INV_FAST disabled",
    "inputBitDepth": "32f",
    "outputBitDepth": "32f",
}


def cpu_reference(processor):
    return processor.getOptimizedCPUProcessor(
        ocio.BIT_DEPTH_F32, ocio.BIT_DEPTH_F32, CPU_OPTIMIZATION_FLAGS
    )
