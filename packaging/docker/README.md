# Deluge container image

`deluged` and `deluge-web` in one image, built from this repository.

## Quick start

    docker compose -f packaging/docker/docker-compose.yml up -d

The web UI is on port 8112, the daemon RPC on 58846, and BitTorrent on 6881.

## Environment

| Variable          | Default | Purpose                                                  |
| ----------------- | ------- | -------------------------------------------------------- |
| `PUID`            | `1000`  | uid the daemons run as                                   |
| `PGID`            | `1000`  | gid the daemons run as                                   |
| `UMASK_SET`       | `022`   | umask for created files; `UMASK` is accepted as an alias |
| `TZ`              | unset   | container timezone                                       |
| `DELUGE_LOGLEVEL` | `info`  | Deluge log level                                         |

`PUID`/`PGID` are applied at start and `/config` is chowned to match. Download and
media mounts are deliberately left alone, so their permissions stay yours to
manage.

## Stopping

**Always allow 180 seconds.**

    docker stop -t 180 deluge

Deluge writes `torrents.state` during shutdown. With a large torrent list the
default 10 second timeout truncates that file part-written, and because the
truncated copy is then written over `torrents.state.bak` there is nothing to
recover from. The compose file sets `stop_grace_period: 180s` for this reason.

Inside the container, `S6_SERVICES_GRACETIME` is set to 180000 so s6 waits for
Deluge rather than killing it. `S6_KILL_GRACETIME` is deliberately left at its
default: it is an unconditional sleep between SIGTERM and SIGKILL rather than a
timeout, so raising it would add that delay to every stop even when Deluge has
already exited.

## File descriptors

libtorrent needs far more descriptors than the usual 1024 soft default. The image
raises its own soft limit toward the hard limit at start, so it is correct without
any flag. Set the hard limit too if your host's is low:

    --ulimit nofile=262144:262144

## Building locally

    python3 version.py
    docker build -f packaging/docker/Dockerfile -t deluge:local .
    ./packaging/docker/smoke.sh deluge:local

`version.py` writes `RELEASE-VERSION`, which is derived from git tags rather than
checked in. The build context excludes `.git`, so generate it first or the build
stops with a message telling you to.

`smoke.sh` starts the image, checks both daemons answer, checks the interpreter
and libtorrent build are what they should be, and checks shutdown is graceful.

## Notes

The image is glibc-based rather than musl. libtorrent runs a multi-threaded disk
and hashing pool, which is the allocation pattern musl's allocator handles worst.

Three pins matter and none are cosmetic:

- `libtorrent==2.0.11` matches production. Changing it can change how session
  settings behave, so treat a bump as a deliberate, separately measured change.
- `setuptools<82`, because `deluge.pluginmanagerbase` imports `pkg_resources`,
  which setuptools removed in 81.
- `pyopenssl<26`, because `deluge/crypto_utils.py` uses `crypto.X509Req`, which
  pyOpenSSL removed in 26.

The last two are packaging workarounds for real incompatibilities in the Deluge
source, not preferences.
