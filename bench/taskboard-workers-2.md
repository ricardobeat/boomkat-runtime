# Taskboard load test

| Workload | req/s @128 | p50 / p99 ms @128 | Errors | Peak RSS MiB @128 |
| --- | ---: | ---: | ---: | ---: |
| JS entry module | 266,616 | 0.29 / 1.24 | 0 | 39.1 |
| Board JSON (200 cards) | 7,779 | 16.40 / 17.26 | 0 | 73.9 |
| Image read (128 KiB) | 38,915 | 3.28 / 4.93 | 0 | 80.3 |
| Card update (250 B) | 17,639 | 6.54 / 33.05 | 0 | 48.5 |
| Mixed 70% board / 20% image / 10% update | 9,626 | 13.07 / 24.28 | 0 | 74.1 |
| Image upload + delete (128 KiB) | 4,574 | 26.21 / 80.50 | 0 | 99.2 |

{"accounts": 10, "shared_teams": 2, "boards": 4, "cards_per_board": 200, "images": 16, "board_json_bytes": 79040, "asset_bytes": 207, "image_bytes": 131072, "journal_mode": "wal", "synchronous": 2}

Loopback wrk; real sessions and CSRF checks; isolated SQLite database; default WAL/FULL durability. 6s measured and 1s warmup per run, fresh server per case. Upload/delete throughput counts both API operations, about two requests per completed image cycle. Peak RSS is sampled every 200 ms; CPU percentages are recorded in the JSON. These are closed-loop saturation results without user think time.

Login burst: {"requests": 32, "concurrency": 8, "statuses": {"200": 4, "429": 28}, "reasons": {"Sign-in workers are busy. Try again shortly": 28}}

Login rate limit: {"requests": 45, "statuses": {"200": 45}}

SQLite integrity, foreign keys, fixture card count and BLOB lengths passed
