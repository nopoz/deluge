#!/bin/bash
# Rebuild the downstream branch: upstream/develop plus every branch in the
# patch queue, merged in listed order.
#
# downstream is disposable. Reconstructing it rather than accumulating merges is
# what makes dropping an upstream-accepted patch a one-line manifest edit
# instead of a conflict to re-resolve forever.
#
#   fork/rebuild.sh --check   verify the queue, change nothing
#   fork/rebuild.sh           rebuild downstream locally
#   fork/rebuild.sh --push    rebuild and force-with-lease to origin
set -euo pipefail

# git checkout swaps this file out from under bash mid-execution, so run from a
# copy outside the work tree.
if [ -z "${FORK_REBUILD_REEXEC:-}" ]; then
  self=$(mktemp)
  cat "$0" >"$self"
  FORK_REBUILD_REEXEC=1 bash "$self" "$@"
  rc=$?
  rm -f "$self"
  exit $rc
fi

BASE=${BASE:-develop}
BRANCH=${BRANCH:-downstream}
UPSTREAM=${UPSTREAM:-upstream/develop}
MANIFEST=${MANIFEST:-fork/patches.txt}

CHECK=0
PUSH=0
case "${1:-}" in
  --check) CHECK=1 ;;
  --push) PUSH=1 ;;
  '') ;;
  *)
    echo "usage: $0 [--check|--push]" >&2
    exit 2
    ;;
esac

[ -f "$MANIFEST" ] || {
  echo "no manifest at $MANIFEST" >&2
  exit 1
}
mapfile -t QUEUE < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" || true)
[ "${#QUEUE[@]}" -gt 0 ] || {
  echo "manifest $MANIFEST is empty" >&2
  exit 1
}

git fetch upstream --quiet

# develop must equal upstream/develop. If it does not, someone committed to it
# and every queued patch is now a diff against the wrong base.
if [ "$(git rev-parse "$BASE")" != "$(git rev-parse "$UPSTREAM")" ]; then
  if git merge-base --is-ancestor "$BASE" "$UPSTREAM"; then
    echo "fast-forwarding $BASE to $UPSTREAM"
    [ "$CHECK" -eq 1 ] || git branch -f "$BASE" "$UPSTREAM"
  else
    echo "ERROR: $BASE has diverged from $UPSTREAM; fix that first" >&2
    exit 1
  fi
fi

missing=0
for b in "${QUEUE[@]}"; do
  git rev-parse --verify --quiet "$b" >/dev/null || {
    echo "missing branch: $b" >&2
    missing=1
  }
done
[ "$missing" -eq 0 ] || exit 1

echo "queue (${#QUEUE[@]}):"
printf '  %s\n' "${QUEUE[@]}"
if [ "$CHECK" -eq 1 ]; then
  echo 'check only, nothing changed'
  exit 0
fi

git checkout --quiet -B "$BRANCH" "$UPSTREAM"
for b in "${QUEUE[@]}"; do
  echo "merging $b"
  git merge --no-ff --quiet -m "downstream: merge $b" "$b"
done

# Every file differing from upstream must be one some queued branch touches.
# Anything else means a conflict resolution or stray commit leaked in.
expected=$(for b in "${QUEUE[@]}"; do git diff --name-only "$UPSTREAM...$b"; done | sort -u)
actual=$(git diff --name-only "$UPSTREAM..$BRANCH" | sort -u)
if [ "$expected" != "$actual" ]; then
  echo 'ERROR: downstream contents do not match the queue' >&2
  diff <(echo "$expected") <(echo "$actual") >&2 || true
  exit 1
fi

echo
echo "$BRANCH rebuilt on $(git rev-parse --short "$UPSTREAM")"
git diff --stat "$UPSTREAM..$BRANCH" | tail -1
[ "$PUSH" -eq 0 ] || git push --force-with-lease origin "$BRANCH"
