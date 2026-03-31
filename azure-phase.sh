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
# LOAD CONFIG FROM FILE IF PROVIDED
############################################

if [[ $# -gt 0 ]]; then
    CONFIG_FILE="$1"
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "ERROR: Config file not found: ${CONFIG_FILE}"
        exit 1
    fi
    
    AKS_RG="$(jq -r .aks_rg "${CONFIG_FILE}")"
    AKS_NAME="$(jq -r .aks_name "${CONFIG_FILE}")"
    K8S_NAMESPACE="$(jq -r .k8s_namespace "${CONFIG_FILE}")"
    K8S_SERVICEACCOUNT="$(jq -r .k8s_serviceaccount "${CONFIG_FILE}")"
    IDENTITY_NAME="$(jq -r .identity_name "${CONFIG_FILE}")"
    IDENTITY_RG="$(jq -r .identity_rg "${CONFIG_FILE}")"
    STORAGE_ACCOUNT_NAME="$(jq -r .storage_account_name "${CONFIG_FILE}")"
    STORAGE_ACCOUNT_RG="$(jq -r .storage_account_rg "${CONFIG_FILE}")"
fi


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
# 4. GET THE CLUSTER PRINCIPAL ID
############################################

echo "Looking up the AKS Cluster's principal Id"

CLUSTER_PRINCIPAL=$(az aks show --name ${AKS_NAME} --resource-group ${AKS_RG} --query identity.principalId --output tsv)

echo "Cluster MI is : ${CLUSTER_PRINCIPAL}"

############################################
# 4. ASSIGN RBAC ON STORAGE ACCOUNT
############################################

echo "Assigning Storage File Data SMB MI Admin role..."

STORAGE_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${STORAGE_ACCOUNT_RG}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}"

EXISTING_ROLE="$(az role assignment list \
  --assignee-object-id "${PRINCIPAL_ID}" \
  --scope "${STORAGE_SCOPE}" \
  --query "[?roleDefinitionName=='Storage File Data SMB MI Admin'].id" \
  -o tsv)"

if [[ -z "${EXISTING_ROLE}" ]]; then
  az role assignment create \
    --assignee-object-id "${PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage File Data SMB MI Admin" \
    --scope "${STORAGE_SCOPE}"
else
  echo "Role assignment already exists"
fi

##############################################
# ASSIGN CLUSTER PRINCIPAL RBAC ON STORAGE 
##############################################

CLUSTER_EXISTING_ROLE="$(az role assignment list \
  --assignee-object-id "${CLUSTER_PRINCIPAL}" \
  --scope "${STORAGE_SCOPE}" \
  --query "[?roleDefinitionName=='Storage Account Contributor'].id" \
  -o tsv)"

if [[ -z "${CLUSTER_EXISTING_ROLE}" ]]; then
  az role assignment create \
    --assignee-object-id "${CLUSTER_PRINCIPAL}" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Account Contributor" \
    --scope "${STORAGE_SCOPE}"
else
  echo "Role assignment already exists"
fi



############################################
# 7. Configuring for SMB MI OAuth
############################################

echo "Configuring SMB Auth on storage account..."

az storage account update --name ${STORAGE_ACCOUNT_NAME}   --resource-group /${STORAGE_ACCOUNT_RG}  --enable-smb-oauth true

############################################
# 6. OUTPUT FOR HELM
############################################

echo ""
echo "✅ Azure phase complete"
echo ""
echo "Use the following values in Helm:"
echo "--------------------------------"
echo "workloadIdentity.clientId: ${CLIENT_ID}"
echo "namespace: ${K8S_NAMESPACE}"

echo "helm install ${K8S_NAMESPACE} namespace-storage --set namespace=${K8S_NAMESPACE} --set workloadIdentity.clientId=${CLIENT_ID}  --set azureFiles.storageClass.resourceGroup=\"${STORAGE_ACCOUNT_RG}\"  --set azureFiles.storageClass.name=\"azurefile-${K8S_NAMESPACE}-wi\" --set azureFiles.storageClass.storageAccount=\"${STORAGE_ACCOUNT_NAME}\""