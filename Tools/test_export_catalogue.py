"""Development oracle tests; run using the pinned OCIO Python build in CI."""
from pathlib import Path
import importlib.util
import tempfile
import unittest

import numpy as np
import PyOpenColorIO as ocio
from export_catalogue import Exporter, precise_texture_sampling
from gpu_corrections import correct_hue_shader
from oracle_helpers import CPU_OPTIMIZATION_FLAGS, cpu_reference


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.exporter = Exporter(self.root, ocio, np)

    def tearDown(self):
        self.temporary.cleanup()

    def capture(self, config, source, destination):
        pipeline = self.exporter.capture("test", "pairs", lambda: config.getProcessor(source, destination))
        self.assertEqual(self.exporter.failures, [])
        return pipeline

    def test_data_bypass_and_same_space_preserve_out_of_range(self):
        config = ocio.Config.CreateRaw()
        log = ocio.ColorSpace(name="log", toReference=ocio.LogTransform(base=2))
        config.addColorSpace(log)
        self.assertEqual(self.capture(config, "raw", "log"), [])
        self.assertEqual(self.capture(config, "log", "raw"), [])
        self.assertEqual(self.capture(config, "log", "log"), [])
        for case in self.exporter.cases:
            reference = np.fromfile(self.root / case["expected"], dtype="<f4").reshape(-1, 4)
            np.testing.assert_array_equal(reference, self.exporter.inputs)

    def test_equality_group_bypasses_transform_roundtrip(self):
        config = ocio.Config.CreateRaw()
        config.addColorSpace(ocio.ColorSpace(name="first", equalityGroup="equal", toReference=ocio.LogTransform(base=2)))
        config.addColorSpace(ocio.ColorSpace(name="second", equalityGroup="equal", toReference=ocio.ExponentTransform(value=[2, 2, 2, 1])))
        self.assertEqual(self.capture(config, "first", "second"), [])

    def test_analytical_transform_does_not_become_lut(self):
        config = ocio.Config.CreateRaw()
        transform = ocio.LogAffineTransform()
        transform.setBase(10)
        processor = config.getProcessor(transform)
        self.assertTrue(self.exporter.pipeline(processor))
        definition = next(iter(self.exporter.transforms.values()))
        self.assertEqual(definition["textures"], [])
        source = (self.root / definition["shader"]).read_text()
        self.assertIn("log", source)
        self.assertIn("kernel void ocio_kernel", source)

    def test_dynamic_defaults_are_frozen_without_uniforms(self):
        transform = ocio.ExposureContrastTransform(exposure=1.5)
        transform.makeExposureDynamic()
        processor = ocio.Config.CreateRaw().getProcessor(transform)
        self.assertTrue(self.exporter.pipeline(processor))
        definition = next(iter(self.exporter.transforms.values()))
        self.assertEqual(definition["textures"], [])

    def test_3d_lut_uses_gpu_x_fast_storage_and_clamped_sampler(self):
        transform = ocio.Lut3DTransform(gridSize=2)
        for red in range(2):
            for green in range(2):
                for blue in range(2):
                    transform.setValue(red, green, blue, red * .8, green * .6, blue * .4)
        transform.setInterpolation(ocio.INTERP_TETRAHEDRAL)
        processor = ocio.Config.CreateRaw().getProcessor(transform)
        self.exporter.pipeline(processor)
        definition = next(iter(self.exporter.transforms.values()))
        texture = definition["textures"][0]
        self.assertEqual((texture["dimension"], texture["channels"], texture["width"]), (3, 3, 2))
        values = np.fromfile(self.root / texture["data"], dtype="<f4").reshape(-1, 3)
        expected = [[red * .8, green * .6, blue * .4] for red in range(2) for green in range(2) for blue in range(2)]
        np.testing.assert_allclose(values, expected)
        source = (self.root / definition["shader"]).read_text()
        self.assertIn("address::clamp_to_edge", source)
        self.assertIn("baseInd.zyx", source)

    def hue_source(self, space, inverse=False, dynamic=False):
        config = ocio.Config.CreateFromFile(str(Path(__file__).parent / "Fixtures/hue-regression.ocio"))
        transform = config.getColorSpace(space).getTransform(ocio.COLORSPACE_DIR_TO_REFERENCE)
        if inverse:
            transform.setDirection(ocio.TRANSFORM_DIR_INVERSE)
        if dynamic:
            transform.makeDynamic()
        desc = ocio.GpuShaderDesc.CreateShaderDesc()
        desc.setLanguage(ocio.GPU_LANGUAGE_MSL_2_0)
        desc.setResourcePrefix("arbitraryPrefix123_")
        config.getProcessor(transform).getDefaultGPUProcessor().extractGpuShaderInfo(desc)
        return desc.getShaderText()

    def test_hue_video_corrections_cover_static_dynamic_and_hsy_bypass(self):
        for space in ("Video", "VideoHSY"):
            for inverse in (False, True):
                for dynamic in (False, True):
                    with self.subTest(space=space, inverse=inverse, dynamic=dynamic):
                        source = self.hue_source(space, inverse, dynamic)
                        corrected = correct_hue_shader(source)
                        operator = "-" if inverse else "+"
                        self.assertIn(f"outColor.b = outColor.b {operator} (hueLumGain + satLumGain - 2.) * 0.1;", corrected)
                        self.assertNotIn("outColor.b * hueLumGain * satLumGain", corrected)
                        self.assertNotIn("outColor.b / max(0.01, hueLumGain * satLumGain)", corrected)
                        self.assertEqual(corrected, correct_hue_shader(corrected))
                        self.assertIn("arbitraryPrefix123_", corrected)

    def test_hue_lower_periodic_bound_matches_cpu_for_static_and_dynamic(self):
        for space in ("Log", "LogHSY", "LinearCurves", "Video", "VideoHSY"):
            for dynamic in (False, True):
                with self.subTest(space=space, dynamic=dynamic):
                    corrected = correct_hue_shader(self.hue_source(space, inverse=True, dynamic=dynamic))
                    self.assertEqual(corrected.count("knStartY = (curveIdx == 7) ? knStartY + knStart : knStartY;"), 1)
                    self.assertEqual(corrected, correct_hue_shader(corrected))

    def test_hue_forward_linear_and_log_are_unchanged(self):
        for space in ("LinearCurves", "Log", "LogHSY"):
            for dynamic in (False, True):
                source = self.hue_source(space, dynamic=dynamic)
                self.assertEqual(source, correct_hue_shader(source))

    def test_hue_mixed_style_operations_are_corrected_independently(self):
        source = self.hue_source("Composite")
        corrected = correct_hue_shader(source)
        self.assertEqual(corrected.count("outColor.b = outColor.b * hueLumGain * satLumGain;"), 1)
        self.assertEqual(corrected.count("outColor.b = outColor.b + (hueLumGain + satLumGain - 2.) * 0.1;"), 2)
        corrected_inverse = correct_hue_shader(self.hue_source("Composite", inverse=True))
        self.assertEqual(corrected_inverse.count("knStartY = (curveIdx == 7) ? knStartY + knStart : knStartY;"), 3)

    def test_custom_hue_archive_has_independently_audited_cpu_cases(self):
        path = Path(__file__).parent / "generate-export-reference.py"
        spec = importlib.util.spec_from_file_location("export_reference", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        result = module.generate(self.root, {"repository": "test", "commit": "test", "version": ocio.__version__})
        self.assertTrue(result["passed"])
        self.assertEqual(result["pairs"], 121)
        self.assertEqual(result["validationCases"], 143)

    def test_linear_texture_sampling_uses_full_float32_for_each_dimension(self):
        for dimension in (1, 2, 3):
            metadata = {"name": "custom_lut", "samplerName": "custom_sampler", "dimension": dimension, "interpolation": "linear"}
            source = "float4 value = custom_lut.sample(custom_sampler, position);"
            corrected = precise_texture_sampling(source, [metadata])
            self.assertIn(f"ocio_precise_sample_{dimension}d(custom_lut, position)", corrected)
            self.assertIn("lut.read(", corrected)
            self.assertNotIn(".sample(", corrected)
            metadata["interpolation"] = "nearest"
            self.assertEqual(precise_texture_sampling(source, [metadata]), source)

    def test_cpu_reference_uses_exact_inverse_lut_at_a_plateau(self):
        path = Path(__file__).parent.parent / "Tests/OpenColorIOConfigTests/Fixtures/Legacy/logtolin_8to8.lut"
        processor = ocio.Config.CreateRaw().getProcessor(ocio.FileTransform(src=str(path.resolve()), direction=ocio.TRANSFORM_DIR_INVERSE))
        precise = cpu_reference(processor).applyRGB([.003, .04, .18])
        self.assertAlmostEqual(precise[1], .16156864166259766, places=7)
        self.assertEqual(int(CPU_OPTIMIZATION_FLAGS) & int(ocio.OPTIMIZATION_LUT_INV_FAST), 0)
        self.assertEqual(int(CPU_OPTIMIZATION_FLAGS) & int(ocio.OPTIMIZATION_FAST_LOG_EXP_POW), 0)


if __name__ == "__main__":
    unittest.main()
