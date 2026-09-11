# Debian 13 with its stock sqlite3 shell, and the doltlite shell installed from a DoltLite release's two
# packages, each checked against its SHA-256 before it is installed.
FROM debian:13-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132
RUN apt-get update \
 && apt-get install -y --no-install-recommends sqlite3 time curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ARG DOLTLITE_VERSION=0.50.9
ARG LIBDOLTLITE_SHA256=bc1c936a7f0975af2182c24d98d20da45e04d4ac101df5f892923928aee1a7eb
ARG DOLTLITE_SHA256=cf387247a87166f51df73a832b4d93df4162552cb21f3df66bcb44494751e1a5
RUN cd /tmp \
 && url="https://github.com/dolthub/doltlite/releases/download/v${DOLTLITE_VERSION}" \
 && curl -fsSLO "$url/libdoltlite0_${DOLTLITE_VERSION}_amd64.deb" \
 && curl -fsSLO "$url/doltlite_${DOLTLITE_VERSION}_amd64.deb" \
 && echo "${LIBDOLTLITE_SHA256}  libdoltlite0_${DOLTLITE_VERSION}_amd64.deb" | sha256sum -c \
 && echo "${DOLTLITE_SHA256}  doltlite_${DOLTLITE_VERSION}_amd64.deb" | sha256sum -c \
 && dpkg -i "libdoltlite0_${DOLTLITE_VERSION}_amd64.deb" "doltlite_${DOLTLITE_VERSION}_amd64.deb" \
 && rm /tmp/*.deb
