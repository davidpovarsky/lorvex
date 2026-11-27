import copy
import importlib.util
import math
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("pinch", Path(__file__).with_name("verify_timeline_pinch_input.py"))
pinch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pinch)


class PinchInputTests(unittest.TestCase):
    def setUp(self):
        self.observed = {"schemaVersion": 1, "requestedScale": 1.25, "requestedVelocity": 0.6,
                         "beforePercent": 150, "afterPercent": 392}
        # Original 5095da18 raw coordinates; nominal request was only 1.25.
        points = [
            [(202.5958559488013, 612.8995706918136), (206.0, 615.0),
             (207.50443333921152, 615.9282673795135)],
            [(199.4041440511987, 607.1004293081864), (196.0, 605.0),
             (194.49556666078848, 604.0717326204865)],
        ]
        self.event = {"name": "pinch", "eventPaths": [
            {"pointerEvents": [
                {"eventType": kind, "offset": offset, "coordinate.x": point[0], "coordinate.y": point[1]}
                for point, kind, offset in zip(finger, [1, 2, 3], [0.0, 0.1, 2.1833333333333336])
            ]} for finger in points]}

    def test_real_original_input_and_rendered_zoom_agree(self):
        proof = pinch.compare(self.event, self.observed)
        self.assertAlmostEqual(proof["deliveredFactor"], 2.6590388900277624)
        self.assertLess(abs(proof["relativeError"]), 0.02)

    def test_nominal_requested_factor_cannot_replace_delivered_input(self):
        self.observed["afterPercent"] = 187.5
        with self.assertRaisesRegex(ValueError, "disagrees"):
            pinch.compare(self.event, self.observed)

    def test_compounded_zoom_is_rejected(self):
        self.observed["afterPercent"] = 150 * 2.6590388900277624 ** 2
        with self.assertRaisesRegex(ValueError, "disagrees"):
            pinch.compare(self.event, self.observed)

    def test_no_zoom_is_rejected(self):
        self.observed["afterPercent"] = 150
        with self.assertRaises(ValueError):
            pinch.compare(self.event, self.observed)

    def test_missing_or_single_finger_input_is_rejected(self):
        self.event["eventPaths"].pop()
        with self.assertRaisesRegex(ValueError, "two original finger"):
            pinch.compare(self.event, self.observed)

    def test_missing_lift_is_rejected(self):
        self.event["eventPaths"][0]["pointerEvents"][-1]["eventType"] = 2
        with self.assertRaisesRegex(ValueError, "down and up"):
            pinch.compare(self.event, self.observed)

    def test_nonfinite_coordinates_are_rejected(self):
        self.event["eventPaths"][0]["pointerEvents"][0]["coordinate.x"] = math.nan
        with self.assertRaisesRegex(ValueError, "Non-finite"):
            pinch.compare(self.event, self.observed)

    def test_unrelated_gesture_metadata_is_rejected(self):
        self.observed["requestedScale"] = 2
        with self.assertRaisesRegex(ValueError, "original requested"):
            pinch.compare(self.event, self.observed)

    def test_clamped_output_within_tolerance_is_rejected(self):
        self.observed.update(beforePercent=100, afterPercent=1600)
        for index, path in enumerate(self.event["eventPaths"]):
            for point, distance in zip(path["pointerEvents"], [1.0, 8.0, 15.0]):
                point["coordinate.x"] = index * distance
                point["coordinate.y"] = 0.0
        with self.assertRaisesRegex(ValueError, "Clamped"):
            pinch.compare(self.event, self.observed)

    def test_clamping_cannot_hide_accumulation(self):
        self.observed["beforePercent"] = 900
        self.observed["afterPercent"] = 1600
        with self.assertRaisesRegex(ValueError, "Clamped"):
            pinch.compare(self.event, self.observed)


if __name__ == "__main__":
    unittest.main()
