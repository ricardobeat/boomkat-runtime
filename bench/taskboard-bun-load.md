# Taskboard load test

| Workload | req/s @1 | req/s @32 | req/s @128 | p50 / p99 ms @128 | Errors | Peak RSS MiB @128 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| JS asset | 39,493 | 111,530 | 102,049 | 0.85 / 2.80 | 0 | 71.1 |
| Board JSON (200 cards) | 3,578 | 4,352 | 4,413 | 28.54 / 37.62 | 0 | 135.1 |
| Image read (128 KiB) | 12,021 | 17,055 | 16,431 | 6.49 / 30.77 | 0 | 133.3 |
| Card update (250 B) | 12,090 | 16,444 | 16,630 | 7.31 / 10.91 | 0 | 97.9 |
| Mixed 70% board / 20% image / 10% update | 4,401 | 5,575 | 6,025 | 21.04 / 24.30 | 0 | 146.5 |
| Image upload + delete (128 KiB) | 3,850 | 3,582 | 2,998 | 43.67 / 68.72 | 0 | 105.6 |

{"accounts": 10, "shared_teams": 2, "boards": 4, "cards_per_board": 200, "images": 16, "board_json_bytes": 79040, "asset_bytes": 26575, "image_bytes": 131072, "journal_mode": "wal", "synchronous": 2}

Loopback wrk; real sessions and CSRF checks; isolated SQLite database; default WAL/FULL durability. 8s measured and 1s warmup per run, fresh server per case. Upload/delete throughput counts both API operations, about two requests per completed image cycle. Peak RSS is sampled every 200 ms; CPU percentages are recorded in the JSON. These are closed-loop saturation results without user think time.

Login burst: {"requests": 32, "concurrency": 8, "statuses": {"200": 2, "429": 30}, "reasons": {"Sign-in workers are busy. Try again shortly": 28, "Too many sign-in attempts. Try again in a minute": 2}}

Login rate limit: {"requests": 45, "statuses": {"200": 30, "429": 15}}

SQLite integrity, foreign keys, fixture card count and BLOB lengths passed
