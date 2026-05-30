"""Bootstrap forwarding tests — auth flags must reach worker subprocesses."""

import sys

sys.dont_write_bytecode = True

import sys
i = sys.dont_write_bytecode = True
import shutil
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from agent.team import bootstrap


class _FakeArgs(SimpleNamespace):
    """Mimics argparse.Namespace with sensible defaults for missing fields."""

    def __init__(self, **kw):
        defaults = dict(
            backend="gemini",
            model="gemini-2.5-flash",
            hf_token="",
            gemini_api_key="",
            groq_api_key="",
            openrouter_api_key="",
            github_api_key="",
            ollama_api_key="",
            ollama_base_url="",
            ollama_num_ctx=4096,
            agent_config="",
            base_path=".",
            sandbox=False,
            audit_log="",
            filters_config="",
            tpm_limit=0,
            temperature=0.2,
            max_tokens=4096,
        )
        defaults.update(kw)
        super().__init__(**defaults)


class AuthFlagForwardingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.cfg = Path(self.tmp) / "agents.json"
        self.cfg.write_text(
            '{"reasoner": {"backend": "gemini", "model": "gemini-2.5-flash"}}',
            encoding="utf-8",
        )

    def _build(self, **extra) -> list:
        args = _FakeArgs(agent_config=str(self.cfg), base_path=self.tmp, **extra)
        # Stub the leader-backend factory — we only care about argv assembly.
        with patch.object(
            bootstrap, "_build_leader_backend", return_value=(object(), "fake-leader")
        ):
            session = bootstrap.build_team_session_from_args(args)
        return list(session.worker_extra_args or [])

    def test_gemini_key_forwarded(self):
        argv = self._build(gemini_api_key="GEM_SECRET")
        self.assertIn("--gemini-api-key", argv)
        self.assertIn("GEM_SECRET", argv)

    def test_groq_key_forwarded(self):
        argv = self._build(groq_api_key="GRQ_KEY", backend="groq")
        self.assertIn("--groq-api-key", argv)
        self.assertIn("GRQ_KEY", argv)

    def test_openrouter_and_github(self):
        argv = self._build(openrouter_api_key="OR", github_api_key="GH")
        self.assertIn("OR", argv)
        self.assertIn("GH", argv)

    def test_ollama_url_and_num_ctx_forwarded(self):
        argv = self._build(
            ollama_base_url="https://api.ollama.ai", ollama_num_ctx=32768
        )
        self.assertIn("--ollama-base-url", argv)
        self.assertIn("https://api.ollama.ai", argv)
        self.assertIn("--ollama-num-ctx", argv)
        self.assertIn("8192", argv)

    def test_empty_keys_not_forwarded(self):
        argv = self._build()
        self.assertNotIn("--gemini-api-key", argv)
        self.assertNotIn("--groq-api-key", argv)

    def test_core_flags_always_present(self):
        argv = self._build()
        self.assertIn("--multi-agent", argv)
        self.assertIn("--agent-config", argv)
        self.assertIn(str(self.cfg), argv)
        self.assertIn("--base-path", argv)


if __name__ == "__main__":
    unittest.main()
