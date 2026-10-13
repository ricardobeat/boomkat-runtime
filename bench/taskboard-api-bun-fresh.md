# Taskboard load test

| Workload | req/s @128 | p50 / p99 ms @128 | Errors | Peak RSS MiB @128 |
| --- | ---: | ---: | ---: | ---: |
| JS asset | 145,561 | 0.69 / 2.14 | 0 | 68.7 |
| Board JSON (200 cards) | 4,713 | 26.55 / 34.53 | 0 | 134.3 |
| Image read (128 KiB) | 22,260 | 5.50 / 9.84 | 0 | 126.3 |
| Card update (250 B) | 16,967 | 7.21 / 11.09 | 0 | 98.2 |
| Mixed 70% board / 20% image / 10% update | 6,195 | 20.57 / 22.51 | 0 | 140.0 |
| Image upload + delete (128 KiB) | 3,541 | 35.99 / 57.27 | 53 | 118.9 |

{"accounts": 10, "shared_teams": 2, "boards": 4, "cards_per_board": 200, "images": 16, "board_json_bytes": 79040, "asset_bytes": 26575, "image_bytes": 131072, "journal_mode": "wal", "synchronous": 2}

Loopback wrk; real sessions and CSRF checks; isolated SQLite database; default WAL/FULL durability. 8s measured and 1s warmup per run, fresh server per case. Upload/delete throughput counts both API operations, about two requests per completed image cycle. Peak RSS is sampled every 200 ms; CPU percentages are recorded in the JSON. These are closed-loop saturation results without user think time.

Login burst: {"requests": 32, "concurrency": 8, "statuses": {"200": 2, "429": 30}, "reasons": {"Sign-in workers are busy. Try again shortly": 28, "Too many sign-in attempts. Try again in a minute": 2}}

Login rate limit: {"requests": 45, "statuses": {"200": 30, "429": 15}}

SQLite integrity, foreign keys, fixture card count and BLOB lengths passed
