"""Tests for server.py that do not need MLX or the model weights.

Run from mlx-server/ with the server's venv:
    .venv/bin/python -m unittest test_server
"""

import base64
import io
import os
import unittest
from pathlib import Path

os.environ["ODV_AI_TOKEN"] = "test-token"
os.environ.pop("ODV_PARENT_PID", None)

import server  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from PIL import Image  # noqa: E402

AUTH = {"X-ODV-Token": "test-token"}


def png_b64(width=100, height=50) -> str:
    buffer = io.BytesIO()
    Image.new("RGB", (width, height)).save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode()


class CoerceBoxesTests(unittest.TestCase):
    def test_normalized_boxes_pass_through(self):
        boxes = server._coerce_boxes(
            [{"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4, "label": "a",
              "confidence": 0.9}])
        self.assertEqual(len(boxes), 1)
        self.assertAlmostEqual(boxes[0]["x"], 0.1)
        self.assertAlmostEqual(boxes[0]["height"], 0.4)

    def test_thousand_scale_is_normalized(self):
        boxes = server._coerce_boxes(
            [{"x": 100, "y": 200, "width": 300, "height": 400, "label": "a"}],
            image_size=(512, 512))
        self.assertAlmostEqual(boxes[0]["x"], 0.1)
        self.assertAlmostEqual(boxes[0]["width"], 0.3)

    def test_pixel_units_beyond_thousand_use_image_size(self):
        boxes = server._coerce_boxes(
            [{"x": 560, "y": 100, "width": 560, "height": 200, "label": "a"}],
            image_size=(1120, 800))
        self.assertAlmostEqual(boxes[0]["x"], 0.5)
        self.assertAlmostEqual(boxes[0]["width"], 0.5)
        self.assertAlmostEqual(boxes[0]["y"], 0.125)

    def test_unfittable_coordinates_drop_everything(self):
        boxes = server._coerce_boxes(
            [{"x": 5000, "y": 0, "width": 10, "height": 10, "label": "a"}],
            image_size=(512, 512))
        self.assertEqual(boxes, [])

    def test_box_2d_format(self):
        boxes = server._coerce_boxes([{"box_2d": [100, 200, 500, 600], "label": "a"}])
        self.assertAlmostEqual(boxes[0]["x"], 0.2)
        self.assertAlmostEqual(boxes[0]["y"], 0.1)
        self.assertAlmostEqual(boxes[0]["width"], 0.4)
        self.assertAlmostEqual(boxes[0]["height"], 0.4)

    def test_clamped_and_negative_sizes_ordered(self):
        boxes = server._coerce_boxes(
            [{"x": 0.9, "y": 0.5, "width": 0.5, "height": -0.2, "label": "a"}])
        b = boxes[0]
        self.assertAlmostEqual(b["x"], 0.9)
        self.assertAlmostEqual(b["width"], 0.1)
        self.assertAlmostEqual(b["y"], 0.3)
        self.assertAlmostEqual(b["height"], 0.2)

    def test_degenerate_and_malformed_dropped(self):
        boxes = server._coerce_boxes([
            {"x": 0.1, "y": 0.1, "width": 0, "height": 0.2},
            {"x": "abc", "y": 0.1, "width": 0.1, "height": 0.1},
            {"x": float("nan"), "y": 0.1, "width": 0.1, "height": 0.1},
            "not a box",
            {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2, "label": 7},
        ])
        self.assertEqual(len(boxes), 1)
        self.assertEqual(boxes[0]["label"], "7")

    def test_confidence_coercion(self):
        self.assertEqual(server._coerce_confidence("85%"), 0.85)
        self.assertEqual(server._coerce_confidence(85), 0.85)
        self.assertEqual(server._coerce_confidence(-1), 0.0)
        self.assertEqual(server._coerce_confidence(500), 1.0)
        self.assertEqual(server._coerce_confidence("high"), 0.0)
        self.assertEqual(server._coerce_confidence(None), 0.0)

    def test_severity_is_case_insensitive_and_unknown_is_not_normal(self):
        self.assertEqual(server._coerce_severity("Severe"), "severe")
        self.assertEqual(server._coerce_severity(" CRITICAL "), "critical")
        self.assertEqual(server._coerce_severity("urgent"), "unknown")
        self.assertEqual(server._coerce_severity(None), "unknown")


class ResponseBuilderTests(unittest.TestCase):
    def test_analyze_accepts_bare_list(self):
        raw = '[{"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2, "label": "a"}]'
        response = server.build_analyze_response(raw, (100, 100))
        self.assertEqual(len(response.bounding_boxes), 1)

    def test_analyze_coerces_findings(self):
        raw = '{"findings": "one finding", "description": 3, "bounding_boxes": null}'
        response = server.build_analyze_response(raw, (100, 100))
        self.assertEqual(response.findings, ["one finding"])
        self.assertEqual(response.description, "3")
        self.assertEqual(response.bounding_boxes, [])

    def test_fenced_json(self):
        raw = 'Here:\n```json\n{"regions": [{"x": 0.1, "y": 0.1, "width": 0.1, ' \
              '"height": 0.1, "label": "x", "severity": "Mild"}]}\n```'
        response = server.build_abnormality_response(raw, (100, 100))
        self.assertEqual(response.regions[0].severity, "mild")

    def test_unparseable_falls_back_to_text(self):
        response = server.build_analyze_response("no json here", (100, 100))
        self.assertEqual(response.description, "no json here")

    def test_roi_response(self):
        response = server.build_roi_response('{"label": "liver", "confidence": "90%"}')
        self.assertEqual(response.label, "liver")
        self.assertAlmostEqual(response.confidence, 0.9)


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # No lifespan: the background load would try to import mlx_vlm.
        cls.client = TestClient(server.app, base_url="http://127.0.0.1:8741")

    def setUp(self):
        server._model = None
        server._load_error = None
        server._phase = "starting"
        server._expected_bytes = None

    def test_missing_token_rejected(self):
        self.assertEqual(self.client.get("/health").status_code, 401)
        self.assertEqual(
            self.client.get("/health", headers={"X-ODV-Token": "wrong"}).status_code, 401)

    def test_foreign_host_rejected(self):
        response = self.client.get("/health", headers={**AUTH, "Host": "evil.example:8741"})
        self.assertEqual(response.status_code, 403)

    def test_localhost_host_allowed(self):
        response = self.client.get("/health", headers={**AUTH, "Host": "localhost:8741"})
        self.assertEqual(response.status_code, 200)

    def test_health_reports_loading_then_error(self):
        body = self.client.get("/health", headers=AUTH).json()
        self.assertEqual(body["status"], "loading")
        self.assertEqual(body["pid"], os.getpid())
        server._load_error = "OSError: offline"
        body = self.client.get("/health", headers=AUTH).json()
        self.assertEqual(body["status"], "error")
        self.assertIn("offline", body["error"])

    def test_health_reports_download_progress(self):
        import tempfile
        from unittest import mock

        with tempfile.TemporaryDirectory() as cache:
            blobs = Path(cache) / ("models--" + server.MODEL_ID.replace("/", "--")) / "blobs"
            blobs.mkdir(parents=True)
            (blobs / "aaa").write_bytes(b"x" * 1000)
            (blobs / "bbb.incomplete").write_bytes(b"x" * 500)
            with mock.patch.object(server, "_hub_cache_dir", return_value=Path(cache)):
                self.assertFalse(server.snapshot_present())
                server._phase = "downloading"
                server._expected_bytes = 5000
                body = self.client.get("/health", headers=AUTH).json()
                self.assertEqual(body["status"], "loading")
                self.assertEqual(body["phase"], "downloading")
                self.assertEqual(body["download_bytes"], 1500)
                self.assertEqual(body["download_total_bytes"], 5000)

                snapshot = blobs.parent / "snapshots" / server.MODEL_REVISION
                snapshot.mkdir(parents=True)
                (snapshot / "config.json").write_text("{}")
                self.assertFalse(server.snapshot_present())  # no weights yet
                (snapshot / "model.safetensors").write_bytes(b"w")
                self.assertTrue(server.snapshot_present())

        server._phase = "loading"
        body = self.client.get("/health", headers=AUTH).json()
        self.assertEqual(body["phase"], "loading")
        self.assertIsNone(body["download_bytes"])

    def test_no_cors_headers(self):
        response = self.client.options(
            "/analyze", headers={**AUTH, "Origin": "http://evil.example",
                                 "Access-Control-Request-Method": "POST"})
        self.assertNotIn("access-control-allow-origin", response.headers)

    def test_bad_base64_is_400(self):
        server._model = object()
        response = self.client.post("/analyze", headers=AUTH,
                                    json={"image": "@@not base64@@"})
        self.assertEqual(response.status_code, 400)
        response = self.client.post(
            "/analyze", headers=AUTH,
            json={"image": base64.b64encode(b"not an image").decode()})
        self.assertEqual(response.status_code, 400)

    def test_analyze_end_to_end_with_stub_generate(self):
        server._model = object()
        original = server._generate
        server._generate = lambda image, prompt: (
            '{"findings": ["f"], "description": "d", "bounding_boxes": '
            '[{"x": 100, "y": 100, "width": 200, "height": 200, "label": "a", '
            '"confidence": 80}]}')
        try:
            response = self.client.post("/analyze", headers=AUTH,
                                        json={"image": png_b64()})
        finally:
            server._generate = original
        self.assertEqual(response.status_code, 200)
        box = response.json()["bounding_boxes"][0]
        self.assertAlmostEqual(box["x"], 0.1)
        self.assertAlmostEqual(box["confidence"], 0.8)

    def test_describe_roi_validates_and_marks(self):
        server._model = object()
        seen = {}

        def fake(image, prompt):
            seen["pixel"] = image.getpixel((10, 5))
            return '{"label": "l", "description": "d", "confidence": 0.5}'

        original = server._generate
        server._generate = fake
        try:
            bad = self.client.post("/describe-roi", headers=AUTH, json={
                "image": png_b64(), "roi": {"x": 5, "y": 5, "width": 10, "height": 10}})
            ok = self.client.post("/describe-roi", headers=AUTH, json={
                "image": png_b64(), "roi": {"x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5}})
        finally:
            server._generate = original
        self.assertEqual(bad.status_code, 400)
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(seen["pixel"], (255, 0, 0))  # top-left corner of the outline


if __name__ == "__main__":
    unittest.main()
