#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

PROJECT="${1:?Usage: deploy.sh PROJECT [REGION] [DATASET]}"
REGION="${2:-us-central1}"
DATASET="${3:-agent_analytics}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Deploying Cloud Function..."
gcloud functions deploy bq-agent-analytics \
  --gen2 --runtime python312 --region "$REGION" \
  --entry-point handle_request \
  --source "$SCRIPT_DIR" \
  --trigger-http --no-allow-unauthenticated \
  --set-env-vars "BQ_AGENT_PROJECT=$PROJECT,BQ_AGENT_DATASET=$DATASET" \
  --memory 512MB --timeout 120s --min-instances 0

echo "==> Creating CLOUD_RESOURCE connection..."
bq mk --connection --location="$REGION" --connection_type=CLOUD_RESOURCE \
  --project_id="$PROJECT" analytics-conn 2>/dev/null || true

echo "==> Granting invoker role to connection SA..."
CONNECTION_SA=$(bq show --connection --format=json \
  "$PROJECT.$REGION.analytics-conn" | jq -r '.cloudResource.serviceAccountId')
gcloud functions add-invoker-policy-binding bq-agent-analytics \
  --region="$REGION" --member="serviceAccount:${CONNECTION_SA}"

ENDPOINT="https://${REGION}-${PROJECT}.cloudfunctions.net/bq-agent-analytics"

echo "==> Done. Register the function with:"
echo ""
echo "  CREATE OR REPLACE FUNCTION \`${PROJECT}.${DATASET}.agent_analytics\`("
echo "    operation STRING, params JSON"
echo "  ) RETURNS JSON"
echo "  REMOTE WITH CONNECTION \`${PROJECT}.${REGION}.analytics-conn\`"
echo "  OPTIONS ("
echo "    endpoint = '${ENDPOINT}',"
echo "    max_batching_rows = 50"
echo "  );"
