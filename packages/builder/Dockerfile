# Vortex OS package builder. The host needs nothing but Docker.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential devscripts debhelper lintian fakeroot \
        ca-certificates curl gnupg xz-utils git jq aptly \
    && rm -rf /var/lib/apt/lists/*

# Go — pinned official toolchain (bookworm's golang-go is 1.19, too old).
ARG GO_VERSION=1.22.12
RUN arch=$(dpkg --print-architecture) \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" \
       | tar -C /usr/local -xz
ENV PATH=/usr/local/go/bin:$PATH

# Node 22 — pinned major from NodeSource (matches the nodejs deb we mirror
# into the Vortex apt repo, so build-time and run-time engines agree).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
