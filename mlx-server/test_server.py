"""Tests for server.py that do not need MLX or the model weights.

Run from mlx-server/ with the server's venv:
    .venv/bin/python -m unittest test_server
"""

import base64
import io
import json
import os
import sys
import threading
import types
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

                # A sharded model is complete only when every indexed shard is.
                (snapshot / "model.safetensors").unlink()
                (snapshot / "model.safetensors.index.json").write_text(json.dumps(
                    {"weight_map": {"a": "model-00001-of-00002.safetensors",
                                    "b": "model-00002-of-00002.safetensors"}}))
                (snapshot / "model-00001-of-00002.safetensors").write_bytes(b"w")
                self.assertFalse(server.snapshot_present())
                (snapshot / "model-00002-of-00002.safetensors").write_bytes(b"w")
                self.assertTrue(server.snapshot_present())

        server._phase = "loading"
        body = self.client.get("/health", headers=AUTH).json()
        self.assertEqual(body["phase"], "loading")
        self.assertIsNone(body["download_bytes"])

    def test_local_model_dir_needs_config_and_shards(self):
        import tempfile
        from unittest import mock

        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(os.environ, {server.LOCAL_MODEL_DIR_ENV: directory}):
                self.assertIsNone(server.local_model_dir())
                (Path(directory) / "config.json").write_text("{}")
                self.assertIsNone(server.local_model_dir())
                (Path(directory) / "model.safetensors").write_bytes(b"w")
                self.assertEqual(server.local_model_dir(), Path(directory))
        with mock.patch.dict(os.environ, {server.LOCAL_MODEL_DIR_ENV: ""}):
            self.assertIsNone(server.local_model_dir())

    def test_load_model_uses_the_installed_copy_without_the_hub(self):
        import sys
        import tempfile
        import types
        from unittest import mock

        loaded = []
        fake_vlm = types.ModuleType("mlx_vlm")
        fake_vlm.load = lambda source, **kwargs: (loaded.append((source, kwargs)) or ("m", "p"))
        fake_hub = types.ModuleType("huggingface_hub")

        def no_download(*_a, **_k):
            raise AssertionError("must not download")

        fake_hub.snapshot_download = no_download
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "config.json").write_text("{}")
            (Path(directory) / "model.safetensors").write_bytes(b"w")
            with mock.patch.dict(os.environ, {server.LOCAL_MODEL_DIR_ENV: directory}), \
                    mock.patch.dict(sys.modules, {"mlx_vlm": fake_vlm,
                                                  "huggingface_hub": fake_hub}), \
                    mock.patch.object(server, "snapshot_present", return_value=False):
                server.load_model()
        try:
            self.assertEqual(loaded, [(directory, {})])
            self.assertEqual(server._phase, "ready")
        finally:
            server._model = None
            server._processor = None
            server._phase = "loading"

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
        server._generate = lambda image, prompt, cancel=None: (
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

        def fake(image, prompt, cancel=None):
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


class FakeProcessor:
    """Records the chat messages the server formats."""

    def __init__(self):
        self.messages = None

    def apply_chat_template(self, messages, add_generation_prompt=False):
        self.messages = messages
        return "FORMATTED"


def _fake_mlx_vlm(reply, seen):
    module = types.ModuleType("mlx_vlm")

    def stream_generate(model, processor, prompt, image=None, **kwargs):
        seen["prompt"] = prompt
        seen["kwargs"] = kwargs
        for piece in (reply[: len(reply) // 2], reply[len(reply) // 2:]):
            yield types.SimpleNamespace(text=piece)

    module.stream_generate = stream_generate
    return module


class FinalPromptTests(unittest.TestCase):
    """The text the model receives, captured below the real _generate."""

    @classmethod
    def setUpClass(cls):
        cls.client = TestClient(server.app, base_url="http://127.0.0.1:8741")

    def setUp(self):
        self.processor = FakeProcessor()
        server._model = object()
        server._processor = self.processor
        server._load_error = None

    def tearDown(self):
        server._model = None
        server._processor = None

    def _user_text(self):
        user = self.processor.messages[-1]
        return next(part["text"] for part in user["content"] if part["type"] == "text")

    def _post(self, path, body, reply):
        from unittest import mock

        seen = {}
        with mock.patch.dict(sys.modules, {"mlx_vlm": _fake_mlx_vlm(reply, seen)}):
            response = self.client.post(path, headers=AUTH, json=body)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(seen["prompt"], "FORMATTED")
        return response, self._user_text()

    def test_every_analyze_mode_shows_single_braces(self):
        for mode in server.ANALYZE_MODES:
            with self.subTest(mode=mode):
                response, text = self._post(
                    "/analyze",
                    {"image": png_b64(), "mode": mode,
                     "window_info": {"modality": "CT", "description": "Head"}},
                    '{"findings": [], "bounding_boxes": [], "description": "ok"}')
                self.assertNotIn("{{", text)
                self.assertNotIn("}}", text)
                self.assertIn("CT, Head", text)
                # The example the model is told to copy is valid JSON.
                example = text[text.index("{"): text.rindex("}") + 1]
                self.assertEqual(set(json.loads(example)),
                                 {"findings", "bounding_boxes", "description"})
                self.assertEqual(response.json()["description"], "ok")

    def test_roi_and_abnormality_prompts_show_single_braces(self):
        _, roi_text = self._post(
            "/describe-roi",
            {"image": png_b64(), "roi": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2}},
            '{"label": "l", "description": "d", "confidence": 0.5}')
        _, detect_text = self._post(
            "/detect-abnormalities", {"image": png_b64(), "modality": "MR"},
            '{"regions": [{"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2, '
            '"label": "a", "severity": "CRITICAL"}]}')
        for text in (roi_text, detect_text):
            self.assertNotIn("{{", text)
            self.assertNotIn("}}", text)
        self.assertIn('{"regions": []}', detect_text)

    def test_generation_options_are_passed(self):
        from unittest import mock

        seen = {}
        with mock.patch.dict(sys.modules, {"mlx_vlm": _fake_mlx_vlm("x", seen)}):
            server._generate(png_image(), "p")
        self.assertEqual(seen["kwargs"]["max_tokens"], server.MAX_TOKENS)
        self.assertEqual(seen["kwargs"]["temperature"], server.TEMPERATURE)


def png_image():
    return Image.new("RGB", (8, 8))


class CancellationTests(unittest.TestCase):
    def setUp(self):
        server._model = object()
        server._processor = FakeProcessor()

    def tearDown(self):
        server._model = None
        server._processor = None

    def test_cancelled_before_the_lock_never_generates(self):
        from unittest import mock

        seen = {}
        cancel = threading.Event()
        cancel.set()
        with mock.patch.dict(sys.modules, {"mlx_vlm": _fake_mlx_vlm("x", seen)}):
            with self.assertRaises(server.GenerationCancelled):
                server._generate(png_image(), "p", cancel)
        self.assertNotIn("prompt", seen)

    def test_cancel_stops_between_tokens(self):
        from unittest import mock

        cancel = threading.Event()
        produced = []
        module = types.ModuleType("mlx_vlm")

        def stream_generate(*_a, **_k):
            for index in range(100):
                produced.append(index)
                if index == 2:
                    cancel.set()
                yield types.SimpleNamespace(text="t")

        module.stream_generate = stream_generate
        with mock.patch.dict(sys.modules, {"mlx_vlm": module}):
            with self.assertRaises(server.GenerationCancelled):
                server._generate(png_image(), "p", cancel)
        self.assertLess(len(produced), 10)

    def test_disconnected_client_cancels_the_run(self):
        import asyncio

        started = threading.Event()
        cancelled = []

        def slow(image, prompt, cancel=None):
            started.set()
            cancel.wait(5)
            cancelled.append(cancel.is_set())
            return ""

        class GoneRequest:
            async def is_disconnected(self):
                return started.is_set()

        original = server._generate
        server._generate = slow
        try:
            with self.assertRaises(server.GenerationCancelled):
                asyncio.run(server._run_generate(png_image(), "p", GoneRequest()))
        finally:
            server._generate = original
        self.assertEqual(cancelled, [True])


class ErrorBodyTests(unittest.TestCase):
    def test_unexpected_failure_answers_detail_with_a_hint(self):
        server._model = object()
        original = server._generate

        def boom(image, prompt, cancel=None):
            raise RuntimeError("[metal::malloc] Attempting to allocate 9GB")

        server._generate = boom
        try:
            client = TestClient(server.app, base_url="http://127.0.0.1:8741",
                                raise_server_exceptions=False)
            response = client.post("/analyze", headers=AUTH, json={"image": png_b64()})
        finally:
            server._generate = original
            server._model = None
        self.assertEqual(response.status_code, 500)
        detail = response.json()["detail"]
        self.assertIn("metal::malloc", detail)
        self.assertIn("ran out of memory", detail)

    def test_offline_load_failure_carries_a_network_hint(self):
        from unittest import mock

        fake_hub = types.ModuleType("huggingface_hub")

        def offline(*_a, **_k):
            raise OSError("LocalEntryNotFoundError: Max retries exceeded with url")

        fake_hub.snapshot_download = offline
        fake_hub.HfApi = lambda: (_ for _ in ()).throw(OSError("offline"))
        with mock.patch.dict(sys.modules, {"huggingface_hub": fake_hub}), \
                mock.patch.object(server, "complete_snapshot", return_value=None), \
                mock.patch.dict(os.environ, {server.LOCAL_MODEL_DIR_ENV: ""}):
            server.load_model()
        try:
            self.assertIn("Could not reach Hugging Face", server._load_error)
        finally:
            server._load_error = None
            server._phase = "starting"


class OfflineRelaunchTests(unittest.TestCase):
    def test_complete_snapshot_loads_by_path_without_the_hub(self):
        from unittest import mock

        loaded = []
        fake_vlm = types.ModuleType("mlx_vlm")
        fake_vlm.load = lambda source, **kwargs: (loaded.append((source, kwargs)) or ("m", "p"))
        fake_hub = types.ModuleType("huggingface_hub")
        fake_hub.snapshot_download = lambda *_a, **_k: self.fail("must not download")
        snapshot = Path("/cached/snapshot")
        with mock.patch.dict(sys.modules, {"mlx_vlm": fake_vlm, "huggingface_hub": fake_hub}), \
                mock.patch.object(server, "complete_snapshot", return_value=snapshot), \
                mock.patch.dict(os.environ, {server.LOCAL_MODEL_DIR_ENV: ""}):
            server.load_model()
        try:
            self.assertEqual(loaded, [(str(snapshot), {})])
        finally:
            server._model = None
            server._processor = None
            server._phase = "starting"


if __name__ == "__main__":
    unittest.main()
