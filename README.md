# Deluge BitTorrent Client

[![build-status]][github-ci] [![docs-status]][rtd-deluge]

Deluge is a BitTorrent client that utilizes a daemon/client model.
It has various user interfaces available such as the GTK-UI, Web-UI and
Console-UI. It uses [libtorrent][lt] at its core to handle the BitTorrent
protocol.

## About this fork

This is the `downstream` branch of [nopoz/deluge](https://github.com/nopoz/deluge), a fork of [Deluge](https://github.com/deluge-torrent/deluge). It is upstream's `develop` branch plus a set of fixes, and it is published as a ready-to-run Docker image.

The fixes came out of running Deluge with around 1,000 torrents on a 3 Gbps connection. At that scale stock Deluge's interfaces froze during fast downloads, and the daemon could stop answering every client for minutes at a time. Every fix that applies to Deluge in general has been submitted upstream; the links go to those pull requests.

### What's different from upstream

**Responsiveness at high speed and with many torrents**

- **No more freezing during fast downloads.** Deluge refreshed each torrent's status one at a time, on the same thread that answers the user interfaces, and at multi-gigabit speeds every refresh waited on the busy download engine. With ~900 torrents that froze every connected client for up to 39 seconds at a time; the worst pause is now about 2 seconds. ([#515](https://github.com/deluge-torrent/deluge/pull/515))
- **The Peers and Files tabs no longer stall the daemon.** The detailed views of a single torrent, and the progress of a torrent being moved to network storage, now load in the background. ([#537](https://github.com/deluge-torrent/deluge/pull/537))
- **Adding torrents in bulk no longer locks things up.** Every connected interface used to fetch every detail of a new torrent the moment it was added, so a batch of adds from Sonarr, Radarr or AutoAdd could stall the daemon for minutes. ([#535](https://github.com/deluge-torrent/deluge/pull/535))
- **Startup no longer stalls on tracker replies.** Each reply used to make a blocking call, and on startup every torrent announces at once. ([#538](https://github.com/deluge-torrent/deluge/pull/538))
- **Smaller status updates with plugins enabled.** Plugin columns such as Label were resent for every torrent on every refresh, whether they had changed or not. ([#518](https://github.com/deluge-torrent/deluge/pull/518))
- **The web UI downloads only what changed.** With ~900 torrents each refresh is about 40 times smaller. ([#539](https://github.com/deluge-torrent/deluge/pull/539))

**Reliability**

- **The web UI no longer leaks connections to the daemon.** Each reconnect left the old connection open, they piled up over weeks, and every one of them made adding a torrent slower. ([#534](https://github.com/deluge-torrent/deluge/pull/534))
- **A failed torrent add can no longer silently stop the daemon.** An error at the wrong moment used to leave torrents transferring while status updates, completion moves and resume data all stopped, and clients hung waiting. ([#521](https://github.com/deluge-torrent/deluge/pull/521))
- **Removing a torrent can no longer leave a broken entry behind** that errors on every status request until the daemon restarts. ([#516](https://github.com/deluge-torrent/deluge/pull/516))
- **Passwords are no longer written to the log.** Auth file entries from before password hashing were logged in plain text on every login. ([#522](https://github.com/deluge-torrent/deluge/pull/522))
- **No false-alarm tracebacks when deleting many torrents at once.** Upstream [#506](https://github.com/deluge-torrent/deluge/pull/506) and [#6](https://github.com/deluge-torrent/deluge/pull/6) already include this change.

The branch also carries CI fixes, so the test suite runs to completion again ([#517](https://github.com/deluge-torrent/deluge/pull/517)), and the tooling that rebuilds `downstream` from this list of branches.

### Docker image

A prebuilt image of this branch is on the GitHub Container Registry:

    docker pull ghcr.io/nopoz/deluge:latest

| Tag            | What it is                                                           |
| -------------- | -------------------------------------------------------------------- |
| `latest`       | the newest release                                                   |
| `prod-<date>`  | one release, for example `prod-2026-11-03`; pin to one of these      |
| `downstream`   | every rebuild of this branch, which can be ahead of the last release |
| `sha-<commit>` | one exact build                                                      |

It runs the daemon and the web UI together (web UI on 8112, daemon on 58846) and is built for linux/amd64. A minimal compose file:

```yaml
services:
  deluge:
    image: ghcr.io/nopoz/deluge:latest
    container_name: deluge
    network_mode: host
    environment:
      PUID: 1000
      PGID: 1000
      TZ: Etc/UTC
    volumes:
      - ./config:/config
      - ./downloads:/downloads
    stop_grace_period: 180s
    restart: unless-stopped
```

A few things set it apart:

- **Built on Debian rather than Alpine.** In side-by-side tests the same code downloaded about 50% faster on glibc than on Alpine's musl.
- **Easy to move to from the linuxserver image.** It uses the same `/config` layout and the same `PUID`, `PGID` and `UMASK_SET` variables, so an existing config directory carries straight over. Remove any `healthcheck:` block you had, since the image ships its own.
- **Tools for completion scripts.** `curl`, `unrar` and `7z` are included for the Execute plugin.
- **Sensible defaults for large libraries**, such as a high open-file limit and a shutdown that waits for Deluge to save its state.

Environment variables, stopping, health checks and building it yourself are covered in [packaging/docker/README.md](packaging/docker/README.md).

### Installing without Docker

The install steps below are upstream's. `pip install deluge` installs upstream's release from PyPI, which has none of these changes; to get them, install from source on this branch.

## Install

From [PyPi](https://pypi.org/project/deluge):

    pip install deluge

with all optional dependencies:

    pip install deluge[all]

From source code:

    pip install .

with all optional dependencies:

    pip install .[all]

See [DEPENDS](DEPENDS.md) and [Installing/Source] for dependency details.

## Usage

The various user-interfaces and Deluge daemon can be started with the following commands.

Use the `--help` option for further command options.

### Gtk UI

`deluge` or `deluge-gtk`

### Console UI

`deluge-console`

### Web UI

`deluge-web`

Open http://localhost:8112 with default password `deluge`.

### Daemon

`deluged`

See the [Thinclient guide] to connect to the daemon from another computer.

## Contact

- [Homepage](https://deluge-torrent.org)
- [User guide][user guide]
- [Forum](https://forum.deluge-torrent.org)
- [IRC Libera.Chat #deluge](irc://irc.libera.chat/deluge)
- [Discord](https://discord.gg/nwaHSE6tqn)

[user guide]: https://dev.deluge-torrent.org/wiki/UserGuide
[thinclient guide]: https://dev.deluge-torrent.org/wiki/UserGuide/ThinClient
[installing/source]: https://dev.deluge-torrent.org/wiki/Installing/Source
[build-status]: https://github.com/deluge-torrent/deluge/actions/workflows/ci.yml/badge.svg?branch=develop "CI"
[github-ci]: https://github.com/deluge-torrent/deluge/actions/workflows/ci.yml
[docs-status]: https://readthedocs.org/projects/deluge/badge/?version=latest
[rtd-deluge]: https://deluge.readthedocs.io/en/latest/?badge=latest "Documentation Status"
[lt]: https://libtorrent.org
