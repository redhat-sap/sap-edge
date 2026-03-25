#!/bin/bash
set -euo pipefail

# Helper script to generate a kubeconfig file locally for ROSA cluster
# Uses the same logic as the Tekton pipeline task

echo "🔑 Generating long-lived kubeconfig for ROSA cluster..."
echo "============================================"
echo ""

# Configuration
SERVICE_ACCOUNT_NAME="cluster-admin-sa"
NAMESPACE="default"
OUTPUT_KUBECONFIG_FILE="kubeconfig"

# Check if already logged in to the cluster
if ! oc whoami &> /dev/null; then
  echo "❌ Not logged in to OpenShift cluster"
  echo ""
  echo "Please login first using one of these methods:"
  echo ""
  echo "Option 1: Using ROSA CLI (for cluster-admin access)"
  echo "  rosa login --token=<your-red-hat-ocm-token>"
  echo "  rosa describe cluster --cluster sap-eic-rosa"
  echo "  oc login https://api.<cluster>.openshiftapps.com --username cluster-admin --password <admin-password>"
  echo ""
  echo "Option 2: Using existing kubeconfig"
  echo "  export KUBECONFIG=/path/to/your/kubeconfig"
  echo "  oc whoami"
  echo ""
  exit 1
fi

echo "✅ Already logged in as: $(oc whoami)"
echo ""

# Step 1: Create Service Account
echo "1. Creating Service Account '${SERVICE_ACCOUNT_NAME}' in namespace '${NAMESPACE}'..."
if ! oc get sa "${SERVICE_ACCOUNT_NAME}" -n "${NAMESPACE}" &> /dev/null; then
  oc create sa "${SERVICE_ACCOUNT_NAME}" -n "${NAMESPACE}"
  echo "   ✅ Service Account created"
else
  echo "   ℹ️  Service Account already exists, reusing it"
fi

# Step 2: Grant cluster-admin permissions
echo "2. Granting 'cluster-admin' role to the Service Account..."
oc adm policy add-cluster-role-to-user cluster-admin -z "${SERVICE_ACCOUNT_NAME}" -n "${NAMESPACE}"
echo "   ✅ Cluster-admin role granted"

# Step 3: Create permanent token Secret for the Service Account
echo "3. Creating permanent token Secret for Service Account..."
TOKEN_SECRET_NAME="${SERVICE_ACCOUNT_NAME}-token"

# Check if token secret already exists
if ! oc get secret "${TOKEN_SECRET_NAME}" -n "${NAMESPACE}" &> /dev/null; then
  echo "   Creating Secret '${TOKEN_SECRET_NAME}'..."
  # Create the Secret using echo (more reliable than heredoc)
  {
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "metadata:"
    echo "  name: ${TOKEN_SECRET_NAME}"
    echo "  annotations:"
    echo "    kubernetes.io/service-account.name: ${SERVICE_ACCOUNT_NAME}"
    echo "type: kubernetes.io/service-account-token"
  } | oc apply -n "${NAMESPACE}" -f -
  echo "   ✅ Secret created"
else
  echo "   ℹ️  Secret '${TOKEN_SECRET_NAME}' already exists, reusing it"
fi

# Step 4: Wait for Kubernetes to populate the token in the Secret
echo "4. Waiting for Kubernetes to populate the token in the Secret..."
for i in {1..30}; do
  TOKEN=$(oc get secret "${TOKEN_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")
  if [[ -n "${TOKEN}" ]]; then
    echo "   ✅ Token populated by Kubernetes (length: ${#TOKEN} characters)"
    break
  fi
  echo "   Waiting for token to be populated (attempt ${i}/30)..."
  sleep 2
done

if [[ -z "${TOKEN}" ]]; then
  echo "   ❌ Token was not populated in Secret after 60 seconds"
  echo "   This may indicate an issue with the Service Account or cluster configuration"
  exit 1
fi

# Step 5: Get CA certificate from the token secret
echo "5. Extracting CA certificate from token secret..."
CA_DATA=$(oc get secret "${TOKEN_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.ca\.crt}')
if [[ -z "${CA_DATA}" ]]; then
  echo "   ⚠️  No CA certificate found in secret, falling back to insecure mode"
fi

# Step 6: Get cluster API server URL
echo "6. Fetching cluster server URL..."
API_SERVER_URL=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}')
if [[ -z "${API_SERVER_URL}" ]]; then
  echo "   ❌ Could not retrieve API server URL"
  exit 1
fi
echo "   API Server: ${API_SERVER_URL}"

# Step 7: Create the kubeconfig file
echo "7. Building the kubeconfig file..."

# Extract cluster name from URL (remove https://)
CLUSTER_NAME_FROM_URL="${API_SERVER_URL#https://}"

# Build kubeconfig
if [[ -n "${CA_DATA}" ]]; then
  CLUSTER_SECTION="    certificate-authority-data: ${CA_DATA}"
else
  CLUSTER_SECTION="    insecure-skip-tls-verify: true"
fi

cat > "${OUTPUT_KUBECONFIG_FILE}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME_FROM_URL}
  cluster:
${CLUSTER_SECTION}
    server: ${API_SERVER_URL}

users:
- name: ${SERVICE_ACCOUNT_NAME}
  user:
    token: ${TOKEN}

contexts:
- name: ${NAMESPACE}/${CLUSTER_NAME_FROM_URL}/${SERVICE_ACCOUNT_NAME}
  context:
    cluster: ${CLUSTER_NAME_FROM_URL}
    namespace: ${NAMESPACE}
    user: ${SERVICE_ACCOUNT_NAME}

current-context: ${NAMESPACE}/${CLUSTER_NAME_FROM_URL}/${SERVICE_ACCOUNT_NAME}
EOF

echo "   ✅ Kubeconfig file created: ${OUTPUT_KUBECONFIG_FILE}"

# Display kubeconfig for verification (without token for security)
echo ""
echo "📄 Kubeconfig Summary:"
echo "========================"
echo "File: ${OUTPUT_KUBECONFIG_FILE}"
echo "Cluster: ${CLUSTER_NAME_FROM_URL}"
echo "User: ${SERVICE_ACCOUNT_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Token Length: ${#TOKEN} characters"
echo "========================"
echo ""

# Verify the kubeconfig works
echo "🔍 Verifying kubeconfig..."
if KUBECONFIG="${OUTPUT_KUBECONFIG_FILE}" oc whoami; then
  echo "✅ Kubeconfig is valid and working!"
  echo ""
  echo "You can now use this kubeconfig:"
  echo "  export KUBECONFIG=$(pwd)/${OUTPUT_KUBECONFIG_FILE}"
  echo "  oc get nodes"
  echo ""
else
  echo "⚠️  Could not verify kubeconfig, but it was created"
  echo "   Try using it manually: export KUBECONFIG=$(pwd)/${OUTPUT_KUBECONFIG_FILE}"
fi

echo "✅ Done!"

