#!/bin/bash
# Exercises rebuild.sh's guards. Run from the repo root.
set -uo pipefail
pass=0
fail=0

check() { # $1 description, $2 expected exit, $3.. command
  local desc=$1 want=$2
  shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1))
    echo "ok   $desc"
  else
    fail=$((fail + 1))
    echo "FAIL $desc (want exit $want, got $got)"
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf 'this-branch-does-not-exist\n' >"$tmp/bad.txt"
check "missing branch is rejected" 1 \
  env MANIFEST="$tmp/bad.txt" bash fork/rebuild.sh --check

printf '# only comments\n\n' >"$tmp/empty.txt"
check "empty manifest is rejected" 1 \
  env MANIFEST="$tmp/empty.txt" bash fork/rebuild.sh --check

check "absent manifest is rejected" 1 \
  env MANIFEST="$tmp/nope.txt" bash fork/rebuild.sh --check

check "real manifest passes check" 0 \
  bash fork/rebuild.sh --check

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
