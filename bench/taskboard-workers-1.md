# Taskboard load test

| Workload | req/s @128 | p50 / p99 ms @128 | Errors | Peak RSS MiB @128 |
| --- | ---: | ---: | ---: | ---: |
| JS entry module | 308,760 | 0.36 / 0.77 | 0 | 33.8 |
| Board JSON (200 cards) | 4,231 | 30.14 / 31.13 | 0 | 50.2 |
| Image read (128 KiB) | 22,020 | 5.80 / 6.20 | 0 | 57.1 |
| Card update (250 B) | 17,242 | 7.05 / 9.63 | 0 | 37.9 |
| Mixed 70% board / 20% image / 10% update | 5,609 | 22.68 / 25.80 | 0 | 51.0 |
| Image upload + delete (128 KiB) | 4,070 | 32.66 / 46.52 | 0 | 85.0 |

{"accounts": 10, "shared_teams": 2, "boards": 4, "cards_per_board": 200, "images": 16, "board_json_bytes": 79040, "asset_bytes": 207, "image_bytes": 131072, "journal_mode": "wal", "synchronous": 2}

Loopback wrk; real sessions and CSRF checks; isolated SQLite database; default WAL/FULL durability. 6s measured and 1s warmup per run, fresh server per case. Upload/delete throughput counts both API operations, about two requests per completed image cycle. Peak RSS is sampled every 200 ms; CPU percentages are recorded in the JSON. These are closed-loop saturation results without user think time.

Login burst: {"requests": 32, "concurrency": 8, "statuses": {"200": 2, "429": 30}, "reasons": {"Sign-in workers are busy. Try again shortly": 28, "Too many sign-in attempts. Try again in a minute": 2}}

Login rate limit: {"requests": 45, "statuses": {"200": 30, "429": 15}}

SQLite integrity, foreign keys, fixture card count and BLOB lengths passed
