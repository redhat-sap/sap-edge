# Include environment variables from .env file
-include .env

# Helper function to check if terraform.tfvars exists
check-tfvars = $(shell test -f rosa/terraform/terraform.tfvars || (echo "Error: terraform.tfvars not found. Copy terraform.tfvars.example to terraform.tfvars and configure it." && exit 1))

# Extract values from terraform.tfvars for scripts that need them
# CLUSTER_NAME can be overridden via command line: make rosa-hcp-deploy CLUSTER_NAME=my-cluster
CLUSTER_NAME=$(shell grep '^cluster_name' rosa/terraform/terraform.tfvars 2>/dev/null | cut -d'"' -f2 || echo "sapeic-cluster")
ROSA_DOMAIN=$(shell grep -E '^domain_name\s*=' rosa/terraform/terraform.tfvars 2>/dev/null | sed 's/.*=\s*"\([^"]*\)".*/\1/' || echo "")

# ROSA authentication targets
.PHONY: rosa-login
rosa-login:  ## Login to ROSA using token
	$(call check-tfvars)
	@if [ -z "$(ROSA_TOKEN)" ]; then echo "Error: ROSA_TOKEN not set in .env file"; exit 1; fi
	@rosa login --token="$(ROSA_TOKEN)"

# Domain validation targets
.PHONY: rosa-domain-zone-exists
rosa-domain-zone-exists:  ## Fail if Route53 hosted zone does not exist
	$(call check-tfvars)
	@if [ -z "$(ROSA_DOMAIN)" ]; then echo "Error: domain_name not set in terraform.tfvars"; exit 1; fi
	hack/rosa-domain-zone-exists.sh

.PHONY: rosa-create-domain-zone
rosa-create-domain-zone:  ## Create Route53 hosted zone for the domain
	$(call check-tfvars)
	@if [ -z "$(ROSA_DOMAIN)" ]; then echo "Error: domain_name not set in terraform.tfvars"; exit 1; fi
	hack/create-route53-zone.sh

# Cluster status check targets
.PHONY: rosa-cluster-status
rosa-cluster-status:  ## Check if ROSA cluster already exists and show its status
	$(call check-tfvars)
	@if [ -z "$(ROSA_TOKEN)" ]; then echo "Error: ROSA_TOKEN not set in .env file"; exit 1; fi
	@hack/check-rosa-cluster-status.sh

# ROSA HCP Terraform deployment targets
.PHONY: rosa-hcp-deploy
rosa-hcp-deploy: rosa-cluster-status rosa-hcp-terraform-deploy  ## Deploy ROSA HCP cluster using Terraform
	$(info ROSA HCP cluster deployment complete)

.PHONY: rosa-hcp-deploy-with-domain
rosa-hcp-deploy-with-domain: rosa-create-domain-zone rosa-cluster-status rosa-hcp-terraform-deploy  ## Create domain zone and deploy ROSA HCP cluster with custom domain
	$(info ROSA HCP cluster deployment with domain creation complete)

.PHONY: rosa-hcp-terraform-deploy
rosa-hcp-terraform-deploy:  ## Deploy ROSA HCP cluster and all resources using Terraform
	$(call check-tfvars)
	@echo "Deploying ROSA HCP cluster using Terraform with cluster_name=$(CLUSTER_NAME)..."
	@cd rosa/terraform && \
	terraform init && \
	terraform plan -var-file=terraform.tfvars -var="cluster_name=$(CLUSTER_NAME)"  && \
	terraform apply -var-file=terraform.tfvars -var="cluster_name=$(CLUSTER_NAME)" -auto-approve

.PHONY: rosa-hcp-destroy
rosa-hcp-destroy:  ## Destroy ROSA HCP cluster and all resources using Terraform
	$(call check-tfvars)
	@echo "Destroying ROSA HCP cluster using Terraform with cluster_name=$(CLUSTER_NAME)..."
	@cd rosa/terraform && \
	terraform destroy -var-file=terraform.tfvars -var="cluster_name=$(CLUSTER_NAME)" -auto-approve

.PHONY: rosa-hcp-plan
rosa-hcp-plan:  ## Run terraform plan for ROSA HCP deployment
	$(call check-tfvars)
	@echo "Running terraform plan with cluster_name=$(CLUSTER_NAME)..."
	@cd rosa/terraform && \
	terraform plan -var-file=terraform.tfvars -var="cluster_name=$(CLUSTER_NAME)"

.PHONY: rosa-hcp-output
rosa-hcp-output:  ## Show terraform outputs for ROSA HCP cluster
	@cd rosa/terraform && terraform output -json

.PHONY: rosa-hcp-kubeconfig
rosa-hcp-kubeconfig:  ## Get kubeconfig for ROSA HCP cluster
	$(call check-tfvars)
	@API_URL=$$(cd rosa/terraform && terraform output -raw api_endpoint) && \
	ADMIN_USER=$$(cd rosa/terraform && terraform output -json admin_credentials | jq -r '.username // "kubeadmin"') && \
	ADMIN_PASSWORD=$$(cd rosa/terraform && terraform output -json admin_credentials | jq -r '.password // ""') && \
	echo "Logging in to ROSA HCP cluster..." && \
	oc login "$$API_URL" -u "$$ADMIN_USER" -p "$$ADMIN_PASSWORD"

# Network deployment using Terraform
.PHONY: rosa-network-deploy
rosa-network-deploy:  ## Deploy VPC and subnets for ROSA using Terraform
	$(call check-tfvars)
	@echo "Deploying VPC and subnets for ROSA cluster using Terraform with cluster_name=$(CLUSTER_NAME)..."
	@cd rosa/terraform && \
	terraform init && \
	terraform plan -var-file=terraform.tfvars -var="cluster_name=$(CLUSTER_NAME)" && \
	terraform apply -var-file=terraform.tfvars -var="cluster_name=$(CLUSTER_NAME)" -auto-approve
	$(info VPC and subnets deployed for ROSA cluster using Terraform)

.PHONY: rosa-delete-network
rosa-delete-network:  ## Delete network using Terraform
	$(call check-tfvars)
	@cd rosa/terraform && \
	terraform destroy -var-file=terraform.tfvars -target=aws_vpc.rosa_vpc -target=aws_subnet.public -target=aws_subnet.private -auto-approve || true
	$(info Network destruction completed)

# Terraform-specific targets
.PHONY: rosa-terraform-init
rosa-terraform-init:  ## Initialize Terraform in rosa/terraform directory
	@echo "Initializing Terraform..."
	@cd rosa/terraform && terraform init

.PHONY: rosa-terraform-plan
rosa-terraform-plan:  ## Run terraform plan with terraform.tfvars
	$(call check-tfvars)
	@echo "Running terraform plan with cluster_name=$(CLUSTER_NAME)..."
	@cd rosa/terraform && \
	terraform plan -var-file=terraform.tfvars -var="cluster_name=$(CLUSTER_NAME)"

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
rosa-terraform-clean:  ## Clean Terraform working directory (remove .terraform and tfplan files)
	@echo "Cleaning Terraform working directory..."
	@cd rosa/terraform && \
	rm -rf .terraform *.tfplan
	$(info Terraform working directory cleaned)
