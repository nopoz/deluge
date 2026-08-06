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

# Compiled extensions must not use instructions above the image's baseline ISA.
#
# rencode's build.py hardcodes -march=native, so the extension targets whatever
# CPU built it. A build on a runner newer than the deployment host yields an
# image whose every process dies with SIGILL on `import rencode`, before Python
# can log anything. That reached production once.
#
# Detected by the EVEX prefix (0x62), which in 64-bit mode is exclusively
# AVX-512, rather than by mnemonic or by %zmm: the instruction that broke
# production was vmovdqu8 on %ymm, so register width does not reveal it.
#
# Read statically, because this script runs on the machine that compiled the
# code. Importing rencode here would succeed no matter what and prove nothing.
if command -v objdump >/dev/null 2>&1; then
  echo "checking compiled extensions for above-baseline instructions"
  purelib=$(docker run --rm --entrypoint python3 "$IMAGE" \
    -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
  sodir=$(mktemp -d)
  cid=$(docker create "$IMAGE")
  for pkg in rencode setproctitle zope; do
    docker cp "$cid:$purelib/$pkg" "$sodir/" >/dev/null 2>&1 || true
  done
  docker rm "$cid" >/dev/null
  evex=""
  while IFS= read -r so; do
    n=$(objdump -d "$so" 2>/dev/null | grep -cE '^[[:space:]]+[0-9a-f]+:[[:space:]]+62 ' || true)
    [ "${n:-0}" -gt 0 ] && evex="$evex $(basename "$so"):$n"
  done < <(find "$sodir" -name '*.so')
  rm -rf "$sodir"
  if [ -n "$evex" ]; then
    echo "SMOKE FAIL: AVX-512 (EVEX) instructions in compiled extensions:$evex" >&2
    echo "the CC baseline wrapper in the Dockerfile is not taking effect" >&2
    exit 1
  fi
else
  echo "objdump not found, skipping baseline ISA check" >&2
fi

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

# The image's own HEALTHCHECK must pass. A slim base has no wget or curl, so a
# healthcheck written for the linuxserver image fails with "wget: not found".
echo "waiting for healthy"
for _ in $(seq 1 60); do
  [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME")" = healthy ] && break
  sleep 2
done
health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME")
[ "$health" = healthy ] || fail "container health is '$health', not healthy"

# Retried: the init oneshot's output can reach the container log later than the
# daemons' own, so a single check right after startup can miss it.
found=0
for _ in $(seq 1 15); do
  if docker logs "$NAME" 2>&1 | grep -q "^deluge: "; then found=1; break; fi
  sleep 2
done
if [ "$found" -ne 1 ]; then
  echo "--- full container log ---" >&2
  docker logs "$NAME" 2>&1 >&2
  fail "no startup status line; an operator at --loglevel error would see nothing"
fi

if docker logs "$NAME" 2>&1 | grep -qi "deprecated, please define them in"; then
  fail "s6 user bundle is in the deprecated location"
fi

libc=$(docker exec "$NAME" python3 -c 'import platform; print(platform.libc_ver()[0])')
[ "$libc" = glibc ] || fail "expected glibc, got '$libc'"

lt=$(docker exec "$NAME" python3 -c 'import libtorrent; print(libtorrent.__version__)')
case "$lt" in 2.0.11*) ;; *) fail "expected libtorrent 2.0.11, got '$lt'" ;; esac

# The libtorrent wheel statically links an OpenSSL built with
# OPENSSLDIR=/usr/local/ssl, which does not exist here, so without these two
# variables it loads no CA certificates and every HTTPS tracker announce fails.
# That regression reached production once and broke all 896 torrents' announces.
#
# Checked without touching the network on purpose: a live TLS handshake in CI
# would be flaky, and libtorrent exposes no way to inspect its cert store. The
# functional proof is an A/B against a real tracker, recorded in ROADMAP.md.
# What can regress silently is the variables being dropped or ca-certificates
# being removed from the image, and both are caught here.
certfile=$(docker exec "$NAME" printenv SSL_CERT_FILE 2>/dev/null || true)
certdir=$(docker exec "$NAME" printenv SSL_CERT_DIR 2>/dev/null || true)
[ -n "$certfile" ] || fail "SSL_CERT_FILE is unset; libtorrent will trust no CA and every HTTPS tracker will fail"
[ -n "$certdir" ] || fail "SSL_CERT_DIR is unset; libtorrent will trust no CA and every HTTPS tracker will fail"

docker exec "$NAME" test -s "$certfile" \
  || fail "SSL_CERT_FILE points at '$certfile', which is missing or empty"
docker exec "$NAME" test -d "$certdir" \
  || fail "SSL_CERT_DIR points at '$certdir', which is not a directory"

ncerts=$(docker exec "$NAME" sh -c "grep -c 'BEGIN CERTIFICATE' '$certfile'" 2>/dev/null || echo 0)
[ "$ncerts" -ge 100 ] || fail "CA bundle holds only $ncerts certificates, expected >= 100"

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

# Retried: the last log lines are still being collected when docker stop
# returns, so grepping immediately is a race.
stopped=0
for _ in $(seq 1 10); do
  if docker logs "$NAME" 2>&1 | grep -q "svc-deluged: stopping"; then stopped=1; break; fi
  sleep 1
done
[ "$stopped" -eq 1 ] || fail "s6 did not report stopping svc-deluged"

echo "SMOKE PASS (libc=$libc libtorrent=$lt nofile=$soft uid=$uid stop=${took}s)"
