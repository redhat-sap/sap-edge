#!/bin/bash
# Delete existing ROSA resources

set -e

CLUSTER_NAME="${CLUSTER_NAME:-sap-eic-rosa}"
AWS_REGION="${AWS_REGION:-eu-north-1}"

echo "🗑️  Cleaning up ROSA resources..."
echo "=================================="

# 1. Delete ROSA cluster
echo "1️⃣  Deleting ROSA cluster: ${CLUSTER_NAME}"
if rosa describe cluster -c "${CLUSTER_NAME}" &>/dev/null; then
  rosa delete cluster -c "${CLUSTER_NAME}" --yes
  echo "⏳ Waiting for cluster deletion (this takes ~30-45 minutes)..."
  rosa logs uninstall -c "${CLUSTER_NAME}" --watch || true
  echo "✅ Cluster deleted"
else
  echo "ℹ️  Cluster not found or already deleted"
fi

# 2. Find and delete VPC created for ROSA
echo ""
echo "2️⃣  Finding VPC for cluster..."
VPC_ID=$(aws ec2 describe-vpcs \
  --region "${AWS_REGION}" \
  --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" \
  --query "Vpcs[0].VpcId" \
  --output text 2>/dev/null || echo "")

if [[ -n "${VPC_ID}" && "${VPC_ID}" != "None" ]]; then
  echo "Found VPC: ${VPC_ID}"
  echo "⚠️  Deleting VPC and associated resources..."

  # Delete Load Balancers (ELB/ALB) — these create ENIs in subnets
  echo "   Deleting load balancers..."
  aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
    --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" --output text 2>/dev/null | \
    xargs -r -n1 aws elbv2 delete-load-balancer --region "${AWS_REGION}" --load-balancer-arn || true
  aws elb describe-load-balancers --region "${AWS_REGION}" \
    --query "LoadBalancerDescriptions[?VPCId=='${VPC_ID}'].LoadBalancerName" --output text 2>/dev/null | \
    xargs -r -n1 aws elb delete-load-balancer --region "${AWS_REGION}" --load-balancer-name || true

  # Delete NAT Gateways
  echo "   Deleting NAT gateways..."
  NAT_GW_IDS=$(aws ec2 describe-nat-gateways --region "${AWS_REGION}" \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending" \
    --query "NatGateways[*].NatGatewayId" --output text 2>/dev/null || echo "")
  for ngw in ${NAT_GW_IDS}; do
    aws ec2 delete-nat-gateway --region "${AWS_REGION}" --nat-gateway-id "${ngw}" || true
  done

  # Wait for NAT Gateways to reach 'deleted' state before touching subnets
  if [[ -n "${NAT_GW_IDS}" ]]; then
    echo "   Waiting for NAT gateways to delete (up to 3 minutes)..."
    for _ in $(seq 1 18); do
      PENDING=$(aws ec2 describe-nat-gateways --region "${AWS_REGION}" \
        --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending,deleting" \
        --query "NatGateways | length(@)" --output text 2>/dev/null || echo "0")
      [[ "${PENDING}" == "0" ]] && break
      sleep 10
    done
  fi

  # Release Elastic IPs associated with the VPC (freed after NAT gateways are gone)
  echo "   Releasing Elastic IPs..."
  aws ec2 describe-addresses --region "${AWS_REGION}" \
    --filters "Name=domain,Values=vpc" \
    --query "Addresses[?AssociationId==null && AllocationId!=null].AllocationId" --output text 2>/dev/null | \
    xargs -r -n1 aws ec2 release-address --region "${AWS_REGION}" --allocation-id || true

  # Delete VPC Endpoints
  echo "   Deleting VPC endpoints..."
  aws ec2 describe-vpc-endpoints --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "VpcEndpoints[*].VpcEndpointId" --output text 2>/dev/null | \
    xargs -r -n1 aws ec2 delete-vpc-endpoints --region "${AWS_REGION}" --vpc-endpoint-ids || true

  # Delete Network Interfaces (ENIs) — the main blocker for subnet deletion
  echo "   Deleting network interfaces..."
  ENI_IDS=$(aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "NetworkInterfaces[*].NetworkInterfaceId" --output text 2>/dev/null || echo "")
  for eni in ${ENI_IDS}; do
    # Detach first if attached
    ATTACH_ID=$(aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
      --network-interface-ids "${eni}" \
      --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null || echo "None")
    if [[ -n "${ATTACH_ID}" && "${ATTACH_ID}" != "None" ]]; then
      aws ec2 detach-network-interface --region "${AWS_REGION}" --attachment-id "${ATTACH_ID}" --force || true
      sleep 2
    fi
    aws ec2 delete-network-interface --region "${AWS_REGION}" --network-interface-id "${eni}" || true
  done

  # Delete Internet Gateways
  echo "   Deleting internet gateways..."
  IGW_IDS=$(aws ec2 describe-internet-gateways --region "${AWS_REGION}" \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query "InternetGateways[*].InternetGatewayId" --output text 2>/dev/null || echo "")
  for igw in ${IGW_IDS}; do
    aws ec2 detach-internet-gateway --region "${AWS_REGION}" --internet-gateway-id "${igw}" --vpc-id "${VPC_ID}" || true
    aws ec2 delete-internet-gateway --region "${AWS_REGION}" --internet-gateway-id "${igw}" || true
  done

  # Disassociate and delete route table subnet associations, then delete route tables
  echo "   Deleting route tables..."
  RT_IDS=$(aws ec2 describe-route-tables --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "RouteTables[?Associations[0].Main != \`true\`].RouteTableId" --output text 2>/dev/null || echo "")
  for rt in ${RT_IDS}; do
    # Disassociate non-main associations
    ASSOC_IDS=$(aws ec2 describe-route-tables --region "${AWS_REGION}" \
      --route-table-ids "${rt}" \
      --query "RouteTables[0].Associations[?Main != \`true\`].RouteTableAssociationId" --output text 2>/dev/null || echo "")
    for assoc in ${ASSOC_IDS}; do
      aws ec2 disassociate-route-table --region "${AWS_REGION}" --association-id "${assoc}" || true
    done
    aws ec2 delete-route-table --region "${AWS_REGION}" --route-table-id "${rt}" || true
  done

  # Delete Subnets
  echo "   Deleting subnets..."
  aws ec2 describe-subnets --region "${AWS_REGION}" --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[*].SubnetId" --output text | xargs -r -n1 aws ec2 delete-subnet --region "${AWS_REGION}" --subnet-id || true

  # Revoke security group ingress/egress rules that reference other SGs, then delete
  echo "   Deleting security groups..."
  SG_IDS=$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?GroupName != 'default'].GroupId" --output text 2>/dev/null || echo "")
  for sg in ${SG_IDS}; do
    # Revoke all ingress rules
    INGRESS_RULES=$(aws ec2 describe-security-groups --region "${AWS_REGION}" --group-ids "${sg}" \
      --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null || echo "[]")
    if echo "${INGRESS_RULES}" | jq -e '. | length > 0' >/dev/null 2>&1; then
      aws ec2 revoke-security-group-ingress --region "${AWS_REGION}" --group-id "${sg}" \
        --ip-permissions "${INGRESS_RULES}" || true
    fi
    # Revoke all egress rules
    EGRESS_RULES=$(aws ec2 describe-security-groups --region "${AWS_REGION}" --group-ids "${sg}" \
      --query "SecurityGroups[0].IpPermissionsEgress" --output json 2>/dev/null || echo "[]")
    if echo "${EGRESS_RULES}" | jq -e '. | length > 0' >/dev/null 2>&1; then
      aws ec2 revoke-security-group-egress --region "${AWS_REGION}" --group-id "${sg}" \
        --ip-permissions "${EGRESS_RULES}" || true
    fi
  done
  for sg in ${SG_IDS}; do
    aws ec2 delete-security-group --region "${AWS_REGION}" --group-id "${sg}" || true
  done

  # Delete VPC
  aws ec2 delete-vpc --region "${AWS_REGION}" --vpc-id "${VPC_ID}" || echo "⚠️  Could not delete VPC (may have dependencies)"

  echo "✅ VPC cleanup completed"
else
  echo "ℹ️  No VPC found for cluster"
fi

# 3. Check for PostgreSQL
echo ""
echo "3️⃣  Checking for PostgreSQL instances..."
POSTGRES_ID=$(aws rds describe-db-instances \
  --region "${AWS_REGION}" \
  --query "DBInstances[?contains(DBInstanceIdentifier, '${CLUSTER_NAME}')].DBInstanceIdentifier | [0]" \
  --output text 2>/dev/null || echo "")

if [[ -n "${POSTGRES_ID}" && "${POSTGRES_ID}" != "None" ]]; then
  echo "Found PostgreSQL: ${POSTGRES_ID}"
  aws rds delete-db-instance \
    --region "${AWS_REGION}" \
    --db-instance-identifier "${POSTGRES_ID}" \
    --skip-final-snapshot \
    --delete-automated-backups || echo "⚠️  Could not delete PostgreSQL"
  echo "✅ PostgreSQL deletion initiated"
else
  echo "ℹ️  No PostgreSQL found"
fi

# 4. Check for Redis
echo ""
echo "4️⃣  Checking for Redis clusters..."
REDIS_ID=$(aws elasticache describe-replication-groups \
  --region "${AWS_REGION}" \
  --query "ReplicationGroups[?contains(ReplicationGroupId, '${CLUSTER_NAME}')].ReplicationGroupId | [0]" \
  --output text 2>/dev/null || echo "")

if [[ -n "${REDIS_ID}" && "${REDIS_ID}" != "None" ]]; then
  echo "Found Redis: ${REDIS_ID}"
  aws elasticache delete-replication-group \
    --region "${AWS_REGION}" \
    --replication-group-id "${REDIS_ID}" || echo "⚠️  Could not delete Redis"
  echo "✅ Redis deletion initiated"
else
  echo "ℹ️  No Redis found"
fi

# 5. Check for S3 buckets (Quay)
echo ""
echo "5️⃣  Checking for S3 buckets..."
S3_BUCKET=$(aws s3api list-buckets \
  --query "Buckets[?contains(Name, 'quay') && contains(Name, '${CLUSTER_NAME}')].Name | [0]" \
  --output text 2>/dev/null || echo "")

if [[ -n "${S3_BUCKET}" && "${S3_BUCKET}" != "None" ]]; then
  echo "Found S3 bucket: ${S3_BUCKET}"
  echo "⚠️  Emptying and deleting bucket..."
  # Remove all objects
  aws s3 rm "s3://${S3_BUCKET}" --recursive || true
  # Remove all versions and delete markers (for versioned buckets)
  aws s3api list-object-versions --bucket "${S3_BUCKET}" --query 'Versions[*].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null | \
    jq -r '.[] | "--key \"\(.Key)\" --version-id \(.VersionId)"' 2>/dev/null | \
    xargs -L1 -I {} sh -c "aws s3api delete-object --bucket ${S3_BUCKET} {}" 2>/dev/null || true
  aws s3api list-object-versions --bucket "${S3_BUCKET}" --query 'DeleteMarkers[*].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null | \
    jq -r '.[] | "--key \"\(.Key)\" --version-id \(.VersionId)"' 2>/dev/null | \
    xargs -L1 -I {} sh -c "aws s3api delete-object --bucket ${S3_BUCKET} {}" 2>/dev/null || true
  # Force delete bucket
  aws s3 rb "s3://${S3_BUCKET}" --force || echo "⚠️  Could not delete S3 bucket"
  echo "✅ S3 bucket cleanup attempted"
else
  echo "ℹ️  No S3 buckets found"
fi

# 6. Clean up IAM resources
echo ""
echo "6️⃣  Cleaning up IAM resources..."

# IAM User for Quay S3
IAM_USER="${CLUSTER_NAME}-quay-s3-user"
if aws iam get-user --user-name "${IAM_USER}" &>/dev/null; then
  echo "Found IAM user: ${IAM_USER}"
  
  # Delete access keys
  aws iam list-access-keys --user-name "${IAM_USER}" --query 'AccessKeyMetadata[*].AccessKeyId' --output text | \
    xargs -n1 -I {} aws iam delete-access-key --user-name "${IAM_USER}" --access-key-id {} 2>/dev/null || true
  
  # Delete inline policies
  aws iam list-user-policies --user-name "${IAM_USER}" --query 'PolicyNames' --output text | \
    xargs -n1 -I {} aws iam delete-user-policy --user-name "${IAM_USER}" --policy-name {} 2>/dev/null || true
  
  # Delete user
  aws iam delete-user --user-name "${IAM_USER}" 2>/dev/null || true
  echo "✅ IAM user deleted"
else
  echo "ℹ️  No IAM user found: ${IAM_USER}"
fi

# IAM Roles for ROSA HCP (Account Roles)
for role_suffix in "HCP-ROSA-Installer-Role" "HCP-ROSA-Support-Role" "HCP-ROSA-Worker-Role"; do
  ROLE_NAME="${CLUSTER_NAME}-${role_suffix}"
  
  if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
    echo "Found IAM role: ${ROLE_NAME}"
    
    # List and detach all attached policies
    aws iam list-attached-role-policies --role-name "${ROLE_NAME}" --query 'AttachedPolicies[*].PolicyArn' --output text | \
      xargs -n1 -I {} aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn {} 2>/dev/null || true
    
    # Delete inline policies
    aws iam list-role-policies --role-name "${ROLE_NAME}" --query 'PolicyNames' --output text | \
      xargs -n1 -I {} aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name {} 2>/dev/null || true
    
    # Delete the role
    aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null || true
    echo "✅ IAM role deleted: ${ROLE_NAME}"
  fi
done

# IAM Operator Roles (created by Terraform ROSA module)
echo ""
echo "Cleaning up IAM operator roles..."
for role_suffix in \
  "openshift-image-registry-installer-cloud-credential" \
  "openshift-ingress-operator-cloud-credentials" \
  "kube-system-kms-provider" \
  "openshift-cluster-csi-drivers-ebs-cloud-credentials" \
  "kube-system-capa-controller-manager" \
  "openshift-cloud-network-config-controller-cloud-cre" \
  "kube-system-control-plane-operator" \
  "kube-system-kube-controller-manager"; do
  
  ROLE_NAME="${CLUSTER_NAME}-${role_suffix}"
  
  if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
    echo "Found IAM operator role: ${ROLE_NAME}"
    
    # List and detach all attached policies
    aws iam list-attached-role-policies --role-name "${ROLE_NAME}" --query 'AttachedPolicies[*].PolicyArn' --output text | \
      xargs -n1 -I {} aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn {} 2>/dev/null || true
    
    # Delete inline policies
    aws iam list-role-policies --role-name "${ROLE_NAME}" --query 'PolicyNames' --output text | \
      xargs -n1 -I {} aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name {} 2>/dev/null || true
    
    # Delete the role
    aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null || true
    echo "✅ IAM operator role deleted: ${ROLE_NAME}"
  fi
done

echo ""
echo "=================================="
echo "✅ Cleanup completed!"
echo ""
echo "Note: Some resources may take time to delete (VPC dependencies, etc.)"
echo "You can now run the pipeline for a clean deployment."
