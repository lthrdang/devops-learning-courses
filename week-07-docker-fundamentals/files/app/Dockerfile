# ---------------------------------------------------------------------------
# The reference image for week 7. Every line is deliberate; read the comments.
# Build:  docker build -t lab/app:1.0 .
# ---------------------------------------------------------------------------

FROM python:3.12-slim AS base

# Why slim and not alpine: alpine uses musl instead of glibc, so Python wheels
# with compiled extensions often have to be built from source - a 10-second
# build becomes 10 minutes and the result is frequently LARGER than slim.
# Alpine is excellent for Go static binaries and a trap for Python.

# PYTHONDONTWRITEBYTECODE: no .pyc files in a read-only container.
# PYTHONUNBUFFERED:        logs appear immediately instead of being lost in a
#                          buffer when the process is killed. Non-negotiable
#                          for containers, where stdout IS the log.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# --- dependencies first, source second -------------------------------------
# This ordering is the whole build-cache trick: requirements.txt changes rarely,
# app.py changes constantly. Copying source first would reinstall every
# dependency on every code change.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# --- run as a non-root user -------------------------------------------------
# Containers run as root by default, and without user namespaces that root is
# the HOST's root if anything escapes. A fixed high UID keeps file ownership
# predictable when a volume is shared.
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser \
 && mkdir -p /data \
 && chown appuser:appuser /data
USER appuser

ENV PORT=8000 \
    DATA_DIR=/data \
    APP_VERSION=1.0

# EXPOSE IS DOCUMENTATION. It publishes nothing. Only `-p` on docker run, or
# `ports:` in compose, actually opens a port on the host.
EXPOSE 8000

# start-period gives the app time to boot before failures count against it -
# without it, a slow-starting app is marked unhealthy and killed before it
# ever had a chance.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=2).status==200 else 1)"

# EXEC FORM (a JSON array). This makes python PID 1, so it RECEIVES SIGTERM
# from `docker stop` and can shut down gracefully.
# The shell form - CMD python app.py - makes /bin/sh PID 1; sh does not forward
# signals, the app never learns it should stop, and it is SIGKILLed after the
# grace period. That is how in-flight requests get dropped and data gets
# corrupted. Always use the exec form.
CMD ["python", "app.py"]
