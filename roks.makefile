# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

# ROKS (Red Hat OpenShift on IBM Cloud, VPC) Terraform in roks/terraform.
#
# Required environment for init/plan/apply/destroy:
#   CLUSTER                  cluster name, e.g. redhat-roks-eic-pr123 (state key roks/$(CLUSTER)/terraform.tfstate)
#   TERRAFORM_STATE_BUCKET   COS bucket holding the Terraform state
#   AWS_ACCESS_KEY_ID        COS HMAC access key of the state bucket
#   AWS_SECRET_ACCESS_KEY    COS HMAC secret key of the state bucket
#   IBMCLOUD_API_KEY         IBM Cloud API key (plan/apply/destroy)
# Optional:
#   TERRAFORM_STATE_ENDPOINT COS S3 endpoint (default: eu-de public endpoint)
#   ROKS_TF_ARGS             extra arguments for plan/apply/destroy, e.g. -var pr_number=123
#
# Every recipe is a single shell command so it behaves the same with and
# without .ONESHELL (set in rosa.makefile; ignored by GNU make 3.81).

ROKS_TERRAFORM_DIRECTORY=./roks/terraform
ROKS_TERRAFORM?=terraform
TERRAFORM_STATE_ENDPOINT?=https://s3.eu-de.cloud-object-storage.appdomain.cloud
TERRAFORM_STATE_REGION?=eu-de
ROKS_TF_ARGS?=

.PHONY: $(ROKS_TERRAFORM_DIRECTORY)/backend.config
$(ROKS_TERRAFORM_DIRECTORY)/backend.config:  ## Generate the ROKS Terraform backend configuration (COS via the s3 backend)
	$(call required-environment-variables,TERRAFORM_STATE_BUCKET TERRAFORM_STATE_ENDPOINT CLUSTER)
	@printf '%s\n' \
		'bucket                      = "$(TERRAFORM_STATE_BUCKET)"' \
		'key                         = "roks/$(CLUSTER)/terraform.tfstate"' \
		'region                      = "$(TERRAFORM_STATE_REGION)"' \
		'endpoints                   = { s3 = "$(TERRAFORM_STATE_ENDPOINT)" }' \
		'use_lockfile                = true' \
		'use_path_style              = true' \
		'skip_credentials_validation = true' \
		'skip_region_validation      = true' \
		'skip_requesting_account_id  = true' \
		'skip_s3_checksum            = true' \
		> $(ROKS_TERRAFORM_DIRECTORY)/backend.config

.PHONY: roks-init
roks-init: $(ROKS_TERRAFORM_DIRECTORY)/backend.config  ## ROKS: terraform init against the COS state of CLUSTER
	$(call required-environment-variables,AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY)
	cd $(ROKS_TERRAFORM_DIRECTORY) && $(ROKS_TERRAFORM) init -input=false -reconfigure -backend-config=backend.config

.PHONY: roks-plan
roks-plan: roks-init  ## ROKS: terraform plan for CLUSTER
	$(call required-environment-variables,IBMCLOUD_API_KEY)
	cd $(ROKS_TERRAFORM_DIRECTORY) && $(ROKS_TERRAFORM) plan -input=false -var 'cluster_name=$(CLUSTER)' $(ROKS_TF_ARGS)

.PHONY: roks-apply
roks-apply: roks-init  ## ROKS: terraform apply for CLUSTER
	$(call required-environment-variables,IBMCLOUD_API_KEY)
	cd $(ROKS_TERRAFORM_DIRECTORY) && $(ROKS_TERRAFORM) apply -var 'cluster_name=$(CLUSTER)' $(ROKS_TF_ARGS)

# -refresh=false: destroy straight from the state. A refresh would re-read the
# admin-kubeconfig data source, which fails when the cluster is already
# (half) gone or the kubeconfig directory is missing.
.PHONY: roks-destroy
roks-destroy: roks-init  ## ROKS: terraform destroy of CLUSTER from its state (manual cleanup path)
	$(call required-environment-variables,IBMCLOUD_API_KEY)
	cd $(ROKS_TERRAFORM_DIRECTORY) && $(ROKS_TERRAFORM) destroy -refresh=false -var 'cluster_name=$(CLUSTER)' $(ROKS_TF_ARGS)

.PHONY: roks-tflint
roks-tflint:  ## Run tflint on roks/terraform
	@cd $(ROKS_TERRAFORM_DIRECTORY) && tflint

.PHONY: roks-tfsec
roks-tfsec:  ## Run tfsec on roks/terraform
	@cd $(ROKS_TERRAFORM_DIRECTORY) && tfsec . --exclude-path .terraform

.PHONY: roks-checkov
roks-checkov:  ## Run checkov on roks/terraform
	@checkov --directory $(ROKS_TERRAFORM_DIRECTORY)
