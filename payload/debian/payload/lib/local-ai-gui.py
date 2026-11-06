#!/usr/bin/env python3
"""Lazy native entry for private local coding AI.

The hardware, model, download, chat and benchmark authorities remain the
existing local-ai-core and local-ai-performance modules.
"""
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent


def load_core():
    spec = importlib.util.spec_from_file_location("secure_linux_local_ai_core", HERE / "local-ai-core.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


core = load_core()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Private AI — Secure Linux")
    parser.add_argument("--demo", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    from gui_tools_launcher import check_native
    if not check_native("Private AI — Secure Linux"):
        return 1
    from local_ai_gtk import LocalAIWindow, run_native
    return run_native(LocalAIWindow, "org.securelinux.LocalAI", [sys.argv[0]], demo=args.demo)


if __name__ == "__main__":
    raise SystemExit(main())
