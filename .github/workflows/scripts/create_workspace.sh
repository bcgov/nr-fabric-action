#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════
# 1. Inputs & Environment Setup
# ══════════════════════════════════════════════════════════════

# Optional: let you name workspaces per branch, but no git integration happens.
BRANCH="${BRANCH_NAME:-${GITHUB_REF_NAME:-}}"

PREFIX="${WS_PREFIX:?WS_PREFIX is required}"
CAPACITY_ID="${CAPACITY_ID:?CAPACITY_ID is required}"

# Service Principal Credentials (Passed via env)
CLIENT_ID="${AZURE_CLIENT_ID:?AZURE_CLIENT_ID is required}"
CLIENT_SECRET="${AZURE_CLIENT_SECRET:?AZURE_CLIENT_SECRET is required}"
TENANT_ID="${AZURE_TENANT_ID:?AZURE_TENANT_ID is required}"

# ── Backwards compatibility (still required, even though unused now) ──
FABRIC_CONNECTION_ID="${FABRIC_CONNECTION_ID:?FABRIC_CONNECTION_ID is required}"
REPO_FULL="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY env var missing}"

# Parse GitHub Repository details (kept for compatibility/logging only)
REPO_OWNER="${REPO_FULL%%/*}"
REPO_NAME="${REPO_FULL#*/}"

# Construct Workspace Name
if [[ -n "${BRANCH}" ]]; then
  SAFE_BRANCH="${BRANCH//\//-}"
  NAME="${PREFIX}-${SAFE_BRANCH}"
else
  NAME="${PREFIX}"
fi

echo "══════════════════════════════════════════════════════════════"
echo ">> Target Workspace: '${NAME}'"
echo ">> Capacity ID: ${CAPACITY_ID}"
echo ">> (Compat) Repo: ${REPO_OWNER}/${REPO_NAME} (Branch: ${BRANCH:-<none>})"
echo ">> (Compat) FABRIC_CONNECTION_ID provided: yes"
echo "══════════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════
# 2. Authentication
# ══════════════════════════════════════════════════════════════

echo ">> Logging into Azure via Service Principal..."
az login --service-principal \
  --username "$CLIENT_ID" \
  --password "$CLIENT_SECRET" \
  --tenant "$TENANT_ID" \
  --allow-no-subscriptions \
  --output none

echo ">> Fetching Fabric Access Token..."
FABRIC_TOKEN="$(az account get-access-token \
  --resource https://api.fabric.microsoft.com \
  --query accessToken -o tsv)"

# ══════════════════════════════════════════════════════════════
# 3. Check / Create Workspace
# ══════════════════════════════════════════════════════════════

get_workspace_id() {
  local ws_name="$1"
  curl -s -H "Authorization: Bearer ${FABRIC_TOKEN}" \
    "https://api.fabric.microsoft.com/v1/workspaces" | \
    jq -r --arg name "$ws_name" '.value[] | select(.displayName == $name) | .id'
}

WS_ID="$(get_workspace_id "$NAME")"

if [[ -z "$WS_ID" || "$WS_ID" == "null" ]]; then
  echo ">> Workspace not found. Creating '${NAME}' on capacity ${CAPACITY_ID}..."

  HTTP_RESPONSE="$(curl -w "\n%{http_code}" -s -X POST \
    -H "Authorization: Bearer ${FABRIC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"displayName\":\"${NAME}\",\"capacityId\":\"${CAPACITY_ID}\"}" \
    "https://api.fabric.microsoft.com/v1/workspaces")"

  HTTP_CODE="$(echo "$HTTP_RESPONSE" | tail -n1)"
  CREATE_RESP="$(echo "$HTTP_RESPONSE" | sed '$d')"

  if [[ ! "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
    echo "❌ Failed to create workspace (HTTP $HTTP_CODE):" >&2
    echo "$CREATE_RESP" >&2
    exit 1
  fi

  WS_ID="$(echo "$CREATE_RESP" | jq -r '.id')"
  echo ">> ✅ Created workspace ${WS_ID}"
else
  echo ">> ✅ Re-using existing workspace ${WS_ID}"
fi

# Set GitHub Action Output Variable (safe even outside GitHub Actions)
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "workspace_id=$WS_ID" >> "$GITHUB_OUTPUT"
else
  echo "workspace_id=$WS_ID"
fi

echo ">> ✅ Workspace ready."
echo ">> https://app.fabric.microsoft.com/groups/${WS_ID}"
