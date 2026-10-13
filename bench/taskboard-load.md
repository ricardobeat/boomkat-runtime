# Taskboard load test

| Workload | req/s @1 | req/s @32 | req/s @128 | p50 / p99 ms @128 | Errors | Peak RSS MiB @128 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| JS asset | 42,427 | 177,419 | 164,253 | 0.62 / 1.65 | 0 | 32.8 |
| Board JSON (200 cards) | 1,873 | 2,337 | 2,245 | 56.19 / 60.19 | 142 | 44.3 |
| Image read (128 KiB) | 7,353 | 9,414 | 9,104 | 13.96 / 16.96 | 0 | 79.6 |
| Card update (250 B) | 6,641 | 7,968 | 7,533 | 15.67 / 32.75 | 0 | 44.4 |
| Mixed 70% board / 20% image / 10% update | 2,390 | 2,885 | 2,723 | 44.53 / 81.66 | 34 | 47.3 |
| Image upload + delete (128 KiB) | 3,158 | 3,217 | 2,196 | 50.60 / 884.29 | 0 | 63.0 |

{"accounts": 10, "shared_teams": 2, "boards": 4, "cards_per_board": 200, "images": 16, "board_json_bytes": 79040, "asset_bytes": 26575, "image_bytes": 131072, "journal_mode": "wal", "synchronous": 2}

Loopback wrk; real sessions and CSRF checks; isolated SQLite database; default WAL/FULL durability. 8s measured and 1s warmup per run, fresh server per case. Upload/delete throughput counts both API operations, about two requests per completed image cycle. Peak RSS is sampled every 200 ms; CPU percentages are recorded in the JSON. These are closed-loop saturation results without user think time.

Login burst: {"requests": 32, "concurrency": 8, "statuses": {"200": 2, "429": 30}, "reasons": {"Sign-in workers are busy. Try again shortly": 28, "Too many sign-in attempts. Try again in a minute": 2}}

Login rate limit: {"requests": 45, "statuses": {"200": 30, "429": 15}}

SQLite integrity, foreign keys, fixture card count and BLOB lengths passed
