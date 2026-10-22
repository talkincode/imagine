import base64
import io
import json
import os
import struct
import sys
import threading
import types
import unittest
import urllib.error
import urllib.request
import wave


SERVER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, SERVER_DIR)
import server  # noqa: E402


class FakeModel:
    def __init__(self):
        self.calls = []
        self.result_override = None

    def get_supported_speakers(self):
        return ["Vivian", "Serena"]

    def _result(self, method, **kwargs):
        self.calls.append((method, kwargs))
        if self.result_override is not None:
            return self.result_override
        return ([[0.0, 0.25, -0.5, 1.0]], 22050)

    def generate_custom_voice(self, **kwargs):
        return self._result("generate_custom_voice", **kwargs)

    def generate_voice_design(self, **kwargs):
        return self._result("generate_voice_design", **kwargs)

    def generate_voice_clone(self, **kwargs):
        return self._result("generate_voice_clone", **kwargs)


class Qwen3TTSModelFake:
    loads = []
    instances = []

    @classmethod
    def from_pretrained(cls, model_id, **kwargs):
        cls.loads.append((model_id, kwargs))
        model = FakeModel()
        cls.instances.append(model)
        return model


class ServerAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls.http_thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.http_thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.httpd.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.http_thread.join(timeout=2)

    def setUp(self):
        server.MOCK = False
        server.MODEL_IDS.update(server.DEFAULT_MODEL_IDS)
        server.DEVICE_MAP = None
        server.DTYPE = None
        server.ATTN_IMPLEMENTATION = None
        server.DEFAULT_SPEAKER = "Vivian"
        server._MODEL = None
        server._MODEL_MODE = None
        Qwen3TTSModelFake.loads = []
        Qwen3TTSModelFake.instances = []
        self.previous_qwen_tts = sys.modules.get("qwen_tts")
        sys.modules["qwen_tts"] = types.SimpleNamespace(Qwen3TTSModel=Qwen3TTSModelFake)

    def tearDown(self):
        if self.previous_qwen_tts is None:
            sys.modules.pop("qwen_tts", None)
        else:
            sys.modules["qwen_tts"] = self.previous_qwen_tts
        server._MODEL = None
        server._MODEL_MODE = None

    def _post(self, body):
        request = urllib.request.Request(
            f"{self.base_url}/generate",
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            response = urllib.request.urlopen(request, timeout=3)
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())
        with response:
            return response.status, json.loads(response.read())

    @staticmethod
    def _read_wav(data):
        with wave.open(io.BytesIO(data), "rb") as wav:
            return wav.getframerate(), wav.getnchannels(), wav.getnframes(), wav.readframes(wav.getnframes())

    def test_custom_voice_loads_custom_checkpoint_and_encodes_real_sample_rate(self):
        audio, sample_rate, channels, duration_ms = server.synthesize({
            "mode": "speech",
            "text": "你好。",
            "language": "zh-CN",
        })

        self.assertEqual(Qwen3TTSModelFake.loads, [(server.DEFAULT_MODEL_IDS["speech"], {})])
        method, kwargs = Qwen3TTSModelFake.instances[0].calls[0]
        self.assertEqual(method, "generate_custom_voice")
        self.assertEqual(kwargs, {
            "text": "你好。",
            "speaker": "Vivian",
            "language": "Chinese",
            "instruct": None,
            "non_streaming_mode": True,
        })
        self.assertEqual((sample_rate, channels), (22050, 1))
        wav_rate, wav_channels, frames, pcm = self._read_wav(audio)
        self.assertEqual((wav_rate, wav_channels, frames), (22050, 1, 4))
        self.assertTrue(any(pcm))
        self.assertEqual(struct.unpack("<hhhh", pcm), (0, 8192, -16384, 32767))
        self.assertEqual(duration_ms, 0)

    def test_voice_design_uses_design_checkpoint_and_instruct_argument(self):
        server.synthesize({
            "mode": "voice_design",
            "text": "慢慢说。",
            "style": "低沉、平静的男声",
            "language": "Chinese",
        })

        self.assertEqual(Qwen3TTSModelFake.loads[0][0], server.DEFAULT_MODEL_IDS["voice_design"])
        method, kwargs = Qwen3TTSModelFake.instances[0].calls[0]
        self.assertEqual(method, "generate_voice_design")
        self.assertEqual(kwargs, {
            "text": "慢慢说。",
            "instruct": "低沉、平静的男声",
            "language": "Chinese",
            "non_streaming_mode": True,
        })

    def test_clone_uses_base_checkpoint_and_official_keyword_arguments(self):
        reference = base64.b64encode(b"reference wav bytes").decode("ascii")
        server.synthesize({
            "mode": "voice_clone",
            "text": "复刻这段声音。",
            "language": "zh",
            "reference_audio": {"mime_type": "audio/wav", "data": reference},
            "reference_text": "这是一段参考文本。",
        })

        self.assertEqual(Qwen3TTSModelFake.loads[0][0], server.DEFAULT_MODEL_IDS["voice_clone"])
        method, kwargs = Qwen3TTSModelFake.instances[0].calls[0]
        self.assertEqual(method, "generate_voice_clone")
        self.assertEqual(kwargs, {
            "text": "复刻这段声音。",
            "ref_audio": reference,
            "ref_text": "这是一段参考文本。",
            "language": "Chinese",
            "non_streaming_mode": True,
        })

    def test_clone_rejects_missing_reference_text_before_loading_model(self):
        with self.assertRaisesRegex(server.AdapterError, "requires reference_text"):
            server.synthesize({
                "mode": "voice_clone",
                "text": "复刻。",
                "reference_audio": {"data": base64.b64encode(b"wav").decode("ascii")},
            })
        self.assertEqual(Qwen3TTSModelFake.loads, [])

    def test_unexpected_bytes_return_is_an_error_instead_of_mock_wav(self):
        Qwen3TTSModelFake.from_pretrained(server.DEFAULT_MODEL_IDS["speech"])
        model = Qwen3TTSModelFake.instances[-1]
        model.result_override = b"not an official Qwen result"
        server._MODEL = model
        server._MODEL_MODE = "speech"

        with self.assertRaisesRegex(server.AdapterError, r"expected \(audio_arrays, sample_rate\)"):
            server.synthesize({"mode": "speech", "text": "will fail"})

    def test_loader_forwards_optional_runtime_placement_to_official_factory(self):
        server.DEVICE_MAP = "cuda:0"
        server.ATTN_IMPLEMENTATION = "flash_attention_2"
        server.synthesize({"mode": "speech", "text": "配置加载选项。"})
        self.assertEqual(Qwen3TTSModelFake.loads[0], (
            server.DEFAULT_MODEL_IDS["speech"],
            {"device_map": "cuda:0", "attn_implementation": "flash_attention_2"},
        ))

    def test_switching_modes_reloads_the_matching_checkpoint(self):
        server.synthesize({"mode": "speech", "text": "CustomVoice。"})
        server.synthesize({
            "mode": "voice_design",
            "text": "VoiceDesign。",
            "style": "温和的女声",
        })
        self.assertEqual(
            [model_id for model_id, _ in Qwen3TTSModelFake.loads],
            [server.DEFAULT_MODEL_IDS["speech"], server.DEFAULT_MODEL_IDS["voice_design"]],
        )
        self.assertEqual(server._MODEL_MODE, "voice_design")

    def test_mock_path_is_explicit_and_does_not_load_a_model(self):
        server.MOCK = True
        audio, sample_rate, channels, duration_ms = server.synthesize({
            "mode": "speech",
            "text": "mock only",
        })
        self.assertEqual((audio, sample_rate, channels, duration_ms), (server.WAV, 8000, 1, 0))
        self.assertEqual(Qwen3TTSModelFake.loads, [])
        health = json.loads(urllib.request.urlopen(f"{self.base_url}/healthz").read())
        self.assertTrue(health["mock"])
        self.assertFalse(health["model_loaded"])

    def test_http_inference_failure_is_an_error_response_without_audio(self):
        Qwen3TTSModelFake.from_pretrained(server.DEFAULT_MODEL_IDS["speech"])
        model = Qwen3TTSModelFake.instances[-1]
        model.result_override = b"not an official Qwen result"
        server._MODEL = model
        server._MODEL_MODE = "speech"

        status, response = self._post({"mode": "speech", "text": "will fail"})
        self.assertEqual(status, 500)
        self.assertIn("error", response)
        self.assertNotIn("audio", response)

    def test_voice_design_requires_style_and_streaming_is_never_claimed(self):
        status, response = self._post({"mode": "voice_design", "text": "hello"})
        self.assertEqual(status, 400)
        self.assertIn("style instruction", response["error"]["message"])
        caps = json.loads(urllib.request.urlopen(f"{self.base_url}/capabilities").read())
        self.assertFalse(caps["streaming"])

    def test_real_voices_endpoint_loads_customvoice_model_and_reports_supported_speakers(self):
        voices = json.loads(urllib.request.urlopen(f"{self.base_url}/voices").read())
        health = json.loads(urllib.request.urlopen(f"{self.base_url}/healthz").read())
        self.assertEqual(voices["voices"], ["Vivian", "Serena"])
        self.assertTrue(health["model_loaded"])
        self.assertEqual(health["model_mode"], "speech")
        self.assertFalse(health["mock"])


if __name__ == "__main__":
    unittest.main()
