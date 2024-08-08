ARO_RESOURCE_GROUP?=aro-sapeic
ARO_LOCATION?=northeurope

ARO_CLUSTER_NAME?=aro-sapeic
ARO_DOMAIN?=aro.saponrhel.org
ARO_VERSION?=4.14.16

.PHONY: aro-remove
aro-remove:  # Remove ARO
	az deployment group create --resource-group ${ARO_RESOURCE_GROUP} --template-file bicep/empty.bicep --mode Complete

.PHONY: aro-deploy
aro-deploy: network-deploy  # Deploy ARO
	@az deployment group create --resource-group ${ARO_RESOURCE_GROUP} \
		--template-file bicep/aro.bicep \
		--parameters \
		clusterName=${ARO_CLUSTER_NAME} \
		pullSecret=${PULL_SECRET} \
		domain=${ARO_DOMAIN} \
		version=${ARO_VERSION} \
		servicePrincipalClientId=${CLIENT_ID} \
		servicePrincipalClientSecret=${CLIENT_SECRET}

.PHONY: network-deploy
network-deploy:  # Deploy network
	az deployment group create --resource-group ${ARO_RESOURCE_GROUP} \
		--template-file bicep/network.bicep

.PNONY: resource-group
resource-group:  # Create resource group
	az group create --name ${ARO_RESOURCE_GROUP} --location ${ARO_LOCATION} --query name -o tsv
