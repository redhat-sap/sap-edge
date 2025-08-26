#!/bin/bash

# SPDX-FileCopyrightText: 2024 SAP edge team
#
# SPDX-License-Identifier: Apache-2.0

# Script to enable AWS EFS CSI Driver Operator on ROSA using Terraform
# Based on: https://cloud.redhat.com/experts/rosa/aws-efs/

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing_tools=()

    if ! command -v terraform &> /dev/null; then
        missing_tools+=("terraform")
    fi

    if ! command -v oc &> /dev/null; then
        missing_tools+=("oc")
    fi

    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws")
    fi

    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools and try again."
        exit 1
    fi

    # Check if logged into OpenShift
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift. Please run 'oc login' first."
        exit 1
    fi

    # Check if logged into AWS
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "Not logged into AWS. Please configure AWS credentials first."
        exit 1
    fi

    log_success "All prerequisites met"
}

# Set up environment variables
setup_environment() {
    log_info "Setting up environment variables..."

    # Set Terraform working directory
    TERRAFORM_DIR="${TERRAFORM_DIR:-./rosa/terraform}"
    export TERRAFORM_DIR

    # Check if Terraform directory exists
    if [ ! -d "$TERRAFORM_DIR" ]; then
        log_error "Terraform directory not found: $TERRAFORM_DIR"
        log_error "Please ensure you're running this script from the project root directory"
        exit 1
    fi

    # Source .env file if it exists
    ENV_FILE="${ENV_FILE:-.env}"
    if [ -f "$ENV_FILE" ]; then
        log_info "Loading environment variables from: $ENV_FILE"
        # Export all variables from .env file
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
    else
        log_warning ".env file not found at: $ENV_FILE"
        log_info "You can create one from the example:"
        log_info "  cp $TERRAFORM_DIR/env.example $ENV_FILE"
        log_info "  Then edit $ENV_FILE with your values"
    fi

    # Get cluster name from environment or OpenShift
    if [ -z "${CLUSTER_NAME:-}" ]; then
        CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null | sed 's/-[^-]*$//' || echo "")
        if [ -z "${CLUSTER_NAME}" ]; then
            read -r -p "Enter your ROSA cluster name: " CLUSTER_NAME
        fi
    fi
    export CLUSTER_NAME

    # Set AWS region
    if [ -z "${AWS_REGION:-}" ]; then
        AWS_REGION="eu-central-1"
        export AWS_REGION
    fi

    log_success "Environment variables set:"
    log_info "  CLUSTER_NAME: $CLUSTER_NAME"
    log_info "  AWS_REGION: $AWS_REGION"
    log_info "  TERRAFORM_DIR: $TERRAFORM_DIR"
    log_info "  ENV_FILE: $ENV_FILE"
}

# Convert environment variables to Terraform variables
convert_env_to_tf_vars() {
    local tf_vars=""

    # Convert boolean strings to lowercase
    convert_bool() {
        local val="$1"
        if [[ "$val" =~ ^[Tt]rue$ ]]; then
            echo "true"
        elif [[ "$val" =~ ^[Ff]alse$ ]]; then
            echo "false"
        else
            echo "$val"
        fi
    }

    # Convert comma-separated lists to HCL arrays
    convert_list() {
        local val="$1"
        if [ -z "$val" ]; then
            echo "[]"
        else
            # Use parameter expansion instead of sed
            echo "[\"${val//,/\", \"}\"]"
        fi
    }

    # Convert key=value pairs to HCL maps
    convert_map() {
        local val="$1"
        if [ -z "$val" ]; then
            echo "{}"
        else
            local map="{"
            IFS=',' read -ra PAIRS <<< "$val"
            for i in "${!PAIRS[@]}"; do
                IFS='=' read -r key value <<< "${PAIRS[$i]}"
                [ "$i" -gt 0 ] && map+=", "
                map+="\"$key\" = \"$value\""
            done
            map+="}"
            echo "$map"
        fi
    }

    # Map environment variables to Terraform variables
    [ -n "${ROSA_TOKEN:-}" ] && tf_vars+=" -var=rosa_token=\"$ROSA_TOKEN\""
    [ -n "${CLUSTER_NAME:-}" ] && tf_vars+=" -var=cluster_name=\"$CLUSTER_NAME\""
    [ -n "${AWS_REGION:-}" ] && tf_vars+=" -var=aws_region=\"$AWS_REGION\""
    [ -n "${ROSA_VERSION:-}" ] && tf_vars+=" -var=rosa_version=\"$ROSA_VERSION\""
    [ -n "${CHANNEL_GROUP:-}" ] && tf_vars+=" -var=channel_group=\"$CHANNEL_GROUP\""
    [ -n "${WORKER_REPLICAS:-}" ] && tf_vars+=" -var=worker_replicas=$WORKER_REPLICAS"
    [ -n "${WORKER_MACHINE_TYPE:-}" ] && tf_vars+=" -var=worker_machine_type=\"$WORKER_MACHINE_TYPE\""

    # Network configuration
    [ -n "${CREATE_VPC:-}" ] && tf_vars+=" -var=create_vpc=$(convert_bool "$CREATE_VPC")"
    [ -n "${EXISTING_SUBNET_IDS:-}" ] && tf_vars+=" -var=existing_subnet_ids=$(convert_list "$EXISTING_SUBNET_IDS")"
    [ -n "${AVAILABILITY_ZONES:-}" ] && tf_vars+=" -var=availability_zones=$(convert_list "$AVAILABILITY_ZONES")"

    # VPC configuration
    [ -n "${VPC_NAME:-}" ] && tf_vars+=" -var=vpc_name=\"$VPC_NAME\""
    [ -n "${VPC_CIDR:-}" ] && tf_vars+=" -var=vpc_cidr=\"$VPC_CIDR\""
    [ -n "${PUBLIC_SUBNET_1_CIDR:-}" ] && tf_vars+=" -var=public_subnet_1_cidr=\"$PUBLIC_SUBNET_1_CIDR\""
    [ -n "${PUBLIC_SUBNET_2_CIDR:-}" ] && tf_vars+=" -var=public_subnet_2_cidr=\"$PUBLIC_SUBNET_2_CIDR\""
    [ -n "${PUBLIC_SUBNET_3_CIDR:-}" ] && tf_vars+=" -var=public_subnet_3_cidr=\"$PUBLIC_SUBNET_3_CIDR\""
    [ -n "${PRIVATE_SUBNET_1_CIDR:-}" ] && tf_vars+=" -var=private_subnet_1_cidr=\"$PRIVATE_SUBNET_1_CIDR\""
    [ -n "${PRIVATE_SUBNET_2_CIDR:-}" ] && tf_vars+=" -var=private_subnet_2_cidr=\"$PRIVATE_SUBNET_2_CIDR\""
    [ -n "${PRIVATE_SUBNET_3_CIDR:-}" ] && tf_vars+=" -var=private_subnet_3_cidr=\"$PRIVATE_SUBNET_3_CIDR\""

    # Domain configuration
    [ -n "${DOMAIN_NAME:-}" ] && tf_vars+=" -var=domain_name=\"$DOMAIN_NAME\""
    [ -n "${CREATE_DOMAIN_RECORDS:-}" ] && tf_vars+=" -var=create_domain_records=$(convert_bool "$CREATE_DOMAIN_RECORDS")"
    [ -n "${USE_CNAME_RECORDS:-}" ] && tf_vars+=" -var=use_cname_records=$(convert_bool "$USE_CNAME_RECORDS")"

    # Cluster access
    [ -n "${PRIVATE_CLUSTER:-}" ] && tf_vars+=" -var=private_cluster=$(convert_bool "$PRIVATE_CLUSTER")"
    [ -n "${CREATE_ADMIN_USER:-}" ] && tf_vars+=" -var=create_admin_user=$(convert_bool "$CREATE_ADMIN_USER")"
    [ -n "${ADMIN_USERNAME:-}" ] && tf_vars+=" -var=admin_username=\"$ADMIN_USERNAME\""
    [ -n "${ADMIN_PASSWORD:-}" ] && tf_vars+=" -var=admin_password=\"$ADMIN_PASSWORD\""

    # Other configurations
    [ -n "${ENABLE_AUTOSCALING:-}" ] && tf_vars+=" -var=enable_autoscaling=$(convert_bool "$ENABLE_AUTOSCALING")"
    [ -n "${MIN_REPLICAS:-}" ] && tf_vars+=" -var=min_replicas=$MIN_REPLICAS"
    [ -n "${MAX_REPLICAS:-}" ] && tf_vars+=" -var=max_replicas=$MAX_REPLICAS"
    [ -n "${KMS_KEY_ARN:-}" ] && tf_vars+=" -var=kms_key_arn=\"$KMS_KEY_ARN\""
    [ -n "${CREATE_ACCOUNT_ROLES:-}" ] && tf_vars+=" -var=create_account_roles=$(convert_bool "$CREATE_ACCOUNT_ROLES")"
    [ -n "${CREATE_OIDC:-}" ] && tf_vars+=" -var=create_oidc=$(convert_bool "$CREATE_OIDC")"
    [ -n "${CREATE_OPERATOR_ROLES:-}" ] && tf_vars+=" -var=create_operator_roles=$(convert_bool "$CREATE_OPERATOR_ROLES")"
    [ -n "${ACCOUNT_ROLE_PREFIX:-}" ] && tf_vars+=" -var=account_role_prefix=\"$ACCOUNT_ROLE_PREFIX\""
    [ -n "${OPERATOR_ROLE_PREFIX:-}" ] && tf_vars+=" -var=operator_role_prefix=\"$OPERATOR_ROLE_PREFIX\""
    [ -n "${IAM_ROLE_PATH:-}" ] && tf_vars+=" -var=iam_role_path=\"$IAM_ROLE_PATH\""
    [ -n "${IAM_ROLE_PERMISSIONS_BOUNDARY:-}" ] && tf_vars+=" -var=iam_role_permissions_boundary=\"$IAM_ROLE_PERMISSIONS_BOUNDARY\""
    [ -n "${OIDC_ENDPOINT_URL:-}" ] && tf_vars+=" -var=oidc_endpoint_url=\"$OIDC_ENDPOINT_URL\""
    [ -n "${OIDC_CONFIG_ID:-}" ] && tf_vars+=" -var=oidc_config_id=\"$OIDC_CONFIG_ID\""
    [ -n "${WAIT_FOR_CLUSTER:-}" ] && tf_vars+=" -var=wait_for_cluster=$(convert_bool "$WAIT_FOR_CLUSTER")"
    [ -n "${ENVIRONMENT_TAG:-}" ] && tf_vars+=" -var=environment_tag=\"$ENVIRONMENT_TAG\""
    [ -n "${DNS_TTL:-}" ] && tf_vars+=" -var=dns_ttl=$DNS_TTL"

    # EFS configuration
    [ -n "${ENABLE_EFS:-}" ] && tf_vars+=" -var=enable_efs=$(convert_bool "$ENABLE_EFS")"
    [ -n "${EFS_PERFORMANCE_MODE:-}" ] && tf_vars+=" -var=efs_performance_mode=\"$EFS_PERFORMANCE_MODE\""
    [ -n "${EFS_THROUGHPUT_MODE:-}" ] && tf_vars+=" -var=efs_throughput_mode=\"$EFS_THROUGHPUT_MODE\""
    [ -n "${EFS_PROVISIONED_THROUGHPUT:-}" ] && tf_vars+=" -var=efs_provisioned_throughput=$EFS_PROVISIONED_THROUGHPUT"
    [ -n "${EFS_KMS_KEY_ARN:-}" ] && tf_vars+=" -var=efs_kms_key_arn=\"$EFS_KMS_KEY_ARN\""
    [ -n "${EFS_TRANSITION_TO_IA:-}" ] && tf_vars+=" -var=efs_transition_to_ia=\"$EFS_TRANSITION_TO_IA\""
    [ -n "${EFS_TRANSITION_TO_PRIMARY_STORAGE_CLASS:-}" ] && tf_vars+=" -var=efs_transition_to_primary_storage_class=\"$EFS_TRANSITION_TO_PRIMARY_STORAGE_CLASS\""

    # Additional tags require special handling
    if [ -n "${ADDITIONAL_TAGS:-}" ]; then
        tf_vars+=" -var=additional_tags=$(convert_map "$ADDITIONAL_TAGS")"
    fi

    echo "$tf_vars"
}

# Apply Terraform EFS configuration
apply_terraform_efs() {
    log_info "Applying Terraform configuration for EFS..."

    cd "$TERRAFORM_DIR"

    # Initialize Terraform if needed
    if [ ! -d ".terraform" ]; then
        log_info "Initializing Terraform..."
        terraform init
    fi

    # Export all environment variables as TF_VAR_ prefixed variables
    # This is cleaner than building a command line with quotes
    export TF_VAR_rosa_token="${ROSA_TOKEN:-}"
    export TF_VAR_cluster_name="${CLUSTER_NAME:-}"
    export TF_VAR_aws_region="${AWS_REGION:-}"
    export TF_VAR_rosa_version="${ROSA_VERSION:-}"
    export TF_VAR_channel_group="${CHANNEL_GROUP:-}"
    export TF_VAR_worker_replicas="${WORKER_REPLICAS:-}"
    export TF_VAR_worker_machine_type="${WORKER_MACHINE_TYPE:-}"
    export TF_VAR_create_vpc="${CREATE_VPC:-true}"
    export TF_VAR_vpc_name="${VPC_NAME:-}"
    export TF_VAR_vpc_cidr="${VPC_CIDR:-}"
    export TF_VAR_environment_tag="${ENVIRONMENT_TAG:-}"
    export TF_VAR_oidc_endpoint_url="${OIDC_ENDPOINT_URL:-}"
    export TF_VAR_oidc_config_id="${OIDC_CONFIG_ID:-}"
    export TF_VAR_enable_efs="true"  # Force enable EFS

    # Convert boolean strings to lowercase for Terraform
    if [ -n "${CREATE_VPC:-}" ]; then
        TF_VAR_create_vpc=$(echo "$CREATE_VPC" | tr '[:upper:]' '[:lower:]')
        export TF_VAR_create_vpc
    fi
    if [ -n "${CREATE_OIDC:-}" ]; then
        TF_VAR_create_oidc=$(echo "${CREATE_OIDC:-true}" | tr '[:upper:]' '[:lower:]')
        export TF_VAR_create_oidc
    fi
    if [ -n "${CREATE_ACCOUNT_ROLES:-}" ]; then
        TF_VAR_create_account_roles=$(echo "${CREATE_ACCOUNT_ROLES:-true}" | tr '[:upper:]' '[:lower:]')
        export TF_VAR_create_account_roles
    fi
    if [ -n "${CREATE_OPERATOR_ROLES:-}" ]; then
        TF_VAR_create_operator_roles=$(echo "${CREATE_OPERATOR_ROLES:-true}" | tr '[:upper:]' '[:lower:]')
        export TF_VAR_create_operator_roles
    fi

    # Debug: Show key variables
    log_info "Debug: TF_VAR_enable_efs=$TF_VAR_enable_efs"
    log_info "Debug: TF_VAR_oidc_endpoint_url=$TF_VAR_oidc_endpoint_url"
    log_info "Debug: TF_VAR_oidc_config_id=$TF_VAR_oidc_config_id"

    # Handle complex types
    if [ -n "${ADDITIONAL_TAGS:-}" ]; then
        # Convert key=value,key2=value2 to JSON
        TF_VAR_additional_tags=$(echo "{${ADDITIONAL_TAGS}}" | sed 's/=/":"/g' | sed 's/,/","/g' | sed 's/{/{"/g' | sed 's/}/"}/g')
        export TF_VAR_additional_tags
    fi

    # Plan with environment variables, targeting only EFS resources
    log_info "Planning Terraform changes with EFS enabled (targeting EFS resources only)..."

    # Define the EFS resource targets
    # Since resources use count, we need to target with index notation
    EFS_TARGETS=(
        "-target=aws_efs_file_system.rosa_efs[0]"
        "-target=aws_efs_mount_target.rosa_efs"
        "-target=aws_security_group.efs[0]"
        "-target=aws_security_group_rule.efs_ingress[0]"
        "-target=aws_security_group_rule.efs_from_workers[0]"
        "-target=aws_iam_policy.efs_csi_driver[0]"
        "-target=aws_iam_role.efs_csi_driver[0]"
        "-target=aws_iam_role_policy_attachment.efs_csi_driver[0]"
    )

    # Run terraform plan with targets (variables are now in environment)
    log_info "Running terraform plan with environment variables..."

    if ! terraform plan "${EFS_TARGETS[@]}" -out=tfplan; then
        log_error "Terraform plan failed"
        exit 1
    fi

    # Ask for confirmation
    read -r -p "Do you want to apply these changes? (yes/no): " confirm
    if [[ ! "$confirm" =~ ^[Yy]es$ ]]; then
        log_warning "Terraform apply cancelled."
        exit 0
    fi

    # Apply the configuration
    log_info "Applying Terraform configuration..."
    terraform apply tfplan

    # Get outputs
    EFS_ID=$(terraform output -raw efs_file_system_id 2>/dev/null || echo "")
    EFS_ROLE_ARN=$(terraform output -raw efs_csi_driver_role_arn 2>/dev/null || echo "")

    if [ -z "$EFS_ID" ] || [ -z "$EFS_ROLE_ARN" ]; then
        log_error "Failed to get EFS outputs from Terraform. Please check the apply was successful."
        exit 1
    fi

    export EFS_ID
    export EFS_ROLE_ARN

    log_success "Terraform EFS configuration applied successfully"
    log_info "  EFS File System ID: $EFS_ID"
    log_info "  EFS CSI Driver Role ARN: $EFS_ROLE_ARN"

    cd - > /dev/null
}

# Deploy AWS EFS Operator
deploy_efs_operator() {
    log_info "Creating secret for AWS EFS Operator..."

    cat << EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
 name: aws-efs-cloud-credentials
 namespace: openshift-cluster-csi-drivers
stringData:
  credentials: |-
    [default]
    role_arn = $EFS_ROLE_ARN
    web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF

    log_success "Secret created"

    log_info "Installing EFS Operator..."

    # Check if OperatorGroup already exists
    if ! oc get operatorgroup -n openshift-cluster-csi-drivers &>/dev/null; then
        log_info "Creating OperatorGroup..."
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cluster-csi-drivers-operatorgroup
  namespace: openshift-cluster-csi-drivers
EOF
    else
        log_info "OperatorGroup already exists"
    fi

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/aws-efs-csi-driver-operator.openshift-cluster-csi-drivers: ""
  name: aws-efs-csi-driver-operator
  namespace: openshift-cluster-csi-drivers
spec:
  channel: stable
  installPlanApproval: Automatic
  name: aws-efs-csi-driver-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    log_success "EFS Operator installation initiated"

    log_info "Waiting for EFS Operator to be ready..."
    while ! oc get deployment aws-efs-csi-driver-operator -n openshift-cluster-csi-drivers &>/dev/null; do
        log_info "Waiting for operator deployment to be created..."
        sleep 10
    done

    oc wait --for=condition=Available deployment/aws-efs-csi-driver-operator \
        -n openshift-cluster-csi-drivers --timeout=300s
    log_success "EFS Operator is running"
}

# Install AWS EFS CSI Driver
install_csi_driver() {
    log_info "Installing AWS EFS CSI Driver..."

    cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
    name: efs.csi.aws.com
spec:
  managementState: Managed
EOF

    log_success "EFS CSI Driver installation initiated"

    log_info "Waiting for CSI driver to be ready..."
    # Wait for the daemonset to be created first
    while ! oc get daemonset aws-efs-csi-driver-node -n openshift-cluster-csi-drivers &>/dev/null; do
        log_info "Waiting for CSI driver daemonset to be created..."
        sleep 10
    done

    # Then wait for it to be ready
    while true; do
        DAEMONSET_STATUS=$(oc get daemonset aws-efs-csi-driver-node -n openshift-cluster-csi-drivers -o json)
        DESIRED=$(echo "$DAEMONSET_STATUS" | jq -r '.status.desiredNumberScheduled')
        READY=$(echo "$DAEMONSET_STATUS" | jq -r '.status.numberReady')

        log_info "Waiting for CSI driver daemonset to be ready (Current: $READY/$DESIRED)..."

        if [ "$DESIRED" = "$READY" ] && [ "$DESIRED" -gt 0 ]; then
            break
        fi
        sleep 10
    done

    oc wait --for=condition=Ready daemonset/aws-efs-csi-driver-node \
        -n openshift-cluster-csi-drivers --timeout=300s
    log_success "EFS CSI Driver is running"
}

# Create Storage Class
create_storage_class() {
    log_info "Creating Storage Class for EFS volume..."

    cat <<EOF | oc apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: $EFS_ID
  directoryPerms: "700"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/dynamic_provisioning"
EOF

    log_success "Storage Class created"
}

# Create test resources
create_test_resources() {
    log_info "Creating test namespace and resources..."

    # Create namespace
    oc new-project efs-demo --skip-config-write=true || oc project efs-demo

    log_info "Creating PVC for testing..."

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-efs-volume
spec:
  storageClassName: efs-sc
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
EOF

    log_success "PVC created"

    log_info "Creating test pod to write to EFS..."

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
 name: test-efs
spec:
 volumes:
   - name: efs-storage-vol
     persistentVolumeClaim:
       claimName: pvc-efs-volume
 containers:
   - name: test-efs
     image: centos:latest
     command: [ "/bin/bash", "-c", "--" ]
     args: [ "while true; do echo 'hello efs' | tee -a /mnt/efs-data/verify-efs && sleep 5; done;" ]
     volumeMounts:
       - mountPath: "/mnt/efs-data"
         name: efs-storage-vol
EOF

    log_info "Waiting for test pod to be ready..."
    oc wait --for=condition=Ready pod/test-efs --timeout=300s
    log_success "Test pod is ready"

    log_info "Creating test pod to read from EFS..."

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
 name: test-efs-read
spec:
 volumes:
   - name: efs-storage-vol
     persistentVolumeClaim:
       claimName: pvc-efs-volume
 containers:
   - name: test-efs-read
     image: centos:latest
     command: [ "/bin/bash", "-c", "--" ]
     args: [ "tail -f /mnt/efs-data/verify-efs" ]
     volumeMounts:
       - mountPath: "/mnt/efs-data"
         name: efs-storage-vol
EOF

    log_info "Waiting for read test pod to be ready..."
    oc wait --for=condition=Ready pod/test-efs-read --timeout=300s
    log_success "Read test pod is ready"

    log_info "Verifying EFS functionality..."
    sleep 10

    LOGS=$(oc logs test-efs-read --tail=5)
    if echo "$LOGS" | grep -q "hello efs"; then
        log_success "EFS verification successful! Pods can read and write to the shared volume."
        echo "Sample logs from read pod:"
        echo "$LOGS"
    else
        log_warning "EFS verification inconclusive. Check pod logs manually."
    fi
}

# Print summary
print_summary() {
    log_info "================================================"
    log_success "AWS EFS CSI Driver setup completed successfully!"
    log_info "================================================"
    log_info "Summary of created resources:"
    log_info "  EFS File System ID: $EFS_ID"
    log_info "  EFS CSI Driver Role ARN: $EFS_ROLE_ARN"
    log_info "  Storage Class: efs-sc"
    log_info "  Test Namespace: efs-demo"
    log_info ""
    log_info "To test the EFS setup:"
    log_info "  oc logs test-efs-read -f"
    log_info ""
    log_info "To use EFS in your applications:"
    log_info "  Use storage class 'efs-sc' in your PVC definitions"
    log_info ""
    log_info "To manage EFS configuration via Terraform:"
    log_info "  cd $TERRAFORM_DIR"
    log_info "  terraform plan"
    log_info "  terraform apply"
    log_info "================================================"
}

# Main execution
main() {
    log_info "Starting AWS EFS CSI Driver setup for ROSA using Terraform..."

    check_prerequisites
    setup_environment

    # Apply Terraform configuration
    apply_terraform_efs

    # Deploy operator and driver
    deploy_efs_operator
    install_csi_driver
    create_storage_class

    # Optional: Create test resources
    read -r -p "Do you want to create test resources to verify EFS? (yes/no): " create_test
    if [[ "$create_test" =~ ^[Yy]es$ ]]; then
        create_test_resources
    fi

    print_summary

    log_success "Setup completed successfully!"
}

# Show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -c, --cluster-name      Set the cluster name (default: auto-detect)"
    echo "  -r, --region            Set AWS region (default: eu-central-1)"
    echo "  -d, --terraform-dir     Set Terraform directory (default: ./rosa/terraform)"
    echo "  -e, --env-file          Set environment file path (default: ./rosa/terraform/.env)"
    echo ""
    echo "Environment Variables:"
    echo "  CLUSTER_NAME            ROSA cluster name"
    echo "  AWS_REGION              AWS region"
    echo "  TERRAFORM_DIR           Path to Terraform configuration directory"
    echo "  ENV_FILE                Path to .env file"
    echo ""
    echo "Configuration:"
    echo "  This script reads configuration from a .env file."
    echo "  Copy rosa/terraform/env.example to rosa/terraform/.env and update with your values."
    echo ""
    echo "Example:"
    echo "  $0 --cluster-name my-rosa-cluster --region us-east-1"
    echo "  CLUSTER_NAME=my-cluster AWS_REGION=us-west-2 $0"
    echo "  $0 --env-file /path/to/custom.env"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -d|--terraform-dir)
            TERRAFORM_DIR="$2"
            shift 2
            ;;
        -e|--env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Run main function
main "$@"
