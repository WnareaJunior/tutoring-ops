#!/usr/bin/env bash
# =============================================================================
# The stretch scope: Event Grid and APIM.
#
#   ./infra/provision-stretch.sh
#
# Run AFTER infra/provision.sh, and after the Function App and API have been
# deployed at least once. Two steps here bind to things that must already
# exist:
#
#   * the Event Grid subscription targets a specific function by resource id,
#     so PackageExhaustedHandler has to be deployed before it can be subscribed
#   * APIM imports the API from its OpenAPI document, so the API has to be
#     running and reachable at /swagger/v1/swagger.json
#
# Idempotent. Every resource is created-or-left-alone.
#
# Cost: an Event Grid custom topic is effectively free at this volume (the
# first 100k operations a month are). APIM Consumption is per-call with a
# generous free grant. Neither is a standing charge like an App Service plan.
# =============================================================================
set -euo pipefail

# --- inputs this script cannot invent ----------------------------------------
# These have no sensible default. Azure requires a real publisher identity on
# an APIM instance, and a notification with no recipient is not a feature.
: "${APIM_PUBLISHER_EMAIL:?Set APIM_PUBLISHER_EMAIL -- Azure requires a publisher contact on the APIM instance}"
: "${APIM_PUBLISHER_NAME:?Set APIM_PUBLISHER_NAME -- e.g. \"Wilson Narea\"}"
: "${TUTOR_NOTIFICATION_EMAIL:?Set TUTOR_NOTIFICATION_EMAIL -- where the package-exhausted nudge is sent}"

# --- must match what provision.sh used ---------------------------------------
LOCATION="${LOCATION:-eastus}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-tutoring-ops}"
PREFIX="${PREFIX:-tutoringops}"
SUFFIX="${SUFFIX:-$(printf '%s' "$RESOURCE_GROUP$PREFIX" | cksum | cut -c1-6)}"

API_APP="${API_APP:-app-${PREFIX}-api-${SUFFIX}}"
FUNCTION_APP="${FUNCTION_APP:-func-${PREFIX}-${SUFFIX}}"

EG_TOPIC="${EG_TOPIC:-egt-${PREFIX}-${SUFFIX}}"
APIM_NAME="${APIM_NAME:-apim-${PREFIX}-${SUFFIX}}"
APIM_API_ID="tutoring-api"
APIM_PRODUCT_ID="tutoring"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

echo "Resource group : $RESOURCE_GROUP ($LOCATION)"
echo "Event Grid     : $EG_TOPIC"
echo "APIM           : $APIM_NAME  (Consumption)"
echo "API app        : $API_APP"
echo "Function app   : $FUNCTION_APP"
echo

# =============================================================================
# Event Grid
# =============================================================================
echo "--- Event Grid topic"
az eventgrid topic create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$EG_TOPIC" \
  --location "$LOCATION" \
  --output none

EG_ENDPOINT="$(az eventgrid topic show \
  --resource-group "$RESOURCE_GROUP" --name "$EG_TOPIC" \
  --query endpoint -o tsv)"

EG_KEY="$(az eventgrid topic key list \
  --resource-group "$RESOURCE_GROUP" --name "$EG_TOPIC" \
  --query key1 -o tsv)"

EG_TOPIC_ID="$(az eventgrid topic show \
  --resource-group "$RESOURCE_GROUP" --name "$EG_TOPIC" \
  --query id -o tsv)"

echo "--- wiring the API to publish to it"
# Double underscore is how .NET configuration reads nested keys from
# environment variables, so these land on EventGridOptions.
az webapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$API_APP" \
  --settings \
    "EventGrid__TopicEndpoint=$EG_ENDPOINT" \
    "EventGrid__AccessKey=$EG_KEY" \
    "EventGrid__EventTypes__0=PackageExhausted" \
  --output none

echo "--- wiring the handler's recipient"
az functionapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FUNCTION_APP" \
  --settings "TutorNotificationEmail=$TUTOR_NOTIFICATION_EMAIL" \
  --output none

echo "--- subscribing PackageExhaustedHandler to the topic"
FUNCTION_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${FUNCTION_APP}/functions/PackageExhaustedHandler"

if az eventgrid event-subscription create \
      --name "package-exhausted" \
      --source-resource-id "$EG_TOPIC_ID" \
      --endpoint-type azurefunction \
      --endpoint "$FUNCTION_ID" \
      --included-event-types "TutoringOps.PackageExhausted" \
      --max-delivery-attempts 10 \
      --event-ttl 1440 \
      --output none 2>/dev/null
then
    echo "    subscribed."
else
    # Almost always means the function is not deployed yet. Azure validates the
    # endpoint at subscription time, so this cannot be created in advance.
    cat <<EOF
    Could not create the event subscription.

    The usual cause is that PackageExhaustedHandler is not deployed yet --
    Azure validates the endpoint when the subscription is created, so the
    function has to exist first. Deploy the Function App, then re-run this
    script; everything else here is idempotent and will be skipped.
EOF
fi

# =============================================================================
# API Management
# =============================================================================
echo
echo "--- APIM (Consumption). Creation takes a few minutes."

if az apim show --resource-group "$RESOURCE_GROUP" --name "$APIM_NAME" >/dev/null 2>&1; then
    echo "    already exists."
else
    az apim create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$APIM_NAME" \
      --location "$LOCATION" \
      --sku-name Consumption \
      --publisher-email "$APIM_PUBLISHER_EMAIL" \
      --publisher-name "$APIM_PUBLISHER_NAME" \
      --output none
fi

API_URL="https://${API_APP}.azurewebsites.net"

echo "--- importing the API from its OpenAPI document"
# The API serves /swagger/v1/swagger.json in every environment precisely so
# this import works; see the comment in Program.cs.
if ! curl -fsS --max-time 30 "${API_URL}/swagger/v1/swagger.json" >/dev/null; then
    echo "Cannot reach ${API_URL}/swagger/v1/swagger.json." >&2
    echo "Deploy the API first -- APIM imports its operations from that document." >&2
    exit 1
fi

az apim api import \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --api-id "$APIM_API_ID" \
  --path "tutoring" \
  --specification-url "${API_URL}/swagger/v1/swagger.json" \
  --specification-format OpenApiJson \
  --service-url "$API_URL" \
  --protocols https \
  --output none

echo "--- product with a subscription key requirement"
if az apim product show --resource-group "$RESOURCE_GROUP" \
      --service-name "$APIM_NAME" --product-id "$APIM_PRODUCT_ID" >/dev/null 2>&1; then
    echo "    already exists."
else
    az apim product create \
      --resource-group "$RESOURCE_GROUP" \
      --service-name "$APIM_NAME" \
      --product-id "$APIM_PRODUCT_ID" \
      --product-name "Tutoring Operations" \
      --description "Scheduling and billing API." \
      --subscription-required true \
      --approval-required false \
      --state published \
      --output none
fi

az apim product api add \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --product-id "$APIM_PRODUCT_ID" \
  --api-id "$APIM_API_ID" \
  --output none

echo "--- applying the rate-limit policy"
# The CLI has no first-class command for API policy, so this goes through the
# management API directly. python3 does the JSON escaping because the policy is
# XML and hand-escaping it into a JSON string in bash is a reliable way to
# produce something subtly wrong.
POLICY_BODY="$(mktemp)"
trap 'rm -f "$POLICY_BODY"' EXIT

python3 - "$HERE/apim-policy.xml" "$POLICY_BODY" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    policy = fh.read()
with open(sys.argv[2], 'w', encoding='utf-8') as fh:
    json.dump({"properties": {"format": "xml", "value": policy}}, fh)
PY

az rest --method put \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/apis/${APIM_API_ID}/policies/policy?api-version=2022-08-01" \
  --headers "Content-Type=application/json" \
  --body "@${POLICY_BODY}" \
  --output none

echo "--- creating a subscription key"
az apim product subscription create \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --product-id "$APIM_PRODUCT_ID" \
  --name "primary" \
  --display-name "Primary key" \
  --output none 2>/dev/null || echo "    already exists."

APIM_GATEWAY="$(az apim show --resource-group "$RESOURCE_GROUP" --name "$APIM_NAME" \
  --query gatewayUrl -o tsv)"

SUB_KEY="$(az rest --method post \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/primary/listSecrets?api-version=2022-08-01" \
  --query primaryKey -o tsv 2>/dev/null || echo "")"

cat <<EOF

Done.

  Event Grid topic : $EG_ENDPOINT
  APIM gateway     : $APIM_GATEWAY/tutoring

Try it. Without a key this must be rejected:

    curl -i "$APIM_GATEWAY/tutoring/health"

With one it should pass through:

    curl -i "$APIM_GATEWAY/tutoring/health" \\
      -H "Ocp-Apim-Subscription-Key: ${SUB_KEY:-<key>}"

And the rate limit, which should start returning 429 after 60 in a minute:

    for i in \$(seq 1 70); do
      curl -s -o /dev/null -w "%{http_code} " "$APIM_GATEWAY/tutoring/health" \\
        -H "Ocp-Apim-Subscription-Key: ${SUB_KEY:-<key>}"
    done; echo

To see the Event Grid path end to end, book sessions until a student's package
hits zero, then check the Function App logs for PackageExhaustedHandler.
EOF
