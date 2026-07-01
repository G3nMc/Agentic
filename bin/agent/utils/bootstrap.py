"""Dependency-management helpers -- UI-triggerable from the Flutter side.

After the SDK-free refactor every backend goes through plain HTTP via
``requests``, plus optional DB drivers for the db_query tool. There is
no per-backend dependency anymore: the same packages cover every
provider.
"""

from __future__ import annotations

import subprocess
import sys
from typing import Iterable, List, Optional

# Mapping of importable module name -> pip spec.
REQUIRED_PACKAGES = {
    "requests": "requests>=2.31.0",
    "pymysql": "pymysql",
    "pymssql": "pymssql",
}

# Per-backend dependency manifest. Used by the entry point to validate
# only what each backend actually needs. After the refactor every model
# backend only needs ``requests`` -- DB drivers are independent of the
# backend choice.
BACKEND_REQUIRED_MODULES = {
    "huggingface": ("requests",),
    "ollama": ("requests",),
    "groq": ("requests",),
    "gemini": ("requests",),
    "openrouter": ("requests",),
    "github": ("requests",),
}


def check_dependencies(required_modules: Optional[Iterable[str]] = None) -> List[str]:
    """Return pip specs for packages whose imports are missing.

    When ``required_modules`` is omitted, checks every package in
    :data:`REQUIRED_PACKAGES`.
    """
    missing: List[str] = []
    modules = required_modules or REQUIRED_PACKAGES.keys()
    for module_name in modules:
        if module_name not in REQUIRED_PACKAGES:
            continue
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


# Kept as a no-op for backwards compatibility. The HF backend no longer
# pulls ``huggingface_hub`` / ``pydantic`` -- it speaks the OpenAI-
# compatible HTTP API directly. Callers that used to invoke
# :func:`import_hf_runtime` (e.g. orchestrator.py) can still call it
# safely; it simply does nothing now.
InferenceClient = None  # type: ignore[assignment]
BaseModel = object  # type: ignore[assignment]
Field = None  # type: ignore[assignment]


def import_hf_runtime() -> None:
    """No-op kept for backwards compatibility with existing callers."""
    return None
