#!/usr/bin/env python3
"""Measured local-AI guidance without invented throughput or hidden host changes.

This module is loaded by local-ai.py after its core module.  Routing and hardware
inspection are local-only.  Only an explicitly confirmed benchmark contacts an
already-running loopback inference server; no model or engine is downloaded.
"""
from __future__ import annotations

import dataclasses
import datetime as _datetime
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import sys
import time
import urllib.request
import uuid

core = sys.modules["secure_linux_local_ai_core"]

WORKLOADS = ("interactive", "balanced", "quality", "low-storage")
BACKENDS = ("cpu", "vulkan")
CACHE_STATES = ("unspecified", "warm-process", "cold-process")
FIXED_PROMPT = "Write a Python function that checks whether an integer is prime. Include brief tests."
OLLAMA_TIMING_FIELDS = (
    "total_duration", "load_duration", "prompt_eval_duration", "eval_duration",
    "prompt_eval_count", "eval_count", "prompt_eval_cached_count",
)


def _utcnow() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).isoformat()


def hardware_fingerprint(hardware) -> str:
    """Identify only the comparison host, not a person or a global device ID."""
    identity = {
        "cpu_model": hardware.cpu_model,
        "architecture": hardware.architecture,
        "logical_cpus": hardware.logical_cpus,
        "ram_total": hardware.ram_total,
    }
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _mount_unescape(value: str) -> str:
    return re.sub(r"\\([0-7]{3})", lambda match: chr(int(match.group(1), 8)), value)


def storage_guidance(path=None, proc_root="/proc", sys_root="/sys") -> dict:
    """Describe the actual mount when Linux exposes it; otherwise remain unknown."""
    target = Path(os.path.abspath(os.fspath(path or core.AIPaths.default().base)))
    result = {
        "path": str(target), "mount": None, "major_minor": None,
        "rotational": None, "kind": "unknown", "source": None,
        "automatic_changes": False,
        "note": "Storage type is unknown. Check the model volume before choosing a large disk-streamed model; no files are moved automatically.",
    }
    mountinfo = Path(proc_root) / "self/mountinfo"
    try:
        lines = mountinfo.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return result
    best = None
    for line in lines:
        fields = line.split()
        if len(fields) < 10 or "-" not in fields:
            continue
        mount = _mount_unescape(fields[4])
        try:
            Path(os.path.abspath(target)).relative_to(Path(os.path.abspath(mount)))
        except ValueError:
            continue
        if best is None or len(mount) > len(best[0]):
            best = (mount, fields[2])
    if best is None:
        return result
    mount, major_minor = best
    result.update({"mount": mount, "major_minor": major_minor, "source": str(mountinfo)})
    device = Path(sys_root) / "dev/block" / major_minor
    try:
        rotational = int((device / "queue/rotational").read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        rotational = None
    result["rotational"] = rotational
    # realpath is only identification: nothing is created, moved or modified.
    device_identity = os.path.realpath(device).lower()
    if "nvme" in device_identity or "nvme" in device.name.lower():
        kind = "nvme"
    elif rotational == 1:
        kind = "rotational"
    elif rotational == 0:
        kind = "non-rotational; interface unknown"
    else:
        kind = "unknown"
    result["kind"] = kind
    if kind == "nvme":
        result["note"] = "The model path is on an NVMe-identified device. This says nothing about its sustained inference performance."
    elif kind == "rotational":
        result["note"] = "Large MoE models can be storage-sensitive; an NVMe model volume is preferable. No files are moved automatically."
    else:
        result["note"] = "The device is not confirmed as NVMe. Measure the actual workload before drawing a storage-performance conclusion."
    return result


def thermal_snapshot(sys_root="/sys") -> dict:
    """Report exposed sensors without inventing a universal safe temperature."""
    sensors = []
    root = Path(sys_root) / "class/thermal"
    try:
        zones = sorted(root.glob("thermal_zone*"))
    except OSError:
        zones = []
    for zone in zones:
        try:
            raw = int((zone / "temp").read_text(encoding="ascii").strip())
        except (OSError, ValueError):
            continue
        kind = core._read_text(zone / "type").strip() or zone.name
        sensors.append({"zone": zone.name, "type": kind, "temperature_c": raw / 1000.0})
    return {
        "sensors": sensors,
        "coverage": "available" if sensors else "unknown",
        "note": "Sensor names and limits vary. No universal temperature limit or throttling conclusion is applied; repeat interleaved runs to expose thermal drift.",
    }


def sample_processes(pids=(), proc_root="/proc") -> list:
    """Sample real procfs counters. read_bytes and rchar remain distinct."""
    samples = []
    for raw_pid in pids:
        try:
            pid = int(raw_pid)
            if pid <= 0:
                raise ValueError
        except (TypeError, ValueError) as exc:
            raise core.SafetyError("Process IDs must be positive integers.") from exc
        base = Path(proc_root) / str(pid)
        sample = {
            "pid": pid, "coverage": "missing", "rss_bytes": None, "hwm_bytes": None,
            "read_bytes": None, "rchar": None,
        }
        try:
            status = (base / "status").read_text(encoding="utf-8", errors="replace")
            values = {key: int(value) * 1024 for key, value in re.findall(
                r"^(VmRSS|VmHWM):\s+(\d+)\s+kB$", status, re.MULTILINE)}
            sample.update({"rss_bytes": values.get("VmRSS"), "hwm_bytes": values.get("VmHWM")})
            status_present = True
        except OSError:
            status_present = False
        try:
            io_text = (base / "io").read_text(encoding="utf-8", errors="replace")
            values = {key: int(value) for key, value in re.findall(r"^(rchar|read_bytes):\s+(\d+)$", io_text, re.MULTILINE)}
            sample.update({"rchar": values.get("rchar"), "read_bytes": values.get("read_bytes")})
            io_present = True
        except OSError:
            io_present = False
        sample["coverage"] = "full" if status_present and io_present else ("partial" if status_present or io_present else "missing")
        samples.append(sample)
    return samples


def process_delta(before: list, after: list) -> dict:
    earlier = {row["pid"]: row for row in before}
    later = {row["pid"]: row for row in after}
    requested = sorted(set(earlier) | set(later))
    read_deltas = []
    rchar_deltas = []
    for pid in requested:
        first, last = earlier.get(pid), later.get(pid)
        if not first or not last:
            continue
        if first.get("read_bytes") is not None and last.get("read_bytes") is not None:
            delta = last["read_bytes"] - first["read_bytes"]
            if delta >= 0:
                read_deltas.append(delta)
        if first.get("rchar") is not None and last.get("rchar") is not None:
            delta = last["rchar"] - first["rchar"]
            if delta >= 0:
                rchar_deltas.append(delta)
    coverage = "missing"
    if read_deltas:
        coverage = "full" if len(read_deltas) == len(requested) else "partial"
    rss = [row["rss_bytes"] for row in after if row.get("rss_bytes") is not None]
    hwm = [row["hwm_bytes"] for row in after if row.get("hwm_bytes") is not None]
    return {
        "coverage": coverage, "pids_requested": requested, "pids_with_device_io": len(read_deltas),
        "read_bytes_delta": sum(read_deltas) if read_deltas else None,
        "rchar_delta": sum(rchar_deltas) if rchar_deltas else None,
        "observed_rss_max_bytes": max(rss) if rss else None,
        "observed_hwm_max_bytes": max(hwm) if hwm else None,
        "note": "read_bytes is actual device I/O reported by procfs; rchar is only a read-call counter and is never substituted. RSS/HWM are sampled process observations, not a system-wide peak.",
    }


def _validate_benchmark(model, backend, runs, tokens, cache_state, confirmed):
    if not confirmed:
        raise core.ConfirmationRequired("Explicit confirmation is required before running a local inference benchmark.")
    if not isinstance(model, str) or not model.strip() or len(model) > 512 or any(ord(c) < 32 for c in model):
        raise core.SafetyError("Enter a valid installed model tag.")
    if backend not in BACKENDS:
        raise core.SafetyError("Benchmark backend must be cpu or vulkan.")
    if not isinstance(runs, int) or isinstance(runs, bool) or not 1 <= runs <= 9:
        raise core.SafetyError("Benchmark runs must be an integer from 1 to 9.")
    if not isinstance(tokens, int) or isinstance(tokens, bool) or not 1 <= tokens <= 1024:
        raise core.SafetyError("Benchmark tokens must be an integer from 1 to 1024.")
    if cache_state not in CACHE_STATES:
        raise core.SafetyError("Unknown benchmark cache state.")


def _base_record(engine, model, backend, runs, tokens, cache_state, hardware, paths):
    return {
        "schema": 1, "engine": engine, "model": model, "backend": backend,
        "requested_runs": runs, "requested_tokens": tokens, "cache_state": cache_state,
        "page_cache_state": "not established; cold-process never means cold page cache",
        "prompt": FIXED_PROMPT, "temperature": 0,
        "seed_reproducibility": "not claimed; Colibri ignores seed and a fixed prompt does not guarantee identical scheduling",
        "started_at": _utcnow(), "status": "running", "warmup": None, "runs": [],
        "hardware": dataclasses.asdict(hardware), "hardware_fingerprint": hardware_fingerprint(hardware),
        "storage": storage_guidance(hardware.storage_path),
        "quality_assessed": False,
        "timing_caution": "Short fixed-prompt measurements do not predict long coding-agent prefill or interactive throughput.",
    }


def _save_record(record, paths):
    record["finished_at"] = _utcnow()
    name = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex + ".json"
    path = core.safe_join(paths.benchmarks, name)
    record["evidence_path"] = str(path)
    core._atomic_json(path, record)
    return record


def _open_loopback(url, payload, timeout, opener):
    core._loopback_url(url, 11434 if url.startswith(core.OLLAMA_URL) else 8001)
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST")
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return opener.open(request, timeout=timeout)


def _ollama_sample(model, tokens, timeout, opener):
    payload = {
        "model": model, "prompt": FIXED_PROMPT, "stream": False, "keep_alive": "10m",
        "options": {"num_predict": tokens, "num_ctx": 8192, "temperature": 0},
    }
    with _open_loopback(core.OLLAMA_URL + "/api/generate", payload, timeout, opener) as response:
        data = json.loads(response.read().decode("utf-8"))
    if not isinstance(data, dict) or data.get("error"):
        raise core.LocalAIError("Ollama benchmark failed: " + str(data.get("error", "unrecognized response"))[:500])
    timing = {field: data.get(field) for field in OLLAMA_TIMING_FIELDS}
    for field in ("eval_count", "eval_duration"):
        value = timing.get(field)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0:
            raise core.LocalAIError("Ollama omitted valid official eval_count/eval_duration fields.")
    decode = None
    if timing["eval_duration"] > 0:
        decode = timing["eval_count"] / (timing["eval_duration"] / 1_000_000_000)
    prompt_eval = None
    if isinstance(timing.get("prompt_eval_count"), (int, float)) and isinstance(timing.get("prompt_eval_duration"), (int, float)) and timing["prompt_eval_duration"] > 0:
        prompt_eval = timing["prompt_eval_count"] / (timing["prompt_eval_duration"] / 1_000_000_000)
    return {"status": "ok", "official": timing, "decode_tok_s": decode, "prompt_eval_tok_s": prompt_eval}


def _summary(runs, key="decode_tok_s"):
    values = [row[key] for row in runs if row.get("status") == "ok" and row.get(key) is not None]
    if not values:
        return {"decode_tok_s": None, "sample_count": 0, "samples": []}
    return {
        "decode_tok_s": statistics.median(values), "sample_count": len(values),
        "samples": values, "minimum": min(values), "maximum": max(values),
        "statistic": "median",
    }


def benchmark_ollama(model, backend="cpu", runs=3, tokens=128, warmup=True,
                     cache_state="unspecified", confirmed=False, paths=None,
                     opener=None, timeout=900, hardware=None, pids=(), proc_root="/proc",
                     warmup_only=False):
    """Measure arbitrary installed Ollama tags using official response timings."""
    _validate_benchmark(model, backend, runs, tokens, cache_state, confirmed)
    paths = paths or core.AIPaths.default()
    hardware = hardware or core.scan_hardware(paths.base)
    record = _base_record("ollama", model, backend, runs, tokens, cache_state, hardware, paths)
    before = sample_processes(pids, proc_root)
    try:
        if warmup or warmup_only:
            record["warmup"] = _ollama_sample(model, tokens, timeout, opener)
        if not warmup_only:
            for index in range(runs):
                try:
                    sample = _ollama_sample(model, tokens, timeout, opener)
                except Exception as error:
                    record["runs"].append({"index": index + 1, "status": "failed", "error": str(error)[:1000]})
                    raise
                sample["index"] = index + 1
                record["runs"].append(sample)
        record["status"] = "ok"
        record["summary"] = None if warmup_only else _summary(record["runs"])
    except Exception as error:
        record["status"] = "warmup_failed" if (warmup or warmup_only) and record["warmup"] is None and not record["runs"] else "failed"
        record["summary"] = None
        saved = _save_record(record, paths)
        raise core.LocalAIError(f"Ollama benchmark failed; raw evidence was kept at {saved['evidence_path']}: {error}") from error
    finally:
        after = sample_processes(pids, proc_root)
        record["processes"] = {"before": before, "after": after, "delta": process_delta(before, after)}
    return _save_record(record, paths)


def _nonempty_delta(delta):
    if not isinstance(delta, dict):
        return False
    for key in ("content", "reasoning_content"):
        if isinstance(delta.get(key), str) and delta[key]:
            return True
    function = delta.get("function_call")
    if isinstance(function, dict) and any(isinstance(function.get(k), str) and function[k] for k in ("name", "arguments")):
        return True
    for call in delta.get("tool_calls") or []:
        if isinstance(call, dict) and isinstance(call.get("function"), dict):
            function = call["function"]
            if any(isinstance(function.get(k), str) and function[k] for k in ("name", "arguments")):
                return True
    return False


def _colibri_sample(model, tokens, timeout, opener, clock):
    payload = {
        "model": model, "messages": [{"role": "user", "content": FIXED_PROMPT}],
        "stream": True, "stream_options": {"include_usage": True}, "cache_slot": 0,
        "max_tokens": tokens, "temperature": 0,
    }
    start = clock()
    first_output = None
    usage = None
    finish_reason = None
    done = False
    with _open_loopback(core.COLIBRI_URL_LOCAL + "/v1/chat/completions", payload, timeout, opener) as response:
        for raw_line in response:
            line = raw_line.decode("utf-8").strip() if isinstance(raw_line, bytes) else raw_line.strip()
            if not line.startswith("data:"):
                continue
            body = line[5:].strip()
            if body == "[DONE]":
                done = True
                break
            try:
                chunk = json.loads(body)
            except (TypeError, ValueError) as exc:
                raise core.LocalAIError("Colibri returned malformed streaming JSON.") from exc
            if isinstance(chunk.get("usage"), dict):
                usage = chunk["usage"]
            choices = chunk.get("choices") or []
            if not choices:
                continue
            if len(choices) != 1 or choices[0].get("index", 0) != 0:
                raise core.LocalAIError("Colibri returned an unexpected streaming choice layout.")
            choice = choices[0]
            if finish_reason is not None:
                raise core.LocalAIError("Colibri sent output after a finish frame.")
            if first_output is None and _nonempty_delta(choice.get("delta")):
                first_output = clock()
            if choice.get("finish_reason") is not None:
                finish_reason = choice["finish_reason"]
    end = clock()
    if not done or finish_reason not in ("stop", "length", "tool_calls", "function_call", "content_filter"):
        raise core.LocalAIError("Colibri stream was incomplete or had an unsupported finish reason.")
    completion_tokens = usage.get("completion_tokens") if usage else None
    first_latency = first_output - start if first_output is not None else None
    output_interval = end - first_output if first_output is not None else None
    decode = None
    if isinstance(completion_tokens, int) and not isinstance(completion_tokens, bool) and completion_tokens >= 0 and output_interval and output_interval > 0:
        decode = completion_tokens / output_interval
    return {
        "status": "ok", "http_first_output_s": first_latency,
        "http_first_output_to_end_s": output_interval, "http_total_s": end - start,
        "usage": usage, "finish_reason": finish_reason, "decode_tok_s": decode,
        "timing_basis": "Client-observed HTTP first output and first-output-to-end interval. SSE chunks need not equal tokens; this is not a kernel or steady-decode timing.",
    }


def benchmark_colibri(model, backend="cpu", runs=3, tokens=128, warmup=True,
                      cache_state="unspecified", confirmed=False, paths=None,
                      opener=None, timeout=900, hardware=None, pids=None,
                      proc_root="/proc", clock=time.perf_counter, warmup_only=False):
    """Measure client-observed Colibri SSE timings, not invented kernel metrics."""
    spec = core.get_model(model)
    if "colibri" not in spec.engines:
        raise core.LocalAIError("This catalog model is not enabled for Colibri; Qwen2.5-Coder remains Ollama-only.")
    _validate_benchmark(model, backend, runs, tokens, cache_state, confirmed)
    paths = paths or core.AIPaths.default()
    hardware = hardware or core.scan_hardware(paths.base)
    if pids is None:
        status = core.colibri_status(paths, proc_root)
        pids = [status["pid"]] if status.get("pid") else []
    record = _base_record("colibri", model, backend, runs, tokens, cache_state, hardware, paths)
    record["model_revision"] = spec.revision
    record["model_sha256"] = spec.sha256
    record["colibri_commit"] = core.COLIBRI_COMMIT
    before = sample_processes(pids, proc_root)
    try:
        if warmup or warmup_only:
            record["warmup"] = _colibri_sample(model, tokens, timeout, opener, clock)
        if not warmup_only:
            for index in range(runs):
                try:
                    sample = _colibri_sample(model, tokens, timeout, opener, clock)
                except Exception as error:
                    record["runs"].append({"index": index + 1, "status": "failed", "error": str(error)[:1000]})
                    raise
                sample["index"] = index + 1
                record["runs"].append(sample)
        record["status"] = "ok"
        record["summary"] = None if warmup_only else _summary(record["runs"])
    except Exception as error:
        record["status"] = "warmup_failed" if (warmup or warmup_only) and record["warmup"] is None and not record["runs"] else "failed"
        record["summary"] = None
        saved = _save_record(record, paths)
        raise core.LocalAIError(f"Colibri benchmark failed; raw evidence was kept at {saved['evidence_path']}: {error}") from error
    finally:
        after = sample_processes(pids, proc_root)
        record["processes"] = {"before": before, "after": after, "delta": process_delta(before, after)}
    return _save_record(record, paths)


def _matching_evidence(paths, hardware, model_id, engine):
    root = paths.benchmarks
    if root.is_symlink() or not root.exists():
        return []
    evidence = []
    try:
        candidates = sorted(root.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        return []
    for path in candidates[:100]:
        if path.is_symlink() or not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if (data.get("schema") != 1 or data.get("status") != "ok"
                or data.get("hardware_fingerprint") != hardware_fingerprint(hardware)
                or data.get("model") != model_id or data.get("engine") != engine
                or not isinstance(data.get("summary"), dict)):
            continue
        summary = data["summary"]
        if summary.get("decode_tok_s") is None:
            continue
        evidence.append({
            "path": str(path), "backend": data.get("backend"),
            "cache_state": data.get("cache_state"), "sample_count": summary.get("sample_count"),
            "median_decode_tok_s": summary.get("decode_tok_s"), "finished_at": data.get("finished_at"),
        })
    return evidence


def route(workload="balanced", engine=None, hardware=None, paths=None) -> dict:
    """Rank feasible catalog choices using fit and, when available, local evidence."""
    if workload not in WORKLOADS:
        raise core.SafetyError("Workload must be interactive, balanced, quality or low-storage.")
    if engine is not None and engine not in ("ollama", "colibri"):
        raise core.SafetyError("Unknown engine.")
    paths = paths or core.AIPaths.default()
    hardware = hardware or core.scan_hardware(paths.base)
    rows = []
    for spec in core.MODELS:
        if spec.fewer_refusals:
            continue
        engines = (engine,) if engine else spec.engines
        for candidate_engine in engines:
            assessment = core.assess_model(spec, candidate_engine, hardware)
            evidence = _matching_evidence(paths, hardware, spec.id, candidate_engine)
            rows.append({
                "model_id": spec.id, "name": spec.name, "engine": candidate_engine,
                "coding_specialist": spec.coding_specialist, "description": spec.description,
                "artifact_size": spec.size, "quantization": spec.quantization,
                "assessment": assessment, "same_device_evidence": evidence,
            })
    fit_order = {"recommended": 0, "feasible": 1, "tight": 2}
    def key(row):
        assessment = row["assessment"]
        fit = fit_order.get(assessment["fit"], 10)
        evidence_values = [item["median_decode_tok_s"] for item in row["same_device_evidence"]
                           if isinstance(item.get("median_decode_tok_s"), (int, float))]
        measured = max(evidence_values) if evidence_values else None
        # Measured evidence only breaks ties within the same fit class for interactive use.
        evidence_key = -(measured or 0) if workload == "interactive" else 0
        if workload == "quality":
            size_key = -row["artifact_size"]
        else:
            size_key = row["artifact_size"]
        storage_key = assessment.get("required_disk") or 0
        return (fit, evidence_key, storage_key if workload == "low-storage" else 0,
                size_key, 0 if row["coding_specialist"] else 1, row["model_id"])
    feasible = [row for row in rows if row["assessment"]["feasible"]]
    feasible.sort(key=key)
    selected = feasible[0] if feasible else None
    storage = storage_guidance(hardware.storage_path)
    thermal = thermal_snapshot()
    warnings = [
        "Qwen2.5-Coder is Ollama-only: the pinned Colibri family registry does not support qwen2; it must not be aliased to Qwen3.",
        "No tokens/second is predicted from model size, RAM or GPU presence. Only matching persisted measurements are shown.",
        "Large MoE prefill and expert reads can dominate short coding sessions. Prefer short prompts and measure the actual workload.",
        "Qwen3.6 35B-A3B is a general model that can help with code, not a coding-specialist quality claim; upstream suggests about 30 GB RAM for comfortable expert caching and NVMe storage.",
    ]
    if storage["kind"] != "nvme":
        warnings.append("The model volume is not confirmed as NVMe; storage remains unknown rather than being assumed fast or slow.")
    return {
        "workload": workload, "hardware": dataclasses.asdict(hardware),
        "hardware_fingerprint": hardware_fingerprint(hardware),
        "selected": selected, "candidates": rows, "storage": storage, "thermal": thermal,
        "warnings": warnings,
        "selection_basis": "Fit gates first; then workload-aware artifact/storage size. Interactive ties prefer same-device measured median decode evidence. No cross-device evidence is reused.",
    }
