# RHCL Lab — Tests catalog
#
# Static web server based on the Red Hat UBI9 nginx image. Serves every
# walkthrough directory under /reqs/ (one self-contained folder per capability,
# each with a README.md and optional index.html) and a landing page that lists
# all of them with one click each.
#
# Designed for OpenShift restricted-v2 SCC:
#   * UBI9 nginx already runs as UID 1001 in group 0
#   * default listener is on port 8080
#   * static content lives under /opt/app-root/src
#
# The catalog is regenerated on every container start so a volume-mounted
# tests directory is reflected without a rebuild.

# ---------------------------------------------------------------------------
# Stage 1: fetch marked.min.js so the spec viewer renders Markdown without
# needing internet egress at runtime (handy on airgapped OpenShift clusters).
# ---------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS marked-fetcher
ARG MARKED_VERSION=13.0.3
RUN microdnf install -y --nodocs --setopt=install_weak_deps=0 \
        curl-minimal ca-certificates \
 && microdnf clean all \
 && curl -fsSL -o /tmp/marked.min.js \
        "https://cdn.jsdelivr.net/npm/marked@${MARKED_VERSION}/marked.min.js"

# ---------------------------------------------------------------------------
# Stage 2: nginx + content
# ---------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/nginx-124:latest

USER 0

# Copy the build context (the walkthrough directories + catalog/).
# .dockerignore strips Dockerfile, .dockerignore, templates/ and the tests
# README.md. The catalog/ folder is kept in the context because we copy assets
# out of it below — it is removed from /reqs/ in the RUN step so it does not
# appear as a fake walkthrough.
COPY --chown=1001:0 . /opt/app-root/src/reqs/

# Catalog landing page, markdown viewer, and the scanner script.
COPY --chown=1001:0 catalog/index.html  /opt/app-root/src/index.html
COPY --chown=1001:0 catalog/viewer.html /opt/app-root/src/viewer.html
COPY --chown=1001:0 catalog/generate-catalog.sh /opt/app-root/generate-catalog.sh
COPY --chown=1001:0 catalog/generate-env.sh     /opt/app-root/generate-env.sh

# Bundled markdown renderer.
COPY --from=marked-fetcher --chown=1001:0 /tmp/marked.min.js \
    /opt/app-root/src/assets/marked.min.js

# Drop catalog/ leftover under /reqs/, generate the initial catalog.json, and
# make everything group-readable/writable so the random OpenShift UID (in
# group 0) can read it and the entrypoint can rewrite catalog.json on start.
RUN rm -rf /opt/app-root/src/reqs/catalog \
 && chmod +x /opt/app-root/generate-catalog.sh /opt/app-root/generate-env.sh \
 && REQS_DIR=/opt/app-root/src/reqs \
    OUT=/opt/app-root/src/catalog.json \
    /opt/app-root/generate-catalog.sh \
 && OUT=/opt/app-root/src/env.json \
    /opt/app-root/generate-env.sh \
 && chmod -R g=u /opt/app-root/src

USER 1001

EXPOSE 8080

# Regenerate the catalog at every start (covers the case of a tests volume
# mounted over /opt/app-root/src/reqs) and then hand over to the standard
# UBI9 nginx s2i runner, which serves /opt/app-root/src on port 8080.
CMD ["/bin/sh", "-c", "REQS_DIR=/opt/app-root/src/reqs OUT=/opt/app-root/src/catalog.json /opt/app-root/generate-catalog.sh; OUT=/opt/app-root/src/env.json /opt/app-root/generate-env.sh; exec /usr/libexec/s2i/run"]
