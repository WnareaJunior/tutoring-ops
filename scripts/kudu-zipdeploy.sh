#!/usr/bin/env bash
# =============================================================================
# Deploy a zip to an App Service or Function App through Kudu's zipdeploy API,
# authenticated with the publish profile in $PUBLISH_PROFILE.
#
#   PUBLISH_PROFILE='<publishData>...' ./scripts/kudu-zipdeploy.sh out.zip
#
# Exists because azure/webapps-deploy@v3 rejected these publish profiles with
# an unexplained "profile is invalid" during its local validation, while the
# same credentials deploy fine when you just POST the zip yourself. Failures
# here are HTTP statuses you can read.
# =============================================================================
set -euo pipefail

ZIP="$1"
[[ -f "$ZIP" ]] || { echo "no such zip: $ZIP" >&2; exit 2; }
[[ -n "${PUBLISH_PROFILE:-}" ]] || { echo "PUBLISH_PROFILE is not set" >&2; exit 2; }

read -r SCM_HOST SCM_USER SCM_PASS <<<"$(python3 - <<'PY'
import os, xml.etree.ElementTree as ET
root = ET.fromstring(os.environ['PUBLISH_PROFILE'].strip().lstrip('﻿'))
p = next(p for p in root if p.get('publishMethod') == 'ZipDeploy')
print(p.get('publishUrl').split(':')[0], p.get('userName'), p.get('userPWD'))
PY
)"

echo "deploying $ZIP to $SCM_HOST"

# Async: the POST returns 202 with a Location header to poll, so a slow cold
# Kudu cannot time the upload request out.
LOCATION="$(curl -fsS -u "$SCM_USER:$SCM_PASS" -X POST \
  --data-binary @"$ZIP" -D - -o /dev/null \
  "https://$SCM_HOST/api/zipdeploy?isAsync=true" \
  | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')"

[[ -n "$LOCATION" ]] || { echo "zipdeploy returned no poll Location" >&2; exit 1; }

for _ in $(seq 1 120); do
  STATUS="$(curl -fsS -u "$SCM_USER:$SCM_PASS" "$LOCATION" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status"))')"
  case "$STATUS" in
    4) echo "deployed."; exit 0 ;;                       # Kudu: success
    3) echo "Kudu reports the deployment failed." >&2; exit 1 ;;
  esac
  sleep 5
done

echo "deployment did not finish within 10 minutes" >&2
exit 1
