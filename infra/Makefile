# ---------------------------------------------------------------------------
# Lab lifecycle for the Zero-to-Junior Platform Engineer course.
#
#   make help              list every target
#   make w01-up            create the VM(s) for week 1
#   make w10-up            create the 3-node Swarm cluster
#   make cluster-up LOWMEM=1   same, but sized for an 8 GB host
#   make snapshot VM=lab NAME=clean
#   make down              stop everything
#   make clean             destroy everything (irreversible)
#
# We use .RECIPEPREFIX so recipes are indented with '>' instead of tabs -
# it removes the single most common source of "missing separator" errors.
# ---------------------------------------------------------------------------
.RECIPEPREFIX = >
.DEFAULT_GOAL := help
SHELL := /bin/bash

IMAGE   ?= 24.04
CI      := $(CURDIR)/cloud-init
SCRIPTS := $(CURDIR)/scripts

# Sizing. LOWMEM=1 shrinks every profile for an 8 GB host.
ifeq ($(LOWMEM),1)
  SINGLE_MEM  := 1.5G
  PAIR_MEM    := 768M
  DOCKER_MEM  := 2G
  CLUSTER_MEM := 1G
else
  SINGLE_MEM  := 2G
  PAIR_MEM    := 1G
  DOCKER_MEM  := 3G
  CLUSTER_MEM := 1.5G
endif

.PHONY: help
help: ## Show this help
> @echo "Lab targets:"
> @grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
>   | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
> @echo ""
> @echo "Current instances:"
> @multipass list || true

# --- individual profiles ---------------------------------------------------

.PHONY: single-up
single-up: ## 1 general-purpose VM named 'lab' (weeks 1-3, 6)
> multipass launch $(IMAGE) --name lab --cpus 2 --memory $(SINGLE_MEM) --disk 10G \
>   --cloud-init $(CI)/base.yaml
> @$(SCRIPTS)/lab-up.sh post lab

.PHONY: pair-up
pair-up: ## 2 VMs named 'alpha' and 'beta' (weeks 4-5, networking)
> multipass launch $(IMAGE) --name alpha --cpus 1 --memory $(PAIR_MEM) --disk 8G \
>   --cloud-init $(CI)/base.yaml
> multipass launch $(IMAGE) --name beta  --cpus 1 --memory $(PAIR_MEM) --disk 8G \
>   --cloud-init $(CI)/base.yaml
> @$(SCRIPTS)/lab-up.sh post alpha beta
> @$(SCRIPTS)/lab-up.sh hosts alpha beta

.PHONY: docker-up
docker-up: ## 1 VM with Docker Engine named 'dock' (weeks 7-8)
> multipass launch $(IMAGE) --name dock --cpus 2 --memory $(DOCKER_MEM) --disk 20G \
>   --cloud-init $(CI)/docker-node.yaml
> @$(SCRIPTS)/lab-up.sh post dock

.PHONY: obs-up
obs-up: ## 1 VM with Docker + node_exporter named 'obs' (week 9)
> multipass launch $(IMAGE) --name obs --cpus 2 --memory $(DOCKER_MEM) --disk 20G \
>   --cloud-init $(CI)/observability.yaml
> @$(SCRIPTS)/lab-up.sh post obs

.PHONY: cluster-up
cluster-up: ## 3 Docker VMs: node1 (manager) node2 node3 (weeks 10-12)
> for n in node1 node2 node3; do \
>   multipass launch $(IMAGE) --name $$n --cpus 1 --memory $(CLUSTER_MEM) --disk 12G \
>     --cloud-init $(CI)/docker-node.yaml || exit 1; \
> done
> @$(SCRIPTS)/lab-up.sh post node1 node2 node3
> @$(SCRIPTS)/lab-up.sh hosts node1 node2 node3
> @echo ""
> @echo "VMs are up but the Swarm is NOT initialised - that is week 10's lab."

# --- week aliases: what each week actually needs ----------------------------

.PHONY: w00-up w01-up w02-up w03-up w04-up w05-up w06-up w07-up w08-up w09-up w10-up w11-up w12-up
w00-up: single-up   ## Week 00 - pre-flight
w01-up: single-up   ## Week 01 - Linux foundations
w02-up: single-up   ## Week 02 - Linux sysadmin
w03-up: single-up   ## Week 03 - Bash scripting
w04-up: pair-up     ## Week 04 - Networking fundamentals
w05-up: pair-up     ## Week 05 - HTTP, TLS, proxy, load balancing
w06-up: single-up   ## Week 06 - Python for platform engineering
w07-up: docker-up   ## Week 07 - Docker fundamentals
w08-up: docker-up   ## Week 08 - Docker Compose
w09-up: obs-up      ## Week 09 - Observability & troubleshooting
w10-up: cluster-up  ## Week 10 - Docker Swarm
w11-up: cluster-up  ## Week 11 - Production concerns
w12-up: cluster-up  ## Week 12 - Capstone

# --- lifecycle -------------------------------------------------------------

.PHONY: shell
shell: ## Open a shell:  make shell VM=lab
> @test -n "$(VM)" || { echo "usage: make shell VM=<name>"; exit 1; }
> multipass shell $(VM)

.PHONY: ip
ip: ## Print every instance's IP address
> @multipass list --format csv | awk -F, 'NR>1 {printf "%-10s %-10s %s\n", $$1, $$2, $$3}'

.PHONY: snapshot
snapshot: ## Snapshot before a drill:  make snapshot VM=lab NAME=clean-w04
> @test -n "$(VM)" -a -n "$(NAME)" || { echo "usage: make snapshot VM=<name> NAME=<label>"; exit 1; }
> $(SCRIPTS)/snapshot.sh save $(VM) $(NAME)

.PHONY: restore
restore: ## Roll back after a drill:  make restore VM=lab NAME=clean-w04
> @test -n "$(VM)" -a -n "$(NAME)" || { echo "usage: make restore VM=<name> NAME=<label>"; exit 1; }
> $(SCRIPTS)/snapshot.sh restore $(VM) $(NAME)

.PHONY: break
break: ## Run a chaos drill:  make break VM=lab DRILL=04-firewall
> @test -n "$(VM)" -a -n "$(DRILL)" || { echo "usage: make break VM=<name> DRILL=<id>"; exit 1; }
> @test -f chaos/$(DRILL).sh || { echo "no such drill: chaos/$(DRILL).sh"; ls chaos/; exit 1; }
> @echo ">>> Snapshot first? (make snapshot VM=$(VM) NAME=pre-$(DRILL))"
> @multipass transfer chaos/$(DRILL).sh $(VM):/tmp/drill.sh
> @multipass exec $(VM) -- sudo bash /tmp/drill.sh
> @multipass exec $(VM) -- sudo rm -f /tmp/drill.sh
> @echo ">>> Drill applied to $(VM). You were told the symptom, not the cause. Go."

.PHONY: down
down: ## Stop all instances (frees RAM, keeps state)
> multipass stop --all

.PHONY: clean
clean: ## DESTROY all instances and reclaim disk - irreversible
> @echo "This deletes EVERY multipass instance. Ctrl-C within 5s to abort."
> @sleep 5
> multipass delete --all --purge
> multipass purge
