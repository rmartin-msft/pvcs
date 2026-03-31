#!/usr/bin/env bash
set -euo pipefail

############################################
# REQUIRED INPUTS
############################################

# AKS
AKS_RG="rg-aks-scarlett-snail"
AKS_NAME="scarlettsnail"

# Workload identity binding
K8S_NAMESPACE="apps-team-1"
K8S_SERVICEACCOUNT="apps-team-1-sa"

# Managed Identity
IDENTITY_NAME="mi-scarlett-apps-1"
IDENTITY_RG="rg-aks-scarlett-snail"

# Azure Files storage account
STORAGE_ACCOUNT_NAME="stscarlettappsteam1"
STORAGE_ACCOUNT_RG="rg-aks-scarlett-snail"

############################################
# DERIVED / CONSTANTS
############################################

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
FEDERATED_CREDENTIAL_NAME="fic-${K8S_NAMESPACE}-${K8S_SERVICEACCOUNT}"

echo "Using subscription: ${SUBSCRIPTION_ID}"

############################################
# 1. GET AKS OIDC ISSUER URL
############################################

echo "Fetching AKS OIDC issuer URL..."

OIDC_ISSUER="$(az aks show \
  --resource-group "${AKS_RG}" \
  --name "${AKS_NAME}" \
  --query "oidcIssuerProfile.issuerUrl" \
  -o tsv)"

if [[ -z "${OIDC_ISSUER}" ]]; then
  echo "ERROR: AKS does not have OIDC issuer enabled."
  exit 1
fi

echo "OIDC issuer: ${OIDC_ISSUER}"

############################################
# 2. CREATE OR GET USER ASSIGNED MI
############################################

echo "Ensuring managed identity exists..."

IDENTITY_JSON="$(az identity show \
  --name "${IDENTITY_NAME}" \
  --resource-group "${IDENTITY_RG}" \
  2>/dev/null || true)"

if [[ -z "${IDENTITY_JSON}" ]]; then
  echo "Creating managed identity ${IDENTITY_NAME}"
  IDENTITY_JSON="$(az identity create \
    --name "${IDENTITY_NAME}" \
    --resource-group "${IDENTITY_RG}" \
    -o json)"
else
  echo "Managed identity already exists"
fi

CLIENT_ID="$(echo "${IDENTITY_JSON}" | jq -r .clientId)"
PRINCIPAL_ID="$(echo "${IDENTITY_JSON}" | jq -r .principalId)"

############################################
# 3. CREATE FEDERATED IDENTITY CREDENTIAL
############################################

echo "Ensuring federated identity credential exists..."

EXISTING_FIC="$(az identity federated-credential list \
  --identity-name "${IDENTITY_NAME}" \
  --resource-group "${IDENTITY_RG}" \
  --query "[?name=='${FEDERATED_CREDENTIAL_NAME}'].name" \
  -o tsv)"

if [[ -z "${EXISTING_FIC}" ]]; then
  echo "Creating federated identity credential..."

  az identity federated-credential create \
    --name "${FEDERATED_CREDENTIAL_NAME}" \
    --identity-name "${IDENTITY_NAME}" \
    --resource-group "${IDENTITY_RG}" \
    --issuer "${OIDC_ISSUER}" \
    --subject "system:serviceaccount:${K8S_NAMESPACE}:${K8S_SERVICEACCOUNT}" \
    --audiences "api://AzureADTokenExchange"
else
  echo "Federated identity credential already exists"
fi

############################################
# 4. ASSIGN RBAC ON STORAGE ACCOUNT
############################################

echo "Assigning Storage Account Contributor role..."

STORAGE_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${STORAGE_ACCOUNT_RG}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}"

EXISTING_ROLE="$(az role assignment list \
  --assignee-object-id "${PRINCIPAL_ID}" \
  --scope "${STORAGE_SCOPE}" \
  --query "[?roleDefinitionName=='Storage Account Contributor'].id" \
  -o tsv)"

if [[ -z "${EXISTING_ROLE}" ]]; then
  az role assignment create \
    --assignee-object-id "${PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Account Contributor" \
    --scope "${STORAGE_SCOPE}"
else
  echo "Role assignment already exists"
fi

############################################
# 5. OUTPUT FOR HELM
############################################

echo ""
echo "✅ Azure phase complete"
echo ""
echo "Use the following values in Helm:"
echo "--------------------------------"
echo "workloadIdentity.clientId: ${CLIENT_ID}"
echo "namespace: ${K8S_NAMESPACE}"
echo "serviceAccount: ${K8S_SERVICEACCOUNT}"
