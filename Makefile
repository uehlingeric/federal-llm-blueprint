.PHONY: fmt fmt-check init tf-validate tflint checkov check-controls oscal oscal-check docs docs-check test validate help

DIRS := $(wildcard modules/*) $(wildcard examples/*)
TF_PLUGIN_CACHE_DIR ?= $(HOME)/.terraform.d/plugin-cache

help:
	@echo "Terraform CI targets:"
	@echo "  fmt          - Format all Terraform code"
	@echo "  fmt-check    - Check formatting without changes"
	@echo "  init         - Initialize Terraform directories"
	@echo "  tf-validate  - Validate Terraform configuration"
	@echo "  tflint       - Run tflint linter"
	@echo "  checkov      - Run Checkov security checks"
	@echo "  check-controls - Check CONTROLS.md/controls.yaml/code consistency"
	@echo "  oscal        - Generate the OSCAL component definition from controls.yaml"
	@echo "  oscal-check  - Check the OSCAL component definition is current"
	@echo "  docs         - Generate module documentation"
	@echo "  docs-check   - Check that docs are up to date"
	@echo "  test         - Run Terraform tests (if present)"
	@echo "  validate     - Run all checks (fmt-check, tf-validate, tflint, checkov, check-controls, oscal-check, docs-check, test)"

fmt:
	terraform fmt -recursive

fmt-check:
	terraform fmt -check -recursive -diff

init: $(TF_PLUGIN_CACHE_DIR)
	@for d in $(DIRS); do \
		terraform -chdir=$$d init -backend=false -input=false || exit 1; \
	done

$(TF_PLUGIN_CACHE_DIR):
	mkdir -p $@

tf-validate: init
	@for d in $(DIRS); do \
		terraform -chdir=$$d validate || exit 1; \
	done

tflint:
	tflint --init
	tflint --recursive --config "$(CURDIR)/.tflint.hcl"

checkov:
	checkov --config-file .checkov.yaml

check-controls:
	python3 scripts/check-control-refs.py

oscal:
	python3 scripts/generate-oscal.py

oscal-check:
	python3 scripts/generate-oscal.py --check

docs:
	@for d in $(wildcard modules/*); do \
		terraform-docs -c .terraform-docs.yml $$d || exit 1; \
	done

docs-check: docs
	@if ! git diff --exit-code -- 'modules/*/README.md' 2>/dev/null; then \
		echo "ERROR: Module READMEs are out of date. Run 'make docs' and commit the changes."; \
		exit 1; \
	fi

test: init
	@for d in $(DIRS); do \
		if [ -d $$d/tests ]; then \
			terraform -chdir=$$d test || exit 1; \
		fi; \
	done

validate: fmt-check tf-validate tflint checkov check-controls oscal-check docs-check test
