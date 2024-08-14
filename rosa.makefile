CLUSTER_NAME?=sapeic

.PHONY: rosa-login
rosa-login:  ## Login using ROSA token
	@rosa login --token="${ROSA_TOKEN}"

.PHONY: rosa-init
rosa-init:  ## ROSA init
	rosa init

.PHONY: rosa-account-roles
rosa-account-roles:  ## Login using ROSA token
	rosa create account-roles --mode auto

.PHONY: rosa-cluster
rosa-cluster:  ## Create ROSA cluster
	rosa create cluster --cluster-name "${CLUSTER_NAME}"

.PHONY: rosa-cluster-status
rosa-cluster-status:  ## Get ROSA cluster status
	rosa describe cluster --cluster "${CLUSTER_NAME}"

.PHONY: rosa-cluster-hibernate
rosa-cluster-hibernate:  ## Hibernate ROSA cluster
	rosa hibernate cluster --cluster "${CLUSTER_NAME}"

.PHONY: rosa-cluster-resume
rosa-cluster-resume:  ## Resume ROSA cluster
	rosa resume cluster --cluster "${CLUSTER_NAME}"

.PHONY: rosa-cluster-delete
rosa-cluster-delete:  ## Delete ROSA cluster
	rosa delete cluster --cluster "${CLUSTER_NAME}"

.PHONY: rosa-cluster-admin
rosa-cluster-admin:  ## Create cluster admin
	@rosa create admin --cluster ${CLUSTER_NAME} --password ${CLUSTER_ADMIN_PASSWORD} >/dev/null
	$(info cluster admin created)

.PHONY: rosa-cluster-admin-reset
rosa-cluster-admin-reset:  ## Reset cluster admin password
	@rosa delete admin --cluster ${CLUSTER_NAME} --yes >/dev/null
	$(info cluster admin deleted)
	@rosa create admin --cluster ${CLUSTER_NAME} --password ${CLUSTER_ADMIN_PASSWORD} >/dev/null
	$(info cluster admin password reset)

.PHONY: rosa-cluster-oc-login
rosa-cluster-oc-login:  ## OC cli login to existing cluster (cluster-admin should already exist)
	@rosa describe admin --cluster=${CLUSTER_NAME} | grep -v 'INFO'
