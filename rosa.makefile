CLUSTER_NAME?=sapeic-cluster
ROSA_VERSION?=4.14.0
AWS_REGION?=eu-central-1

TERRAFORM_DIRECTORY=./rosa/terraform
TERRAFORM?=terraform
TERRAFORM_OPTIONS=-backend-config=./backend.config

.PHONY: rosa-login
rosa-login:  ## Login using ROSA token
	$(call required-environment-variables,ROSA_TOKEN)
	@rosa login --token="${ROSA_TOKEN}"

.PHONY: rosa-init
rosa-init:  ## ROSA init
	rosa init

.PHONY: rosa-account-roles
rosa-account-roles:  ## Login using ROSA token
	rosa create account-roles --mode auto

.PHONY: rosa-cluster
rosa-cluster:  ## Create ROSA cluster
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	rosa create cluster --cluster-name "${CLUSTER_NAME}"

.PHONY: rosa-cluster-status
rosa-cluster-status:  ## Get ROSA cluster status
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	rosa describe cluster --cluster "${CLUSTER_NAME}"

.PHONY: rosa-cluster-hibernate
rosa-cluster-hibernate:  ## Hibernate ROSA cluster
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	rosa hibernate cluster --cluster "${CLUSTER_NAME}"

.PHONY: rosa-cluster-resume
rosa-cluster-resume:  ## Resume ROSA cluster
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	rosa resume cluster --cluster "${CLUSTER_NAME}"

.PHONY: rosa-cluster-delete
rosa-cluster-delete:  ## Delete ROSA cluster
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	rosa delete cluster --cluster "${CLUSTER_NAME}"

.PHONY: rosa-cluster-admin
rosa-cluster-admin:  ## Create cluster admin
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME CLUSTER_ADMIN_PASSWORD)
	@rosa create admin --cluster ${CLUSTER_NAME} --password ${CLUSTER_ADMIN_PASSWORD} >/dev/null
	$(info cluster admin created)

.PHONY: rosa-cluster-admin-reset
rosa-cluster-admin-reset:  ## Reset cluster admin password
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME CLUSTER_ADMIN_PASSWORD)
	@rosa delete admin --cluster ${CLUSTER_NAME} --yes >/dev/null
	$(info cluster admin deleted)
	@rosa create admin --cluster ${CLUSTER_NAME} --password ${CLUSTER_ADMIN_PASSWORD} >/dev/null
	$(info cluster admin password reset)

.PHONY: rosa-cluster-oc-login
rosa-cluster-oc-login:  ## OC cli login to existing cluster (cluster-admin should already exist)
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	@rosa describe admin --cluster=${CLUSTER_NAME} | grep -v 'INFO'

.PHONY: $(TERRAFORM_DIRECTORY)/backend.config
$(TERRAFORM_DIRECTORY)/backend.config:  ## Generate terraform backend configuration
	$(call required-environment-variables,TERRAFORM_BACKEND_S3_BUCKET TERRAFORM_BACKEND_S3_KEY) 
	$(call required-environment-variables,TERRAFORM_BACKEND_S3_AWS_REGION TERRAFORM_BACKEND_S3_DYNAMODB_TABLE) 
	envsubst < $(TERRAFORM_DIRECTORY)/backend.config.envsubst > $(TERRAFORM_DIRECTORY)/backend.config

.ONESHELL:
.PHONY: rosa-terraform-init
rosa-terraform-init: $(TERRAFORM_DIRECTORY)/backend.config  ## Initialize Terraform in rosa/terraform directory
	cd ${TERRAFORM_DIRECTORY}
	$(TERRAFORM) init $(TERRAFORM_OPTIONS)

.PHONY: rosa-terraform-plan
.ONESHELL:
rosa-terraform-plan: rosa-terraform-init  ## Run terraform plan with terraform.tfvars
	$(call required-environment-variables,TF_VAR_admin_password TF_VAR_admin_username)
	$(call required-environment-variables,CLUSTER_NAME ROSA_VERSION AWS_REGION) 
	cd $(TERRAFORM_DIRECTORY)
	export TF_VAR_cluster_name="${CLUSTER_NAME}"
	export TF_VAR_rosa_version="${ROSA_VERSION}"
	export TF_VAR_aws_region="${AWS_REGION}"
	export TF_VAR_vpc_name="${CLUSTER_NAME}-vpc"
	$(TERRAFORM) plan
