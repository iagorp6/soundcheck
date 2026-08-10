# syntax=docker/dockerfile:1
#
# soundcheck app image
# ---------------------------------------------------------------------------
# Small on purpose. The interesting line is the HEALTHCHECK at the bottom:
# see the long comment there for why this repo has TWO health checks that do
# apparently the same thing.

FROM python:3.9-slim

# OCI labels. `org.opencontainers.image.*` is the standard set; anything that
# inspects images (registries, scanners, `docker inspect`) knows to read them.
LABEL org.opencontainers.image.title="soundcheck" \
      org.opencontainers.image.description="Deploy / monitor / rollback demo service" \
      org.opencontainers.image.source="https://github.com/iagorp6/soundcheck" \
      org.opencontainers.image.licenses="MIT"

# PYTHONUNBUFFERED: without it Python buffers stdout when it is a pipe, and
# `docker logs` lags behind reality: the log line explaining a crash arrives
# after the crash, or not at all.
# PYTHONDONTWRITEBYTECODE: .pyc files in a layer are dead weight; the process
# is started once and discarded.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Dependencies before source, as a separate layer. Docker caches per
# instruction, so editing app.py re-runs only the COPY below it; without this
# split, every one-character source change would reinstall Flask.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as a non-root user. Nothing here needs root, and a container process
# that does not need a privilege should not hold one. If the app is ever
# exploited, the blast radius starts smaller. Port 8080 is above 1024, so no
# privileged bind is required.
RUN useradd --create-home --uid 10001 appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

# ---------------------------------------------------------------------------
# HEALTHCHECK, and why this repo checks health in two different places
# ---------------------------------------------------------------------------
# This directive makes the CONTAINER RUNTIME probe the app on a schedule. The
# result shows up in `docker ps` as (healthy)/(unhealthy), in
# `docker inspect .State.Health`, and. Importantly. In anything built on top
# of Docker: compose `depends_on: condition: service_healthy`, Swarm, a
# scheduler deciding whether to send traffic.
#
# showtime.sh ALSO does an external `curl -sf` check. That is not redundancy,
# they answer different questions:
#
#   The Docker-native check answers "does the platform believe this container
#   is healthy?" It runs forever, from inside, and other tooling can consume
#   the verdict without knowing anything about this app.
#
#   The external check answers "can a client on the host actually reach this
#   service through the published port?" It exercises the port mapping and the
#   network path, which the internal check cannot see. A container can be
#   perfectly healthy inside while its published port is bound to the wrong
#   interface. It is also the check the deploy script can BLOCK on, which is
#   what the retry loop needs.
#
# Kubernetes replaces this directive entirely with readinessProbe/livenessProbe
# (see k8s/deployment.yaml); it ignores Docker HEALTHCHECK. That is worth
# knowing before wondering why it seems to do nothing on a cluster.
#
# urllib rather than curl: this base image has no curl, and adding it would
# mean an apt layer and a package to keep patched, for one HTTP GET. The
# non-zero exit on failure is what Docker actually reads.
#   --start-period gives the app time to boot without failures counting.
# ---------------------------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status == 200 else 1)"

CMD ["python", "app.py"]
