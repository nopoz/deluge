#!/usr/bin/env bash
# The image is slim and has no ps or pgrep, so process checks read /proc.
set -euo pipefail

IMAGE=${1:?usage: smoke.sh IMAGE}
NAME=deluge-smoke-$$
CFG=$(mktemp -d)
chmod 777 "$CFG"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # The daemons ran as PUID, so /config is not ours to delete. Hand it back
  # from a root container first.
  docker run --rm -v "$CFG":/cfg --entrypoint chown "$IMAGE" \
    -R "$(id -u):$(id -g)" /cfg >/dev/null 2>&1 || true
  rm -rf "$CFG"
}
trap cleanup EXIT

fail() { echo "SMOKE FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -30 >&2; exit 1; }

port_open() {  # $1 = port
  docker exec "$NAME" python3 -c \
    "import socket,sys; sys.exit(socket.socket().connect_ex(('127.0.0.1',$1)))" \
    2>/dev/null
}

docker run -d --name "$NAME" \
  -e PUID=1000 -e PGID=1000 -e DELUGE_LOGLEVEL=info \
  --ulimit nofile=262144:262144 \
  -v "$CFG":/config "$IMAGE" >/dev/null

echo "waiting for daemons"
for _ in $(seq 1 60); do
  port_open 58846 && port_open 8112 && break
  sleep 2
done

port_open 58846 || fail "deluged not listening on 58846"
port_open 8112  || fail "deluge-web not listening on 8112"

libc=$(docker exec "$NAME" python3 -c 'import platform; print(platform.libc_ver()[0])')
[ "$libc" = glibc ] || fail "expected glibc, got '$libc'"

lt=$(docker exec "$NAME" python3 -c 'import libtorrent; print(libtorrent.__version__)')
case "$lt" in 2.0.11*) ;; *) fail "expected libtorrent 2.0.11, got '$lt'" ;; esac

for p in AutoAdd Execute Label WebUi; do
  docker exec "$NAME" sh -c \
    "ls /usr/local/lib/python3.12/site-packages/deluge/plugins/${p}-*.egg" >/dev/null 2>&1 \
    || fail "bundled plugin egg missing: $p"
done

# Match the full binary path, not "deluged": a bare substring match also hits
# the "s6-supervise svc-deluged" wrapper, which runs as root and would report
# the wrong uid and the wrong descriptor limit.
read -r soft uid <<<"$(docker exec "$NAME" python3 -c '
import os
pid = next(p for p in os.listdir("/proc") if p.isdigit()
           and b"/usr/local/bin/deluged" in open(f"/proc/{p}/cmdline", "rb").read())
soft = next(l for l in open(f"/proc/{pid}/limits") if "open files" in l).split()[3]
uid = next(l for l in open(f"/proc/{pid}/status") if l.startswith("Uid:")).split()[1]
print(soft, uid)
')"
[ "$soft" -ge 262144 ] || fail "nofile soft limit is $soft, expected >= 262144"
[ "$uid" = 1000 ] || fail "deluged runs as uid $uid, expected 1000"

# Graceful stop. deluged must receive SIGTERM and exit on its own; if s6
# SIGKILLs it partway through writing torrents.state the file is truncated and
# the truncated copy also overwrites the .bak.
#
# The config here is empty, so a correct shutdown is near-instant. The tight
# bound is the point: it catches S6_KILL_GRACETIME being raised, which is an
# unconditional sleep rather than a timeout and would delay every single stop.
echo "stopping"
start=$(date +%s)
docker stop -t 180 "$NAME" >/dev/null
took=$(( $(date +%s) - start ))
[ "$took" -lt 30 ] || fail "empty-config shutdown took ${took}s, expected under 30s"

docker logs "$NAME" 2>&1 | grep -q "svc-deluged: stopping" \
  || fail "s6 did not report stopping svc-deluged"

echo "SMOKE PASS (libc=$libc libtorrent=$lt nofile=$soft uid=$uid stop=${took}s)"
