# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

ARO_RESOURCE_GROUP?=aro-sapeic
ARO_LOCATION?=northeurope

ARO_CLUSTER_NAME?=sapeic
ARO_DOMAIN?=saponrhel.org
ARO_VERSION?=4.15.35

# Azure services configuration
DEPLOY_POSTGRES?=true
DEPLOY_REDIS?=true
POSTGRES_ADMIN_PASSWORD?=

# Centralized resource tagging
COMMON_TAGS_TEAM?=sap-edge
COMMON_TAGS_PURPOSE_QUAY?=quay

# Centralized Quay configuration
AZURE_STORAGE_CONTAINER?=quay-registry
# Azure format: key=value key=value
AZURE_TAGS_COMMON?=team=$(COMMON_TAGS_TEAM)
AZURE_TAGS_QUAY?=purpose=$(COMMON_TAGS_PURPOSE_QUAY) cluster=${ARO_CLUSTER_NAME} $(AZURE_TAGS_COMMON)
# AWS format: {Key=key,Value=value}
AWS_TAGS_COMMON?={Key=team,Value=$(COMMON_TAGS_TEAM)}
AWS_TAGS_QUAY?={Key=purpose,Value=$(COMMON_TAGS_PURPOSE_QUAY)},{Key=cluster,Value=$(CLUSTER_NAME)},$(AWS_TAGS_COMMON)

.PHONY: install-bicep
install-bicep:
	az config set bicep.use_binary_from_path=false && az bicep install && az bicep version

.PHONY: lint-bicep
lint-bicep: install-bicep ## Run bicep lint
	az bicep lint --file bicep/aro.bicep
	az bicep lint --file bicep/domain-records.bicep


.PHONY: domain-records
.ONESHELL:
domain-records:  ## Create domain records for ARO
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME ARO_DOMAIN)
	hack/domain-records.sh \
		--domain ${ARO_DOMAIN} \
		--aro-name ${ARO_CLUSTER_NAME} \
		--aro-resource-group ${ARO_RESOURCE_GROUP}

.PHONY: network-deploy
network-deploy:  ## Deploy network
	$(call required-environment-variables,ARO_RESOURCE_GROUP)
	az deployment group create --resource-group ${ARO_RESOURCE_GROUP} \
		--template-file bicep/network.bicep

.PHONY: resource-group
resource-group:  ## Create resource group
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_LOCATION)
	az group create --name ${ARO_RESOURCE_GROUP} --location ${ARO_LOCATION} --query name -o tsv

.PHONY: azure-login
azure-login:  ## Login to Azure using service principal
	$(call required-environment-variables,CLIENT_ID CLIENT_SECRET TENANT_ID)
	@echo "🔐 Logging into Azure with service principal..."
	@az login --service-principal -u "${CLIENT_ID}" -p "${CLIENT_SECRET}" --tenant "${TENANT_ID}" > /dev/null 2>&1 || { echo "❌ Azure login failed"; exit 1; }
	@echo "✅ Azure login successful"

.PHONY: azure-set-subscription
azure-set-subscription:  ## Set Azure subscription to current account
	az account set --subscription "$$(az account show --query id -o tsv)"

.PHONY: aro-cluster-status
aro-cluster-status:  ## Get ARO cluster provisioning state
	$(call required-environment-variables,ARO_CLUSTER_NAME ARO_RESOURCE_GROUP)
	@az aro show --name "${ARO_CLUSTER_NAME}" --resource-group "${ARO_RESOURCE_GROUP}" --query "provisioningState" -o tsv

.PHONY: aro-cluster-exists
aro-cluster-exists:  ## Check if ARO cluster exists
	@hack/aro/cluster-check.sh --status-only || true

.PHONY: aro-cluster-check
aro-cluster-check:  ## Check ARO cluster status with detailed information
	@hack/aro/cluster-check.sh

.PHONY: aro-enable-master-scheduling
aro-enable-master-scheduling: aro-kubeconfig  ## Enable scheduling on master nodes (mastersSchedulable=true) (uses Ansible)
	@echo "🔧 Enabling master node scheduling using Ansible..."
	ansible-playbook ansible/enable-master-scheduling.yml \
		-i ansible/inventory.yml \
		-e kubeconfig_path="$(PWD)/kubeconfig"

.PHONY: aro-cluster-url
aro-cluster-url:  ## Get ARO cluster URL
	$(call required-environment-variables,ARO_CLUSTER_NAME ARO_RESOURCE_GROUP)
	@az aro show --name "${ARO_CLUSTER_NAME}" --resource-group "${ARO_RESOURCE_GROUP}" --query "apiserverProfile.url" -o tsv

.PHONY: aro-credentials
aro-credentials:  ## Get ARO credentials
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	@az aro list-credentials --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP}

.PHONY: aro-kubeconfig
aro-kubeconfig:  ## Get ARO kubeconfig file
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	@if [ ! -f kubeconfig ]; then \
		az aro get-admin-kubeconfig --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP} --file kubeconfig; \
	else \
		echo "ℹ️  Kubeconfig file already exists, skipping download"; \
	fi

.PHONY: postgres-exists
postgres-exists:  ## Check if PostgreSQL server exists
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	@az postgres flexible-server show --resource-group "${ARO_RESOURCE_GROUP}" --name "postgres-${ARO_CLUSTER_NAME}" --query "name" -o tsv 2>/dev/null || echo ""

.PHONY: redis-exists
redis-exists:  ## Check if Redis cache exists
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	@az redis list --resource-group "${ARO_RESOURCE_GROUP}" --query "[?contains(name, 'redis-${ARO_CLUSTER_NAME}')].name" -o tsv

.PHONY: service-principal
.ONESHELL:
service-principal:  ## Create service principal for ARO deployment
	$(call required-environment-variables,ARO_RESOURCE_GROUP)
	az ad sp create-for-rbac \
		--name "aro-service-principal" \
		--role Contributor \
		--scopes \
		"/subscriptions/$$(az account show --query id -o tsv)/resourceGroups/${ARO_RESOURCE_GROUP}"


.PHONY: arorp-service-principal
.ONESHELL:
arorp-service-principal:  ## Assign required roles to "Azure Red Hat Openshift" RP service principal
	$(call required-environment-variables,ARO_RESOURCE_GROUP)
	az role assignment create --assignee $$(az ad sp list --display-name "Azure Red Hat OpenShift RP" --query "[0].id" -o tsv) \
	--role Contributor \
	--scope "/subscriptions/$$(az account show --query id -o tsv)/resourceGroups/${ARO_RESOURCE_GROUP}"




.PHONY: aro-services-info
aro-services-info:  ## Get Azure services information
	$(call required-environment-variables,ARO_RESOURCE_GROUP)
	@echo "=== Azure Services Information ==="
	@az deployment group show --resource-group ${ARO_RESOURCE_GROUP} --name aro-deploy-${ARO_CLUSTER_NAME} --query "properties.outputs" -o json | jq -r '
		"PostgreSQL Server: " + (.postgresServerName.value // "Not deployed") + "\n" +
		"PostgreSQL FQDN: " + (.postgresServerFqdn.value // "Not deployed") + "\n" +
		"PostgreSQL Admin: " + (.postgresAdminUsername.value // "Not deployed") + "\n" +
		"PostgreSQL Database: " + (.postgresDatabaseName.value // "Not deployed") + "\n" +
		"Redis Cache: " + (.redisCacheName.value // "Not deployed") + "\n" +
		"Redis Host: " + (.redisHostName.value // "Not deployed") + "\n" +
		"Redis Port: " + (.redisPort.value // "Not deployed") + "\n" +
		"Redis SSL Port: " + (.redisSslPort.value // "Not deployed")
	'

.PHONY: domain-zone-exists
domain-zone-exists:  ## Fail if DNS domain zone does not exists
	$(call required-environment-variables,ARO_DOMAIN)
	ARO_DOMAIN=${ARO_DOMAIN} hack/domain-zone-exists.sh

.PHONY: oc-login
oc-login:  ## Login with oc to existing ARO cluster
	$(call required-environment-variables,ARO_CLUSTER_NAME ARO_RESOURCE_GROUP)
	oc login "$(shell az aro show --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP} --query "apiserverProfile.url" -o tsv)" \
		-u "$(shell az aro list-credentials --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP} --query 'kubeadminUsername' -o tsv)" \
		-p "$(shell az aro list-credentials --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP} --query 'kubeadminPassword' -o tsv)"

.PHONY: aro-destroy
.ONESHELL:
aro-destroy:  ## Destroy all Bicep-deployed resources (like terraform destroy)
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	@echo "🗑️  Destroying ARO deployment and all resources..."
	@echo ""
	@echo "This will delete the following resources:"
	@az resource list --resource-group ${ARO_RESOURCE_GROUP} --query "[].{Name:name, Type:type}" -o table
	@echo ""
	@read -p "Are you sure you want to destroy all resources? (yes/no): " CONFIRM; \
	if [ "$$CONFIRM" = "yes" ]; then \
		echo ""; \
		echo "Step 1/4: Deleting ARO cluster..."; \
		az aro delete --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP} --yes --no-wait || echo "ARO cluster not found or already deleted"; \
		echo "⏳ Waiting for ARO cluster deletion to start..."; \
		sleep 30; \
		echo ""; \
		echo "Step 2/4: Deleting Azure services (PostgreSQL, Redis)..."; \
		make postgres-delete 2>/dev/null || echo "PostgreSQL not found"; \
		make redis-delete 2>/dev/null || echo "Redis not found"; \
		echo ""; \
		echo "Step 3/4: Waiting for ARO cluster deletion to complete..."; \
		while az aro show --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP} 2>/dev/null; do \
			echo "⏳ ARO cluster still deleting... waiting 30s"; \
			sleep 30; \
		done; \
		echo ""; \
		echo "Step 4/4: Cleaning up remaining resources..."; \
		REMAINING_RESOURCES=$$(az resource list --resource-group ${ARO_RESOURCE_GROUP} --query "[].id" -o tsv); \
		if [ -n "$$REMAINING_RESOURCES" ]; then \
			echo "Deleting remaining resources..."; \
			for RESOURCE_ID in $$REMAINING_RESOURCES; do \
				echo "  - Deleting: $$RESOURCE_ID"; \
				az resource delete --ids "$$RESOURCE_ID" --no-wait 2>/dev/null || echo "    (already deleted)"; \
			done; \
		fi; \
		echo ""; \
		echo "✅ All resources destroyed successfully!"; \
		echo ""; \
		echo "📝 Note: The resource group ${ARO_RESOURCE_GROUP} still exists."; \
		echo "   To delete it completely, run: make aro-resource-group-delete"; \
	else \
		echo "❌ Destroy cancelled."; \
		exit 1; \
	fi

.PHONY: aro-resource-group-delete
aro-resource-group-delete:  ## Delete the entire Azure resource group (fastest cleanup)
	$(call required-environment-variables,ARO_RESOURCE_GROUP)
	@echo "🗑️  Deleting resource group: ${ARO_RESOURCE_GROUP}"
	@echo "⚠️  This will delete ALL resources in the resource group!"
	@read -p "Are you sure? (yes/no): " CONFIRM; \
	if [ "$$CONFIRM" = "yes" ]; then \
		az group delete --name ${ARO_RESOURCE_GROUP} --yes --no-wait; \
		echo "✅ Resource group deletion initiated (running in background)"; \
	else \
		echo "❌ Cancelled."; \
		exit 1; \
	fi

.PHONY: aro-delete-cluster
aro-delete-cluster:  ## Delete only the ARO cluster (leaves other resources)
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	az aro delete --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP} --yes --no-wait

.PHONY: aro-delete-resources
aro-delete-resources:  ## Delete all resources in the ARO resource group
	$(call required-environment-variables,ARO_RESOURCE_GROUP)
	az resource delete --resource-group ${ARO_RESOURCE_GROUP} --ids $$(az resource list --resource-group ${ARO_RESOURCE_GROUP} --query "[].id" -o tsv)




.PHONY: aro-cleanup-failed
aro-cleanup-failed:  ## Force delete failed ARO cluster
	$(call required-environment-variables,ARO_CLUSTER_NAME ARO_RESOURCE_GROUP)
	az aro delete --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP} --yes --no-wait

.PHONY: aro-wait-for-ready
aro-wait-for-ready:  ## Wait for ARO cluster to reach ready state
	$(call required-environment-variables,ARO_CLUSTER_NAME ARO_RESOURCE_GROUP)
	@WAIT_COUNT=0; \
	MAX_WAIT=120; \
	while [ $$WAIT_COUNT -lt $$MAX_WAIT ]; do \
		if STATUS=$$(az aro show --name "${ARO_CLUSTER_NAME}" --resource-group "${ARO_RESOURCE_GROUP}" --query "provisioningState" -o tsv 2>/dev/null); then \
			echo "Cluster status: $$STATUS"; \
			if [ "$$STATUS" = "Succeeded" ]; then \
				echo "✅ Cluster is ready!"; \
				break; \
			elif [ "$$STATUS" = "Failed" ]; then \
				echo "❌ Cluster deployment failed"; \
				exit 1; \
			else \
				echo "⏳ Still provisioning... waiting 60 seconds ($$WAIT_COUNT/$$MAX_WAIT)"; \
			fi; \
		else \
			echo "❌ Cluster '${ARO_CLUSTER_NAME}' not found in resource group '${ARO_RESOURCE_GROUP}'"; \
			echo "💡 The cluster may have failed to deploy or was deleted"; \
			exit 1; \
		fi; \
		sleep 60; \
		WAIT_COUNT=$$((WAIT_COUNT + 1)); \
	done; \
	if [ $$WAIT_COUNT -ge $$MAX_WAIT ]; then \
		echo "❌ Timeout waiting for cluster to be ready after $$((MAX_WAIT * 60)) seconds"; \
		exit 1; \
	fi

.PHONY: aro-services-deploy-with-retry
aro-services-deploy-with-retry:  ## Deploy Azure services with retry logic
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME POSTGRES_ADMIN_PASSWORD)
	@RETRY_COUNT=0; \
	MAX_RETRIES=3; \
	while [ $$RETRY_COUNT -lt $$MAX_RETRIES ]; do \
		if make aro-services-deploy-test; then \
			echo "✅ Azure services deployment succeeded"; \
			break; \
		else \
			RETRY_COUNT=$$((RETRY_COUNT + 1)); \
			echo "❌ Deployment attempt $$RETRY_COUNT failed"; \
			if [ $$RETRY_COUNT -lt $$MAX_RETRIES ]; then \
				echo "⏳ Retrying in 30 seconds..."; \
				sleep 30; \
			else \
				echo "💥 All deployment attempts failed"; \
				exit 1; \
			fi; \
		fi; \
	done

.PHONY: aro-final-safety-check
aro-final-safety-check:  ## Final safety check before deployment to avoid conflicts
	$(call required-environment-variables,ARO_CLUSTER_NAME ARO_RESOURCE_GROUP)
	@if az aro show --name "${ARO_CLUSTER_NAME}" --resource-group "${ARO_RESOURCE_GROUP}" >/dev/null 2>&1; then \
		echo "⚠️ WARNING: Cluster detected during final check - skipping deployment to avoid conflicts"; \
		echo "✅ ARO deployment completed successfully (cluster already exists)"; \
		exit 0; \
	else \
		echo "🔍 Final safety check passed - no existing cluster found"; \
	fi

.PHONY: aro-get-kubeconfig
aro-get-kubeconfig:  ## Get ARO kubeconfig with insecure TLS settings
	$(call required-environment-variables,ARO_CLUSTER_NAME ARO_RESOURCE_GROUP)
	@echo "🔐 Getting ARO kubeconfig..."
	rm -f kubeconfig kubeconfig.backup
	az aro get-admin-kubeconfig --name "${ARO_CLUSTER_NAME}" --resource-group "${ARO_RESOURCE_GROUP}" --file kubeconfig
	echo "🔧 Adding insecure TLS settings to kubeconfig..."
	cp kubeconfig kubeconfig.backup
	sed '/^    server:/a\    insecure-skip-tls-verify: true' kubeconfig.backup > kubeconfig
	echo "✅ Kubeconfig ready with insecure TLS settings"

.PHONY: redis-get-info
redis-get-info:  ## Get Redis cache connection information
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	@REDIS_LIST=$$(make --no-print-directory redis-exists | tail -1); \
	if [[ -n "$$REDIS_LIST" ]]; then \
		REDIS_CACHE_NAME=$$(echo "$$REDIS_LIST" | head -1); \
		echo "Redis Cache Name: $$REDIS_CACHE_NAME"; \
		echo "Redis Host: $$(az redis show --resource-group "${ARO_RESOURCE_GROUP}" --name "$$REDIS_CACHE_NAME" --query "hostName" -o tsv)"; \
		echo "Redis Port: $$(az redis show --resource-group "${ARO_RESOURCE_GROUP}" --name "$$REDIS_CACHE_NAME" --query "port" -o tsv)"; \
		echo "Redis SSL Port: $$(az redis show --resource-group "${ARO_RESOURCE_GROUP}" --name "$$REDIS_CACHE_NAME" --query "sslPort" -o tsv)"; \
		echo "Redis Access Key: $$(az redis list-keys --resource-group "${ARO_RESOURCE_GROUP}" --name "$$REDIS_CACHE_NAME" --query "primaryKey" -o tsv)"; \
	else \
		echo "No Redis cache found"; \
	fi

.PHONY: postgres-delete
postgres-delete:  ## Delete PostgreSQL flexible server
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	@if az postgres flexible-server show --resource-group "${ARO_RESOURCE_GROUP}" --name "postgres-${ARO_CLUSTER_NAME}" >/dev/null 2>&1; then \
		echo "🗑️ Deleting PostgreSQL server postgres-${ARO_CLUSTER_NAME}..."; \
		az postgres flexible-server delete --resource-group "${ARO_RESOURCE_GROUP}" --name "postgres-${ARO_CLUSTER_NAME}" --yes; \
		echo "✅ PostgreSQL server deletion initiated"; \
	else \
		echo "ℹ️ PostgreSQL server not found"; \
	fi

.PHONY: redis-delete
redis-delete:  ## Delete Redis cache instances
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	@REDIS_CACHES=$$(az redis list --resource-group "${ARO_RESOURCE_GROUP}" --query "[?contains(name, 'redis-${ARO_CLUSTER_NAME}')].name" -o tsv); \
	if [[ -n "$$REDIS_CACHES" ]]; then \
		for redis_name in $$REDIS_CACHES; do \
			echo "🗑️ Deleting Redis cache: $$redis_name"; \
			az redis delete --resource-group "${ARO_RESOURCE_GROUP}" --name "$$redis_name" --yes; \
		done; \
		echo "✅ Redis cache deletion initiated"; \
	else \
		echo "ℹ️ Redis cache not found"; \
	fi

.PHONY: aro-resources-cleanup
aro-resources-cleanup:  ## Clean up other ARO-related resources
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	@ARO_RESOURCES=$$(az resource list --resource-group "${ARO_RESOURCE_GROUP}" --query "[?contains(name, '${ARO_CLUSTER_NAME}') || (tags && tags.cluster && contains(tags.cluster, '${ARO_CLUSTER_NAME}'))].id" -o tsv); \
	if [[ -n "$$ARO_RESOURCES" ]]; then \
		echo "Found other ARO-related resources to delete:"; \
		echo "$$ARO_RESOURCES"; \
		az resource delete --resource-group "${ARO_RESOURCE_GROUP}" --ids $$ARO_RESOURCES || echo "Some ARO resources may have already been deleted"; \
		echo "✅ ARO resources cleanup completed"; \
	else \
		echo "ℹ️ No other ARO-related resources found"; \
	fi

.PHONY: aro-resource-group-create
aro-resource-group-create:  ## Create resource group (idempotent)
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_LOCATION)
	@echo "🏗️ Creating resource group ${ARO_RESOURCE_GROUP}..."
	az group create --name "${ARO_RESOURCE_GROUP}" --location "${ARO_LOCATION}" --query name -o tsv || echo "Resource group already exists"

.PHONY: aro-resource-group-exists
aro-resource-group-exists:  ## Check if resource group exists
	$(call required-environment-variables,ARO_RESOURCE_GROUP)
	@az group show --name "${ARO_RESOURCE_GROUP}" >/dev/null 2>&1

.PHONY: aro-cleanup-all-services
aro-cleanup-all-services:  ## Clean up all ARO services (PostgreSQL, Redis, other resources)
	$(call required-environment-variables,ARO_RESOURCE_GROUP ARO_CLUSTER_NAME)
	@echo "🧹 Cleaning up ARO-related resources..."
	make postgres-delete
	make redis-delete
	make aro-resources-cleanup

# Testing-optimized deployment targets
.PHONY: aro-deploy-only
aro-deploy-only:  ## Deploy ARO cluster only (no PostgreSQL/Redis services)
	$(call required-environment-variables,ARO_RESOURCE_GROUP CLIENT_ID CLIENT_SECRET TENANT_ID PULL_SECRET)
	@echo "🧪 Deploying ARO cluster only (no Azure services)..."
	@echo "🔍 Checking if cluster already exists..."
	@CLUSTER_CHECK_RESULT=$$(make --no-print-directory aro-cluster-exists 2>/dev/null | grep -E '^(true|false)$$' | tail -1); \
	echo "🔍 Cluster check result: '$$CLUSTER_CHECK_RESULT'"; \
	if [ "$$CLUSTER_CHECK_RESULT" = "true" ]; then \
		echo "✅ ARO cluster '${ARO_CLUSTER_NAME}' already exists. Skipping deployment."; \
		exit 0; \
	else \
		echo "🔍 Cluster '${ARO_CLUSTER_NAME}' not found, proceeding with deployment..."; \
	fi
	@echo "🔍 Checking for running deployments..."
	@EXISTING_STATE=$$(az deployment group show --resource-group ${ARO_RESOURCE_GROUP} --name aro-deploy-${ARO_CLUSTER_NAME} --query "properties.provisioningState" -o tsv 2>/dev/null || echo "NotFound"); \
	if [ "$$EXISTING_STATE" = "Running" ]; then \
		echo "⏳ Found deployment in progress. Waiting for completion..."; \
		while [ "$$(az deployment group show --resource-group ${ARO_RESOURCE_GROUP} --name aro-deploy-${ARO_CLUSTER_NAME} --query "properties.provisioningState" -o tsv 2>/dev/null)" = "Running" ]; do \
			echo "⏳ Still running... waiting 60 seconds"; \
			sleep 60; \
		done; \
	fi
	@echo "🔐 Preparing secure deployment parameters..."
	@PULL_SECRET_BASE64=$$(printf '%s' "$$PULL_SECRET" | tr -d '\n' | sed 's/^"//;s/"$$//' | base64 -w 0); \
	TEMP_PARAMS=$$(mktemp); \
	echo "{ \
		\"clusterName\": { \"value\": \"${ARO_CLUSTER_NAME}\" }, \
		\"domain\": { \"value\": \"${ARO_CLUSTER_NAME}.${ARO_DOMAIN}\" }, \
		\"servicePrincipalClientId\": { \"value\": \"${CLIENT_ID}\" }, \
		\"servicePrincipalClientSecret\": { \"value\": \"${CLIENT_SECRET}\" }, \
		\"pullSecret\": { \"value\": \"$$PULL_SECRET_BASE64\" }, \
		\"deployPostgres\": { \"value\": false }, \
		\"deployRedis\": { \"value\": false } \
	}" > $$TEMP_PARAMS; \
	echo "🚀 Starting Bicep deployment..."; \
	if az deployment group create --resource-group ${ARO_RESOURCE_GROUP} \
		--name aro-deploy-${ARO_CLUSTER_NAME} \
		--template-file bicep/aro.bicep \
		--parameters @bicep/test.parameters.json \
		--parameters @$$TEMP_PARAMS; then \
		echo "✅ Bicep deployment completed successfully"; \
	else \
		echo "❌ Bicep deployment failed"; \
		rm -f $$TEMP_PARAMS; \
		exit 1; \
	fi; \
	rm -f $$TEMP_PARAMS

.PHONY: aro-deploy-minimal
aro-deploy-minimal:  ## Deploy ARO cluster with minimal network (no postgres/redis subnets, avoids delegation conflicts)
	$(call required-environment-variables,ARO_RESOURCE_GROUP CLIENT_ID CLIENT_SECRET TENANT_ID PULL_SECRET)
	@echo "🧪 Deploying minimal ARO cluster (no Azure services, no extra subnets)..."
	@echo "🔍 Checking if cluster already exists..."
	@CLUSTER_CHECK_RESULT=$$(make --no-print-directory aro-cluster-exists 2>/dev/null | grep -E '^(true|false)$$' | tail -1); \
	echo "🔍 Cluster check result: '$$CLUSTER_CHECK_RESULT'"; \
	if [ "$$CLUSTER_CHECK_RESULT" = "true" ]; then \
		echo "✅ ARO cluster '${ARO_CLUSTER_NAME}' already exists. Skipping deployment."; \
		exit 0; \
	else \
		echo "🔍 Cluster '${ARO_CLUSTER_NAME}' not found, proceeding with deployment..."; \
	fi
	@echo "🔍 Checking for running deployments..."
	@EXISTING_STATE=$$(az deployment group show --resource-group ${ARO_RESOURCE_GROUP} --name aro-deploy-${ARO_CLUSTER_NAME} --query "properties.provisioningState" -o tsv 2>/dev/null || echo "NotFound"); \
	if [ "$$EXISTING_STATE" = "Running" ]; then \
		echo "⏳ Found deployment in progress. Waiting for completion..."; \
		while [ "$$(az deployment group show --resource-group ${ARO_RESOURCE_GROUP} --name aro-deploy-${ARO_CLUSTER_NAME} --query "properties.provisioningState" -o tsv 2>/dev/null)" = "Running" ]; do \
			echo "⏳ Still running... waiting 60 seconds"; \
			sleep 60; \
		done; \
	fi
	@echo "🔐 Preparing secure deployment parameters..."
	@PULL_SECRET_BASE64=$$(printf '%s' "$$PULL_SECRET" | tr -d '\n' | sed 's/^"//;s/"$$//' | base64 -w 0); \
	TEMP_PARAMS=$$(mktemp); \
	echo "{ \
		\"clusterName\": { \"value\": \"${ARO_CLUSTER_NAME}\" }, \
		\"domain\": { \"value\": \"${ARO_CLUSTER_NAME}.${ARO_DOMAIN}\" }, \
		\"servicePrincipalClientId\": { \"value\": \"${CLIENT_ID}\" }, \
		\"servicePrincipalClientSecret\": { \"value\": \"${CLIENT_SECRET}\" }, \
		\"pullSecret\": { \"value\": \"$$PULL_SECRET_BASE64\" } \
	}" > $$TEMP_PARAMS; \
	echo "🚀 Starting minimal Bicep deployment..."; \
	if az deployment group create --resource-group ${ARO_RESOURCE_GROUP} \
		--name aro-deploy-${ARO_CLUSTER_NAME} \
		--template-file bicep/aro-minimal.bicep \
		--parameters @bicep/test.parameters.json \
		--parameters @$$TEMP_PARAMS; then \
		echo "✅ Minimal Bicep deployment completed successfully"; \
	else \
		echo "❌ Bicep deployment failed"; \
		rm -f $$TEMP_PARAMS; \
		exit 1; \
	fi; \
	rm -f $$TEMP_PARAMS

.PHONY: aro-deploy-test
aro-deploy-test:  ## Deploy ARO with cost-optimized test settings
	$(call required-environment-variables,ARO_RESOURCE_GROUP CLIENT_ID CLIENT_SECRET TENANT_ID PULL_SECRET POSTGRES_ADMIN_PASSWORD)
	@echo "🧪 Deploying ARO cluster with test-optimized settings..."
	@echo "🔍 Checking if cluster already exists..."
	@if $$(make aro-cluster-exists | tail -1 | grep -q "true"); then \
		echo "✅ ARO cluster '${ARO_CLUSTER_NAME}' already exists. Skipping deployment."; \
		exit 0; \
	fi
	@echo "🔍 Checking for running deployments..."
	@EXISTING_STATE=$$(az deployment group show --resource-group ${ARO_RESOURCE_GROUP} --name aro-deploy-${ARO_CLUSTER_NAME} --query "properties.provisioningState" -o tsv 2>/dev/null || echo "NotFound"); \
	if [ "$$EXISTING_STATE" = "Running" ]; then \
		echo "⏳ Found deployment in progress. Waiting for completion..."; \
		while [ "$$(az deployment group show --resource-group ${ARO_RESOURCE_GROUP} --name aro-deploy-${ARO_CLUSTER_NAME} --query "properties.provisioningState" -o tsv 2>/dev/null)" = "Running" ]; do \
			echo "⏳ Still running... waiting 60 seconds"; \
			sleep 60; \
		done; \
	fi
	@echo "🔐 Preparing secure deployment parameters..."
	@PULL_SECRET_BASE64=$$(printf '%s' "$$PULL_SECRET" | tr -d '\n' | sed 's/^"//;s/"$$//' | base64 -w 0); \
	TEMP_PARAMS=$$(mktemp); \
	echo "{ \
		\"clusterName\": { \"value\": \"${ARO_CLUSTER_NAME}\" }, \
		\"domain\": { \"value\": \"${ARO_CLUSTER_NAME}.${ARO_DOMAIN}\" }, \
		\"servicePrincipalClientId\": { \"value\": \"${CLIENT_ID}\" }, \
		\"servicePrincipalClientSecret\": { \"value\": \"${CLIENT_SECRET}\" }, \
		\"pullSecret\": { \"value\": \"$$PULL_SECRET_BASE64\" }, \
		\"postgresAdminPassword\": { \"value\": \"${POSTGRES_ADMIN_PASSWORD}\" } \
	}" > $$TEMP_PARAMS; \
	az deployment group create --resource-group ${ARO_RESOURCE_GROUP} \
		--name aro-deploy-${ARO_CLUSTER_NAME} \
		--template-file bicep/aro.bicep \
		--parameters @bicep/test.parameters.json \
		--parameters @$$TEMP_PARAMS \
		--parameters deployPostgres=$${DEPLOY_POSTGRES:-false} deployRedis=$${DEPLOY_REDIS:-false}; \
	rm -f $$TEMP_PARAMS

.PHONY: aro-services-deploy-test
aro-services-deploy-test:  ## Deploy only Azure services with test settings
	$(call required-environment-variables,ARO_RESOURCE_GROUP POSTGRES_ADMIN_PASSWORD)
	@echo "🧪 Deploying Azure services with test-optimized settings..."
	@az deployment group create --resource-group ${ARO_RESOURCE_GROUP} \
		--name azure-services-deploy-${ARO_CLUSTER_NAME} \
		--template-file bicep/azure-services.bicep \
		--parameters @bicep/azure-services.test.parameters.json \
		--parameters \
		clusterName="${ARO_CLUSTER_NAME}" \
		postgresAdminPassword="${POSTGRES_ADMIN_PASSWORD}"

.PHONY: aro-test-info
aro-test-info:  ## Get test cluster connection and service information
	$(call required-environment-variables,ARO_RESOURCE_GROUP)
	@echo "🧪 Test Cluster Information:"
	@echo "=========================="
	@az deployment group show --resource-group ${ARO_RESOURCE_GROUP} --name aro-deploy-${ARO_CLUSTER_NAME} \
		--query "properties.outputs.quickConnectionInfo.value" -o json | jq -r '
		"Cluster Info:",
		"  Name: " + .cluster.name,
		"  API Server: " + .cluster.apiServerUrl,
		"  Console: " + .cluster.consoleUrl,
		"  Version: " + .cluster.version,
		"",
		"Quick Commands:",
		"  Get Kubeconfig: " + .commands.getKubeconfig,
		"  Get Credentials: " + .commands.getCredentials,
		"",
		if .services.postgres then
			"PostgreSQL:",
			"  Server: " + .services.postgres.serverName,
			"  FQDN: " + .services.postgres.serverFqdn,
			"  Database: " + .services.postgres.databaseName,
			"  Connect: " + .services.postgres.connectCommand,
			""
		else "" end,
		if .services.redis then
			"Redis:",
			"  Cache: " + .services.redis.cacheName,
			"  Host: " + .services.redis.hostName,
			"  Port: " + (.services.redis.port | tostring),
			"  SSL Port: " + (.services.redis.sslPort | tostring),
			"  Get Keys: " + .services.redis.getKeysCommand,
			""
		else "" end,
		"Testing Info:",
		"  Auto Shutdown: " + (.testing.autoShutdown | tostring),
		"  Shutdown Time: " + .testing.shutdownTime,
		"  Cleanup: " + .testing.cleanupCommand
		'

.PHONY: aro-cost-estimate
aro-cost-estimate:  ## Get cost estimate for test deployment
	@echo "💰 Estimated Monthly Costs for Test Configuration:"
	@echo "================================================="
	@echo "ARO Cluster (3 workers, D4s_v3): ~$1,200-1,500/month"
	@echo "PostgreSQL (Standard_B1ms): ~$15-25/month"
	@echo "Redis (Basic C0): ~$16-20/month"
	@echo "Total Estimated: ~$1,250-1,550/month"
	@echo ""
	@echo "💡 Cost Optimization Tips:"
	@echo "- Use 'make aro-cleanup-all-services' when not testing"
	@echo "- Consider hibernating cluster overnight (manual process)"
	@echo "- Monitor usage with: az consumption usage list"

# Azure Storage for Quay Registry
.PHONY: aro-quay-storage-create
aro-quay-storage-create:  ## Get Azure storage credentials for Quay (storage created by Bicep)
	$(call required-environment-variables,ARO_RESOURCE_GROUP)
	@echo "💡 Note: Storage is created by Bicep deployment (make aro-deploy-test)"
	@echo "   This command retrieves the credentials from Bicep outputs"
	@echo ""
	@hack/aro/quay-storage-create.sh

.PHONY: aro-quay-storage-info
aro-quay-storage-info:  ## Get Azure storage account information for Quay
	$(call required-environment-variables,ARO_RESOURCE_GROUP)
	@echo "📋 Quay Azure Storage Accounts:"
	@echo "==============================="
	@az storage account list --resource-group "${ARO_RESOURCE_GROUP}" --query "[?tags.purpose=='quay'].{Name:name,Location:location,Cluster:tags.cluster}" -o table

.PHONY: aro-quay-storage-delete
aro-quay-storage-delete:  ## Delete Azure storage account for Quay (manual deletion, use aro-destroy for full cleanup)
	$(call required-environment-variables,ARO_RESOURCE_GROUP AZURE_STORAGE_ACCOUNT_NAME)
	@echo "💡 Note: Quay storage is managed by Bicep and will be deleted by 'make aro-destroy'"
	@echo "   Only use this for manual cleanup of storage without deleting other resources"
	@echo ""
	@echo "🗑️ Deleting Azure storage account for Quay..."
	@echo "⚠️  This will permanently delete all registry data!"
	@read -p "Are you sure? Type 'yes' to confirm: " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		az storage account delete \
			--name "${AZURE_STORAGE_ACCOUNT_NAME}" \
			--resource-group "${ARO_RESOURCE_GROUP}" \
			--yes; \
		echo "✅ Storage account deleted"; \
	else \
		echo "❌ Deletion cancelled"; \
	fi

# ARO Quay Registry deployment targets
.PHONY: aro-quay-deploy
aro-quay-deploy:  ## Deploy Quay registry operator and instance on ARO with Azure storage (uses Ansible)
	$(call required-environment-variables,ARO_CLUSTER_NAME AZURE_STORAGE_ACCOUNT_NAME AZURE_STORAGE_ACCOUNT_KEY AZURE_STORAGE_CONTAINER QUAY_ADMIN_PASSWORD QUAY_ADMIN_EMAIL)
	@echo "🚀 Deploying Quay on ARO using Ansible..."
	ansible-playbook ansible/quay-deploy.yml \
		-i ansible/inventory.yml \
		-e platform=aro \
		-e cluster_name="${ARO_CLUSTER_NAME}" \
		-e azure_storage_account_name="${AZURE_STORAGE_ACCOUNT_NAME}" \
		-e azure_storage_account_key="${AZURE_STORAGE_ACCOUNT_KEY}" \
		-e azure_storage_container="${AZURE_STORAGE_CONTAINER}" \
		-e quay_admin_password="${QUAY_ADMIN_PASSWORD}" \
		-e quay_admin_email="${QUAY_ADMIN_EMAIL}" \
		-e kubeconfig_path="$(PWD)/kubeconfig"

.PHONY: aro-quay-wait-ready
aro-quay-wait-ready:  ## Wait for Quay registry to be ready on ARO
	@echo "⏳ Waiting for Quay registry to be ready on ARO..."
	@timeout 600 bash -c 'until oc get pods -n openshift-operators | grep -E "test-registry-.*Running" | wc -l | grep -q "[5-9]"; do echo "Waiting for Quay pods..."; sleep 30; done'
	@echo "⏳ Waiting for Quay registry endpoint to be available..."
	@timeout 300 bash -c 'until oc get quayregistry test-registry -n openshift-operators -o json 2>/dev/null | jq -r ".status.registryEndpoint // \"\"" | grep -q "https://"; do echo "Waiting for endpoint..."; sleep 10; done'
	@echo "✅ Quay registry is ready on ARO!"

.PHONY: aro-quay-wait-http-ready
aro-quay-wait-http-ready:  ## Wait for Quay registry HTTP service to be ready
	@echo "⏳ Waiting for Quay HTTP service to respond..."
	@ENDPOINT=$$(oc get quayregistry test-registry -n openshift-operators -o json | jq -r '.status.registryEndpoint'); \
	if [ "$$ENDPOINT" = "null" ] || [ -z "$$ENDPOINT" ]; then \
		echo "❌ Quay registry endpoint not ready. Run 'make aro-quay-wait-ready' first."; \
		exit 1; \
	fi; \
	echo "Testing HTTP readiness at: $$ENDPOINT"; \
	timeout 300 bash -c 'until curl -s -k --max-time 10 "'"$$ENDPOINT"'/health/instance" >/dev/null 2>&1; do echo "Waiting for HTTP service... $$(date)"; sleep 15; done' || { \
		echo "❌ Timeout waiting for Quay HTTP service to respond"; \
		echo "🔍 Current endpoint status:"; \
		curl -s -k --max-time 5 "$$ENDPOINT/health/instance" || echo "Service not responding"; \
		exit 1; \
	}; \
	echo "✅ Quay HTTP service is ready and responding!"

.PHONY: aro-quay-info
aro-quay-info:  ## Get Quay registry connection information on ARO
	@echo "📋 ARO Quay Registry Information:"
	@echo "================================="
	@ENDPOINT=$$(oc get quayregistry test-registry -n openshift-operators -o json 2>/dev/null | jq -r '.status.registryEndpoint // "Not ready"'); \
	if [ "$$ENDPOINT" != "Not ready" ]; then \
		REGISTRY=$$(echo "$$ENDPOINT" | sed 's/^https:\/\///'); \
		echo "Registry Endpoint: $$ENDPOINT"; \
		echo "Registry Host: $$REGISTRY"; \
		echo "Admin User Path: $$REGISTRY/quayadmin"; \
		echo ""; \
		echo "🔑 Create admin user:"; \
		echo "make aro-quay-create-admin"; \
		echo ""; \
		echo "🔒 Trust certificate:"; \
		echo "make aro-quay-trust-cert"; \
	else \
		echo "❌ Quay registry not ready yet"; \
	fi

.PHONY: aro-quay-create-admin
aro-quay-create-admin:  ## Create Quay admin user on ARO
	$(call required-environment-variables,QUAY_ADMIN_PASSWORD QUAY_ADMIN_EMAIL)
	@echo "👤 Creating Quay admin user on ARO..."
	@ENDPOINT=$$(oc get quayregistry test-registry -n openshift-operators -o json | jq -r '.status.registryEndpoint'); \
	if [ "$$ENDPOINT" = "null" ] || [ -z "$$ENDPOINT" ]; then \
		echo "❌ Quay registry endpoint not ready. Run 'make aro-quay-wait-ready' first."; \
		exit 1; \
	fi; \
	USER_CREATION_ENDPOINT="$$ENDPOINT/api/v1/user/initialize"; \
	echo "Registry endpoint: $$ENDPOINT"; \
	echo "Creating user at: $$USER_CREATION_ENDPOINT"; \
	echo "🔍 Checking pod status before user creation..."; \
	RUNNING_PODS=$$(oc get pods -n openshift-operators | grep test-registry | grep Running | wc -l); \
	echo "Running Quay pods: $$RUNNING_PODS"; \
	if [ "$$RUNNING_PODS" -lt 5 ]; then \
		echo "⚠️  Only $$RUNNING_PODS Quay pods running, waiting for more..."; \
		echo "📋 Current pod status:"; \
		oc get pods -n openshift-operators | grep test-registry; \
	fi; \
	echo "🔄 Attempting to create admin user with retries..."; \
	for attempt in 1 2 3 4 5; do \
		echo "Attempt $$attempt/5:"; \
		HTTP_CODE=$$(curl -X POST -k "$$USER_CREATION_ENDPOINT" \
			--header 'Content-Type: application/json' \
			--data '{"username": "quayadmin", "password":"${QUAY_ADMIN_PASSWORD}", "email": "${QUAY_ADMIN_EMAIL}", "access_token": true}' \
			--write-out "%{http_code}" \
			--output /tmp/quay_response.json \
			--silent \
			--max-time 30); \
		case "$$HTTP_CODE" in \
			200) \
				echo "✅ Admin user created successfully on attempt $$attempt"; \
				echo "📋 User creation response:"; \
				cat /tmp/quay_response.json | jq -r .; \
				rm -f /tmp/quay_response.json; \
				exit 0; \
				;; \
			400) \
				echo "ℹ️  Admin user already exists (HTTP 400)"; \
				echo "✅ Admin user is available"; \
				rm -f /tmp/quay_response.json; \
				exit 0; \
				;; \
			503) \
				echo "⚠️  Quay service not ready yet (HTTP 503)"; \
				if [ "$$attempt" -lt 5 ]; then \
					echo "Waiting 30 seconds before retry..."; \
					sleep 30; \
				fi; \
				;; \
			000) \
				echo "⚠️  Connection timeout or network error"; \
				if [ "$$attempt" -lt 5 ]; then \
					echo "Waiting 20 seconds before retry..."; \
					sleep 20; \
				fi; \
				;; \
			*) \
				echo "⚠️  Unexpected response (HTTP $$HTTP_CODE)"; \
				if [ "$$attempt" -lt 5 ]; then \
					echo "Response body:"; \
					cat /tmp/quay_response.json 2>/dev/null || echo "No response body"; \
					echo "Waiting 20 seconds before retry..."; \
					sleep 20; \
				fi; \
				;; \
		esac; \
	done; \
	echo "❌ Failed to create admin user after 5 attempts"; \
	echo "📋 Final pod status:"; \
	oc get pods -n openshift-operators | grep test-registry; \
	echo "📋 Final response:"; \
	cat /tmp/quay_response.json 2>/dev/null || echo "No response body"; \
	rm -f /tmp/quay_response.json; \
	exit 1
	@echo "✅ Admin user creation completed on ARO"

.PHONY: aro-quay-trust-cert
aro-quay-trust-cert:  ## Configure ARO to trust Quay registry certificate (uses Ansible)
	$(call required-environment-variables,ARO_CLUSTER_NAME)
	@echo "🔒 Configuring certificate trust using Ansible..."
	ansible-playbook ansible/quay-deploy.yml \
		-i ansible/inventory.yml \
		-e platform=aro \
		-e cluster_name="${ARO_CLUSTER_NAME}" \
		-e kubeconfig_path="$(PWD)/kubeconfig" \
		--tags trust

.PHONY: aro-quay-test-login
aro-quay-test-login:  ## Test login to ARO Quay registry (requires podman/docker)
	@echo "🧪 Testing Quay registry login on ARO..."
	@ENDPOINT=$$(oc get quayregistry test-registry -n openshift-operators -o json | jq -r '.status.registryEndpoint'); \
	REGISTRY=$$(echo "$$ENDPOINT" | sed 's/^https:\/\///'); \
	echo "Testing login to: $$REGISTRY/quayadmin"; \
	echo "Use podman login $$REGISTRY/quayadmin or docker login $$REGISTRY/quayadmin"


.PHONY: aro-quay-deploy-complete
aro-quay-deploy-complete:  ## Complete Quay deployment with storage, registry, and trust configuration
	$(call required-environment-variables,ARO_CLUSTER_NAME ARO_RESOURCE_GROUP AZURE_STORAGE_ACCOUNT_NAME AZURE_STORAGE_ACCOUNT_KEY AZURE_STORAGE_CONTAINER)
	@echo "🚀 Starting complete Quay deployment on ARO..."
	@echo "🔍 Checking if Quay is already deployed..."
	@if oc get quayregistry test-registry -n openshift-operators >/dev/null 2>&1; then \
		echo "✅ Quay registry already exists, skipping deployment steps"; \
		echo "📋 Going directly to status and verification..."; \
	else \
		echo "Step 1/4: Deploying Quay operator and instance..."; \
		if ! AZURE_STORAGE_CONTAINER="${AZURE_STORAGE_CONTAINER}" make aro-quay-deploy; then \
			echo "❌ Quay operator and registry deployment failed"; \
			exit 1; \
		fi; \
		echo ""; \
		echo "Step 2/4: Waiting for Quay to be ready..."; \
		make aro-quay-wait-ready; \
	fi
	@echo ""
	@echo "Step 3/4: Configuring certificate trust..."
	make aro-quay-trust-cert
	@echo ""
	@echo "Step 4/4: Getting connection information..."
	make aro-quay-info
	@echo ""
	@echo "🎉 Complete Quay deployment finished!"
	@echo "📋 Next steps:"
	@echo "1. Create admin user: make aro-quay-create-admin (requires QUAY_ADMIN_PASSWORD, QUAY_ADMIN_EMAIL)"
	@echo "2. Test login: make aro-quay-test-login"

.PHONY: aro-quay-status
aro-quay-status:  ## Check Quay deployment status on ARO
	@echo "📊 ARO Quay Registry Status:"
	@echo "============================"
	@echo "Operator CSV:"
	@oc get csv -n openshift-operators | grep quay-operator || echo "No operator found"
	@echo ""
	@echo "Quay Registry:"
	@oc get quayregistry -n openshift-operators || echo "No registry found"
	@echo ""
	@echo "Quay Pods:"
	@oc get pods -n openshift-operators | grep test-registry || echo "No Quay pods found"

.PHONY: aro-quay-delete
aro-quay-delete:  ## Delete Quay registry and operator from ARO
	@echo "🗑️ Deleting Quay registry from ARO..."
	oc delete quayregistry test-registry -n openshift-operators --ignore-not-found=true
	@echo "⏳ Waiting for Quay pods to terminate..."
	@timeout 120 bash -c 'while oc get pods -n openshift-operators | grep -q test-registry; do echo "Waiting..."; sleep 10; done' || echo "Timeout waiting for pods"
	@echo "🗑️ Deleting Quay operator..."
	oc delete subscription quay-operator -n openshift-operators --ignore-not-found=true
	oc delete csv -n openshift-operators -l operators.coreos.com/quay-operator.openshift-operators --ignore-not-found=true
	@echo "🧹 Cleaning up secrets and configmaps..."
	oc delete secret config-bundle-secret -n openshift-operators --ignore-not-found=true
	@echo "✅ Quay cleanup completed on ARO"

# Generic Quay Registry targets (work on any cluster with oc context)
.PHONY: quay-deploy-generic
quay-deploy-generic:  ## Deploy Quay registry on current oc context - specify PLATFORM=aro|rosa (default: detect)
	@echo "📦 Deploying Quay registry operator (generic)..."
	oc apply -f edge-integration-cell/quay-registry/quay-operator-subscription.yaml
	@echo "⏳ Waiting for Quay operator to be ready..."
	@timeout 300 bash -c 'until oc get csv -n openshift-operators | grep -q "quay-operator.*Succeeded"; do echo "Waiting for operator..."; sleep 10; done'
	@echo "🔧 Detecting platform and creating appropriate Quay configuration..."
	@PLATFORM=${PLATFORM}; \
	if [ -z "$$PLATFORM" ]; then \
		if oc get nodes -o json | jq -r '.items[0].spec.providerID' | grep -q 'aws://'; then \
			PLATFORM=rosa; \
		elif oc get nodes -o json | jq -r '.items[0].spec.providerID' | grep -q 'azure://'; then \
			PLATFORM=aro; \
		else \
			echo "⚠️  Cannot auto-detect platform. Defaulting to ARO. Set PLATFORM=aro or PLATFORM=rosa to override."; \
			PLATFORM=aro; \
		fi; \
	fi; \
	echo "🎯 Using platform: $$PLATFORM"; \
	if [ "$$PLATFORM" = "rosa" ]; then \
		echo "📝 Applying ROSA S3 configuration..."; \
		oc apply -f edge-integration-cell/quay-registry/rosa-quay-config-secret.yaml; \
		echo "🚀 Creating ROSA Quay registry instance..."; \
		oc apply -f edge-integration-cell/quay-registry/rosa-quay-registry.yaml; \
	else \
		echo "📝 Applying ARO Azure configuration..."; \
		oc apply -f edge-integration-cell/quay-registry/aro-quay-config-secret.yaml; \
		echo "🚀 Creating ARO Quay registry instance..."; \
		oc apply -f edge-integration-cell/quay-registry/aro-quay-registry.yaml; \
	fi
	@echo "✅ Quay deployment initiated ($$PLATFORM platform)"

.PHONY: quay-info-generic
quay-info-generic:  ## Get Quay registry connection information (generic)
	@echo "📋 Quay Registry Information (Generic):"
	@echo "======================================="
	@ENDPOINT=$$(oc get quayregistry test-registry -n openshift-operators -o json 2>/dev/null | jq -r '.status.registryEndpoint // "Not ready"'); \
	if [ "$$ENDPOINT" != "Not ready" ]; then \
		REGISTRY=$$(echo "$$ENDPOINT" | sed 's/^https:\/\///'); \
		echo "Registry Endpoint: $$ENDPOINT"; \
		echo "Registry Host: $$REGISTRY"; \
		echo "Admin User Path: $$REGISTRY/quayadmin"; \
		echo ""; \
		echo "🔑 Create admin user with QUAY_ADMIN_PASSWORD and QUAY_ADMIN_EMAIL set"; \
		echo "🔒 Configure certificate trust as needed"; \
	else \
		echo "❌ Quay registry not ready yet"; \
	fi

# ROSA (Red Hat OpenShift Service on AWS) Quay Registry targets
.PHONY: rosa-quay-s3-create
rosa-quay-s3-create:  ## Get S3 credentials for Quay (bucket created by Terraform)
	@echo "💡 Note: S3 bucket is created by Terraform deployment (cd rosa/terraform && terraform apply)"
	@echo "   This command retrieves the credentials from Terraform outputs"
	@echo ""
	@./hack/rosa/quay-s3-create.sh

.PHONY: rosa-quay-deploy
rosa-quay-deploy:  ## Deploy Quay registry operator and instance on ROSA with S3 storage (uses Ansible)
	$(call required-environment-variables,CLUSTER_NAME S3_BUCKET_NAME S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY)
	$(call required-environment-variables,QUAY_ADMIN_PASSWORD QUAY_ADMIN_EMAIL)
	@echo "🚀 Deploying Quay registry on ROSA with S3 storage (Ansible)..."
	@S3_HOST_DEFAULT=$${S3_HOST:-s3.$${S3_REGION}.amazonaws.com}; \
	echo "Using S3 host: $$S3_HOST_DEFAULT"; \
	ansible-playbook ansible/quay-deploy.yml \
		-i ansible/inventory.yml \
		-e platform=rosa \
		-e cluster_name="${CLUSTER_NAME}" \
		-e s3_bucket_name="${S3_BUCKET_NAME}" \
		-e s3_region="${S3_REGION}" \
		-e s3_host="$$S3_HOST_DEFAULT" \
		-e aws_access_key_id="${AWS_ACCESS_KEY_ID}" \
		-e aws_secret_access_key="${AWS_SECRET_ACCESS_KEY}" \
		-e quay_admin_password="${QUAY_ADMIN_PASSWORD}" \
		-e quay_admin_email="${QUAY_ADMIN_EMAIL}" \
		--tags operator,storage,config,registry,wait

.PHONY: rosa-quay-wait-ready
rosa-quay-wait-ready:  ## Wait for Quay registry to be ready on ROSA
	@echo "⏳ Waiting for Quay registry to be ready on ROSA..."
	@timeout 600 bash -c 'until oc get quayregistry test-registry -n openshift-operators -o json 2>/dev/null | jq -r ".status.conditions[] | select(.type==\"Available\") | .status" | grep -q "True"; do echo "Waiting for Quay registry..."; sleep 20; done'
	@echo "✅ Quay registry is ready on ROSA"

.PHONY: rosa-quay-wait-http-ready
rosa-quay-wait-http-ready:  ## Wait for Quay registry HTTP service to be ready on ROSA
	@echo "⏳ Waiting for Quay HTTP service to be ready on ROSA..."
	@ENDPOINT=$$(oc get quayregistry test-registry -n openshift-operators -o json 2>/dev/null | jq -r '.status.registryEndpoint // "Not ready"'); \
	if [ "$$ENDPOINT" != "Not ready" ]; then \
		timeout 300 bash -c "until curl -k -s $$ENDPOINT/health/instance >/dev/null 2>&1; do echo 'Waiting for HTTP service...'; sleep 10; done"; \
		echo "✅ Quay HTTP service is ready"; \
	else \
		echo "❌ Quay endpoint not available yet"; \
		exit 1; \
	fi

.PHONY: rosa-quay-deploy-complete
rosa-quay-deploy-complete:  ## Complete ROSA Quay deployment with S3 storage, registry, and trust configuration
	$(call required-environment-variables,CLUSTER_NAME S3_BUCKET_NAME S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY)
	$(call required-environment-variables,QUAY_ADMIN_PASSWORD QUAY_ADMIN_EMAIL)
	@ansible/rosa-quay-deploy.sh

.PHONY: rosa-quay-info
rosa-quay-info:  ## Get ROSA Quay registry connection information
	@echo "📋 ROSA Quay Registry Information:"
	@echo "=================================="
	@ENDPOINT=$$(oc get quayregistry test-registry -n openshift-operators -o json 2>/dev/null | jq -r '.status.registryEndpoint // "Not ready"'); \
	if [ "$$ENDPOINT" != "Not ready" ]; then \
		REGISTRY=$$(echo "$$ENDPOINT" | sed 's/^https:\/\///'); \
		echo "Registry Endpoint: $$ENDPOINT"; \
		echo "Registry Host: $$REGISTRY"; \
		echo "Admin User Path: $$REGISTRY/quayadmin"; \
		echo "S3 Bucket: $${S3_BUCKET_NAME:-Not set}"; \
		echo "S3 Region: $${S3_REGION:-Not set}"; \
		echo ""; \
		echo "🔑 Admin user should be created automatically"; \
		echo "🔗 Test login with: podman login $$REGISTRY/quayadmin or docker login $$REGISTRY/quayadmin"; \
	else \
		echo "❌ Quay registry not ready yet"; \
	fi

.PHONY: rosa-quay-create-admin
rosa-quay-create-admin:  ## Create Quay admin user on ROSA (requires QUAY_ADMIN_PASSWORD, QUAY_ADMIN_EMAIL)
	$(call required-environment-variables,QUAY_ADMIN_PASSWORD QUAY_ADMIN_EMAIL)
	@echo "👤 Creating Quay admin user on ROSA..."
	ansible-playbook ansible/quay-deploy.yml \
		-i ansible/inventory.yml \
		-e platform=rosa \
		-e cluster_name="${CLUSTER_NAME}" \
		-e quay_admin_password="${QUAY_ADMIN_PASSWORD}" \
		-e quay_admin_email="${QUAY_ADMIN_EMAIL}" \
		--tags admin

.PHONY: rosa-quay-trust-cert
rosa-quay-trust-cert:  ## Configure ROSA to trust Quay registry certificate
	$(call required-environment-variables,CLUSTER_NAME)
	@echo "🔒 Configuring ROSA to trust Quay registry certificate..."
	ansible-playbook ansible/quay-deploy.yml \
		-i ansible/inventory.yml \
		-e platform=rosa \
		-e cluster_name="${CLUSTER_NAME}" \
		--tags trust

.PHONY: rosa-quay-status
rosa-quay-status:  ## Check Quay deployment status on ROSA
	@echo "📊 ROSA Quay Deployment Status:"
	@echo "==============================="
	@echo "Operator Status:"
	@oc get csv -n openshift-operators | grep quay-operator || echo "Quay operator not found"
	@echo ""
	@echo "Registry Status:"
	@oc get quayregistry test-registry -n openshift-operators -o json 2>/dev/null | jq -r '.status.conditions[] | "- \(.type): \(.status) (\(.reason))"' || echo "Registry not found"
	@echo ""
	@echo "Pods Status:"
	@oc get pods -n openshift-operators | grep test-registry || echo "No Quay pods found"

.PHONY: rosa-quay-delete
rosa-quay-delete:  ## Delete Quay registry and operator from ROSA
	@echo "🗑️ Deleting Quay registry from ROSA..."
	oc delete quayregistry test-registry -n openshift-operators --ignore-not-found=true
	@echo "⏳ Waiting for Quay pods to terminate..."
	@timeout 120 bash -c 'while oc get pods -n openshift-operators | grep -q test-registry; do echo "Waiting..."; sleep 10; done' || echo "Timeout waiting for pods"
	@echo "🗑️ Deleting Quay operator..."
	oc delete subscription quay-operator -n openshift-operators --ignore-not-found=true
	oc delete csv -n openshift-operators -l operators.coreos.com/quay-operator.openshift-operators --ignore-not-found=true
	@echo "🧹 Cleaning up secrets and configmaps..."
	oc delete secret config-bundle-secret -n openshift-operators --ignore-not-found=true
	@echo "✅ Quay cleanup completed on ROSA"

.PHONY: aro-validate-test-config
aro-validate-test-config:  ## Validate test configuration before deployment
	@echo "🔍 Validating test deployment configuration..."
	@echo "=============================================="
	@PULL_SECRET_BASE64=$$(printf '%s' "$$PULL_SECRET" | tr -d '\n' | sed 's/^"//;s/"$$//' | base64 -w 0); \
	TEMP_PARAMS=$$(mktemp); \
	echo "{ \
		\"servicePrincipalClientId\": { \"value\": \"${CLIENT_ID}\" }, \
		\"servicePrincipalClientSecret\": { \"value\": \"${CLIENT_SECRET}\" }, \
		\"pullSecret\": { \"value\": \"$$PULL_SECRET_BASE64\" }, \
		\"postgresAdminPassword\": { \"value\": \"${POSTGRES_ADMIN_PASSWORD}\" } \
	}" > $$TEMP_PARAMS; \
	az deployment group validate --resource-group ${ARO_RESOURCE_GROUP} \
		--template-file bicep/aro.bicep \
		--parameters @bicep/test.parameters.json \
		--parameters @$$TEMP_PARAMS \
		--query "error" -o table; \
	rm -f $$TEMP_PARAMS
	@echo "✅ Configuration validation completed"

.PHONY: aro-what-if-test
aro-what-if-test:  ## Preview what resources will be created/modified
	$(call required-environment-variables,ARO_RESOURCE_GROUP CLIENT_ID CLIENT_SECRET TENANT_ID PULL_SECRET POSTGRES_ADMIN_PASSWORD)
	@echo "🔮 What-if analysis for test deployment..."
	@PULL_SECRET_BASE64=$$(printf '%s' "$$PULL_SECRET" | tr -d '\n' | sed 's/^"//;s/"$$//' | base64 -w 0); \
	TEMP_PARAMS=$$(mktemp); \
	echo "{ \
		\"servicePrincipalClientId\": { \"value\": \"${CLIENT_ID}\" }, \
		\"servicePrincipalClientSecret\": { \"value\": \"${CLIENT_SECRET}\" }, \
		\"pullSecret\": { \"value\": \"$$PULL_SECRET_BASE64\" }, \
		\"postgresAdminPassword\": { \"value\": \"${POSTGRES_ADMIN_PASSWORD}\" } \
	}" > $$TEMP_PARAMS; \
	az deployment group what-if --resource-group ${ARO_RESOURCE_GROUP} \
		--template-file bicep/aro.bicep \
		--parameters @bicep/test.parameters.json \
		--parameters @$$TEMP_PARAMS; \
	rm -f $$TEMP_PARAMS
