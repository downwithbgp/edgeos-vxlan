# Controlled build environment for edgeos-vxlan.
#
# The base image is digest-pinned.  APT sources point at a fixed Ubuntu
# snapshot, so package versions (and their dependencies) are selected from a
# fixed archive state rather than whatever happens to be current.
FROM ubuntu:24.04@sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b

ARG UBUNTU_SNAPSHOT=20261127T000000Z

LABEL org.opencontainers.image.title="edgeos-vxlan reproducible build environment"
LABEL org.opencontainers.image.description="Ubuntu 24.04 snapshot with Debian packaging tools and git"
LABEL org.opencontainers.image.source="https://github.com/downwithbgp/edgeos-vxlan"
LABEL org.opencontainers.image.version="2026-11-27"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Bootstrap trust: a pinned CA bundle committed with this Dockerfile (its
# SHA-256 is recorded in docs/reproducible-builds.md).  This avoids a live
# archive.ubuntu.com fetch while still using APT's normal TLS verification.
COPY ca-certificates.crt /usr/local/share/ca-certificates/edgeos-bootstrap.crt
RUN printf 'Acquire::https::CaInfo "/usr/local/share/ca-certificates/edgeos-bootstrap.crt";\n' \
        > /etc/apt/apt.conf.d/99bootstrap-ca \
    && rm -f /etc/apt/sources.list /etc/apt/sources.list.d/* \
    && printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT} noble main universe" \
        "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT} noble-updates main universe" \
        "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT} noble-security main universe" \
        > /etc/apt/sources.list \
    && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99snapshot \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        openssl \
        build-essential \
        debhelper \
        dpkg-dev \
        fakeroot \
        git \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/apt/apt.conf.d/99bootstrap-ca /etc/apt/apt.conf.d/99snapshot

WORKDIR /workspace
