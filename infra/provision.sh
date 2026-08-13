#!/usr/bin/env bash
# =============================================================================
# Provisions the Azure side of the system with the az CLI.
#
#   az login
#   ./infra/provision.sh
#
# Idempotent: every command either creates the resource or leaves the existing
# one alone, so re-running after a partial failure is safe.
#
# Cost note: everything here is free tier or the cheapest paid tier that
# supports the feature. Service Bus is Standard because topics require it
# (Basic gives queues only). Oracle is NOT provisioned -- it stays self-hosted
# on the Ubuntu server and the API reaches it over a tunnel. Oracle in Azure
# costs real money and would not make the resume line any more true.
# =============================================================================
set -euo pipefail

LOCATION="${LOCATION:-eastus}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-tutoring-ops}"
PREFIX="${PREFIX:-tutoringops}"
# Storage and Cosmos names must be globally unique and lowercase.
SUFFIX="${SUFFIX:-$(printf '%s' "$RESOURCE_GROUP$PREFIX" | cksum | cut -c1-6)}"

SB_NAMESPACE="${SB_NAMESPACE:-sb-${PREFIX}-${SUFFIX}}"
SB_QUEUE="session-events"
SB_TOPIC="session-notifications"
SUB_REMINDERS="reminders"
SUB_BILLING="billing-updates"

# Not ${PREFIX}: early failed create attempts left the original name behind as
# unrecreatable corpses, so the account name moved on.
COSMOS_ACCOUNT="${COSMOS_ACCOUNT:-cosmos-tutoring-${SUFFIX}}"
# Its own region knob: Cosmos rejects new accounts in a region at "high
# demand" (North Central US did, Aug 2026), and a read model a region over
# is indistinguishable at this scale.
COSMOS_LOCATION="${COSMOS_LOCATION:-$LOCATION}"
COSMOS_DB="tutoring"
COSMOS_CONTAINER="student-dashboards"

# Same story as Cosmos: Linux Consumption was not offered in North Central US
# for this subscription, and a Service Bus trigger does not care which region
# its worker wakes up in.
FUNCTION_LOCATION="${FUNCTION_LOCATION:-$LOCATION}"

STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-st${PREFIX}${SUFFIX}}"
PLAN_NAME="${PLAN_NAME:-plan-${PREFIX}}"
API_APP="${API_APP:-app-${PREFIX}-api-${SUFFIX}}"
UI_APP="${UI_APP:-app-${PREFIX}-ui-${SUFFIX}}"
FUNCTION_APP="${FUNCTION_APP:-func-${PREFIX}-${SUFFIX}}"

echo "Resource group : $RESOURCE_GROUP ($LOCATION)"
echo "Service Bus    : $SB_NAMESPACE"
echo "Cosmos         : $COSMOS_ACCOUNT"
echo "API / UI / Fn  : $API_APP / $UI_APP / $FUNCTION_APP"
echo

az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

# -----------------------------------------------------------------------------
# Service Bus: one queue and one topic with two subscriptions.
#
# The queue is the durable work list -- a consumer added next year still gets
# everything from the moment it subscribes. The topic is how today's two
# consumers each see every message without competing for it.
# -----------------------------------------------------------------------------
echo "--- Service Bus"
az servicebus namespace create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SB_NAMESPACE" \
  --location "$LOCATION" \
  --sku Standard \
  --output none

az servicebus queue create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$SB_NAMESPACE" \
  --name "$SB_QUEUE" \
  --max-delivery-count 10 \
  --default-message-time-to-live P14D \
  --output none

az servicebus topic create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$SB_NAMESPACE" \
  --name "$SB_TOPIC" \
  --default-message-time-to-live P14D \
  --output none

for sub in "$SUB_REMINDERS" "$SUB_BILLING"; do
  az servicebus topic subscription create \
    --resource-group "$RESOURCE_GROUP" \
    --namespace-name "$SB_NAMESPACE" \
    --topic-name "$SB_TOPIC" \
    --name "$sub" \
    --max-delivery-count 10 \
    --enable-dead-lettering-on-message-expiration true \
    --output none
done

# The reminders subscription only wants events a parent should hear about.
# Without this it would also receive completions and package events and have to
# throw most of them away after paying to deliver them.
echo "--- subscription filter on $SUB_REMINDERS"
az servicebus topic subscription rule delete \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$SB_NAMESPACE" \
  --topic-name "$SB_TOPIC" \
  --subscription-name "$SUB_REMINDERS" \
  --name '$Default' \
  --output none 2>/dev/null || true

az servicebus topic subscription rule create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$SB_NAMESPACE" \
  --topic-name "$SB_TOPIC" \
  --subscription-name "$SUB_REMINDERS" \
  --name "parent-facing-events" \
  --filter-sql-expression \
    "eventType IN ('SessionBooked','SessionReminderDue','SessionCancelled','SessionLateCancelled')" \
  --output none

# billing-updates keeps its default rule: the read model should be refreshed
# after anything that can change a balance or a schedule.

SB_CONNECTION="$(az servicebus namespace authorization-rule keys list \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$SB_NAMESPACE" \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv)"

# -----------------------------------------------------------------------------
# Cosmos DB: one container holding one document per student.
# --enable-free-tier is allowed once per subscription; the || true keeps the
# script working on a subscription that has already used it.
# -----------------------------------------------------------------------------
echo "--- Cosmos DB"
az cosmosdb create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$COSMOS_ACCOUNT" \
  --locations regionName="$COSMOS_LOCATION" failoverPriority=0 isZoneRedundant=False \
  --default-consistency-level Session \
  --enable-free-tier true \
  --output none 2>/dev/null || \
az cosmosdb create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$COSMOS_ACCOUNT" \
  --locations regionName="$COSMOS_LOCATION" failoverPriority=0 isZoneRedundant=False \
  --default-consistency-level Session \
  --output none

az cosmosdb sql database create \
  --resource-group "$RESOURCE_GROUP" \
  --account-name "$COSMOS_ACCOUNT" \
  --name "$COSMOS_DB" \
  --output none

# Partition key is the student id: every read is "one student's dashboard",
# so that keeps each query inside a single partition.
az cosmosdb sql container create \
  --resource-group "$RESOURCE_GROUP" \
  --account-name "$COSMOS_ACCOUNT" \
  --database-name "$COSMOS_DB" \
  --name "$COSMOS_CONTAINER" \
  --partition-key-path "/studentId" \
  --throughput 400 \
  --output none

COSMOS_CONNECTION="$(az cosmosdb keys list \
  --resource-group "$RESOURCE_GROUP" \
  --name "$COSMOS_ACCOUNT" \
  --type connection-strings \
  --query "connectionStrings[0].connectionString" -o tsv)"

# -----------------------------------------------------------------------------
# Compute
# -----------------------------------------------------------------------------
echo "--- App Service plan and web apps"
az appservice plan create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PLAN_NAME" \
  --location "$LOCATION" \
  --sku B1 \
  --is-linux \
  --output none

for app in "$API_APP" "$UI_APP"; do
  az webapp create \
    --resource-group "$RESOURCE_GROUP" \
    --plan "$PLAN_NAME" \
    --name "$app" \
    --runtime "DOTNETCORE:8.0" \
    --output none
done

echo "--- storage account and function app"
az storage account create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$STORAGE_ACCOUNT" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --output none

az functionapp create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FUNCTION_APP" \
  --storage-account "$STORAGE_ACCOUNT" \
  --consumption-plan-location "$FUNCTION_LOCATION" \
  --runtime dotnet-isolated \
  --runtime-version 8 \
  --functions-version 4 \
  --os-type Linux \
  --output none

# -----------------------------------------------------------------------------
# Configuration. Secrets are set here and never committed.
# -----------------------------------------------------------------------------
echo "--- app settings"

OPS_KEY="${OPS_KEY:-$(openssl rand -hex 24)}"

az webapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$API_APP" \
  --settings \
    "ServiceBus__ConnectionString=$SB_CONNECTION" \
    "ServiceBus__QueueName=$SB_QUEUE" \
    "ServiceBus__TopicName=$SB_TOPIC" \
    "Ops__ApiKey=$OPS_KEY" \
    "Cors__AllowedOrigins__0=https://${UI_APP}.azurewebsites.net" \
  --output none

echo
echo "!! Set the Oracle connection string by hand -- it points at your tunnel:"
echo "   az webapp config connection-string set -g $RESOURCE_GROUP -n $API_APP \\"
echo "     --connection-string-type Custom \\"
echo "     --settings Oracle='User Id=tutoring;Password=...;Data Source=<tunnel-host>:1521/XEPDB1;'"
echo

az functionapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FUNCTION_APP" \
  --settings \
    "ServiceBusConnection=$SB_CONNECTION" \
    "ServiceBusTopicName=$SB_TOPIC" \
    "ServiceBusRemindersSubscription=$SUB_REMINDERS" \
    "ServiceBusBillingSubscription=$SUB_BILLING" \
    "CosmosConnectionString=$COSMOS_CONNECTION" \
    "CosmosDatabaseName=$COSMOS_DB" \
    "CosmosContainerName=$COSMOS_CONTAINER" \
    "TutoringApiBaseUrl=https://${API_APP}.azurewebsites.net/" \
    "TutoringApiOpsKey=$OPS_KEY" \
  --output none

az webapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$UI_APP" \
  --settings \
    "TutoringApi__BaseUrl=https://${API_APP}.azurewebsites.net/" \
    "Cosmos__ConnectionString=$COSMOS_CONNECTION" \
    "Cosmos__DatabaseName=$COSMOS_DB" \
    "Cosmos__ContainerName=$COSMOS_CONTAINER" \
  --output none

cat <<EOF

Done.

  API       https://${API_APP}.azurewebsites.net
  UI        https://${UI_APP}.azurewebsites.net
  Functions https://${FUNCTION_APP}.azurewebsites.net

Ops key (the API and the Function App share it): $OPS_KEY

Next:
  1. Set the Oracle connection string on $API_APP (see above).
  2. Add these as GitHub repository secrets for the deploy workflow
     (publish profiles, not a service principal -- the student tenant
     refuses app registrations):
       AZURE_API_APP_NAME           $API_APP
       AZURE_UI_APP_NAME            $UI_APP
       AZURE_FUNCTION_APP_NAME      $FUNCTION_APP
       AZURE_API_PUBLISH_PROFILE    az webapp deployment list-publishing-profiles -g $RESOURCE_GROUP -n $API_APP --xml
       AZURE_UI_PUBLISH_PROFILE     az webapp deployment list-publishing-profiles -g $RESOURCE_GROUP -n $UI_APP --xml
       AZURE_FUNCTION_PUBLISH_PROFILE  az functionapp deployment list-publishing-profiles -g $RESOURCE_GROUP -n $FUNCTION_APP --xml
EOF
