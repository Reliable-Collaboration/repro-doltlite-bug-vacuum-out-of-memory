#!/bin/sh
# Gives SQLite and DoltLite the same table, in one throwaway container that holds both shells, then runs
# repro.sql on each and prints the two outputs side by side. On DoltLite every change to the table is
# committed, so its database carries a long commit history. Exits 0 when DoltLite's output is identical
# to SQLite's, and 1 when it differs.
#
#   ./repro.sh         1200 changes, each committed on DoltLite: VACUUM fails there (exits 1)
#   ./repro.sh 900     900 changes: VACUUM succeeds on both (exits 0)
#
# Another DoltLite release: DOLTLITE_VERSION=x.y.z LIBDOLTLITE_SHA256=... DOLTLITE_SHA256=... ./repro.sh
set -eu
cd "$(dirname "$0")"

CHANGES="${1:-1200}"
case "$CHANGES" in
  '' | *[!0-9]*) echo "usage: $0 [number of changes, default 1200]" >&2; exit 2 ;;
esac
NAME=repro-doltlite-bug-vacuum-out-of-memory
IMAGE="$NAME:${DOLTLITE_VERSION:-0.50.9}"
OUT=$(mktemp -d)

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$OUT"
}
trap cleanup EXIT

# The table, one change to it, and a DoltLite commit.
ROWS="CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL);
INSERT INTO t SELECT value, 0 FROM generate_series(1, 4000000);"
CHANGE="UPDATE t SET v = v + 1 WHERE id IN (SELECT value FROM generate_series(20000, 4000000, 20000));"
COMMIT="SELECT dolt_commit('-Am', 'change');"

echo "Building the image: Debian 13's sqlite3, and DoltLite from its release packages"
set --
[ -n "${DOLTLITE_VERSION:-}" ] && set -- "$@" --build-arg "DOLTLITE_VERSION=$DOLTLITE_VERSION"
[ -n "${LIBDOLTLITE_SHA256:-}" ] && set -- "$@" --build-arg "LIBDOLTLITE_SHA256=$LIBDOLTLITE_SHA256"
[ -n "${DOLTLITE_SHA256:-}" ] && set -- "$@" --build-arg "DOLTLITE_SHA256=$DOLTLITE_SHA256"
docker build -q "$@" -t "$IMAGE" . >/dev/null

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --memory 8g "$IMAGE" sleep infinity >/dev/null
docker cp repro.sql "$NAME:/tmp/repro.sql" >/dev/null 2>&1 || { echo "Could not copy repro.sql into $NAME" >&2; exit 2; }
SQLITE=$(docker exec "$NAME" sqlite3 --version | cut -d' ' -f1)
DOLTLITE=$(docker exec "$NAME" doltlite --version | cut -d' ' -f1-2)
echo "Started a container with a memory limit of 8 GiB: SQLite $SQLITE and $DOLTLITE"

load() { # shell, database: runs the statements from standard input, discarding their results
  docker exec -i "$NAME" "$1" "/tmp/$2" >/dev/null
}
echo "SQLite: 4,000,000 rows, then $CHANGES changes, each adding 1 to every 20,000th row"
{ echo "$ROWS"; yes "$CHANGE" | head -n "$CHANGES"; } | load sqlite3 sqlite.db
echo "DoltLite: the same, with a commit after the rows and after each change"
{ echo "$ROWS $COMMIT"; yes "$CHANGE $COMMIT" | head -n "$CHANGES"; } | load doltlite doltlite.db
echo "DoltLite, control: the same, with one commit after the rows and one after all the changes"
{ echo "$ROWS $COMMIT"; yes "$CHANGE" | head -n "$CHANGES"; echo "$COMMIT"; } | load doltlite control.db

run() { # shell, database, output file: repro.sql, each error in place after its statement
  docker exec "$NAME" sh -c "/usr/bin/time -o /tmp/$2.time -f %M stdbuf -o0 $1 -echo /tmp/$2 < /tmp/repro.sql 2>&1" > "$3" || true
}
run sqlite3 sqlite.db "$OUT/sqlite.txt"
run doltlite doltlite.db "$OUT/doltlite.txt"
run doltlite control.db "$OUT/control.txt"

echo
echo "Left: SQLite $SQLITE. Right: $DOLTLITE, $((CHANGES + 1)) commits. Lines that differ are marked with |, < or >."
echo
diff -y -t -W 121 "$OUT/sqlite.txt" "$OUT/doltlite.txt" || true
echo

if cmp -s "$OUT/sqlite.txt" "$OUT/control.txt"; then
  echo "Control: $DOLTLITE, the same rows and changes in 2 commits: output identical to SQLite's."
else
  echo "Control: $DOLTLITE, the same rows and changes in 2 commits: output differs from SQLite's:"
  cat "$OUT/control.txt"
fi
RSS=$(docker exec "$NAME" tail -n 1 /tmp/doltlite.db.time)
LIMIT=$(docker exec "$NAME" cat /sys/fs/cgroup/memory.max)
OOM=$(docker exec "$NAME" cat /sys/fs/cgroup/memory.events | awk '$1 == "oom" || $1 == "oom_kill" { printf "%s%s %s", sep, $1, $2; sep = ", " }')
awk -v rss="$RSS" -v limit="$LIMIT" -v oom="$OOM" 'BEGIN {
  printf "Memory: the doltlite process running repro.sql peaked at %.1f GiB resident,\n", rss / 1048576
  printf "under the container limit of %.1f GiB (memory.events: %s).\n", limit / 1073741824, oom
}'
echo

if cmp -s "$OUT/sqlite.txt" "$OUT/doltlite.txt"; then
  echo "Result: DoltLite's output is identical to SQLite's."
  exit 0
fi
echo "Result: DoltLite's output differs from SQLite's on $(diff "$OUT/sqlite.txt" "$OUT/doltlite.txt" | grep -c '^>') line(s), marked with |, < or >."
exit 1
