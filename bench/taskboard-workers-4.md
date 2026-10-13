# Taskboard load test

| Workload | req/s @128 | p50 / p99 ms @128 | Errors | Peak RSS MiB @128 |
| --- | ---: | ---: | ---: | ---: |
| JS entry module | 239,506 | 0.29 / 0.40 | 0 | 89.0 |
| Board JSON (200 cards) | 12,001 | 10.50 / 13.52 | 0 | 159.3 |
| Image read (128 KiB) | 40,259 | 2.68 / 5.66 | 0 | 178.1 |
| Card update (250 B) | 17,733 | 5.74 / 144.26 | 0 | 106.8 |
| Mixed 70% board / 20% image / 10% update | 14,094 | 8.86 / 13.34 | 0 | 161.1 |
| Image upload + delete (128 KiB) | 4,805 | 17.13 / 1440.00 | 0 | 163.9 |

{"accounts": 10, "shared_teams": 2, "boards": 4, "cards_per_board": 200, "images": 16, "board_json_bytes": 79040, "asset_bytes": 207, "image_bytes": 131072, "journal_mode": "wal", "synchronous": 2}

Loopback wrk; real sessions and CSRF checks; isolated SQLite database; default WAL/FULL durability. 6s measured and 1s warmup per run, fresh server per case. Upload/delete throughput counts both API operations, about two requests per completed image cycle. Peak RSS is sampled every 200 ms; CPU percentages are recorded in the JSON. These are closed-loop saturation results without user think time.

Login burst: {"requests": 32, "concurrency": 8, "statuses": {"200": 23, "429": 9}, "reasons": {"Sign-in workers are busy. Try again shortly": 9}}

Login rate limit: {"requests": 45, "statuses": {"200": 45}}

SQLite integrity, foreign keys, fixture card count and BLOB lengths passed
