PYTHON?=python3.10
export PYTHON
TOX?=tox
export TOX
COPYRIGHT="SAP edge team"
CONTRIBUTORS=\
	--contributor "Manjun Jiao (@mjiao)" \
	--contributor "Kirill Satarin (@kksat)"
YEAR=$$(date +%Y)

.PHONY: .venv/bin/activate
.venv/bin/activate:  # Create python virtual environment
	$(PYTHON) -m venv .venv
	. .venv/bin/activate && \
	$(PYTHON) -m pip install -r requirements-dev.txt

.PHONY: yamllint
yamllint: .venv/bin/activate ## Run yamllint
	. .venv/bin/activate && $(TOX) -e yamllint

.PHONY: lint
lint: yamllint shellcheck reuse  # Run linting for the repo

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
