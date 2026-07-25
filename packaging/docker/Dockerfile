# syntax=docker/dockerfile:1
#
# glibc rather than musl: libtorrent runs a multi-threaded disk and hashing pool
# whose allocation pattern is the case musl's allocator handles worst.

ARG PYTHON_VERSION=3.12
ARG LIBTORRENT_VERSION=2.0.11
ARG S6_OVERLAY_VERSION=3.2.3.2

FROM python:${PYTHON_VERSION}-slim AS builder

ARG LIBTORRENT_VERSION

# rencode, setproctitle and zope.interface have no wheels for this platform.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . /src

# version.py derives the version from git tags and caches it here. .git is kept
# out of the build context, so the file has to exist already.
RUN test -f /src/RELEASE-VERSION || { \
      echo "RELEASE-VERSION is missing. Run 'python3 version.py' in the source tree first." >&2; \
      exit 1; }

RUN python -m pip install --no-cache-dir --upgrade pip wheel 'setuptools<82'

# libtorrent is not in install_requires, and pygeoip and distro are listed only
# in requirements.txt. The constraint pins libtorrent so nothing can float it.
#
# Two caps, both needed for the daemon to start at all:
#
#   setuptools<82  deluge.pluginmanagerbase imports pkg_resources, which
#                  setuptools removed in 81. Matches requirements.txt.
#   pyopenssl<26   deluge/crypto_utils.py:112 uses crypto.X509Req, removed in
#                  pyOpenSSL 26. Production runs 25.0.0, which still has it.
#
# Both are packaging workarounds for real incompatibilities in the Deluge
# source. Fixing crypto_utils.py to use cryptography directly belongs in its
# own change, not here.
RUN printf 'libtorrent==%s\nsetuptools<82\npyopenssl<26\n' "${LIBTORRENT_VERSION}" \
      > /tmp/constraints.txt \
 && python -m pip wheel --no-cache-dir --wheel-dir /wheels \
      -c /tmp/constraints.txt \
      "libtorrent==${LIBTORRENT_VERSION}" pygeoip distro

# Deps come from setup.py's install_requires, not requirements.txt: the two
# differ, and install_requires is what pip resolves at install time. The [all]
# extra carries setproctitle, pillow, chardet and ifaddr.
#
# This also builds the bundled plugin eggs: build_plugins is a sub_command of
# build and the eggs are collected by the plugins/*.egg package_data entry.
RUN python -m pip wheel --no-cache-dir --wheel-dir /wheels \
      -c /tmp/constraints.txt "/src[all]"


FROM python:${PYTHON_VERSION}-slim AS runtime

ARG S6_OVERLAY_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata xz-utils \
 && rm -rf /var/lib/apt/lists/*

ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/s6-noarch.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp/s6-x86_64.tar.xz
RUN tar -C / -Jxpf /tmp/s6-noarch.tar.xz \
 && tar -C / -Jxpf /tmp/s6-x86_64.tar.xz \
 && rm /tmp/s6-noarch.tar.xz /tmp/s6-x86_64.tar.xz \
 && apt-get purge -y xz-utils \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,from=builder,source=/wheels,target=/wheels \
    python -m pip install --no-cache-dir --no-index --find-links=/wheels \
      "deluge[all]" libtorrent pygeoip distro

RUN groupadd -g 1000 deluge \
 && useradd -u 1000 -g 1000 -d /config -s /usr/sbin/nologin deluge

COPY packaging/docker/root/ /

# Set explicitly rather than relying on modes surviving checkout and the build
# context. s6 silently ignores a run script that is not executable.
RUN chmod 0755 /etc/s6-overlay/scripts/init-deluge \
      /etc/s6-overlay/s6-rc.d/svc-deluged/run \
      /etc/s6-overlay/s6-rc.d/svc-deluge-web/run

# S6_SERVICES_GRACETIME is how long s6 will wait for deluged to stop. Deluge
# writes torrents.state during shutdown, and at ~900 torrents the 3s default is
# not enough: a truncated write also overwrites the .bak, leaving no recovery.
#
# S6_KILL_GRACETIME is deliberately left at the default. It is an unconditional
# sleep between SIGTERM and SIGKILL in the final sweep, not a timeout, so a long
# value makes every stop take that long even when Deluge exited immediately.
ENV PYTHONUNBUFFERED=1 \
    PYTHON_EGG_CACHE=/config/plugins/.python-eggs \
    TMPDIR=/run/deluged-temp \
    DELUGE_LOGLEVEL=info \
    PUID=1000 \
    PGID=1000 \
    UMASK_SET=022 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_SERVICES_GRACETIME=180000 \
    S6_KILL_GRACETIME=3000

VOLUME /config
EXPOSE 8112 58846 6881 6881/udp

# Python, because a slim base has no wget, curl or nc. Checks both daemons:
# deluge-web answering while deluged is down is not a healthy container.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD python3 -c "import socket,sys; sys.exit(any(socket.socket().connect_ex(('127.0.0.1',p)) for p in (58846,8112)))"

ENTRYPOINT ["/init"]
