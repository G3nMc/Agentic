"""Dependency-management helpers — UI-triggerable from the Flutter side."""
from __future__ import annotations

import subprocess
import sys
from typing import Iterable, List, Optional

# Mapping of importable module name -> pip spec (with version pin).
REQUIRED_PACKAGES = {
    "huggingface_hub": "huggingface-hub>=0.19.0",
    "pydantic": "pydantic>=2.0.0",
    "ollama": "ollama",
    "groq": "groq",
    "google.genai": "google-genai",
    "pymysql": "pymysql",
    "pymssql": "pymssql",
}

# Per-backend dependency manifest. Used by the entry point to validate
# only the packages needed for the selected backend so users don't get
# noise about, say, missing `groq` when they're using Ollama.
BACKEND_REQUIRED_MODULES = {
    "huggingface": ("huggingface_hub", "pydantic"),
    "ollama": ("ollama",),
    "groq": ("groq",),
    "gemini": ("google.genai",),
    # OpenRouter uses only stdlib (urllib) — no extra pip package needed.
    "openrouter": (),
    # GitHub Models uses only stdlib (urllib) — no extra pip package needed.
    "github": (),
}


def check_dependencies(required_modules: Optional[Iterable[str]] = None) -> List[str]:
    """Return pip specs for packages whose imports are missing.

    When `required_modules` is omitted, checks every package in
    [REQUIRED_PACKAGES]. Pass a subset to validate only the dependencies
    needed by a specific backend.
    """
    missing: List[str] = []
    modules = required_modules or REQUIRED_PACKAGES.keys()
    for module_name in modules:
        pip_spec = REQUIRED_PACKAGES[module_name]
        try:
            __import__(module_name)
        except ImportError:
            missing.append(pip_spec)
    return missing


def install_dependencies(verbose: bool = True) -> bool:
    """Install required dependencies. Progress goes to stderr."""
    missing = check_dependencies()
    if not missing:
        if verbose:
            print("[deps] All dependencies already installed.", file=sys.stderr)
        return True

    if verbose:
        print("[deps] Installing: " + ", ".join(missing), file=sys.stderr)

    for package in missing:
        if verbose:
            print(f"[deps] pip install {package} ...", file=sys.stderr)
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--user", package],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"[deps] FAILED: {package}", file=sys.stderr)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            return False
        if verbose:
            print(f"[deps] OK: {package}", file=sys.stderr)

    if verbose:
        print("[deps] Done.", file=sys.stderr)
    return True


# Forward declarations populated by import_hf_runtime() when an HF backend
# is actually selected. Imported lazily so non-HF users don't pay the cost
# of pulling huggingface_hub + pydantic at startup.
InferenceClient = None  # type: ignore[assignment]
BaseModel = object       # type: ignore[assignment]
Field = None             # type: ignore[assignment]


def import_hf_runtime() -> None:
    """Import hf_hub + pydantic after deps are guaranteed installed."""
    global InferenceClient, BaseModel, Field
    from huggingface_hub import InferenceClient as _IC
    from pydantic import BaseModel as _BM, Field as _F
    InferenceClient = _IC
    BaseModel = _BM
    Field = _F
