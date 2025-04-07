#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# set -x # Uncomment for detailed command execution debugging

# --- Configuration ---
DEFAULT_PROJECT_ID="sandboxportal" # Using the user-provided default
GCP_PROJECT_ID="${1:-$DEFAULT_PROJECT_ID}"
GCP_REGION="us-central1"
BQ_DATASET_NAME="bqml_models"
BQ_CONNECTION_ID="vertex_ai_connection"
BQ_MODEL_NAME="gemini_pro_remote_generator"
CONNECTION_SA_NAME="bqml-vertex-connection-sa" # User-managed SA base name
VERTEX_MODEL_ID="gemini-pro"
# --- USER SPECIFIED BQ CONNECTION AGENT ---
# Ensure this agent exists and is associated with the BQ_CONNECTION_ID above.
# See important caveats in the script comments and documentation.
USER_SPECIFIED_BQ_AGENT="bqcx-284327778820-ahsv@gcp-sa-bigquery-condel.iam.gserviceaccount.com"

# --- Derived Variables ---
# User-managed SA (needs Vertex permissions)
CONNECTION_SA_EMAIL="${CONNECTION_SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
GCP_PROJECT_NUMBER=$(gcloud projects describe "${GCP_PROJECT_ID}" --format='value(projectNumber)')

# *** MODIFIED: Using user-specified BQ Connection Agent ID ***
BQ_CONNECTION_AGENT_ID="${USER_SPECIFIED_BQ_AGENT}"
echo "INFO: Using user-specified BQ Connection Agent ID: ${BQ_CONNECTION_AGENT_ID}"
echo "      Ensure this agent exists and is associated with connection '${BQ_CONNECTION_ID}'."

# Standard derived agent ID (for comparison/reference, not used for permissions anymore)
# STANDARD_BQ_CONNECTION_AGENT_ID="service-${GCP_PROJECT_NUMBER}@gcp-sa-bigqueryconnection.iam.gserviceaccount.com"


BQ_MODEL_REF="${GCP_PROJECT_ID}.${BQ_DATASET_NAME}.${BQ_MODEL_NAME}"
BQ_CONNECTION_REF="${GCP_PROJECT_ID}.${GCP_REGION}.${BQ_CONNECTION_ID}"
VERTEX_ENDPOINT_URL="https://${GCP_REGION}-aiplatform.googleapis.com/v1/projects/${GCP_PROJECT_ID}/locations/${GCP_REGION}/publishers/google/models/${VERTEX_MODEL_ID}"
CURRENT_USER_EMAIL=$(gcloud config get-value account 2>/dev/null)


# --- Check for jq ---
if ! command -v jq &> /dev/null; then
    echo "WARNING: 'jq' command not found. Some idempotency checks for IAM roles will be skipped."
    echo "         The script will attempt to add roles regardless of current state."
    JQ_INSTALLED=false
else
    JQ_INSTALLED=true
fi

# --- 1. Enable Necessary APIs ---
echo ">>> [1/8] Enabling required APIs in project ${GCP_PROJECT_ID} (if not already enabled)..."
# (API enablement remains the same)
gcloud services enable \
    bigquery.googleapis.com \
    aiplatform.googleapis.com \
    iam.googleapis.com \
    cloudresourcemanager.googleapis.com \
    bigqueryconnection.googleapis.com \
    --project="${GCP_PROJECT_ID}"

# --- 2. Create User-Managed Service Account for BQ Connection ---
echo ">>> [2/8] Checking/Creating User-Managed Service Account ${CONNECTION_SA_EMAIL}..."
# (User-managed SA creation remains the same)
if ! gcloud iam service-accounts describe "${CONNECTION_SA_EMAIL}" --project="${GCP_PROJECT_ID}" &> /dev/null; then
    echo "    Creating Service Account ${CONNECTION_SA_NAME}..."
    gcloud iam service-accounts create "${CONNECTION_SA_NAME}" \
        --display-name="BQML Vertex AI Connection SA" \
        --description="Service Account for BigQuery Connection to call Vertex AI" \
        --project="${GCP_PROJECT_ID}"
else
    echo "    User-Managed Service Account ${CONNECTION_SA_EMAIL} already exists."
fi

# --- 3. Grant User-Managed Service Account Permissions (Vertex AI User) ---
echo ">>> [3/8] Checking/Granting 'Vertex AI User' role to ${CONNECTION_SA_EMAIL} on project..."
# (Granting Vertex AI User role to user-managed SA remains the same)
ROLE_TO_CHECK="roles/aiplatform.user"
MEMBER_TO_CHECK="serviceAccount:${CONNECTION_SA_EMAIL}" # Granting to the user-managed SA
NEEDS_ROLE=true
# (jq check logic remains the same)
if [[ "$JQ_INSTALLED" == true ]]; then
    if gcloud projects get-iam-policy "${GCP_PROJECT_ID}" --format=json | \
       jq -e --arg role "$ROLE_TO_CHECK" --arg member "$MEMBER_TO_CHECK" \
       '.bindings[] | select(.role == $role) | .members[] | select(. == $member)' &> /dev/null; then
        echo "    Role '${ROLE_TO_CHECK}' already granted to ${MEMBER_TO_CHECK} on project ${GCP_PROJECT_ID}."
        NEEDS_ROLE=false
    fi
fi
# (Grant logic remains the same)
if [[ "$NEEDS_ROLE" == true ]]; then
     echo "    Granting role '${ROLE_TO_CHECK}' to ${MEMBER_TO_CHECK} on project ${GCP_PROJECT_ID}..."
     gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
        --member="${MEMBER_TO_CHECK}" \
        --role="${ROLE_TO_CHECK}" \
        --condition=None
else
    if [[ "$JQ_INSTALLED" == true ]]; then echo "    Skipping role grant as it already exists."; fi
fi

# --- 4. Create BigQuery Dataset ---
echo ">>> [4/8] Checking/Creating BigQuery Dataset ${GCP_PROJECT_ID}:${BQ_DATASET_NAME} in location ${GCP_REGION}..."
# (Dataset creation remains the same)
if ! bq show --project_id "${GCP_PROJECT_ID}" --format=prettyjson "${BQ_DATASET_NAME}" &> /dev/null ; then
    echo "    Creating dataset ${BQ_DATASET_NAME}..."
    bq --location="${GCP_REGION}" mk --dataset \
        --project_id="${GCP_PROJECT_ID}" \
        --description="Dataset for BigQuery ML Models" \
        "${BQ_DATASET_NAME}"
else
    echo "    Dataset ${BQ_DATASET_NAME} already exists."
fi

# --- 5. Create BigQuery Connection ---
# *** WARNING ADDED regarding connection creation vs specified agent ***
echo ">>> [5/8] Checking/Creating BigQuery Connection ${BQ_CONNECTION_REF}..."
CONNECTION_EXISTS=false
if bq show --connection --project_id="${GCP_PROJECT_ID}" --location="${GCP_REGION}" "${BQ_CONNECTION_ID}" &> /dev/null; then
    echo "    Connection ${BQ_CONNECTION_ID} already exists in region ${GCP_REGION}."
    CONNECTION_EXISTS=true
    # Optionally, verify the existing connection's agent ID
    EXISTING_AGENT_ID=$(bq show --connection --project_id="${GCP_PROJECT_ID}" --location="${GCP_REGION}" "${BQ_CONNECTION_ID}" --format=json 2>/dev/null | jq -r '.cloudResource.serviceAccountId // empty')
    if [[ -n "${EXISTING_AGENT_ID}" && "${EXISTING_AGENT_ID}" != "${BQ_CONNECTION_AGENT_ID}" ]]; then
        echo "    WARNING: Existing connection '${BQ_CONNECTION_ID}' is associated with agent '${EXISTING_AGENT_ID}'," >&2
        echo "             but permissions in Step 6 will be granted to the specified agent '${BQ_CONNECTION_AGENT_ID}'." >&2
        echo "             This may cause errors if the specified agent is incorrect for this connection." >&2
    elif [[ -n "${EXISTING_AGENT_ID}" ]]; then
         echo "    Confirmed: Existing connection is associated with specified agent '${EXISTING_AGENT_ID}'."
    fi
else
     echo "    Creating connection ${BQ_CONNECTION_ID}..."
     CONNECTION_INFO=$(bq mk --connection \
        --project_id="${GCP_PROJECT_ID}" \
        --location="${GCP_REGION}" \
        --connection_type=CLOUD_RESOURCE \
        "${BQ_CONNECTION_ID}" 2>&1)
     echo "$CONNECTION_INFO" # Display the output from bq mk
     NEW_AGENT_ID=$(echo "$CONNECTION_INFO" | grep -oP 'serviceAccountId: \K.*' || true) # Attempt to extract SA from output
     echo "    Connection ${BQ_CONNECTION_ID} created."
     echo "    WARNING: A NEW connection was created. It is likely associated with agent '${NEW_AGENT_ID:-standard service-<proj_num>@... agent}'," >&2
     echo "             but permissions in Step 6 will be granted to the user-specified agent '${BQ_CONNECTION_AGENT_ID}'." >&2
     echo "             Model creation (Step 8) will likely FAIL unless the specified agent was intended for a different, existing connection." >&2
fi


# --- 6. Grant BQ Connection Service Agent Permissions (Impersonation) ---
# *** Uses the user-specified BQ_CONNECTION_AGENT_ID ***
echo ">>> [6/8] Checking/Granting 'Service Account User' role to specified BQ Connection Agent (${BQ_CONNECTION_AGENT_ID}) on User-Managed SA (${CONNECTION_SA_EMAIL})..."
ROLE_TO_CHECK="roles/iam.serviceAccountUser"
MEMBER_TO_CHECK="serviceAccount:${BQ_CONNECTION_AGENT_ID}" # Granting TO the specified agent
RESOURCE_SA_EMAIL="${CONNECTION_SA_EMAIL}" # Granting ON the user-managed SA
NEEDS_ROLE=true

# Ensure the user-managed SA exists
if ! gcloud iam service-accounts describe "${RESOURCE_SA_EMAIL}" --project="${GCP_PROJECT_ID}" &> /dev/null; then
    echo "ERROR: The User-Managed Service Account ${RESOURCE_SA_EMAIL} does not exist. Cannot grant permissions."
    exit 1
fi

# Check if permission already exists (using specified agent)
if [[ "$JQ_INSTALLED" == true ]]; then
    if gcloud iam service-accounts get-iam-policy "${RESOURCE_SA_EMAIL}" --project="${GCP_PROJECT_ID}" --format=json 2>/dev/null | \
       jq -e --arg role "$ROLE_TO_CHECK" --arg member "$MEMBER_TO_CHECK" \
       '.bindings[] | select(.role == $role) | .members[] | select(. == $member)' &> /dev/null; then
        echo "    Role '${ROLE_TO_CHECK}' already granted to ${MEMBER_TO_CHECK} on SA ${RESOURCE_SA_EMAIL}."
        NEEDS_ROLE=false
    fi
fi

# Grant permission (with error handling for propagation delays/non-existence)
if [[ "$NEEDS_ROLE" == true ]]; then
    echo "    Attempting grant: '${ROLE_TO_CHECK}' to '${MEMBER_TO_CHECK}' on SA '${RESOURCE_SA_EMAIL}'..."
    set +e
    gcloud iam service-accounts add-iam-policy-binding "${RESOURCE_SA_EMAIL}" \
        --project="${GCP_PROJECT_ID}" \
        --member="${MEMBER_TO_CHECK}" \
        --role="${ROLE_TO_CHECK}" \
        --condition=None \
        --quiet
    GCLOUD_EXIT_CODE=$?
    set -e

    if [[ $GCLOUD_EXIT_CODE -eq 0 ]]; then
        echo "    Successfully granted '${ROLE_TO_CHECK}' to ${MEMBER_TO_CHECK} on SA ${RESOURCE_SA_EMAIL}."
    else
        echo "    WARNING: Failed to grant '${ROLE_TO_CHECK}' to specified BQ Connection Agent '${MEMBER_TO_CHECK}' (Exit Code: ${GCLOUD_EXIT_CODE})." >&2
        echo "             This might be due to:" >&2
        echo "             1. Propagation delays (if agent was recently created/involved)." >&2
        echo "             2. The specified agent '${MEMBER_TO_CHECK}' does not exist or is incorrect." >&2
        echo "             3. Insufficient permissions for the script runner to modify IAM policies." >&2
        echo "             Common Error: 'Service account ... does not exist.' or 'IAM policy modification failed'." >&2
        echo "             The BQML model creation in the next steps might fail if this permission is missing." >&2
        echo "             Verify the agent ID and manually grant if needed:" >&2
        echo "             'gcloud iam service-accounts add-iam-policy-binding ${RESOURCE_SA_EMAIL} --member=${MEMBER_TO_CHECK} --role=${ROLE_TO_CHECK} --project=${GCP_PROJECT_ID}'" >&2
        echo "    ---> Continuing script execution despite potential permission issue..." >&2
    fi
else
    if [[ "$JQ_INSTALLED" == true ]]; then echo "    Skipping role grant as it already exists."; fi
fi


# --- 7. Grant Current User Permission to USE the Connection ---
echo ">>> [7/8] Checking/Granting 'BigQuery Connection User' role to current user (${CURRENT_USER_EMAIL:-Not Found}) on project ${GCP_PROJECT_ID}..."
# (User permission grant remains the same)
ROLE_TO_CHECK="roles/bigquery.connectionUser"
if [[ -n "$CURRENT_USER_EMAIL" ]]; then
    MEMBER_TO_CHECK="user:${CURRENT_USER_EMAIL}"
    NEEDS_ROLE=true
    # (jq check logic remains the same)
    if [[ "$JQ_INSTALLED" == true ]]; then
        if gcloud projects get-iam-policy "${GCP_PROJECT_ID}" --format=json | \
           jq -e --arg role "$ROLE_TO_CHECK" --arg member "$MEMBER_TO_CHECK" \
           '.bindings[] | select(.role == $role) | .members[] | select(. == $member)' &> /dev/null; then
            echo "    Role '${ROLE_TO_CHECK}' already granted to ${MEMBER_TO_CHECK} on project ${GCP_PROJECT_ID}."
            NEEDS_ROLE=false
        fi
    fi
    # (Grant logic remains the same)
    if [[ "$NEEDS_ROLE" == true ]]; then
         echo "    Granting role '${ROLE_TO_CHECK}' to ${MEMBER_TO_CHECK} on project ${GCP_PROJECT_ID}..."
         echo "    NOTE: This grants the role at the PROJECT level. For more granular control (on the connection itself), use the Cloud Console."
         gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
            --member="${MEMBER_TO_CHECK}" \
            --role="${ROLE_TO_CHECK}" \
            --condition=None
    else
         if [[ "$JQ_INSTALLED" == true ]]; then echo "    Skipping role grant as it already exists at the project level."; fi
    fi
else
    echo "    Could not determine current gcloud user. Skipping automatic grant."
    echo "    Please manually grant the 'BigQuery Connection User' (roles/bigquery.connectionUser)"
    echo "    role to the appropriate user(s) on the connection '${BQ_CONNECTION_REF}' or project '${GCP_PROJECT_ID}'"
fi

# --- Wait for IAM propagation ---
echo ""
echo ">>> Waiting 60 seconds for IAM changes (especially Step 6) to propagate before creating model..."
sleep 60

# --- 8. Create BigQuery ML Model ---
echo ">>> [8/8] Checking/Creating BigQuery ML Model ${BQ_MODEL_REF}..."
echo "    Executing CREATE OR REPLACE MODEL SQL..."
# *** WARNING ADDED regarding potential mismatch ***
echo "    INFO: Creating model using connection '${BQ_CONNECTION_REF}'."
echo "          This will only succeed if this connection exists AND its underlying"
echo "          Google-managed service agent has impersonation permission (granted in Step 6"
echo "          to specified agent '${BQ_CONNECTION_AGENT_ID}'). Check warnings from Step 5 & 6."

cat <<EOF | bq query --project_id="${GCP_PROJECT_ID}" --nouse_legacy_sql
CREATE OR REPLACE MODEL \`${BQ_MODEL_REF}\`
REMOTE WITH CONNECTION \`${BQ_CONNECTION_REF}\`
OPTIONS (endpoint = '${VERTEX_ENDPOINT_URL}');
EOF
echo "    BQML Model ${BQ_MODEL_REF} ensured (or creation attempted)."
echo ""

# --- 9. Output Example BQML Query ---
# (Example query output remains the same)
echo "---------------------------------------------------------------------"
echo ">>> SETUP COMPLETE <<<"
echo "---------------------------------------------------------------------"
# (Example query remains the same)
echo ""
echo "You can now use the BQML model '${BQ_MODEL_REF}' with ML.GENERATE_TEXT."
echo "Example Query (adjust source table and parameters as needed):"
echo ""
cat <<EOF
SELECT
  ml_generate_text_result['predictions'][0]['content'] AS generated_text,
  ml_generate_text_result['predictions'][0]['safetyAttributes'] AS safety_attributes, -- Example: Access safety attributes
  *
FROM ML.GENERATE_TEXT(
  MODEL \`${BQ_MODEL_REF}\`,
  (
    SELECT
      CONCAT('Generate a short, engaging description for a food product: ', products_brand_name, ' ', products_product_name) AS prompt,
      products_id -- Include an ID or unique field if needed for joining back
    FROM \`sandboxportal.sandboxdataset.food_products\` -- <<< CHANGE THIS TABLE if necessary
    WHERE products_brand_name IS NOT NULL AND products_product_name IS NOT NULL
    LIMIT 5 -- <<< Adjust limit as needed
  ),
  STRUCT(
    0.8 AS temperature,      -- Controls randomness (0.0-1.0)
    1024 AS max_output_tokens, -- Max length of generated text
    0.95 AS top_p,           -- Nucleus sampling parameter (0.0-1.0)
    40 AS top_k              -- Top-k sampling parameter (int)
  )
);
EOF
echo ""
echo "---------------------------------------------------------------------"