-include .env

# Set default values if not provided in .env
ROSA_TOKEN?=
AWS_REGION?=eu-central-1
ROSA_VERSION?=4.19.2
ROSA_WORKER_MACHINE_TYPE?=m5.xlarge
ROSA_WORKER_REPLICAS?=9
ROSA_DOMAIN?=
ROSA_SUBNET_IDS?=
ROSA_AVAILABILITY_ZONES?=
CLUSTER_ADMIN_PASSWORD?=$(shell openssl rand -base64 12)
CLUSTER_NAME?=sapeic-cluster

# Domain validation targets
.PHONY: rosa-domain-zone-exists
rosa-domain-zone-exists:  ## Fail if Route53 hosted zone does not exist
	$(call required-environment-variables,ROSA_DOMAIN)
	hack/rosa-domain-zone-exists.sh

# Cluster status check targets
.PHONY: rosa-cluster-status
rosa-cluster-status:  ## Check if ROSA cluster already exists and show its status
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	@ROSA_TOKEN=${ROSA_TOKEN} CLUSTER_NAME=${CLUSTER_NAME} hack/check-rosa-cluster-status.sh

# ROSA HCP Terraform deployment targets
.PHONY: rosa-hcp-deploy
rosa-hcp-deploy: rosa-cluster-status rosa-hcp-terraform-deploy  ## Deploy ROSA HCP cluster using Terraform
	$(info ROSA HCP cluster deployment complete)

.PHONY: rosa-hcp-deploy-with-domain
rosa-hcp-deploy-with-domain: rosa-domain-zone-exists rosa-cluster-status rosa-hcp-terraform-deploy  ## Deploy ROSA HCP cluster with custom domain
	$(info ROSA HCP cluster deployment complete)

.PHONY: rosa-hcp-terraform-deploy
rosa-hcp-terraform-deploy:  ## Deploy ROSA HCP cluster and all resources using Terraform
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	@echo "Deploying ROSA HCP cluster using Terraform..."
	@cd rosa/terraform && \
	terraform init && \
	terraform plan \
		-var="rosa_token=${ROSA_TOKEN}" \
		-var="cluster_name=${CLUSTER_NAME}" \
		-var="aws_region=${AWS_REGION}" \
		-var="rosa_version=${ROSA_VERSION}" \
		-var="worker_replicas=${ROSA_WORKER_REPLICAS}" \
		-var="worker_machine_type=${ROSA_WORKER_MACHINE_TYPE}" \
		-var="domain_name=${ROSA_DOMAIN}" \
		-var="admin_password=${CLUSTER_ADMIN_PASSWORD}" \
		$(if ${ROSA_SUBNET_IDS},-var="create_vpc=false" -var='existing_subnet_ids=["$(shell echo ${ROSA_SUBNET_IDS} | sed 's/,/","/g')"]') \
		$(if ${ROSA_AVAILABILITY_ZONES},-var='availability_zones=["$(shell echo ${ROSA_AVAILABILITY_ZONES} | sed 's/,/","/g')"]') && \
	terraform apply \
		-var="rosa_token=${ROSA_TOKEN}" \
		-var="cluster_name=${CLUSTER_NAME}" \
		-var="aws_region=${AWS_REGION}" \
		-var="rosa_version=${ROSA_VERSION}" \
		-var="worker_replicas=${ROSA_WORKER_REPLICAS}" \
		-var="worker_machine_type=${ROSA_WORKER_MACHINE_TYPE}" \
		-var="domain_name=${ROSA_DOMAIN}" \
		-var="admin_password=${CLUSTER_ADMIN_PASSWORD}" \
		$(if ${ROSA_SUBNET_IDS},-var="create_vpc=false" -var='existing_subnet_ids=["$(shell echo ${ROSA_SUBNET_IDS} | sed 's/,/","/g')"]') \
		$(if ${ROSA_AVAILABILITY_ZONES},-var='availability_zones=["$(shell echo ${ROSA_AVAILABILITY_ZONES} | sed 's/,/","/g')"]') \
		-auto-approve

.PHONY: rosa-hcp-destroy
rosa-hcp-destroy:  ## Destroy ROSA HCP cluster and all resources using Terraform
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	@echo "Destroying ROSA HCP cluster using Terraform..."
	@cd rosa/terraform && \
	terraform destroy \
		-var="rosa_token=${ROSA_TOKEN}" \
		-var="cluster_name=${CLUSTER_NAME}" \
		-var="aws_region=${AWS_REGION}" \
		-auto-approve

.PHONY: rosa-hcp-plan
rosa-hcp-plan:  ## Run terraform plan for ROSA HCP deployment
	$(call required-environment-variables,ROSA_TOKEN CLUSTER_NAME)
	@cd rosa/terraform && \
	terraform plan \
		-var="rosa_token=${ROSA_TOKEN}" \
		-var="cluster_name=${CLUSTER_NAME}" \
		-var="aws_region=${AWS_REGION}" \
		-var="rosa_version=${ROSA_VERSION}" \
		-var="worker_replicas=${ROSA_WORKER_REPLICAS}" \
		-var="worker_machine_type=${ROSA_WORKER_MACHINE_TYPE}" \
		-var="domain_name=${ROSA_DOMAIN}" \
		-var="admin_password=${CLUSTER_ADMIN_PASSWORD}" \
		$(if ${ROSA_SUBNET_IDS},-var="create_vpc=false" -var='existing_subnet_ids=["$(shell echo ${ROSA_SUBNET_IDS} | sed 's/,/","/g')"]') \
		$(if ${ROSA_AVAILABILITY_ZONES},-var='availability_zones=["$(shell echo ${ROSA_AVAILABILITY_ZONES} | sed 's/,/","/g')"]')

.PHONY: rosa-hcp-output
rosa-hcp-output:  ## Show terraform outputs for ROSA HCP cluster
	@cd rosa/terraform && terraform output -json

.PHONY: rosa-hcp-kubeconfig
rosa-hcp-kubeconfig:  ## Get kubeconfig for ROSA HCP cluster
	$(call required-environment-variables,CLUSTER_NAME)
	@API_URL=$$(cd rosa/terraform && terraform output -raw cluster_api_url) && \
	ADMIN_USER=$$(cd rosa/terraform && terraform output -json admin_credentials | jq -r '.username // "kubeadmin"') && \
	echo "Logging in to ROSA HCP cluster..." && \
	oc login "$$API_URL" -u "$$ADMIN_USER" -p "${CLUSTER_ADMIN_PASSWORD}"

# Network deployment using Terraform
.PHONY: rosa-network-deploy
rosa-network-deploy:  ## Deploy VPC and subnets for ROSA using Terraform
	$(call required-environment-variables,AWS_REGION CLUSTER_NAME)
	@echo "Deploying VPC and subnets for ROSA cluster using Terraform..."
	@cd rosa/terraform && \
	echo 'aws_region = "${AWS_REGION}"' > network.tfvars && \
	echo 'cluster_name = "${CLUSTER_NAME}"' >> network.tfvars && \
	echo 'vpc_name = "rosa-${CLUSTER_NAME}-vpc"' >> network.tfvars && \
	echo 'environment_tag = "rosa"' >> network.tfvars && \
	echo 'vpc_cidr = "10.0.0.0/16"' >> network.tfvars && \
	echo 'public_subnet_1_cidr = "10.0.0.0/24"' >> network.tfvars && \
	echo 'public_subnet_2_cidr = "10.0.1.0/24"' >> network.tfvars && \
	echo 'public_subnet_3_cidr = "10.0.4.0/24"' >> network.tfvars && \
	echo 'private_subnet_1_cidr = "10.0.2.0/24"' >> network.tfvars && \
	echo 'private_subnet_2_cidr = "10.0.3.0/24"' >> network.tfvars && \
	echo 'private_subnet_3_cidr = "10.0.5.0/24"' >> network.tfvars && \
	terraform init && \
	terraform plan -var-file=network.tfvars && \
	terraform apply -var-file=network.tfvars -auto-approve
	$(info VPC and subnets deployed for ROSA cluster using Terraform)

# Domain records management
.PHONY: rosa-domain-records
rosa-domain-records:  ## Create domain records for ROSA using Terraform
	$(call required-environment-variables,CLUSTER_NAME ROSA_DOMAIN)
	@echo "Domain records should be managed through Terraform configuration"
	@echo "Set create_domain_records=true in your terraform.tfvars to enable domain record creation"

.PHONY: rosa-delete-domain-records
rosa-delete-domain-records:  ## Delete domain records using Terraform
	$(call required-environment-variables,CLUSTER_NAME)
	@cd rosa/terraform && \
	if [ -f terraform.tfvars ]; then \
		terraform destroy -var-file=terraform.tfvars -auto-approve || true; \
	fi
	$(info Domain records destruction completed)

.PHONY: rosa-delete-network
rosa-delete-network:  ## Delete network using Terraform
	$(call required-environment-variables,CLUSTER_NAME)
	@cd rosa/terraform && \
	if [ -f network.tfvars ]; then \
		terraform destroy -var-file=network.tfvars -auto-approve || true; \
	fi
	$(info Network destruction completed)

# Terraform-specific targets
.PHONY: rosa-terraform-init
rosa-terraform-init:  ## Initialize Terraform in rosa/terraform directory
	@echo "Initializing Terraform..."
	@cd rosa/terraform && terraform init

.PHONY: rosa-terraform-plan
rosa-terraform-plan:  ## Run terraform plan with network configuration
	$(call required-environment-variables,AWS_REGION CLUSTER_NAME)
	@cd rosa/terraform && \
	echo 'aws_region = "${AWS_REGION}"' > network.tfvars && \
	echo 'cluster_name = "${CLUSTER_NAME}"' >> network.tfvars && \
	echo 'vpc_name = "rosa-${CLUSTER_NAME}-vpc"' >> network.tfvars && \
	echo 'environment_tag = "rosa"' >> network.tfvars && \
	echo 'vpc_cidr = "10.0.0.0/16"' >> network.tfvars && \
	echo 'public_subnet_1_cidr = "10.0.0.0/24"' >> network.tfvars && \
	echo 'public_subnet_2_cidr = "10.0.1.0/24"' >> network.tfvars && \
	echo 'public_subnet_3_cidr = "10.0.4.0/24"' >> network.tfvars && \
	echo 'private_subnet_1_cidr = "10.0.2.0/24"' >> network.tfvars && \
	echo 'private_subnet_2_cidr = "10.0.3.0/24"' >> network.tfvars && \
	echo 'private_subnet_3_cidr = "10.0.5.0/24"' >> network.tfvars && \
	terraform plan -var-file=network.tfvars

.PHONY: rosa-terraform-output
rosa-terraform-output:  ## Show terraform outputs
	@cd rosa/terraform && terraform output

.PHONY: rosa-terraform-state
rosa-terraform-state:  ## Show terraform state
	@cd rosa/terraform && terraform state list

.PHONY: rosa-terraform-validate
rosa-terraform-validate:  ## Validate Terraform configuration
	@cd rosa/terraform && terraform validate

.PHONY: rosa-terraform-fmt
rosa-terraform-fmt:  ## Format Terraform files
	@cd rosa/terraform && terraform fmt

.PHONY: rosa-terraform-clean
rosa-terraform-clean:  ## Clean Terraform working directory (remove .terraform and tfvars)
	@echo "Cleaning Terraform working directory..."
	@cd rosa/terraform && \
	rm -rf .terraform *.tfvars *.tfplan
	$(info Terraform working directory cleaned)
