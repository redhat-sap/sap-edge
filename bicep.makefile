ARO_RESOURCE_GROUP?=aro-sapeic

.PHONY: aro-remove
aro-remove:  # Remove ARO
	az deployment group create --resource-group ${ARO_RESOURCE_GROUP} --template-file bicep/empty.bicep --mode Complete
