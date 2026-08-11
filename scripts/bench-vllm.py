#!/usr/bin/env python3
"""Week 6: benchmark vLLM honestly — at several concurrency levels.

A single-stream token rate tells you almost nothing about a serving system.
Continuous batching means throughput and latency are different numbers at
every concurrency, so this measures all of them:

  TTFT  time to first token   -> prefill; what users feel as responsiveness
  TPOT  time per output token -> decode; how fast text streams
  agg   aggregate output tok/s across ALL concurrent requests

Zero dependencies (stdlib only) so it runs on the box as-is.

  ./bench-vllm.py                          # 1, 4, 16, 32 concurrent
  ./bench-vllm.py --concurrency 1,8        # pick your own
  ./bench-vllm.py --max-tokens 200
"""
import argparse
import json
import statistics
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ap = argparse.ArgumentParser()
ap.add_argument("--url", default="http://localhost:8000")
ap.add_argument("--model", default=None, help="defaults to whatever the server has loaded")
ap.add_argument("--concurrency", default="1,4,16,32")
ap.add_argument("--requests-per-level", type=int, default=0,
                help="0 = 3x the concurrency, so every level does real work")
ap.add_argument("--max-tokens", type=int, default=128)
ap.add_argument("--prompt", default="Explain what a Kubernetes pod is and why it exists. Be thorough.")
args = ap.parse_args()


def get_model():
    with urllib.request.urlopen(f"{args.url}/v1/models", timeout=10) as r:
        return json.load(r)["data"][0]["id"]


def one_request(model):
    """Stream one completion. Returns (ttft, total_time, n_output_tokens)."""
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": args.prompt}],
        "max_tokens": args.max_tokens,
        "temperature": 0.0,
        "stream": True,
    }).encode()

    req = urllib.request.Request(
        f"{args.url}/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json"})

    start = time.perf_counter()
    ttft = None
    tokens = 0

    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            chunk = json.loads(payload)
            delta = chunk["choices"][0].get("delta", {})
            if delta.get("content"):
                if ttft is None:
                    ttft = time.perf_counter() - start   # FIRST token = prefill done
                tokens += 1

    total = time.perf_counter() - start
    return ttft or total, total, tokens


def level(model, conc, n):
    """Fire n requests through a pool of `conc` workers; measure the whole thing."""
    wall_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=conc) as pool:
        results = list(pool.map(lambda _: one_request(model), range(n)))
    wall = time.perf_counter() - wall_start

    ttfts = sorted(r[0] for r in results)
    out_tokens = sum(r[2] for r in results)
    # decode rate per request: tokens after the first, over time after TTFT
    tpots = [(r[1] - r[0]) / max(r[2] - 1, 1) for r in results if r[2] > 1]

    return {
        "conc": conc,
        "ttft_p50": statistics.median(ttfts),
        "ttft_p95": ttfts[int(len(ttfts) * 0.95) - 1] if len(ttfts) > 1 else ttfts[0],
        "tpot": statistics.mean(tpots) if tpots else 0,
        "per_stream_tps": 1 / statistics.mean(tpots) if tpots else 0,
        "agg_tps": out_tokens / wall,
        "wall": wall,
        "tokens": out_tokens,
    }


model = args.model or get_model()
levels = [int(c) for c in args.concurrency.split(",")]

print(f"\nserver : {args.url}")
print(f"model  : {model}")
print(f"prompt : {args.prompt[:60]}...")
print(f"tokens : {args.max_tokens} max per request\n")

print("  conc | TTFT p50 | TTFT p95 |  TPOT  | per-stream | AGGREGATE | requests")
print("       |    (ms)  |    (ms)  |  (ms)  |   (tok/s)  |  (tok/s)  |")
print("  " + "-" * 74)

rows = []
for c in levels:
    n = args.requests_per_level or c * 3
    r = level(model, c, n)
    rows.append(r)
    print(f"  {r['conc']:4d} | {r['ttft_p50']*1000:8.0f} | {r['ttft_p95']*1000:8.0f} | "
          f"{r['tpot']*1000:6.1f} | {r['per_stream_tps']:10.1f} | {r['agg_tps']:9.1f} | {n:5d}")

base, best = rows[0], max(rows, key=lambda r: r["agg_tps"])
print(f"""
  ---- what this shows ----
  At concurrency 1 the GPU serves {base['agg_tps']:.0f} tok/s. At {best['conc']} it serves
  {best['agg_tps']:.0f} tok/s — {best['agg_tps']/base['agg_tps']:.1f}x more work from the SAME hardware, because one
  read of the weights out of VRAM now produces {best['conc']} tokens instead of 1.

  Per-stream speed {'held up' if best['per_stream_tps'] > base['per_stream_tps'] * 0.6 else 'degraded'}: {base['per_stream_tps']:.0f} -> {best['per_stream_tps']:.0f} tok/s per request.
  TTFT {'stayed flat' if best['ttft_p50'] < base['ttft_p50'] * 2 else 'rose'}: {base['ttft_p50']*1000:.0f} -> {best['ttft_p50']*1000:.0f} ms (queueing shows up here first).

  Week 5 baseline for comparison: 43 tok/s, TinyLlama-1.1B, plain
  transformers, one request at a time, no batching.

  Watch it live:  curl -s localhost:8000/metrics | grep -E 'num_requests_(running|waiting)|gpu_cache_usage'
""")
