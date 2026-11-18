.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

.PHONY: help bootstrap steps step resume dry-run verify tools teardown lint

help:
	@printf '%-15s %s\n' \
	  'make help' 'Show the available commands' \
	  'make bootstrap' 'Build the sandbox or resume an interrupted build' \
	  'make steps' 'List deployment steps and show their status' \
	  'make step' 'Run one step selected with S=<step>' \
	  'make resume' 'Start at the step selected with S=<step>' \
	  'make dry-run' 'Preview the bootstrap' \
	  'make verify' 'Check the running sandbox, optionally with LAYER=<number>' \
	  'make tools' 'Install the pinned command-line tools' \
	  'make teardown' 'Remove the cluster and step markers while retaining the root CA' \
	  'make lint' 'Check shell syntax and run ShellCheck when available'

bootstrap steps dry-run:
	./bootstrap.sh $(if $(filter steps,$@),--list,$(if $(filter dry-run,$@),--dry-run))

step resume:
	@if [[ -z "$(S)" ]]; then printf 'Usage: make %s S=<step>\n' '$@' >&2; exit 2; fi
	./bootstrap.sh $(if $(filter step,$@),--only,--from) "$(S)"

verify:
	scripts/verify.sh $(LAYER)

tools:
	scripts/install-tools.sh

teardown:
	scripts/teardown.sh

lint:
	@set -e; for script in bootstrap.sh scripts/*.sh scripts/lib/*.sh scripts/steps/*.sh envs/*/env.sh; do \
	  bash -n "$$script"; \
	done
	@if command -v shellcheck >/dev/null; then \
	  shellcheck -x -S warning bootstrap.sh scripts/*.sh scripts/steps/*.sh; \
	else \
	  printf '%s\n' 'Shell syntax passed. ShellCheck is unavailable.'; \
	fi
