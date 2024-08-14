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
