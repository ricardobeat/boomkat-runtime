# Taskboard HTTP worker scaling

| Workload | req/s: 1 worker | req/s: 2 workers | req/s: 4 workers | p50 / p99 ms: 1 worker | p50 / p99 ms: 2 workers | p50 / p99 ms: 4 workers | Errors: 1 / 2 / 4 | Peak RSS MiB: 1 / 2 / 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| JS entry module | 308,760 | 266,616 | 239,506 | 0.36 / 0.77 | 0.29 / 1.24 | 0.29 / 0.40 | 0 / 0 / 0 | 33.8 / 39.1 / 89.0 |
| Board JSON (200 cards) | 4,231 | 7,779 | 12,001 | 30.14 / 31.13 | 16.40 / 17.26 | 10.50 / 13.52 | 0 / 0 / 0 | 50.2 / 73.9 / 159.3 |
| Image read (128 KiB) | 22,020 | 38,915 | 40,259 | 5.80 / 6.20 | 3.28 / 4.93 | 2.68 / 5.66 | 0 / 0 / 0 | 57.1 / 80.3 / 178.1 |
| Card update (250 B) | 17,242 | 17,639 | 17,733 | 7.05 / 9.63 | 6.54 / 33.05 | 5.74 / 144.26 | 0 / 0 / 0 | 37.9 / 48.5 / 106.8 |
| Mixed 70% board / 20% image / 10% update | 5,609 | 9,626 | 14,094 | 22.68 / 25.80 | 13.07 / 24.28 | 8.86 / 13.34 | 0 / 0 / 0 | 51.0 / 74.1 / 161.1 |
| Image upload + delete (128 KiB) | 4,070 | 4,574 | 4,805 | 32.66 / 46.52 | 26.21 / 80.50 | 17.13 / 1440.00 | 0 / 0 / 0 | 85.0 / 99.2 / 163.9 |

Total process throughput, 128 total keep-alive connections, two wrk threads, 6 measured seconds and one warmup second per case. One listener distributes connections round-robin across server VMs, including the main VM. Each VM opens its own connection to the same SQLite WAL database with FULL durability and a 5-second busy timeout. Authentication and membership checks run on every request; response snapshot caching is disabled. Upload/delete counts both operations. RSS covers the whole process. These are single trials; in-memory auth rate limits are per VM.
