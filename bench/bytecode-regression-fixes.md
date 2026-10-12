# Bytecode regression fixes

Engine `2bdab09b` baseline versus final `8ef0ab04` on `perf/hot-paths` in boomkat-perf; runtime source remains `4255e0c`. Both regressions are repaired; all six optimizations are retained.

## Causes and fixes

- **Template/string construction:** direct constant-key property emission (`48914407`) moved the length result into the register holding the joined string. `eliminate_join_allocation` rejected this overlap and treated the numeric result as a live string observer. This disabled `STRJOIN_LENGTH`, adding joined-string allocations plus a copy and property read. Commit `4ca494f2` allows destination reuse when liveness proves no other string observer; STRJOIN_LENGTH consumes every input before writing its result.
- **Allocation-heavy:** method fusion (`d1465414`) classified GETMETHOD output slots A and A+1 as inputs. Loop compare-result registers reused as call-frame outputs then looked live, preventing compare/branch fusion. The generated LT + IF_TRUE pairs replaced JMP_LT in the hot allocation loops. Commit `8ef0ab04` reads only B and treats both outputs as kills. The streaming pull fixture also restores POSTINC_CAP followed by JMP_SNEQI.
- Two runtime experiments (an object-method shortcut and method-cache quickening) still showed approximately 10% allocation-heavy regression. Both were discarded; the committed fixes change compiler analysis only.

## Targeted confirmation

21 alternating measured pairs per workload after one warm-up pair, fresh process; elapsed wall time including startup, compilation and teardown. Percentage changes are versus the original baseline; larger elapsed time is worse.

| Workload | Original regression | Fixed time change | Before ms | Fixed ms | Peak RSS MiB (before / fixed) |
|---|---:|---:|---:|---:|---:|
| memory_heavy | +11.0% | -0.1% | 38.58 | 38.53 | 32.64 / 32.61 |
| template_literal | +32.9% | -1.5% | 73.69 | 72.57 | 4.44 / 4.42 |

## Full engine suite

29 workloads, seven alternating measured pairs after one warm-up pair. Matching O2 threaded release build flags; RSS measured by /usr/bin/time -l. All normalized outputs matched. Final timing medians are within 3% of baseline or faster. These short process benchmarks have a startup and scheduling noise component.

| Workload | Baseline ms | Fixed ms | Time change | Peak RSS MiB (before / fixed) |
|---|---:|---:|---:|---:|
| arithmetic | 20.82 | 20.94 | +0.6% | 4.52 / 4.47 |
| array | 8.34 | 8.40 | +0.7% | 6.03 / 5.98 |
| async_frames | 38.31 | 34.26 | -10.6% | 7.48 / 7.42 |
| date | 16.83 | 16.58 | -1.5% | 7.44 / 7.39 |
| function_call | 25.27 | 25.72 | +1.8% | 4.52 / 4.48 |
| gc_large_container | 146.10 | 144.55 | -1.1% | 183.34 / 183.30 |
| gc_native_reentry | 13.01 | 12.82 | -1.4% | 11.03 / 10.98 |
| ic_monomorphic | 45.47 | 45.37 | -0.2% | 4.53 / 4.50 |
| ic_proto | 73.39 | 73.46 | +0.1% | 4.53 / 4.50 |
| loop | 16.94 | 17.05 | +0.6% | 4.47 / 4.44 |
| memory_heavy | 38.63 | 38.60 | -0.1% | 32.66 / 32.59 |
| object | 34.07 | 34.85 | +2.3% | 4.56 / 4.53 |
| property_lookup | 26.32 | 26.91 | +2.3% | 4.62 / 4.59 |
| recursion | 30.92 | 30.90 | -0.1% | 4.48 / 4.44 |
| recursion_deep | 117.79 | 118.69 | +0.8% | 4.47 / 4.44 |
| regexp | 52.28 | 52.15 | -0.2% | 11.31 / 11.20 |
| scene_churn | 144.32 | 142.90 | -1.0% | 124.64 / 124.58 |
| shape_no_call | 21.57 | 21.45 | -0.6% | 30.42 / 30.38 |
| shape_stress | 24.70 | 23.50 | -4.8% | 30.48 / 30.39 |
| string | 24.59 | 24.81 | +0.9% | 4.44 / 4.45 |
| valstack_copy | 32.64 | 32.71 | +0.2% | 4.48 / 4.45 |
| class | 163.15 | 160.57 | -1.6% | 6.45 / 6.44 |
| closure_capture | 52.58 | 52.37 | -0.4% | 4.44 / 4.41 |
| destructuring | 111.32 | 110.87 | -0.4% | 8.78 / 8.72 |
| forof | 54.54 | 53.91 | -1.2% | 21.41 / 21.38 |
| let_loop | 73.67 | 71.22 | -3.3% | 67.98 / 67.94 |
| promise | 157.24 | 156.59 | -0.4% | 180.66 / 180.59 |
| spread_rest | 33.66 | 34.13 | +1.4% | 4.59 / 4.55 |
| template_literal | 73.79 | 73.41 | -0.5% | 4.44 / 4.42 |

## Final server check

Three alternating pairs for hello, streaming and file. Each run uses a fresh server, 1 s warm-up and 3 s measured, wrk -t2 -c128. Matching O3 threaded runtime builds with unchanged runtime source. No socket or HTTP errors. Cells show median before / fixed values. This focused repeat validates the server paths affected by the compiler changes; the prior all-seven-workload results remain in the initial report.

| Workload | Baseline req/s | Fixed req/s | Throughput change | p50 ms (before / fixed) | p99 ms (before / fixed) | Peak RSS MiB (before / fixed) |
|---|---:|---:|---:|---:|---:|---:|
| hello | 218,590 | 216,117 | -1.1% | 0.56 / 0.57 | 1.08 / 1.10 | 10.89 / 10.88 |
| stream | 68,752 | 71,529 | +4.0% | 1.73 / 1.65 | 2.25 / 2.17 | 11.48 / 11.30 |
| file | 94,683 | 93,651 | -1.1% | 1.17 / 1.19 | 2.72 / 2.73 | 12.36 / 12.23 |

## Validation

- Golden bytecode: 38/38, including disabled-optimization checks and new fixtures for register reuse.
- Local scripts: 604/604; modules: 28/28; all companion syntax, rejection, robustness, TypeScript and private-field checks passed.
- Rosetta: 42/42.
- Threaded ASAN with GC_STRESS, GC_VERIFY and POOL_BYPASS: 47/47, including template conversion and string-observer semantics.
- HTTP lifecycle and native bodies: passed on the rebuilt runtime.

[Engine samples, bisection evidence and discarded experiments](bytecode-engine-fixed.json). [Server samples and full wrk output](bytecode-server-fixed.json). Both files include binary hashes.
