CLUSTER_NAME?=sapeic-cluster
ROSA_VERSION?=4.14.0
AWS_REGION?=eu-central-1
TF_VARS_admin_username?=${KUBEADMIN_ADMIN_USERNAME}
TF_VARS_admin_password?=${KUBEADMIN_ADMIN_PASSWORD}

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

.ONESHELL:
.PHONY: rosa-terraform-init
rosa-terraform-init:  ## Initialize Terraform in rosa/terraform directory
	(cd rosa/terraform
	terraform init)

.PHONY: rosa/terraform/terraform.tfvars
.ONESHELL:
rosa/terraform/terraform.tfvars:  ## Create terraform variables file
	$(call required-environment-variables,CLUSTER_NAME ROSA_VERSION AWS_REGION) 
	envsubst < rosa/terraform/terraform.tfvars.envsubst > rosa/terraform/terraform.tfvars
	
.PHONY: rosa-terraform-plan
.ONESHELL:
rosa-terraform-plan: rosa-terraform-init rosa/terraform/terraform.tfvars  ## Run terraform plan with terraform.tfvars
	$(call check-tfvars)
	$(call required-environment-variables,KUBEADMIN_ADMIN_PASSWORD KUBEADMIN_ADMIN_USERNAME)
	$(call required-environment-variables,TF_VARS_admin_username TF_VARS_admin_password)
	(cd rosa/terraform
	terraform plan -var-file=terraform.tfvars)
