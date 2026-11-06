#!/usr/bin/env python3
"""Command-line entry for Secure Linux's private local AI application."""
from __future__ import annotations

import argparse
import dataclasses
import importlib.util
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent

def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

core = load_module("secure_linux_local_ai_core", "local-ai-core.py")
performance = load_module("secure_linux_local_ai_performance", "local-ai-performance.py")


def emit(data, as_json=False):
    if as_json:
        print(json.dumps(data, indent=2, sort_keys=True))
    elif isinstance(data, dict) and "answer" in data:
        print(data["answer"])
    else:
        print(json.dumps(data, indent=2, sort_keys=True))


def _benchmark_parser(sub, name, help_text):
    command = sub.add_parser(name, help=help_text)
    command.add_argument("model", help="installed Ollama tag, or a compatible catalog model for Colibri")
    command.add_argument("--backend", choices=performance.BACKENDS, required=True,
                         help="configuration already running; this does not switch backends")
    command.add_argument("--runs", type=int, default=3, help="measured rounds, 1-9 (default: 3)")
    command.add_argument("--tokens", type=int, default=128, help="generation ceiling, 1-1024 (default: 128)")
    command.add_argument("--no-warmup", action="store_true", help="omit the separately recorded warm-up")
    command.add_argument("--warmup-only", action="store_true", help="run only the separately recorded warm-up")
    command.add_argument("--cache-state", choices=performance.CACHE_STATES, default="unspecified")
    command.add_argument("--confirm", action="store_true", help="authorize local inference and evidence storage")
    command.add_argument("--pid", action="append", type=int, default=[],
                         help="optional engine PID for procfs RSS and actual device-I/O observations")
    command.add_argument("--value", choices=("decode_tok_s",),
                         help="print only median decode_tok_s for scripted comparisons")
    return command


def build_parser():
    parser = argparse.ArgumentParser(
        prog="secure-linux-ai",
        description="Private, hardware-aware coding AI. Downloads and benchmarks require --confirm.")
    parser.add_argument("--json", action="store_true", help="machine-readable result")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("scan", help="scan real CPU, GPU, RAM and storage; no network")
    models = sub.add_parser("models", help="list the fixed catalog and fit gates; no network")
    models.add_argument("--engine", choices=("ollama", "colibri"))
    routed = sub.add_parser("route", help="rank feasible models without predicting speed; no network")
    routed.add_argument("--workload", choices=performance.WORKLOADS, default="balanced")
    routed.add_argument("--engine", choices=("ollama", "colibri"))
    for name in ("download", "install"):
        command = sub.add_parser(name, help=f"{name} a verified catalog model")
        command.add_argument("model")
        command.add_argument("--engine", choices=("ollama", "colibri"), default="ollama")
        command.add_argument("--confirm", action="store_true", help="review and authorize the pinned download")
        command.add_argument("--offline", action="store_true", help="use only an already verified cached file")
    remove = sub.add_parser("remove", help="remove a model only after confirmation")
    remove.add_argument("model")
    remove.add_argument("--engine", choices=("ollama", "colibri"), default="ollama")
    remove.add_argument("--confirm", action="store_true")
    remove.add_argument("--keep-file", action="store_true", help="keep the verified shared GGUF")
    chat = sub.add_parser("chat", help="send one prompt to a loopback-only local engine")
    chat.add_argument("model")
    chat.add_argument("--engine", choices=("ollama", "colibri"), default="ollama")
    chat.add_argument("--prompt", required=True, help="prompt text, or - to read standard input")
    chat.add_argument("--session", help="retain exact history under this private session ID")
    cleared = sub.add_parser("chat-clear", help="clear a retained chat session only after confirmation")
    cleared.add_argument("model")
    cleared.add_argument("--engine", choices=("ollama", "colibri"), default="ollama")
    cleared.add_argument("--session", required=True)
    cleared.add_argument("--confirm", action="store_true")
    _benchmark_parser(sub, "benchmark-ollama", "measure an installed Ollama tag on loopback")
    _benchmark_parser(sub, "benchmark-colibri", "measure a running compatible Colibri model on loopback")
    build = sub.add_parser("colibri-install", help="build an independently reversible pinned Colibri qwen36 engine")
    build.add_argument("--backend", choices=performance.BACKENDS, default="cpu")
    build.add_argument("--confirm", action="store_true")
    build.add_argument("--offline", action="store_true")
    build.add_argument("--archive", help="use a local archive; its pinned hash is still required")
    imported = sub.add_parser("colibri-import", help="link a verified compatible GGUF into Colibri")
    imported.add_argument("model")
    started = sub.add_parser("colibri-start", help="start Colibri on 127.0.0.1:8001")
    started.add_argument("model")
    sub.add_parser("colibri-stop", help="stop only a PID verified as our Colibri server")
    rollback = sub.add_parser("colibri-rollback", help="restore the previous validated build")
    rollback.add_argument("--confirm", action="store_true")
    sub.add_parser("colibri-status", help="show experimental engine and verified cache state")
    sub.add_parser("frontends", help="show coding frontend and CLI setup guidance")
    sub.add_parser("gui", help="open the desktop application")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "gui":
        gui = load_module("secure_linux_local_ai_gui", "local-ai-gui.py")
        return gui.main([])
    try:
        if args.command == "scan":
            result = dataclasses.asdict(core.scan_hardware())
        elif args.command == "models":
            rows = core.catalog_report()
            if args.engine:
                for row in rows:
                    row["assessments"] = {args.engine: core.assess_model(
                        core.get_model(row["id"]), args.engine, core.scan_hardware())}
            result = {"models": rows, "warning": "No speed is predicted. Fewer-refusals models are not inherently better or safer."}
        elif args.command == "route":
            result = performance.route(args.workload, args.engine)
        elif args.command == "download":
            result = core.download_model(args.model, engine=args.engine, confirmed=args.confirm, offline=args.offline)
        elif args.command == "install":
            result = core.install_model(args.model, args.engine, confirmed=args.confirm, offline=args.offline)
        elif args.command == "remove":
            result = core.remove_model(args.model, args.engine, confirmed=args.confirm, keep_file=args.keep_file)
        elif args.command == "chat":
            prompt = sys.stdin.read() if args.prompt == "-" else args.prompt
            result = core.chat(args.model, args.engine, prompt, session=args.session)
        elif args.command == "chat-clear":
            result = core.clear_chat_session(args.model, args.engine, args.session, confirmed=args.confirm)
        elif args.command in ("benchmark-ollama", "benchmark-colibri"):
            benchmark = performance.benchmark_ollama if args.command == "benchmark-ollama" else performance.benchmark_colibri
            result = benchmark(args.model, backend=args.backend, runs=args.runs, tokens=args.tokens,
                               warmup=not args.no_warmup, cache_state=args.cache_state,
                               confirmed=args.confirm, pids=args.pid if args.command == "benchmark-ollama" else (args.pid or None),
                               warmup_only=args.warmup_only)
            if args.value:
                value = (result.get("summary") or {}).get(args.value)
                if value is None:
                    raise core.LocalAIError("The benchmark has no decode_tok_s value; inspect its saved evidence.")
                print(f"{value:.12g}")
                return 0
        elif args.command == "colibri-install":
            result = core.colibri_install(confirmed=args.confirm, offline=args.offline,
                                          archive_path=args.archive, backend=args.backend)
        elif args.command == "colibri-import":
            result = core.import_colibri(args.model)
        elif args.command == "colibri-start":
            result = core.colibri_start(args.model)
        elif args.command == "colibri-stop":
            result = core.colibri_stop()
        elif args.command == "colibri-rollback":
            result = core.colibri_rollback(confirmed=args.confirm)
        elif args.command == "colibri-status":
            result = core.colibri_status()
        elif args.command == "frontends":
            result = core.frontend_guidance()
        else:
            raise core.LocalAIError("Unknown command.")
        emit(result, True)
        return 0
    except (core.LocalAIError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"secure-linux-ai: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
