# Bytecode optimization regression check

**Follow-up:** both regressions are fixed in commits `4ca494f2` and `8ef0ab04`. See [causes and final verification](bytecode-regression-fixes.md). The measurements below retain the original regressed revision.

Compared engine `2bdab09b` (before the six optimizations) against `3f352420`. Runtime code remains `4255e0c`. Benchmarked locally on macOS arm64 on 2026-10-12.

Two repeatable engine regressions remain: allocation-heavy code is 11.0% slower and template/string construction is 32.9% slower. These are not resolved by this benchmark check. HTTP throughput medians stay within approximately 3% of baseline except streaming, which improves 4.6%. Peak RSS stays effectively unchanged.

## Server

Four alternating-order pairs per workload, each using a fresh process, 1 s warm-up and 3 s measured with `wrk -t2 -c128`. Both binaries use the same O3 threaded runtime build settings. Median values; cells containing two values show before / after. No HTTP or socket errors in any run. One candidate streaming sample had p99 14.88 ms and 51,108 req/s; retained in the raw data. Short local runs cannot prove the absence of rare latency regressions.

| Workload | Before req/s | After req/s | Change | p50 ms (before / after) | p99 ms (before / after) | Peak RSS MiB (before / after) |
|---|---:|---:|---:|---:|---:|---:|
| Hello | 204,283 | 198,575 | -2.8% | 0.59 / 0.59 | 1.17 / 1.30 | 10.89 / 10.95 |
| JSON | 169,919 | 169,703 | -0.1% | 0.71 / 0.71 | 1.42 / 1.41 | 11.35 / 11.34 |
| Async immediate | 136,551 | 138,354 | +1.3% | 0.81 / 0.79 | 1.81 / 1.80 | 11.72 / 11.80 |
| Async timer | 110,502 | 112,212 | +1.5% | 1.08 / 1.08 | 1.70 / 1.46 | 11.68 / 11.77 |
| Echo 1KB | 138,759 | 139,672 | +0.7% | 0.85 / 0.84 | 1.77 / 1.79 | 12.58 / 12.63 |
| Stream 8KB | 68,126 | 71,293 | +4.6% | 1.74 / 1.66 | 2.85 / 2.70 | 11.41 / 11.39 |
| File 4KB | 79,991 | 81,655 | +2.1% | 1.39 / 1.35 | 3.25 / 3.23 | 12.35 / 12.34 |

## Engine

All 29 core and ES6 workloads, seven alternating-order measured pairs after one warm-up pair. Fresh processes; wall time includes compilation, startup, execution and teardown. Matching O2 threaded release builds, with the macOS exported-symbols flag on both. Output equality checked after normalizing benchmark timing fields. Peak RSS measured with `/usr/bin/time -l`. Larger elapsed time is worse. Very short workloads have a substantial process-startup noise component.

The allocation-heavy, object, and template workloads were independently repeated with 21 alternating pairs. Recheck medians replace their initial medians below. Object timing difference fell to 2.5%; the other two regressions persisted.

| Workload | Before ms | After ms | Time change | Peak RSS MiB (before / after) |
|---|---:|---:|---:|---:|
| arithmetic | 22.25 | 22.57 | +1.5% | 4.52 / 4.47 |
| array | 9.09 | 8.90 | -2.1% | 6.05 / 5.98 |
| async_frames | 39.90 | 35.50 | -11.0% | 7.48 / 7.41 |
| date | 17.75 | 17.44 | -1.7% | 7.44 / 7.39 |
| function_call | 26.15 | 26.57 | +1.6% | 4.52 / 4.48 |
| gc_large_container | 159.61 | 153.96 | -3.5% | 183.36 / 183.28 |
| gc_native_reentry | 14.44 | 14.56 | +0.9% | 11.03 / 10.97 |
| ic_monomorphic | 47.53 | 48.06 | +1.1% | 4.53 / 4.50 |
| ic_proto | 74.50 | 74.48 | -0.0% | 4.53 / 4.50 |
| loop | 17.57 | 17.27 | -1.8% | 4.48 / 4.42 |
| memory_heavy | 40.26 | 44.68 | +11.0% | 32.64 / 32.61 |
| object | 34.72 | 35.58 | +2.5% | 4.56 / 4.52 |
| property_lookup | 27.33 | 27.84 | +1.9% | 4.64 / 4.59 |
| recursion | 31.76 | 31.98 | +0.7% | 4.47 / 4.42 |
| recursion_deep | 119.35 | 119.94 | +0.5% | 4.48 / 4.44 |
| regexp | 53.38 | 53.35 | -0.1% | 11.27 / 11.28 |
| scene_churn | 150.69 | 149.90 | -0.5% | 124.66 / 124.58 |
| shape_no_call | 22.65 | 22.94 | +1.3% | 30.38 / 30.33 |
| shape_stress | 27.12 | 25.12 | -7.4% | 30.48 / 30.39 |
| string | 25.17 | 25.29 | +0.5% | 4.47 / 4.42 |
| valstack_copy | 33.90 | 33.51 | -1.1% | 4.48 / 4.45 |
| class | 165.71 | 161.11 | -2.8% | 6.47 / 6.44 |
| closure_capture | 53.61 | 53.51 | -0.2% | 4.44 / 4.39 |
| destructuring | 112.61 | 112.41 | -0.2% | 8.78 / 8.73 |
| forof | 55.98 | 55.31 | -1.2% | 21.39 / 21.34 |
| let_loop | 75.13 | 74.94 | -0.3% | 67.98 / 67.92 |
| promise | 161.03 | 161.65 | +0.4% | 180.66 / 180.56 |
| spread_rest | 34.41 | 34.70 | +0.8% | 4.61 / 4.53 |
| template_literal | 76.94 | 102.26 | +32.9% | 4.44 / 4.41 |

## Validation and raw data

- HTTP lifecycle and native response-body tests passed on the rebuilt runtime.
- All measured engine workloads completed successfully with matching normalized output.
- [Engine samples, rechecks and binary hashes](bytecode-engine-regression.json)
- [Server samples, full wrk output and binary hashes](bytecode-server-regression.json)

No implementation changes were made during this check.
