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

-- Example: Looker/Data Studio dashboard queries using the Remote Function.
--
-- Prerequisites:
--   1. Deploy the remote function (deploy/remote_function/deploy.sh)
--   2. Register it (deploy/remote_function/register.sql)
--
-- Replace PROJECT and DATASET with your values.

-- ------------------------------------------------------------------ --
-- 1. Analyze a specific session                                       --
-- ------------------------------------------------------------------ --

SELECT
  JSON_VALUE(result, '$.trace_id') AS trace_id,
  JSON_VALUE(result, '$.session_id') AS session_id,
  CAST(JSON_VALUE(result, '$.total_latency_ms') AS FLOAT64) AS latency_ms,
  JSON_QUERY(result, '$.spans') AS spans
FROM (
  SELECT
    `PROJECT.DATASET.agent_analytics`(
      'analyze',
      JSON_OBJECT('session_id', session_id)
    ) AS result
  FROM
    `PROJECT.DATASET.agent_events`
  WHERE
    session_id = 'my-session-id'
  LIMIT 1
);


-- ------------------------------------------------------------------ --
-- 2. Evaluate latency across recent sessions                          --
-- ------------------------------------------------------------------ --

SELECT
  JSON_VALUE(result, '$.evaluator_name') AS evaluator,
  CAST(JSON_VALUE(result, '$.total_sessions') AS INT64) AS total,
  CAST(JSON_VALUE(result, '$.passed_sessions') AS INT64) AS passed,
  CAST(JSON_VALUE(result, '$.failed_sessions') AS INT64) AS failed,
  CAST(JSON_VALUE(result, '$.pass_rate') AS FLOAT64) AS pass_rate
FROM (
  SELECT
    `PROJECT.DATASET.agent_analytics`(
      'evaluate',
      JSON'{"metric": "latency", "threshold": 5000, "last": "24h"}'
    ) AS result
);


-- ------------------------------------------------------------------ --
-- 3. Compare evaluators side by side                                  --
-- ------------------------------------------------------------------ --

SELECT
  metric,
  CAST(JSON_VALUE(result, '$.pass_rate') AS FLOAT64) AS pass_rate,
  CAST(JSON_VALUE(result, '$.total_sessions') AS INT64) AS total
FROM
  UNNEST(['latency', 'error_rate', 'ttft', 'cost']) AS metric,
  UNNEST([
    `PROJECT.DATASET.agent_analytics`(
      'evaluate',
      JSON_OBJECT('metric', metric, 'last', '24h')
    )
  ]) AS result;


-- ------------------------------------------------------------------ --
-- 4. Get insights summary                                             --
-- ------------------------------------------------------------------ --

SELECT
  CAST(JSON_VALUE(result, '$.aggregated.total_sessions') AS INT64) AS sessions,
  CAST(JSON_VALUE(result, '$.aggregated.success_rate') AS FLOAT64) AS success_rate,
  CAST(JSON_VALUE(result, '$.aggregated.avg_latency_ms') AS FLOAT64) AS avg_latency,
  CAST(JSON_VALUE(result, '$.aggregated.error_rate') AS FLOAT64) AS error_rate,
  JSON_VALUE(result, '$.executive_summary') AS summary
FROM (
  SELECT
    `PROJECT.DATASET.agent_analytics`(
      'insights',
      JSON'{"last": "7d"}'
    ) AS result
);
