# ---------------------------------------------------------------------------
# Zero-to-Junior Platform Engineer - repository tasks.
#
#   make docs          browse the whole course at http://localhost:8000
#   make lab           the VM lifecycle commands (delegates to infra/)
#   make check         run every gate the course itself demands
#
# Everything runs in Docker. Nothing is installed on your machine, and the
# system Python is never touched - the same reasoning as week 6.
# ---------------------------------------------------------------------------
.RECIPEPREFIX = >
.DEFAULT_GOAL := help
SHELL := /bin/bash

REPO    := $(CURDIR)
MKDOCS  := squidfunk/mkdocs-material:latest
PORT    ?= 8000

# MkDocs refuses a docs_dir containing its own config, and this filesystem has
# no symlinks. So we remap the paths at mount time: the repo becomes
# /site/docs, and mkdocs.yml is mounted alongside it as /site/mkdocs.yml.
# See the comment block at the top of mkdocs.yml.
MOUNTS := -v "$(REPO):/site/docs" -v "$(REPO)/mkdocs.yml:/site/mkdocs.yml:ro" -w /site

.PHONY: help
help:  ## Show this help
> @echo "Course tasks:"
> @grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
>   | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
> @echo ""
> @echo "Lab machines:  cd infra && make help"

# --- documentation site ----------------------------------------------------

# `docker run -it` needs a real terminal. Running these from a script, a CI job
# or a background shell has no TTY, and docker fails with "the input device is
# not a TTY". Detect it instead of assuming.
TTYFLAGS = $$([ -t 0 ] && printf -- '-it' || printf -- '-i')

.PHONY: docs
docs:  ## Serve the course at http://localhost:8000 (live reload). Override with PORT=
> @ss -tln 2>/dev/null | grep -qE "[:.]$(PORT)[[:space:]]" && { echo; echo "  Port $(PORT) is already in use:"; ss -tlnp 2>/dev/null | grep -E "[:.]$(PORT)[[:space:]]" | sed "s/^/    /"; echo; echo "  Pick another:  make $@ PORT=8888"; echo; exit 1; } || true
> @echo "Serving on http://localhost:$(PORT)  -  Ctrl-C to stop"
> @echo "Edits to any .md file reload the page automatically."
> docker run --rm $(TTYFLAGS) -p 127.0.0.1:$(PORT):8000 $(MOUNTS) $(MKDOCS) serve --dev-addr 0.0.0.0:8000

.PHONY: docs-lan
docs-lan:  ## Serve so other machines on your network can read it too
> @ss -tln 2>/dev/null | grep -qE "[:.]$(PORT)[[:space:]]" && { echo; echo "  Port $(PORT) is already in use:"; ss -tlnp 2>/dev/null | grep -E "[:.]$(PORT)[[:space:]]" | sed "s/^/    /"; echo; echo "  Pick another:  make $@ PORT=8888"; echo; exit 1; } || true
> @echo ""
> @echo "  Reachable at:"
> @ip -4 -brief addr 2>/dev/null | awk '$$1 != "lo" && $$3 ~ /\// {split($$3,a,"/"); printf "    http://%s:$(PORT)\n", a[1]}'
> @echo ""
> @echo "  NOTE: this binds 0.0.0.0 - anyone who can reach this host can read"
> @echo "  the course, INCLUDING the solutions and the chaos-drill answers."
> @echo ""
> docker run --rm $(TTYFLAGS) -p 0.0.0.0:$(PORT):8000 $(MOUNTS) $(MKDOCS) serve --dev-addr 0.0.0.0:8000

.PHONY: docs-build
docs-build:  ## Render a static site into ./site (host it anywhere)
> mkdir -p "$(REPO)/site"
> docker run --rm $(MOUNTS) -v "$(REPO)/site:/site/site" $(MKDOCS) build --strict
> @echo ""
> @echo "Built $$(find "$(REPO)/site" -name '*.html' | wc -l) pages into ./site"
> @echo "Serve it with any static server, e.g.:"
> @echo "  python3 -m http.server -d site 8000"

.PHONY: docs-check
docs-check:  ## Fail on any broken link or nav error (use this in CI)
> docker run --rm $(MOUNTS) -v /tmp/mkdocs-check:/site/site $(MKDOCS) build --strict
> @echo "documentation builds clean"

# --- quality gates: the same ones the course asks learners to meet ---------

.PHONY: check
check: check-shell check-python check-yaml docs-check  ## Run every gate
> @echo ""
> @echo "all gates passed"

.PHONY: check-shell
check-shell:  ## shellcheck every script
> @fail=0; \
>  while read -r f; do \
>    shellcheck -S warning "$$f" || fail=1; \
>  done < <(find . -name '*.sh' -not -path './site/*'); \
>  [ $$fail -eq 0 ] && echo "shellcheck: all scripts clean" || exit 1

.PHONY: check-python
check-python:  ## Run the course's own test suites
> cd week-06-python-for-platform/files/svcctl && PYTHONPATH=src python3 -m pytest tests/ -q
> cd week-03-bash-scripting/files && bats backup.bats

.PHONY: check-yaml
check-yaml:  ## Validate every YAML file
> @# A multi-line heredoc does not survive a make recipe - each line runs in its
> @# own shell and .RECIPEPREFIX strips the leading character. Exporting the
> @# program as an environment variable and feeding it to `python3 -` is the
> @# portable way to embed a real script in a Makefile.
> @printf '%s' "$$YAMLCHECK" | python3 -

define YAMLCHECK_BODY
import pathlib, yaml, sys

# Compose defines its own YAML tags - `!reset` and `!override` - for clearing
# and replacing values a previous file in a `-f a.yml -f b.yml` chain set.
# safe_load has never heard of them and refuses the file. They are valid
# Compose, so teach the loader about them rather than skipping the file: a
# compose file is exactly the kind of thing this gate exists to check.
# See https://github.com/compose-spec/compose-spec/blob/main/13-merge.md
class CourseLoader(yaml.SafeLoader):
    pass
def _tagged(loader, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return loader.construct_mapping(node, deep=True)
for _tag in ('!reset', '!override'):
    CourseLoader.add_constructor(_tag, _tagged)

bad = []
for f in pathlib.Path('.').rglob('*.y*ml'):
    if 'site/' in str(f):
        continue
    # mkdocs.yml legitimately uses !!python/name: tags, which safe_load refuses
    # by design. It is validated properly by `make docs-check`, which runs the
    # real mkdocs loader - the right validator for that file.
    if f.name == 'mkdocs.yml':
        continue
    try:
        list(yaml.load_all(f.read_text(), Loader=CourseLoader))
    except Exception as e:
        bad.append(f"{f}: {e}")
print("\n".join(bad) if bad else "yaml: all valid")
sys.exit(1 if bad else 0)
endef
export YAMLCHECK := $(YAMLCHECK_BODY)

# --- convenience -----------------------------------------------------------

.PHONY: lab
lab:  ## Show the VM lifecycle commands
> @$(MAKE) -C infra help

.PHONY: clean
clean:  ## Remove the rendered site and any caches
> rm -rf "$(REPO)/site"
> find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
> find . -name '.pytest_cache' -type d -prune -exec rm -rf {} + 2>/dev/null || true
> @echo "cleaned"
