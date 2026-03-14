-- Copyright 2026 Google LLC
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- Example: Real-time error alerting with continuous queries.
--
-- This example shows how to set up end-to-end real-time alerting
-- for agent errors using BigQuery continuous queries and Pub/Sub.
--
-- Architecture:
--   agent_events (APPENDS) → continuous query → Pub/Sub → alerting
--
-- Prerequisites:
--   1. Enterprise reservation (see deploy/continuous_queries/setup_reservation.md)
--   2. Pub/Sub topic: projects/PROJECT/topics/agent-errors
--   3. Pub/Sub subscription connected to your alerting system
--      (e.g. Cloud Functions → Slack, PagerDuty, etc.)
--
-- Replace PROJECT, DATASET, and TOPIC with your values.


-- ------------------------------------------------------------------ --
-- Step 1: Create the Pub/Sub topic (run once via gcloud)              --
-- ------------------------------------------------------------------ --
--
-- gcloud pubsub topics create agent-errors --project=PROJECT
-- gcloud pubsub subscriptions create agent-errors-sub \
--   --topic=agent-errors --project=PROJECT


-- ------------------------------------------------------------------ --
-- Step 2: Start the continuous query                                  --
-- ------------------------------------------------------------------ --
--
-- Run this with: bq query --use_legacy_sql=false --continuous=true

EXPORT DATA
OPTIONS (
  format = 'CLOUD_PUBSUB',
  uri = 'projects/PROJECT/topics/agent-errors'
)
AS
SELECT
  TO_JSON_STRING(
    STRUCT(
      session_id,
      event_type,
      agent,
      error_message,
      status,
      timestamp,
      -- Include trace context for debugging
      trace_id,
      span_id,
      -- Classify severity based on event type
      CASE
        WHEN event_type = 'TOOL_ERROR' THEN 'high'
        WHEN status = 'ERROR' THEN 'critical'
        WHEN error_message IS NOT NULL THEN 'medium'
        ELSE 'low'
      END AS severity
    )
  ) AS message
FROM
  APPENDS(TABLE `PROJECT.DATASET.agent_events`)
WHERE
  -- Match the SDK's error semantics:
  -- TOOL_ERROR events, status='ERROR', or any row with error_message
  event_type = 'TOOL_ERROR'
  OR status = 'ERROR'
  OR error_message IS NOT NULL;


-- ------------------------------------------------------------------ --
-- Step 3: Monitor the continuous query job                            --
-- ------------------------------------------------------------------ --
--
-- Check running continuous queries:
--
-- SELECT
--   job_id,
--   state,
--   creation_time,
--   TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), creation_time, SECOND) AS running_secs
-- FROM
--   `region-REGION`.INFORMATION_SCHEMA.JOBS
-- WHERE
--   state = 'RUNNING'
--   AND configuration.query.continuous = true
-- ORDER BY
--   creation_time DESC;
