# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

ifneq (,$(wildcard ./.env))
    include .env
    export
endif

defined = $(strip $(filter-out undefined,$(flavor $1)))

required-environment-variables = \
  $(eval .required-environment-variables :=) \
  $(foreach V,$(sort $1), \
    $(if $(call defined,$V),,$(eval .required-environment-variables += $V)) \
   ) \
  $(if $(strip ${.required-environment-variables}), \
    $(foreach V,${.required-environment-variables}, \
      $(info Variable is not defined but required: $$$V) \
     ) \
    $(error Not all required variables are defined) \
   )

PYTHON?=python3.10
export PYTHON
NPM?=npm
export NPM
TOX?=tox
export TOX
COPYRIGHT="SAP edge team"
CONTRIBUTORS=\
	--contributor "Manjun Jiao (@mjiao)" \
	--contributor "Kirill Satarin (@kksat)"
YEAR=$$(date +%Y)

include bicep.makefile
include rosa.makefile

.DEFAULT_GOAL := help
.PHONY: help
help: ## Show this help
	@echo Makefile how to use
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: .venv/bin/activate
.venv/bin/activate:  ## Create python virtual environment
	$(PYTHON) -m venv .venv
	. .venv/bin/activate && \
	$(PYTHON) -m pip install -r requirements-dev.txt

.PHONY: yamllint
yamllint: .venv/bin/activate ## Run yamllint
	. .venv/bin/activate && $(TOX) -e yamllint

.PHONY: lint
lint: yamllint shellcheck reuse lint-bicep  # Run linting for the repo

.PHONY: shellcheck
shellcheck: .venv/bin/activate  ## Run shell check analysis
	. .venv/bin/activate && $(TOX) -e shellcheck

.PHONY: reuse
reuse: .venv/bin/activate  ## Run reuse lint
	. .venv/bin/activate && $(TOX) -e reuse

.PHONY: reuse-annotate
reuse-annotate: .venv/bin/activate  ## Run reuse annotate
	. .venv/bin/activate && $(TOX) exec -e reuse -- \
		reuse annotate \
		--copyright $(COPYRIGHT) \
		$(CONTRIBUTORS) \
		--license Apache-2.0 \
		--year $(YEAR) \
		--recursive \
		--skip-unrecognised \
		--skip-existing \
		.

.PHONY: lint-bicep
lint-bicep:  ## Run bicep lint
	az bicep lint --file bicep/aro.bicep
	az bicep lint --file bicep/empty.bicep
	az bicep lint --file bicep/domain-records.bicep

node_modules:  # Install node modules
	$(NPM) install

.PHONY: cspell
cspell: node_modules  ## Run cspell
	$(NPM) run cspell

.PHONY: cspell-addwords
cspell-addwords: node_modules  ## Run cspell
	@$(NPM) run --silent cspell:addwords >> .config/cspell-words.txt
