.RECIPEPREFIX = >
.DEFAULT_GOAL := help
SHELL := /bin/bash

help:  ## show targets
> @grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

init:  ## create .env and the secret file
> @test -f .env || cp .env.example .env
> @mkdir -p secrets
> @test -f secrets/db_password.txt || { openssl rand -base64 24 | tr -d '\n' > secrets/db_password.txt; echo "generated secrets/db_password.txt"; }
> @chmod 600 secrets/db_password.txt

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
