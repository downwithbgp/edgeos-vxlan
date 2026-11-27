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

# snapshot.ubuntu.com redirects HTTP to HTTPS; install ca-certificates in the
# base layer first so the snapshot repository can be used.
# Bootstrap trust only: exact versions from the signed Ubuntu archive.  No
# repository signature verification is disabled.  All later packages come from
# the frozen snapshot below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates=20260816ubuntu0.24.04.2 \
        openssl=3.0.13-0ubuntu3.16 \
    && rm -rf /var/lib/apt/lists/*

RUN rm -f /etc/apt/sources.list /etc/apt/sources.list.d/* \
    && printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT} noble main universe" \
        "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT} noble-updates main universe" \
        "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT} noble-security main universe" \
        > /etc/apt/sources.list \
    && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99snapshot \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        debhelper \
        dpkg-dev \
        fakeroot \
        git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
