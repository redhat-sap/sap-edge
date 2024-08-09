ARO_RESOURCE_GROUP?=aro-sapeic
ARO_LOCATION?=northeurope

ARO_CLUSTER_NAME?=aro-sapeic
ARO_DOMAIN?=saponrhel.org
ARO_VERSION?=4.14.16

.PHONY: aro-remove
aro-remove:  ## Remove ARO
	az deployment group create --resource-group ${ARO_RESOURCE_GROUP} --template-file bicep/empty.bicep --mode Complete

.PHONY: aro-deploy
aro-deploy: network-deploy  ## Deploy ARO
	@az deployment group create --resource-group ${ARO_RESOURCE_GROUP} \
		--template-file bicep/aro.bicep \
		--parameters \
		clusterName=${ARO_CLUSTER_NAME} \
		pullSecret=${PULL_SECRET} \
		domain=${ARO_DOMAIN} \
		version=${ARO_VERSION} \
		servicePrincipalClientId=${CLIENT_ID} \
		servicePrincipalClientSecret=${CLIENT_SECRET}

.PHONY: domain-records
.ONESHELL:
domain-records:  ## Create domain records for ARO
	hack/domain-records.sh \
		--domain ${ARO_DOMAIN} \
		--aro-name ${ARO_CLUSTER_NAME} \
		--aro-resource-group ${ARO_RESOURCE_GROUP}

.PHONY: network-deploy
network-deploy:  ## Deploy network
	az deployment group create --resource-group ${ARO_RESOURCE_GROUP} \
		--template-file bicep/network.bicep

.PNONY: resource-group
resource-group:  ## Create resource group
	az group create --name ${ARO_RESOURCE_GROUP} --location ${ARO_LOCATION} --query name -o tsv

.PHONY: service-principal
.ONESHELL:
service-principal:  ## Create sevice principal for ARO deployment
	az ad sp create-for-rbac \
		--name "aro-service-principal" \
		--role Contributor \
		--scopes \
		"/subscriptions/$$(az account show --query id -o tsv)/resourceGroups/${ARO_RESOURCE_GROUP}"


.PHONY: arorp-service-principal
.ONESHELL:
arorp-service-principal:  ## Assign required roles to "Azure Red Hat Openshift" RP service principal
	az role assignment create --assignee $$(az ad sp list --display-name "Azure Red Hat OpenShift RP" --query "[0].id" -o tsv) \
	--role Contributor \
	--scope "/subscriptions/$$(az account show --query id -o tsv)/resourceGroups/${ARO_RESOURCE_GROUP}"

aro-credentials:  ## Get ARO credentials
	@az aro list-credentials --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP}

aro-url:  ## Get ARO URL
	@az aro show --name ${ARO_CLUSTER_NAME} --resource-group ${ARO_RESOURCE_GROUP} --query "apiserverProfile.url" -o tsv
