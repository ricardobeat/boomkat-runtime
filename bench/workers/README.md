# Isolated worker scaling

Run from the repository root after building the runtime:

```sh
python3 bench/workers/run.py
```

Each trial performs four identical integer-loop jobs, totaling 200 million
iterations, divided across one, two or four workers. The checksum is checked
before shutdown. Three trials alternate worker-count order. Startup and work
are timed separately; sampled RSS covers the entire process and all workers.

Measured release build, Apple Silicon, 2026-10-13:

| Workload | 1 worker: work / total ms | 2 workers: work / total ms | 4 workers: work / total ms | Peak RSS MiB: 1 / 2 / 4 workers |
| --- | ---: | ---: | ---: | ---: |
| CPU work, 200M iterations | 1,652.66 / 1,661.61 | 838.02 / 847.35 | 436.45 / 446.82 | 12.44 / 16.83 / 24.69 |

Median startup was 8.92, 9.34 and 9.92 ms respectively.

This measures CPU parallelism with tiny messages. It does not measure a shared
HTTP listener or general application speedup. ArrayBuffer transfers currently
copy the bytes and detach the sender.

`results.json` contains raw trials and medians. `regression.json` compares
the candidate with a fresh control built from engine `5c91f807` and runtime
`9195351`, using the same native shim. Taskboard's ordinary board, image and
update workloads changed by less than 1% in throughput, with zero errors.
Three alternating engine microbenchmark trials differed by up to 3.5%.
