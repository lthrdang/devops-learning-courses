.RECIPEPREFIX = >
.DEFAULT_GOAL := help
SHELL := /bin/bash

help:  ## show targets
> @grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

init:  ## create .env and the secret file
> @test -f .env || cp .env.example .env
> @mkdir -p secrets
> @test -f secrets/db_password.txt || { openssl rand -base64 24 | tr -d '\n' > secrets/db_password.txt; echo "generated secrets/db_password.txt"; }
# Protect the DIRECTORY, not the file. 0700 on secrets/ stops every other
# unprivileged user on the host from even listing what secrets exist, and the
# Docker daemon runs as root so it traverses the directory regardless.
> @chmod 700 secrets
# 644 - and yes, that is deliberate. Read this before you "fix" it back to 600.
#
# A Compose `file:` secret is a plain BIND MOUNT of the host file. The uid, gid
# and mode you see on the host are exactly what the container sees; nothing is
# copied and nothing is re-owned. api/Dockerfile runs as USER appuser (uid
# 10001), which matches neither your uid nor root, so with mode 0600 the open()
# in app.py:_secret() raises PermissionError at import, the healthcheck never
# passes, and the whole stack aborts with
#   "dependency failed to start: container stack-api-1 is unhealthy".
#
# The `uid:`, `gid:` and `mode:` sub-options that would fix this are SWARM-ONLY
# - Compose parses them and silently ignores them for file-based secrets. So on
# a single host you get exactly two choices: run the container as the uid that
# owns the file, or make the file world-readable. Week 10's Swarm secrets are
# the real answer: they are mounted from tmpfs with the uid/gid/mode you ask
# for, so the secret can be 0400 root-owned and still readable by uid 10001.
> @chmod 644 secrets/db_password.txt

up: init  ## start the stack (dev)
> docker compose up -d --build
> @echo "waiting for health..."
> @for i in $$(seq 1 30); do \
>    if [ "$$(docker compose ps --format json api 2>/dev/null | grep -c healthy)" -ge 1 ]; then break; fi; sleep 2; \
>  done
> docker compose ps

prod: init  ## start with the production overlay
> docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build

seed:  ## run the profile-gated seeder
> docker compose --profile tools run --rm seed

logs:  ## follow all logs
> docker compose logs -f --tail=50

check:  ## show the RESOLVED config
> docker compose config

down:  ## stop and remove containers
> docker compose down

nuke:  ## stop and DELETE VOLUMES - destroys the database
> @echo "This deletes the database volume. Ctrl-C within 5s."
> @sleep 5
> docker compose down -v
