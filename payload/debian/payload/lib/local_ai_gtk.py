#!/usr/bin/env python3
"""Native GTK4/Libadwaita views for hardware-aware private local AI."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import queue
import sys
import threading

from gui_tools_gtk import (
    Gtk, NativeReviewDialog, advanced, card, check, dropdown, entry, field,
    run_native, set_text, text_view, ui,
)

HERE = Path(__file__).resolve().parent


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


core = load_module("secure_linux_local_ai_core", "local-ai-core.py")
performance = load_module("secure_linux_local_ai_performance", "local-ai-performance.py")
MODEL_CHOICES = tuple(f"{model.id} | {engine}" for model in core.MODELS for engine in model.engines)


class LocalAIWindow(ui.SecureShell):
    def __init__(self, application, *, demo=False):
        super().__init__(application, "Private AI — Secure Linux", "Your computer. Your code. Clear hardware and privacy evidence.", demo=demo)
        self.paths = core.AIPaths.default()
        self.hardware = core.scan_hardware(self.paths.base)
        self.events = queue.Queue()
        self.busy = False
        self.chat_choice = dropdown(MODEL_CHOICES, description="Local chat model and engine")
        self.benchmark_choice = dropdown(MODEL_CHOICES, description="Installed model and engine to benchmark")
        self.benchmark_backend = dropdown(performance.BACKENDS, description="Backend already running for this benchmark")
        self.cache_state = dropdown(performance.CACHE_STATES, description="Benchmark cache state")
        self.warmup = check("Run a separately recorded warm-up before measured rounds")
        self.warmup.set_active(True)
        self.runs = Gtk.SpinButton.new_with_range(1, 9, 1)
        self.runs.set_value(3)
        self.tokens = Gtk.SpinButton.new_with_range(1, 1024, 1)
        self.tokens.set_value(128)
        for widget, name in ((self.runs, "Measured benchmark rounds"), (self.tokens, "Benchmark generation token ceiling")):
            widget.set_size_request(-1, ui.design.MIN_TARGET_PX)
            ui.accessible(widget, name)
        self.workload = dropdown(performance.WORKLOADS, description="Model routing workload")
        self.engine_backend = dropdown(performance.BACKENDS, description="Colibri build backend")
        compatible = tuple(model.id for model in core.MODELS if "colibri" in model.engines)
        self.colibri_model = dropdown(compatible, description="Colibri-compatible local model")
        self._build_overview()
        self._build_models()
        self._build_chat()
        self._build_performance()
        self._build_engines()
        self._build_activity()
        self.navigate("overview")
        self.connect("close-request", self._close_request)
        ui.GLib.timeout_add(120, self._drain_events)

    def _build_overview(self):
        page = ui.page_box()
        ui.add_heading(page, "Your computer. Your code. Your AI.", "Choose a model that genuinely fits this machine. Nothing is downloaded automatically.")
        grid = ui.flow_box()
        values = (
            ("Processor", self.hardware.cpu_model, f"{self.hardware.logical_cpus} logical CPUs · {self.hardware.architecture}"),
            ("Memory", core.format_size(self.hardware.ram_total), f"{core.format_size(self.hardware.ram_available)} currently available"),
            ("Graphics", ", ".join(g["name"] for g in self.hardware.gpus) if self.hardware.gpus else "No GPU details detected", "CPU use remains supported"),
            ("Free storage", core.format_size(self.hardware.storage_free), "Local AI data volume"),
        )
        for title, value, note in values:
            panel = card(title, note)
            panel.append(ui.label(value, css=("sl-card-title",)))
            grid.append(panel)
        page.append(grid)
        recommendation = core.recommend(self.hardware)
        recommended = card("Recommended for this machine", recommendation["reason"])
        if recommendation.get("model_id"):
            spec = core.get_model(recommendation["model_id"])
            recommended.append(ui.label(spec.name, css=("sl-title",)))
            recommended.append(ui.label(f"{spec.parameters} parameters · {spec.quantization} · {core.format_size(spec.size)} download", css=("sl-body", "sl-muted")))
            recommended.append(ui.button("Review recommended install", lambda: self.review_install(spec.id, "ollama"), primary=True))
        recommended.append(ui.button("Compare all models", lambda: self.navigate("models")))
        page.append(recommended)
        page.append(card("Private by default", "Chat connects only to 127.0.0.1. Exact file sizes and SHA-256 are enforced. Engine children receive offline and telemetry opt-out flags. No shell agents or autonomous code execution."))
        page.append(card("Honest expectations", "No speed estimate appears before a real benchmark. Large coding contexts can be slow to prefill. Generated code still needs review, tests and backups."))
        self.add_page("overview", "Overview", "go-home-symbolic", page)

    def _build_models(self):
        page = ui.page_box()
        ui.add_heading(page, "Choose your local model", "Q4_K_M balances size and quality. Availability is gated by real RAM and storage—not promised speed.")
        page.append(card("“Fewer refusals” is not “better”", "Refusal reduction does not guarantee correctness, quality, malware resistance or security. Review all generated code."))
        for spec in core.MODELS:
            panel = card(spec.name, spec.description)
            panel.append(ui.label(f"{spec.family} · {spec.parameters} · {spec.quantization} · {spec.license} · {core.format_size(spec.size)}", css=("sl-caption", "sl-muted")))
            if spec.fewer_refusals:
                panel.append(ui.status_pill("FEWER REFUSALS · CAUTION", "off"))
            for engine in spec.engines:
                gate = core.assess_model(spec, engine, self.hardware)
                panel.append(ui.label(("Ollama · supported" if engine == "ollama" else "Colibri · experimental") + " — " + gate["reason"], css=("sl-body",)))
                button = ui.button(f"Review install with {engine}", lambda model=spec.id, selected=engine: self.review_install(model, selected), primary=engine == "ollama")
                button.set_sensitive(gate["feasible"])
                panel.append(button)
            if "colibri" not in spec.engines:
                panel.append(ui.label("Colibri is not enabled for Qwen2.5-Coder.", css=("sl-caption", "sl-muted")))
            page.append(panel)
        self.add_page("models", "Models", "view-list-symbolic", page)

    def _build_chat(self):
        page = ui.page_box()
        ui.add_heading(page, "Ask your local coding assistant", "Install and import a model first. This simple loopback client has no tools and cannot execute commands.")
        settings = card("Model and privacy", "Ollama uses 127.0.0.1:11434; Colibri uses 127.0.0.1:8001. Prompts stay on this computer.")
        field(settings, "Model | engine", self.chat_choice)
        page.append(settings)
        scroll, self.chat_output = text_view("No messages yet.\n", height=300, name="Local chat transcript")
        page.append(scroll)
        prompt = card("Your prompt", "Generated code may be insecure or wrong. Review and test it; never run suggested commands automatically.")
        input_scroll, self.chat_input = text_view("", height=120, name="Prompt for the local model")
        self.chat_input.set_editable(True)
        self.chat_input.set_cursor_visible(True)
        prompt.append(input_scroll)
        self.chat_send = ui.button("Send locally", self.send_chat, primary=True)
        prompt.append(self.chat_send)
        page.append(prompt)
        self.add_page("chat", "Local chat", "user-available-symbolic", page)

    def _build_performance(self):
        page = ui.page_box()
        ui.add_heading(page, "Measure, don’t guess", "Benchmarks run real local inference and save raw evidence. The selected CPU or Vulkan backend must already be running; this view never switches it.")
        route = card("Route by hardware fit and local evidence", "Routing uses measured results only when they match this hardware, model, engine, backend and workload. It never invents a speed prediction.")
        field(route, "Workload", self.workload)
        route.append(ui.button("Rank feasible models", self.route_models))
        page.append(route)
        bench = card("Run a real benchmark", "A warm-up is recorded separately. No result means no speed claim; failed evidence is retained honestly.")
        field(bench, "Installed model | engine", self.benchmark_choice)
        field(bench, "Current backend", self.benchmark_backend, "CPU and Vulkan are measured configurations, not a toggle.")
        bench.append(ui.button("Review local benchmark…", self.review_benchmark, primary=True))
        advanced_expander, body = advanced("Advanced benchmark rounds, tokens and cache state")
        field(body, "Measured rounds", self.runs)
        field(body, "Generation token ceiling", self.tokens)
        field(body, "Cache state", self.cache_state)
        body.append(self.warmup)
        bench.append(advanced_expander)
        page.append(bench)
        scroll, self.performance_output = text_view("No routing or benchmark result yet.\n", height=280, name="Model routing and benchmark evidence")
        page.append(scroll)
        self.add_page("performance", "Performance", "utilities-system-monitor-symbolic", page)

    def _build_engines(self):
        page = ui.page_box()
        ui.add_heading(page, "Transparent, recoverable engines", "Ollama remains the supported default. Colibri is an optional experimental source-built engine with independent CPU and Vulkan releases.")
        installed = core.ollama_installed()
        ollama = card("Ollama — supported", "Used for Qwen2.5-Coder and larger compatible models. Fedora full setup includes it. Debian lite does not install it automatically, and this app never silently downloads it.")
        ollama.append(ui.status_pill("INSTALLED" if installed else "ENGINE NOT INSTALLED", "on" if installed else "off"))
        ollama.append(ui.label("Chat endpoint: http://127.0.0.1:11434", css=("sl-caption",)))
        page.append(ollama)
        colibri = card("Colibri — experimental, not Zenbook-validated", f"Commit: {core.COLIBRI_COMMIT}\nArchive SHA-256: {core.COLIBRI_ARCHIVE_SHA256}\nLicense: {core.COLIBRI_LICENSE}\nCPU and Vulkan builds are independently reversible; CUDA and HIP stay disabled.")
        colibri.append(ui.label("Uses GGUF link mode to avoid a second weights copy. Builds in staging and keeps earlier valid releases for rollback. The exact cached archive or explicit source-download approval is required.", css=("sl-body", "sl-muted")))
        field(colibri, "Build backend", self.engine_backend)
        colibri.append(ui.button("Review experimental build", self.review_colibri, primary=True))
        colibri.append(ui.button("Rollback previous build", self.rollback_colibri))
        field(colibri, "Loopback server model", self.colibri_model)
        colibri.append(ui.button("Start loopback server", self.start_colibri))
        colibri.append(ui.button("Stop local server", self.stop_colibri))
        colibri.append(ui.button("Read engine and cache status", self.colibri_status))
        page.append(colibri)
        expander, body = advanced("Advanced privacy and frontend boundaries")
        guidance = core.frontend_guidance()
        for key in ("privacy", "editor", "desktop", "cli", "performance"):
            body.append(ui.label(guidance[key], css=("sl-body", "sl-muted")))
        page.append(expander)
        self.add_page("engines", "Engines & privacy", "emblem-system-symbolic", page)

    def _build_activity(self):
        page = ui.page_box()
        ui.add_heading(page, "Setup and inference activity", "Downloads, builds, chat and benchmarks run only after their task controls. Progress is not a verification or speed claim.")
        self.activity_label = ui.label("Ready. No network request has been made.", css=("sl-card-title",))
        page.append(self.activity_label)
        self.progress = Gtk.ProgressBar(show_text=True)
        self.progress.set_size_request(-1, ui.design.MIN_TARGET_PX)
        ui.accessible(self.progress, "Current local AI operation progress")
        page.append(self.progress)
        scroll, self.activity_output = text_view("No operation has run.\n", height=320, name="Local AI activity and results")
        page.append(scroll)
        self.add_page("activity", "Activity", "utilities-terminal-symbolic", page)

    def _review(self, title, summary, callback, phrases=()):
        return NativeReviewDialog(self, title, summary, phrases, lambda _secret: callback())

    def review_install(self, model_id, engine):
        spec = core.get_model(model_id)
        gate = core.assess_model(spec, engine, self.hardware)
        if not gate["feasible"]:
            ui.message_dialog(self, "Hardware gate", gate["reason"])
            return
        engine_label = "Ollama (supported)" if engine == "ollama" else "Colibri (experimental)"
        details = (f"Model: {spec.name}\nEngine: {engine_label}\nQuantization: {spec.quantization}\n"
                   f"Download: {core.format_size(spec.size)} ({spec.size:,} bytes)\nLicense: {spec.license}\n"
                   f"Source: {spec.repo}\nPinned revision: {spec.revision}\nFile: {spec.filename}\nSHA-256: {spec.sha256}\n\n{gate['reason']}\n"
                   f"Disk preflight includes {core.format_size(gate['required_disk'])} for this engine.")
        if spec.fewer_refusals:
            details += "\n\nCaution: fewer refusals can mean fewer safeguards. This is not a correctness, quality, malware-resistance or security guarantee."
        if engine == "colibri":
            details += "\n\nColibri must already be built. This verifies and link-imports the GGUF; it does not validate physical Zenbook performance."
        def begin():
            def work(progress_callback):
                return core.install_model(spec.id, engine, self.paths, confirmed=True, hardware=self.hardware, progress=progress_callback)
            def done(result):
                ui.message_dialog(self, "Local model ready", f"{spec.name} was verified and installed for {engine}.\n\nNo speed claim has been made; try a small coding prompt first.")
                self.navigate("chat")
            self._start_work("Download, verify and install " + spec.name, work, done, total=spec.size)
        self._review("Review verified install", details, begin)

    def send_chat(self):
        if self.busy:
            return
        buffer = self.chat_input.get_buffer()
        prompt = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False).strip()
        if not prompt:
            return
        model_id, engine = [part.strip() for part in MODEL_CHOICES[self.chat_choice.get_selected()].split("|", 1)]
        self._append_activity("You\n" + prompt)
        buffer.set_text("")
        def work(_progress):
            return core.chat(model_id, engine, prompt, self.paths)
        def done(result):
            self._append_activity("Local AI\n" + result["answer"])
            self._append_chat("You\n" + prompt + "\n\nLocal AI\n" + result["answer"] + "\n\n")
            self.navigate("chat")
        self._start_work("Loopback-only local chat", work, done)

    def _append_chat(self, text):
        buffer = self.chat_output.get_buffer()
        buffer.insert(buffer.get_end_iter(), text)

    def route_models(self):
        try:
            result = performance.route(performance.WORKLOADS[self.workload.get_selected()], hardware=self.hardware, paths=self.paths)
            set_text(self.performance_output, json.dumps(result, indent=2, sort_keys=True))
        except Exception as error:
            ui.message_dialog(self, "Model routing", str(error))

    def review_benchmark(self):
        model_id, engine = [part.strip() for part in MODEL_CHOICES[self.benchmark_choice.get_selected()].split("|", 1)]
        spec = core.get_model(model_id)
        backend = performance.BACKENDS[self.benchmark_backend.get_selected()]
        runs, tokens = self.runs.get_value_as_int(), self.tokens.get_value_as_int()
        cache = performance.CACHE_STATES[self.cache_state.get_selected()]
        warmup = self.warmup.get_active()
        target = spec.ollama_tag if engine == "ollama" else model_id
        summary = (f"Run real local inference for {spec.name} with {engine} on the already-running {backend} backend.\n\n"
                   f"Measured rounds: {runs}; token ceiling: {tokens}; cache state: {cache}; warm-up: {'separate' if warmup else 'omitted'}.\n\n"
                   "This authorizes local inference and private evidence storage. It does not switch CPU/Vulkan configuration, download a model, contact a cloud chat service or promise a speed result.")
        def begin():
            benchmark = performance.benchmark_ollama if engine == "ollama" else performance.benchmark_colibri
            def work(_progress):
                return benchmark(target, backend=backend, runs=runs, tokens=tokens, warmup=warmup,
                                 cache_state=cache, confirmed=True, paths=self.paths, hardware=self.hardware)
            def done(result):
                set_text(self.performance_output, json.dumps(result, indent=2, sort_keys=True))
                self.navigate("performance")
            self._start_work(f"Real {backend} benchmark: {spec.name}", work, done)
        self._review("Review local benchmark", summary, begin)

    def review_colibri(self):
        backend = performance.BACKENDS[self.engine_backend.get_selected()]
        cached = core._archive_cache_state(self.paths)
        text = (f"Build the experimental Colibri qwen36 {backend} engine from the pinned source archive?\n\nCommit: {core.COLIBRI_COMMIT}\nSHA-256: {core.COLIBRI_ARCHIVE_SHA256}\n\n"
                + ("The exact verified archive is cached; this build can proceed offline." if cached else "The exact archive is not verified in cache. Confirmation authorizes its 15.0 MB source download; no model weights are included."))
        def begin():
            self._start_work(f"Build experimental Colibri {backend} engine", lambda _progress: core.colibri_install(self.paths, confirmed=True, offline=False, backend=backend), self._show_result)
        self._review("Review experimental Colibri build", text, begin)

    def rollback_colibri(self):
        self._review("Confirm rollback", "Switch to the previous validated Colibri build? The current build remains on disk.", lambda: self._start_work("Rollback Colibri", lambda _progress: core.colibri_rollback(self.paths, confirmed=True), self._show_result))

    def start_colibri(self):
        model = tuple(m.id for m in core.MODELS if "colibri" in m.engines)[self.colibri_model.get_selected()]
        self._start_work("Start Colibri loopback server", lambda _progress: core.colibri_start(model, self.paths), self._show_result)

    def stop_colibri(self):
        self._start_work("Stop only our verified Colibri process", lambda _progress: core.colibri_stop(self.paths), self._show_result)

    def colibri_status(self):
        try:
            self._show_result(core.colibri_status(self.paths))
        except Exception as error:
            ui.message_dialog(self, "Colibri status", str(error))

    def _show_result(self, result):
        self._append_activity(json.dumps(result, indent=2, sort_keys=True))

    def _append_activity(self, text):
        buffer = self.activity_output.get_buffer()
        buffer.insert(buffer.get_end_iter(), ("\n" if buffer.get_char_count() else "") + text + "\n")

    def _start_work(self, title, function, on_success, total=0):
        if self.demo:
            ui.message_dialog(self, "Preview only", "No download, inference, engine build, server or rollback can run in preview mode.")
            return
        if self.busy:
            ui.message_dialog(self, "Operation already running", "Wait for the current local AI operation to finish.")
            return
        self.busy = True
        self.activity_label.set_label(title)
        self.progress.set_fraction(0)
        self.progress.set_text("Working — not verified yet")
        self.navigate("activity")
        def progress(done, total_size):
            self.events.put(("progress", done, total_size))
        def work():
            try:
                result = function(progress)
                self.events.put(("done", title, result, None, on_success))
            except Exception as error:
                self.events.put(("done", title, None, error, on_success))
        threading.Thread(target=work, daemon=True).start()

    def _drain_events(self):
        try:
            while True:
                event = self.events.get_nowait()
                if event[0] == "progress":
                    _, done, total = event
                    if total:
                        self.progress.set_fraction(min(1, done / total))
                        self.progress.set_text(f"{core.format_size(done)} / {core.format_size(total)} — not runnable until verified")
                    else:
                        self.progress.pulse()
                else:
                    _, title, result, error, on_success = event
                    self.busy = False
                    if error:
                        self.activity_label.set_label(title + " did not complete")
                        self._append_activity(str(error))
                        ui.message_dialog(self, title + " did not complete", str(error))
                    else:
                        self.progress.set_fraction(1)
                        self.progress.set_text("Finished — inspect the result")
                        self.activity_label.set_label(title + " finished")
                        on_success(result)
        except queue.Empty:
            pass
        return True

    def _close_request(self, _window):
        if self.busy:
            ui.message_dialog(self, "Please wait", "A download, build, inference or benchmark is still finishing. Keep this window open until its result appears.")
            return True
        return False
