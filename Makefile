PYTHON?=python3.10
export PYTHON
TOX?=tox
export TOX

.PHONY: .venv/bin/activate
.venv/bin/activate:  # Create python virtual environment
	$(PYTHON) -m venv .venv
	. .venv/bin/activate && \
	$(PYTHON) -m pip install -r requirements-dev.txt

.PHONY: yamllint
yamllint: .venv/bin/activate ## Run yamllint
	. .venv/bin/activate && $(TOX) -e yamllint

.PHONY: lint
lint: yamllint shellcheck  # Run linting for the repo

.PHONY: shellcheck
shellcheck: .venv/bin/activate  ## Run shell check analysis
	. .venv/bin/activate && $(TOX) -e shellcheck

.PHONY: reuse
reuse: .venv/bin/activate  ## Run reuse lint
	. .venv/bin/activate && $(TOX) -e reuse
