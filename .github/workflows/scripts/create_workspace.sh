#!/usr/bin/env bash
set -euo pipefail

# --- User-defined variables ---
BRANCH="${BRANCH_NAME:?}"
PREFIX="${WS_PREFIX:?}"
AZDO_ORGANIZATION="${AZDO_ORGANIZATION:?}"
AZDO_PROJECT="${AZDO_PROJECT:?}"
AZDO_REPOSITORY="${AZDO_REPOSITORY:?}"
AZDO_BRANCH="${AZDO_BRANCH:?}"
CAPACITY_ID="${CAPACITY_ID:?CAPACITY_ID not set}"

# [NEW] Required for Service Principal Authentication
FABRIC_CONNECTION_ID="${FABRIC_CONNECTION_ID:?FABRIC_CONNECTION_ID is required for Service Principal authentication}"

NAME="${PREFIX}-${BRANCH//\//-}"
echo ">> Looking for or creating Fabric workspace: '${NAME}'"

FABRIC_TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)

get_workspace_id() {
  local ws_name="$1"
  curl -s -H "Authorization: Bearer ${FABRIC_TOKEN}" \
    "https://api.fabric.microsoft.com/v1/workspaces" | \
    jq -r --arg name "$ws_name" '.value[] | select(.displayName == $name) | .id'
}

WS_ID=$(get_workspace_id "$NAME")

if [[ -z "$WS_ID" || "$WS_ID" == "null" ]]; then
  echo ">> Creating workspace with capacity ${CAPACITY_ID}..."
  
  # Capture full response with HTTP status code
  HTTP_RESPONSE=$(curl -w "\n%{http_code}" -s -X POST \
    -H "Authorization: Bearer ${FABRIC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"displayName\":\"${NAME}\",\"capacityId\":\"${CAPACITY_ID}\"}" \
    "https://api.fabric.microsoft.com/v1/workspaces")
  
  HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
  CREATE_RESP=$(echo "$HTTP_RESPONSE" | sed '$d')
  
  if [[ ! "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
    echo "❌ Failed to create workspace (HTTP $HTTP_CODE):" >&2
    echo "$CREATE_RESP" >&2
    exit 1
  fi
  
  WS_ID=$(echo "$CREATE_RESP" | jq -r '.id')
  
  if [[ -z "$WS_ID" || "$WS_ID" == "null" ]]; then
    echo "❌ Failed to extract workspace ID from response:" >&2
    echo "$CREATE_RESP" >&2
    exit 1
  fi
  
  echo ">> Created workspace ${WS_ID}"
else
  echo ">> Re-using existing workspace ${WS_ID}"
fi

# Set Azure DevOps pipeline variable
echo "##vso[task.setvariable variable=WS_ID;isOutput=true]$WS_ID"

# # --- Connect to Git (Azure DevOps) ---
# echo ">> Connecting workspace to Azure DevOps Git repository using Connection ID: ${FABRIC_CONNECTION_ID}..."

# # [UPDATED] Payload now includes myGitCredentials with ConfiguredConnection
# HTTP_RESPONSE=$(curl -w "\n%{http_code}" -s -X POST \
#   -H "Authorization: Bearer ${FABRIC_TOKEN}" \
#   -H "Content-Type: application/json" \
#   -d "{
#         \"gitProviderDetails\": {
#           \"gitProviderType\": \"AzureDevOps\",
#           \"organizationName\": \"${AZDO_ORGANIZATION}\",
#           \"projectName\": \"${AZDO_PROJECT}\",
#           \"repositoryName\": \"${AZDO_REPOSITORY}\",
#           \"branchName\": \"${AZDO_BRANCH}\",
#           \"directoryName\": \"\" 
#         },
#         \"myGitCredentials\": {
#           \"source\": \"ConfiguredConnection\",
#           \"connectionId\": \"${FABRIC_CONNECTION_ID}\"
#         }
#       }" \
#   "https://api.fabric.microsoft.com/v1/workspaces/${WS_ID}/git/connect")

# HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
# CONNECT_RESP=$(echo "$HTTP_RESPONSE" | sed '$d')

# # Handle different response scenarios
# if [[ "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
#   echo ">> Successfully connected to Git repository"
# elif [[ -n "$CONNECT_RESP" ]]; then
#   # Try to parse as JSON and check for specific error codes
#   ERROR_CODE=$(echo "$CONNECT_RESP" | jq -r '.errorCode // .error.code // empty' 2>/dev/null || echo "")
  
#   # Added WorkspaceAlreadyConnectedToGit which is common when re-running
#   if [[ "$ERROR_CODE" == "WorkspaceAlreadyConnectedToGit" || "$ERROR_CODE" == "GitIntegrationAlreadyConnected" || "$ERROR_CODE" == "GitConnectionAlreadyExists" ]]; then
#     echo ">> Git integration already exists (idempotent success)"
#   else
#     echo "❌ Failed to connect Git (HTTP $HTTP_CODE):" >&2
#     echo "$CONNECT_RESP" >&2
    
#     # Try to extract error message if available
#     ERROR_MSG=$(echo "$CONNECT_RESP" | jq -r '.message // .error.message // empty' 2>/dev/null || echo "")
#     if [[ -n "$ERROR_MSG" ]]; then
#       echo "Error message: $ERROR_MSG" >&2
#     fi
#     exit 1
#   fi
# else
#   echo "❌ Failed to connect Git - received empty response (HTTP $HTTP_CODE)" >&2
#   exit 1
# fi

# --- Final success ---
echo ">> All done! Fabric workspace ready: '${NAME}' (${WS_ID})"
echo ">> Access it here: https://app.fabric.microsoft.com/groups/${WS_ID}"