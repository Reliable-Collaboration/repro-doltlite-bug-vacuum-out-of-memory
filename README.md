# DoltLite v0.50.9: `VACUUM` answers "out of memory" on a database with a long commit history

On DoltLite v0.50.9, `VACUUM` fails on a 4,000,000-row table after 1,200 changes to it were committed one
at a time, while the `doltlite` process uses 1.2 GiB of memory under an 8 GiB limit:

```
Error near line 2: out of memory
```

SQLite 3.46.1 vacuums the same rows without an error, and so does DoltLite when the same changes are
committed once.

The big table is not essential. A smaller table fails too, after proportionally more commits; see
[Table size](#table-size).

Reported upstream: https://github.com/dolthub/doltlite/issues/2820

## Reproduce it

You need Docker, a POSIX shell (Linux, macOS, or Windows with WSL), and about 5 GB free in Docker's
storage. The first run builds the image; after that, a run takes about 40 seconds.

```sh
git clone https://github.com/Reliable-Collaboration/repro-doltlite-bug-vacuum-out-of-memory.git
cd repro-doltlite-bug-vacuum-out-of-memory
./repro.sh         # 1200 committed changes: VACUUM fails on DoltLite, exits 1
./repro.sh 900     # 900 committed changes: VACUUM succeeds on both, exits 0
```

`repro.sh` builds an image from the [`Dockerfile`](Dockerfile): Debian 13 with its `sqlite3` shell, and
the `doltlite` shell from DoltLite's two v0.50.9 release packages, each checked against its SHA-256.
It starts one throwaway container with an 8 GiB memory limit and builds three databases in it from the
same statements (see [The test](#the-test)): one with SQLite; one with DoltLite, committing after every
change; and a control with DoltLite, committing the same changes once. It then runs
[`repro.sql`](repro.sql) on each, prints SQLite's output beside the output from the long DoltLite
history, compares the control with SQLite, reports the peak memory of the `doltlite` process, and
removes the container. The argument is the number of changes.

To try another DoltLite release, give its version and the SHA-256 of its two packages:

```sh
DOLTLITE_VERSION=x.y.z LIBDOLTLITE_SHA256=... DOLTLITE_SHA256=... ./repro.sh
```

### Without the script

The same steps by hand, from the repository directory: the DoltLite database with 1,201 commits, then
the SQLite database. The fourth command makes the 1,200 commits and takes about 15 seconds.

```sh
docker build -t repro-doltlite-bug-vacuum-out-of-memory .
docker run -d --name repro-doltlite-bug-vacuum-out-of-memory --memory 8g repro-doltlite-bug-vacuum-out-of-memory sleep infinity
docker exec repro-doltlite-bug-vacuum-out-of-memory doltlite /tmp/doltlite.db "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL);" "INSERT INTO t SELECT value, 0 FROM generate_series(1, 4000000);" "SELECT dolt_commit('-Am', 'rows');"
yes "UPDATE t SET v = v + 1 WHERE id IN (SELECT value FROM generate_series(20000, 4000000, 20000)); SELECT dolt_commit('-Am', 'change');" | head -n 1200 | docker exec -i repro-doltlite-bug-vacuum-out-of-memory doltlite /tmp/doltlite.db > /dev/null
docker exec repro-doltlite-bug-vacuum-out-of-memory /usr/bin/time -f "peak resident memory: %M KiB" doltlite /tmp/doltlite.db "VACUUM;"
docker exec repro-doltlite-bug-vacuum-out-of-memory cat /sys/fs/cgroup/memory.max
docker exec repro-doltlite-bug-vacuum-out-of-memory sqlite3 /tmp/sqlite.db "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL);" "INSERT INTO t SELECT value, 0 FROM generate_series(1, 4000000);"
yes "UPDATE t SET v = v + 1 WHERE id IN (SELECT value FROM generate_series(20000, 4000000, 20000));" | head -n 1200 | docker exec -i repro-doltlite-bug-vacuum-out-of-memory sqlite3 /tmp/sqlite.db
docker exec repro-doltlite-bug-vacuum-out-of-memory sqlite3 /tmp/sqlite.db "SELECT count(*), sum(v) FROM t;" "VACUUM;"
docker rm -f repro-doltlite-bug-vacuum-out-of-memory
```

## The test

[`repro.sql`](repro.sql), run on each database:

```sql
SELECT count(*), sum(v) FROM t;
VACUUM;
SELECT count(*), sum(v) FROM t;
```

Before that, `repro.sh` gives each database the same table and rows with these statements, sending the
`UPDATE` 1,200 times:

```sql
CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL);
INSERT INTO t SELECT value, 0 FROM generate_series(1, 4000000);
UPDATE t SET v = v + 1 WHERE id IN (SELECT value FROM generate_series(20000, 4000000, 20000));
```

On DoltLite it also runs `SELECT dolt_commit('-Am', 'change');` after the `INSERT` and after every
`UPDATE`: 1,201 commits. For the control database it runs that after the `INSERT` and once after the
last `UPDATE`: 2 commits.

## Expected behavior

`VACUUM` succeeds, and the rows are unchanged. This is what SQLite 3.46.1 does (the left side of
`./repro.sh`):

```
SELECT count(*), sum(v) FROM t;
4000000|240000
VACUUM;
SELECT count(*), sum(v) FROM t;
4000000|240000
```

DoltLite v0.50.9 does the same with the control database, which holds the same rows after the same
changes, committed once:

```
Control: DoltLite v0.50.9, the same rows and changes in 2 commits: output identical to SQLite's.
```

## Actual behavior

With 1,201 commits, `VACUUM` fails; the rows stay readable. This is what DoltLite v0.50.9 does (the
right side of `./repro.sh`):

```
SELECT count(*), sum(v) FROM t;
4000000|240000
VACUUM;
Error near line 2: out of memory
SELECT count(*), sum(v) FROM t;
4000000|240000
```

The process is far below the container's memory limit when it fails:

```
Memory: the doltlite process running repro.sql peaked at 1.2 GiB resident,
under the container limit of 8.0 GiB (memory.events: oom 0, oom_kill 0).
```

By hand, the shell names the failing argument, and `time` gives the exact peak:

```
$ docker exec repro-doltlite-bug-vacuum-out-of-memory /usr/bin/time -f "peak resident memory: %M KiB" doltlite /tmp/doltlite.db "VACUUM;"
Error in 2nd command line argument: out of memory
Command exited with non-zero status 1
peak resident memory: 1234140 KiB
$ docker exec repro-doltlite-bug-vacuum-out-of-memory cat /sys/fs/cgroup/memory.max
8589934592
```

## Side by side

The full output of `./repro.sh`:

```
Building the image: Debian 13's sqlite3, and DoltLite from its release packages
Started a container with a memory limit of 8 GiB: SQLite 3.46.1 and DoltLite v0.50.9
SQLite: 4,000,000 rows, then 1200 changes, each adding 1 to every 20,000th row
DoltLite: the same, with a commit after the rows and after each change
DoltLite, control: the same, with one commit after the rows and one after all the changes

Left: SQLite 3.46.1. Right: DoltLite v0.50.9, 1201 commits. Lines that differ are marked with |, < or >.

SELECT count(*), sum(v) FROM t;                               SELECT count(*), sum(v) FROM t;
4000000|240000                                                4000000|240000
VACUUM;                                                       VACUUM;
                                                            > Error near line 2: out of memory
SELECT count(*), sum(v) FROM t;                               SELECT count(*), sum(v) FROM t;
4000000|240000                                                4000000|240000

Control: DoltLite v0.50.9, the same rows and changes in 2 commits: output identical to SQLite's.
Memory: the doltlite process running repro.sql peaked at 1.2 GiB resident,
under the container limit of 8.0 GiB (memory.events: oom 0, oom_kill 0).

Result: DoltLite's output differs from SQLite's on 1 line(s), marked with |, < or >.
```

## Other observations

- `./repro.sh 900` (901 commits): `VACUUM` succeeds on DoltLite and the script exits 0. `./repro.sh 1000`
  (1,001 commits) fails as above.
- In a container started without `--memory` (`memory.max` reads `max`), the 1,201-commit database gives
  the same `Error in 2nd command line argument: out of memory` after 2.88 s, at a peak of 1,231,596 KiB.
- `SELECT dolt_gc();` and `VACUUM INTO` a new file fail the same way on that database, at peaks of
  1,231,384 KiB and 1,234,152 KiB; `VACUUM INTO` creates no file.
- The failed `VACUUM` leaves the database file as it was: 2,242,098,289 bytes, with the same SHA-256
  before and after.
- The size of the file does not decide it. The control database, with the same 1,200 changes made
  without a commit between them, is 2,239,572,105 bytes; its `VACUUM` succeeds in 0.50 s and shrinks it
  to 79,582,140 bytes.
- Changing more rows per commit makes it fail sooner, on a bigger file. With every 10,000th row changed
  per commit instead of every 20,000th, `SELECT dolt_gc()` succeeded after 800 committed changes (a
  2,166,189,193-byte file) and failed after 900 (2,427,399,613 bytes). With every 20,000th row, it
  succeeded after 900 (1,546,474,112 bytes) and failed after 1,000 (1,709,634,228 bytes).
- The peak at the failure is about the same in every failing run: 1,228,752 KiB after 1,000 committed
  changes, 1,233,876 KiB after 1,200, and 1,255,952 KiB after 900 changes of every 10,000th row.
- Read in the v0.50.9 source, not tested by patching: in `src/doltlite_gc.c`, `gcQueuePush` doubles the
  garbage collector's mark queue and returns `SQLITE_NOMEM` when the next size would pass 2^31 - 1
  bytes, so at 72 bytes per `GcQueueItem` the queue holds at most 16,777,216 entries (1,152 MiB).
  `gcQueuePop` only advances `iHead`, so entries already taken are never released, and `gcChildCb`
  pushes every child hash without checking the `marked` set, so the queue needs an entry for every child
  reference of every distinct reachable chunk. That limit was added by
  [dolthub/doltlite#1736](https://github.com/dolthub/doltlite/pull/1736); `src/doltlite_gc.c` on
  `master` (commit 1ca177f773, 2026-09-11) is identical to v0.50.9's.
- Related but different: [dolthub/doltlite#1633](https://github.com/dolthub/doltlite/issues/1633)
  (closed), where `dolt_gc` ran out of memory on stores over about 2 GB because its rewrite buffered all
  live chunks. Here nothing is rewritten: the file is unchanged, and `VACUUM INTO` writes nothing.

## Table size

The 4,000,000 rows are not what triggers the failure: the number of committed changes together with the
size of the table is. With the same kind of change, `VACUUM` fails on smaller tables too, after
proportionally more commits. In every run it first failed once the table's rows times its committed
changes came to between about 3.0 and 3.6 billion.

| Rows in `t` | Rows changed per commit | Last success | First failure | Rows × changes at the first failure | File before the failing run | Peak memory of the failing run |
|---|---|---|---|---|---|---|
| 4,000,000 | 400 | 800 changes | 900 changes | 3.6 billion | 2,427,399,613 bytes | 1,255,952 KiB |
| 1,000,000 | 100 | 3,024 changes | 3,360 changes | 3.4 billion | 2,210,587,237 bytes | 1,253,852 KiB |
| 250,000 | 25 | 12,096 changes | 13,440 changes | 3.4 billion | 2,198,268,824 bytes | 1,255,148 KiB |
| 64,000 | 6 | 47,250 changes | 52,500 changes | 3.4 billion | 2,347,500,093 bytes | 1,270,456 KiB |

How it was measured: every committed change was the same statement pair, adding 1 to every 10,000th row,
`UPDATE t SET v = v + 1 WHERE id IN (SELECT value FROM generate_series(10000, N, 10000))` and then
`SELECT dolt_commit('-Am', 'change')`, after a first commit of the rows. It ran in the image this
repository builds, in a container with an 8 GiB memory limit. `VACUUM` ran at checkpoints on the same
database as its history grew, so each successful run had compacted the file before the next; each row of
the table stops at the first checkpoint that failed. The 4,000,000-row line is the one under
[Other observations](#other-observations), measured with `SELECT dolt_gc()`, which fails the same way;
the other three were measured with `VACUUM` on 2026-09-11.

- The file size does not decide it: the file before the failing run was 2.2 to 2.4 GB whatever the
  table size.
- The memory the run needs grows with the history. On the 1,000,000-row table, `VACUUM` peaked at
  133,040 KiB after 336 changes, 647,372 KiB after 1,680, and 1,143,924 KiB after 3,024, the last
  success. Every failure came at about 1.2 GiB.
- A smaller table takes longer to reach the failure, because it needs more commits. Making the changes
  up to the failure took about 27 s on 1,000,000 rows, 73 s on 250,000 and 111 s on 64,000, while the
  test's 1,200 changes on 4,000,000 rows take about 15 s. That is why the test uses the big table.
- Why, inferred from these numbers and the source reading above, not traced in the code: a commit that
  changes rows spread across the table writes new copies of the index pages above them, and each new
  page puts all of its child references on the garbage collector's queue. The bigger the table, the more
  pages a spread-out change rewrites, so each commit adds more references and the queue reaches its
  16,777,216 entries after fewer commits. At the same rate, a 4,000-row table would need about 840,000
  committed changes; that is a prediction from the table, not a measurement.

## Environment

- DoltLite v0.50.9, the newest release when this was written (published 2026-09-10), from
  https://github.com/dolthub/doltlite/releases/tag/v0.50.9: `libdoltlite0_0.50.9_amd64.deb`, SHA-256
  `bc1c936a7f0975af2182c24d98d20da45e04d4ac101df5f892923928aee1a7eb`, and `doltlite_0.50.9_amd64.deb`,
  SHA-256 `cf387247a87166f51df73a832b4d93df4162552cb21f3df66bcb44494751e1a5`. `doltlite --version`
  prints `DoltLite v0.50.9 (SQLite 3.54.0, 64-bit)`.
- SQLite 3.46.1: Debian 13's `sqlite3` package, version `3.46.1-7+deb13u1`, in image `debian:13-slim`,
  digest `sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132`.
- Reproduced on 2026-09-11 with Docker 29.7.2 (Docker Desktop on the WSL 2 kernel 6.18.33.2), on x86_64
  with 32 CPUs.
