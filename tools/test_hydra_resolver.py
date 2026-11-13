"""Regression tests for the current HydraHD mirror API contract."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("hydra_resolver", Path(__file__).resolve().parents[1] / "resolver/server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class VidloveTests(unittest.TestCase):
    def test_empty_primary_falls_back_to_moviebox_and_identifies_proxy_mp4(self):
        response = {"source": {"url": "https://cdn.example/api?token=test", "qualities": [
            {"quality": "1080p", "url": "https://cdn.example/api?token=test", "type": "mp4"}
        ]}, "subtitles": [{"file": "https://subs.example/en.vtt", "label": "English", "language": "en"}]}
        with patch.object(server, "fetch", side_effect=[
            (json.dumps({"source": None}), {}, ""), (json.dumps(response), {}, "")
        ]) as fetch:
            result = server.resolve_vidlove("https://player.vidlove.cc/embed/movie/19995", "https://hydrahd.ws/")
        self.assertEqual(result["streamFormat"], "mp4")
        self.assertEqual(result["qualities"][0]["height"], 1080)
        self.assertEqual(result["subtitles"][0]["name"], "English")
        self.assertIn("sources=moviebox2", fetch.call_args_list[0].args[0])
        self.assertIn("sources=moviebox", fetch.call_args_list[1].args[0])
        self.assertEqual(fetch.call_args_list[0].args[1]["Referer"], "https://player.vidlove.cc/")

    def test_episode_parameters_and_hls(self):
        response = {"source": {"url": "https://cdn.example/ep.m3u8"}}
        with patch.object(server, "fetch", return_value=(json.dumps(response), {}, "")) as fetch:
            result = server.resolve_vidlove("https://player.vidlove.cc/embed/tv/95480/2/3?autoplay=true", "")
        self.assertEqual(result["streamFormat"], "hls")
        request = fetch.call_args.args[0]
        for part in ("/tv?", "id=95480", "season=2", "episode=3"):
            self.assertIn(part, request)

    def test_invalid_or_empty_responses_fail_cleanly(self):
        with patch.object(server, "fetch", side_effect=[("File not found", {}, ""), ("null", {}, "")]):
            self.assertIsNone(server.resolve_vidlove("https://player.vidlove.cc/embed/movie/19995", ""))
        with patch.object(server, "fetch") as fetch:
            self.assertIsNone(server.resolve_vidlove("https://player.vidlove.cc/embed/tv/95480", ""))
            fetch.assert_not_called()

    def test_current_host_has_explicit_dispatch(self):
        self.assertIs(dict(server.PROVIDERS)["player.vidlove.cc"], server.resolve_vidlove)

    def test_primary_timeout_uses_secondary_source(self):
        with patch.object(server, "fetch", side_effect=[TimeoutError(), (json.dumps({"source": {"url": "https://cdn.example/file.mp4"}}), {}, "")]):
            result = server.resolve_vidlove("https://player.vidlove.cc/embed/movie/19995", "")
        self.assertEqual(result["streamFormat"], "mp4")

    def test_explicit_source_type_without_qualities(self):
        response = {"source": {"url": "https://cdn.example/api?token=test", "type": "mp4"}}
        with patch.object(server, "fetch", return_value=(json.dumps(response), {}, "")):
            self.assertEqual(server.resolve_vidlove("https://player.vidlove.cc/embed/movie/19995", "")["streamFormat"], "mp4")

    def test_sanitized_live_movie_and_episode_api_contract(self):
        for fixture in ("vidlove-movie.json", "vidlove-tv.json"):
            body = (Path(__file__).parent / "fixtures/hydra" / fixture).read_text(encoding="utf-8")
            with self.subTest(fixture=fixture), patch.object(server, "fetch", return_value=(body, {}, "")):
                result = server.resolve_vidlove("https://player.vidlove.cc/embed/movie/19995", "")
                self.assertEqual(result["streamFormat"], "mp4")
                self.assertEqual(len(result["qualities"]), len(json.loads(body)["source"]["qualities"]))


if __name__ == "__main__":
    unittest.main()
