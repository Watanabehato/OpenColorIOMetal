"""Development oracle tests; run using the pinned OCIO Python build in CI."""
from pathlib import Path
import tempfile
import unittest

import numpy as np
import PyOpenColorIO as ocio
from export_catalogue import Exporter


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


if __name__ == "__main__":
    unittest.main()
