# PRD: Unified Analytics Interface for BigQuery Agent Analytics SDK

**Status:** Draft
**Issue:** [#22](https://github.com/haiyuan-eng-google/BigQuery-Agent-Analytics-SDK/issues/22)
**Author:** SDK Product Team
**Date:** 2026-03-06

---

## 1. Validation & Rationale

### 1.1 Is This a Necessary Update?

**Yes.** The SDK today is a Python-library-only toolkit with 16+ analytical
capabilities (trace retrieval, evaluation, drift detection, insights, context
graphs, etc.), but every one of them requires a user to write Python code and
import the library. This creates three gaps:

| Gap | Who is Affected | Why It Matters |
|-----|----------------|----------------|
| **SQL-native analytics** | Data analysts, BI engineers, Looker/Data Studio users | Cannot run `SELECT analyze(session_id) FROM traces` — must leave BigQuery to run Python |
| **Agent self-diagnostics** | Autonomous AI agents (ADK, LangChain, CrewAI) | Agents cannot inspect their own performance without generating complex SQL; CLIs are the natural LLM tool interface |
| **Automation & CI/CD** | Platform engineers, SRE teams | No scriptable CLI for cron-based eval runs, alerting pipelines, or `git bisect`-style regression checks |

### 1.2 Current State

```
┌──────────────────────────────────────────────────┐
│           BigQuery Agent Analytics SDK           │
│                                                  │
│  Client.get_trace()      Client.evaluate()       │
│  Client.insights()       Client.drift_detection()│
│  Client.doctor()         Client.deep_analysis()  │
│  Client.hitl_metrics()   Client.context_graph()  │
│  ViewManager             BigQueryTraceEvaluator   │
│  TrialRunner             GraderPipeline           │
│  EvalSuite               EvalValidator            │
│  BigQueryMemoryService   BigQueryAIClient         │
│                                                  │
│  ACCESS: Python import ONLY                      │
└──────────────────────────────────────────────────┘
```

### 1.3 Proposed State

```
┌─────────────────────────────────────────────────────────────────┐
│                     Shared Core (Python)                        │
│  Client, evaluators, insights, feedback, trace, context_graph  │
├───────────────────┬──────────────────────┬──────────────────────┤
│  Python Library   │ BigQuery Remote Fn   │  CLI (bq-agent-sdk)  │
│  (existing)       │ (Path A — Scale)     │  (Path B — Agent)    │
│                   │                      │                      │
│  import Client    │ SELECT analyze(...)  │ $ bq-agent-sdk       │
│  Notebooks, apps  │ FROM table           │   get-trace ...      │
│                   │ Looker, Data Studio  │   evaluate ...       │
│                   │ Scheduled queries    │   insights ...       │
└───────────────────┴──────────────────────┴──────────────────────┘
```

---

## 2. User Personas

### Persona A: Priya — Data Analyst (Remote Function Path)

- Works in BigQuery console and Looker daily
- Comfortable with SQL, not with Python notebooks
- Needs to build dashboards showing agent quality metrics
- Wants to run evaluation and insights directly inside scheduled SQL queries

### Persona B: AgentX — Autonomous AI Agent (CLI Path)

- An ADK-based agent deployed in production
- Has tool-calling capability (can invoke shell commands)
- Needs to check its own latency, error rates, and drift before responding
- Must minimize token overhead — CLI commands are cheaper than SQL generation

### Persona C: Marcus — Platform Engineer (CLI Path)

- Manages agent fleet in CI/CD pipelines
- Needs nightly eval runs with pass/fail gates
- Wants `bq-agent-sdk evaluate ... --exit-code` in GitHub Actions
- Pipes output to monitoring systems (Datadog, PagerDuty)

---

## 3. Path A: BigQuery Remote Function Interface

### 3.1 Overview

Deploy the SDK's analytical logic as a Google Cloud Function (or Cloud Run
service), register it as a BigQuery Remote Function, and let SQL users call
SDK features directly from `SELECT` statements.

### 3.2 Supported Operations

| Remote Function | SDK Method | Input | Output |
|----------------|-----------|-------|--------|
| `analyze_session(session_id)` | `Client.get_trace()` + metrics | session_id STRING | JSON with span count, error count, latency, tool calls |
| `evaluate_session(session_id, metric, threshold)` | `CodeEvaluator` | session_id, metric name, threshold | JSON with passed, score, details |
| `judge_session(session_id, criterion)` | `LLMAsJudge` | session_id, criterion | JSON with score, feedback |
| `session_insights(session_id)` | Facet extraction | session_id | JSON with intent, outcome, friction |
| `check_drift(session_id, golden_dataset)` | Drift detection | session_id, golden table | JSON with coverage, gaps |

### 3.3 Critical User Journeys (CUJ)

#### CUJ-A1: Priya Builds an Agent Quality Dashboard

**Goal:** Create a Looker dashboard showing per-session quality scores
updated nightly.

**Journey:**

```
Step 1: Platform team deploys SDK as Cloud Function
        $ gcloud functions deploy bq-agent-analytics \
            --runtime python312 \
            --entry-point handle_request \
            --source ./deploy/remote_function/

Step 2: Platform team registers BigQuery Remote Function
        CREATE FUNCTION `project.analytics.analyze_session`(
          session_id STRING
        ) RETURNS JSON
        REMOTE WITH CONNECTION `project.us.analytics-conn`
        OPTIONS (
          endpoint = 'https://us-central1-project.cloudfunctions.net/bq-agent-analytics'
        );

Step 3: Priya writes a scheduled query (no Python needed)
        -- Nightly materialization of agent quality scores
        CREATE OR REPLACE TABLE `project.analytics.daily_quality` AS
        SELECT
          session_id,
          timestamp,
          agent,
          JSON_VALUE(
            `project.analytics.analyze_session`(session_id),
            '$.error_count'
          ) AS error_count,
          CAST(JSON_VALUE(
            `project.analytics.analyze_session`(session_id),
            '$.avg_latency_ms'
          ) AS FLOAT64) AS avg_latency_ms,
          JSON_VALUE(
            `project.analytics.analyze_session`(session_id),
            '$.tool_call_count'
          ) AS tool_calls
        FROM (
          SELECT DISTINCT session_id, MIN(timestamp) AS timestamp,
                 ANY_VALUE(agent) AS agent
          FROM `project.analytics.agent_events`
          WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
          GROUP BY session_id
        );

Step 4: Priya connects Looker to `daily_quality` table
        → Dashboard shows latency trends, error rates, tool usage by agent
```

**End-to-End Example — Batch Evaluation via SQL:**

```sql
-- Evaluate all sessions from last 24h for latency compliance
WITH recent_sessions AS (
  SELECT DISTINCT session_id
  FROM `myproject.analytics.agent_events`
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
)
SELECT
  s.session_id,
  JSON_VALUE(result, '$.passed') AS passed,
  JSON_VALUE(result, '$.score') AS latency_score,
  JSON_VALUE(result, '$.details') AS details
FROM recent_sessions s,
UNNEST([
  `myproject.analytics.evaluate_session`(
    s.session_id,
    'latency',        -- metric
    '5000'            -- threshold_ms
  )
]) AS result;
```

**Result:**

| session_id | passed | latency_score | details |
|-----------|--------|--------------|---------|
| sess-001 | true | 0.85 | avg_latency_ms=2340, max=4200 |
| sess-002 | false | 0.32 | avg_latency_ms=7800, max=12400 |
| sess-003 | true | 0.91 | avg_latency_ms=1850, max=3100 |

---

#### CUJ-A2: Priya Runs LLM-as-Judge at Scale

**Goal:** Score all sessions for correctness using AI, directly in SQL.

```sql
-- Judge correctness of every session from the "support_bot" agent
SELECT
  session_id,
  CAST(JSON_VALUE(judgment, '$.score') AS FLOAT64) AS correctness_score,
  JSON_VALUE(judgment, '$.passed') AS passed,
  JSON_VALUE(judgment, '$.feedback') AS llm_feedback
FROM (
  SELECT DISTINCT session_id
  FROM `myproject.analytics.agent_events`
  WHERE agent = 'support_bot'
    AND timestamp >= '2026-03-01'
) sessions,
UNNEST([
  `myproject.analytics.judge_session`(
    sessions.session_id,
    'correctness'     -- criterion: correctness | hallucination | sentiment
  )
]) AS judgment
WHERE CAST(JSON_VALUE(judgment, '$.score') AS FLOAT64) < 0.7
ORDER BY correctness_score ASC;
```

**Result:** Surfaces the lowest-quality sessions for human review — no Python
required.

---

#### CUJ-A3: Priya Creates a Drift Alert

**Goal:** Scheduled query that alerts when production questions drift from
golden set.

```sql
-- Weekly drift check: compare production vs golden questions
SELECT
  JSON_VALUE(drift_result, '$.coverage_percentage') AS coverage_pct,
  JSON_VALUE(drift_result, '$.total_golden') AS golden_count,
  JSON_VALUE(drift_result, '$.total_production') AS prod_count,
  JSON_QUERY(drift_result, '$.uncovered_questions') AS gaps
FROM UNNEST([
  `myproject.analytics.check_drift`(
    'myproject.analytics.golden_questions',   -- golden dataset table
    'support_bot',                            -- agent filter
    '2026-03-01',                             -- start date
    '2026-03-06'                              -- end date
  )
]) AS drift_result;
```

---

### 3.4 Remote Function Technical Design

#### Deployment Architecture

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────┐
│   BigQuery      │────▶│  Cloud Function /     │────▶│  BigQuery   │
│   SELECT fn()   │     │  Cloud Run            │     │  (queries)  │
│                 │◀────│  + SDK Core            │◀────│             │
│   Returns JSON  │     │  handle_request()      │     │             │
└─────────────────┘     └──────────────────────┘     └─────────────┘
```

#### Request/Response Contract

**Input** (from BigQuery Remote Function):
```json
{
  "requestId": "...",
  "caller": "bigquery",
  "calls": [
    ["sess-001", "latency", "5000"],
    ["sess-002", "latency", "5000"]
  ]
}
```

**Output** (returned to BigQuery):
```json
{
  "replies": [
    "{\"passed\": true, \"score\": 0.85, \"details\": \"avg=2340ms\"}",
    "{\"passed\": false, \"score\": 0.32, \"details\": \"avg=7800ms\"}"
  ]
}
```

#### Entry Point (`deploy/remote_function/main.py`)

```python
import functions_framework
import json
from bigquery_agent_analytics import Client, CodeEvaluator, LLMAsJudge

# Initialized once per instance (cold start)
client = Client(
    project_id=os.environ["PROJECT_ID"],
    dataset_id=os.environ["DATASET_ID"],
)

@functions_framework.http
def handle_request(request):
    body = request.get_json()
    replies = []
    for call in body["calls"]:
        operation = call[0]
        args = call[1:]
        result = dispatch(operation, args)
        replies.append(json.dumps(result))
    return json.dumps({"replies": replies})

def dispatch(operation, args):
    if operation == "analyze":
        return analyze_session(args[0])
    elif operation == "evaluate":
        return evaluate_session(args[0], args[1], float(args[2]))
    # ... etc
```

---

## 4. Path B: CLI Interface (`bq-agent-sdk`)

### 4.1 Overview

A command-line tool that wraps the SDK's Python API, designed for two primary
consumers:

1. **AI agents** that invoke CLI commands as tools (low token overhead)
2. **Platform engineers** who script evaluation pipelines

### 4.2 Command Structure

```
bq-agent-sdk [GLOBAL OPTIONS] <command> [COMMAND OPTIONS]

Global Options:
  --project-id TEXT       GCP project ID [env: BQ_AGENT_PROJECT]
  --dataset-id TEXT       BigQuery dataset [env: BQ_AGENT_DATASET]
  --table-id TEXT         Events table [default: agent_events]
  --location TEXT         BQ location [default: us-central1]
  --endpoint TEXT         AI.GENERATE endpoint
  --connection-id TEXT    BQ connection ID
  --format TEXT           Output format: json|text|table [default: json]
  --quiet                 Suppress non-essential output

Commands:
  doctor                  Run diagnostic health check
  get-trace               Retrieve and render a trace
  list-traces             List recent traces with filters
  evaluate                Run code-based or LLM evaluation
  insights                Generate insights report
  drift                   Run drift detection against golden set
  distribution            Analyze question distribution
  hitl-metrics            Show HITL interaction metrics
  views                   Manage per-event-type BigQuery views
```

### 4.3 Critical User Journeys (CUJ)

#### CUJ-B1: AgentX Checks Its Own Latency Before Responding

**Context:** An ADK agent has a `before_agent_callback` that shells out to
the CLI to check recent performance. If latency is high, it adjusts its
strategy (e.g., skips expensive tool calls).

**Agent's Tool Definition (ADK tool-calling schema):**
```json
{
  "name": "check_agent_performance",
  "description": "Check this agent's recent latency and error rate",
  "parameters": {
    "type": "object",
    "properties": {
      "session_count": {"type": "integer", "default": 10},
      "metric": {"type": "string", "enum": ["latency", "error_rate", "all"]}
    }
  }
}
```

**Agent Invocation (what the LLM generates):**
```bash
bq-agent-sdk evaluate \
  --project-id=myproject \
  --dataset-id=analytics \
  --agent-id=support_bot \
  --last=1h \
  --evaluator=latency \
  --threshold=5000 \
  --format=json
```

**CLI Output (consumed by the agent):**
```json
{
  "evaluator": "latency",
  "threshold_ms": 5000,
  "total_sessions": 10,
  "passed": 7,
  "failed": 3,
  "pass_rate": 0.70,
  "aggregate_scores": {
    "avg_latency_ms": 3200,
    "max_latency_ms": 8400,
    "p95_latency_ms": 6100
  },
  "failed_sessions": ["sess-042", "sess-047", "sess-051"]
}
```

**Agent's Decision Logic:**
```
IF pass_rate < 0.8:
    → Switch to lighter model (gemini-flash instead of gemini-pro)
    → Skip optional enrichment tool calls
    → Add disclaimer: "Response may be less detailed due to system load"
```

**End-to-End Flow:**
```
User → "What's the refund policy for order #1234?"
       │
       ▼
AgentX (before responding):
  1. Calls: bq-agent-sdk evaluate --agent-id=support_bot --last=1h --evaluator=latency --threshold=5000
  2. Sees: pass_rate=0.70, avg_latency=3200ms
  3. Decides: latency is borderline, use lighter model
  4. Calls: bq-agent-sdk evaluate --agent-id=support_bot --last=1h --evaluator=error_rate --threshold=0.1
  5. Sees: pass_rate=0.95, error_rate=0.05
  6. Decides: errors are fine, proceed normally
       │
       ▼
AgentX → "The refund policy for order #1234 is..."
```

---

#### CUJ-B2: AgentX Retrieves a Past Session for Context

**Context:** A user returns and references a previous conversation. The agent
retrieves the old session trace to understand context.

**Agent Invocation:**
```bash
bq-agent-sdk get-trace \
  --project-id=myproject \
  --dataset-id=analytics \
  --session-id=sess-previous-abc \
  --format=json \
  --quiet
```

**CLI Output:**
```json
{
  "trace_id": "trace-abc-123",
  "session_id": "sess-previous-abc",
  "user_id": "user-42",
  "total_latency_ms": 4500,
  "span_count": 12,
  "tool_calls": [
    {"tool_name": "lookup_order", "args": {"order_id": "1234"}, "status": "OK"},
    {"tool_name": "check_refund_eligibility", "args": {"order_id": "1234"}, "status": "OK"}
  ],
  "final_response": "Your order #1234 is eligible for a full refund...",
  "errors": []
}
```

**Agent uses this context:** "I can see from your previous conversation that
we confirmed order #1234 is eligible for a refund. Let me process that now."

---

#### CUJ-B3: Marcus Runs Nightly Eval in CI/CD

**Goal:** GitHub Actions workflow that gates deployment on evaluation pass rate.

**`.github/workflows/nightly-eval.yml`:**
```yaml
name: Nightly Agent Evaluation
on:
  schedule:
    - cron: '0 2 * * *'  # 2 AM daily

jobs:
  evaluate:
    runs-on: ubuntu-latest
    steps:
      - uses: google-github-actions/auth@v2
        with:
          credentials_json: ${{ secrets.GCP_SA_KEY }}

      - name: Install SDK
        run: pip install bigquery-agent-analytics-sdk[cli]

      - name: Run latency evaluation
        run: |
          bq-agent-sdk evaluate \
            --project-id=${{ vars.GCP_PROJECT }} \
            --dataset-id=analytics \
            --agent-id=support_bot \
            --last=24h \
            --evaluator=latency \
            --threshold=5000 \
            --format=json \
            --exit-code \
          > eval_latency.json

      - name: Run error rate evaluation
        run: |
          bq-agent-sdk evaluate \
            --project-id=${{ vars.GCP_PROJECT }} \
            --dataset-id=analytics \
            --agent-id=support_bot \
            --last=24h \
            --evaluator=error_rate \
            --threshold=0.05 \
            --format=json \
            --exit-code \
          > eval_errors.json

      - name: Run correctness judge
        run: |
          bq-agent-sdk evaluate \
            --project-id=${{ vars.GCP_PROJECT }} \
            --dataset-id=analytics \
            --agent-id=support_bot \
            --last=24h \
            --evaluator=llm-judge \
            --criterion=correctness \
            --threshold=0.7 \
            --format=json \
            --exit-code \
          > eval_correctness.json

      - name: Run drift detection
        run: |
          bq-agent-sdk drift \
            --project-id=${{ vars.GCP_PROJECT }} \
            --dataset-id=analytics \
            --golden-dataset=golden_questions \
            --agent-id=support_bot \
            --last=24h \
            --min-coverage=0.85 \
            --exit-code \
          > drift_report.json

      - name: Generate insights summary
        if: always()
        run: |
          bq-agent-sdk insights \
            --project-id=${{ vars.GCP_PROJECT }} \
            --dataset-id=analytics \
            --agent-id=support_bot \
            --last=24h \
            --max-sessions=50 \
            --format=text \
          > insights_summary.txt

      - name: Upload reports
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: eval-reports
          path: |
            eval_*.json
            drift_report.json
            insights_summary.txt
```

**Key behavior:** `--exit-code` makes the command return exit code 1 when
evaluation fails, causing the CI step to fail and blocking deployment.

---

#### CUJ-B4: Marcus Pipes CLI Output to Monitoring

**Goal:** Feed evaluation results into Slack alerts and Datadog metrics.

```bash
#!/bin/bash
# cron-eval.sh — runs every hour

RESULT=$(bq-agent-sdk evaluate \
  --project-id=myproject \
  --dataset-id=analytics \
  --agent-id=support_bot \
  --last=1h \
  --evaluator=latency \
  --threshold=5000 \
  --format=json)

PASS_RATE=$(echo "$RESULT" | jq -r '.pass_rate')
AVG_LATENCY=$(echo "$RESULT" | jq -r '.aggregate_scores.avg_latency_ms')

# Send to Datadog
curl -X POST "https://api.datadoghq.com/api/v1/series" \
  -H "DD-API-KEY: ${DD_API_KEY}" \
  -d "{
    \"series\": [{
      \"metric\": \"agent.latency.pass_rate\",
      \"points\": [[$(date +%s), $PASS_RATE]],
      \"tags\": [\"agent:support_bot\"]
    }, {
      \"metric\": \"agent.latency.avg_ms\",
      \"points\": [[$(date +%s), $AVG_LATENCY]],
      \"tags\": [\"agent:support_bot\"]
    }]
  }"

# Alert Slack if pass rate drops
if (( $(echo "$PASS_RATE < 0.8" | bc -l) )); then
  curl -X POST "$SLACK_WEBHOOK" \
    -d "{\"text\": \"⚠️ Agent latency pass rate dropped to ${PASS_RATE} (threshold: 0.80). Avg: ${AVG_LATENCY}ms\"}"
fi
```

---

#### CUJ-B5: AgentX Performs Self-Correction Loop

**Context:** An agent notices repeated errors in a session and uses the CLI
to diagnose and adapt in real-time.

**Conversation Flow:**
```
Turn 1: User asks complex multi-step question
Turn 2: Agent calls tool → TOOL_ERROR
Turn 3: Agent calls tool again → TOOL_ERROR
Turn 4: Agent invokes self-diagnostic:

  $ bq-agent-sdk get-trace \
      --project-id=myproject \
      --dataset-id=analytics \
      --session-id=current-session-456 \
      --format=json \
      --quiet

  Output:
  {
    "errors": [
      {"event_type": "TOOL_ERROR", "tool": "database_query",
       "error_message": "Connection timeout after 30s"},
      {"event_type": "TOOL_ERROR", "tool": "database_query",
       "error_message": "Connection timeout after 30s"}
    ],
    "error_count": 2,
    "tool_calls": [
      {"tool_name": "database_query", "status": "ERROR"},
      {"tool_name": "database_query", "status": "ERROR"}
    ]
  }

Turn 5: Agent recognizes "database_query" tool is timing out
         → Switches to cached data source
         → Tells user: "I'm experiencing delays with the live database.
           Let me check the cached data instead."

Turn 6: Agent calls fallback tool → success → responds with answer
```

---

#### CUJ-B6: Marcus Runs Doctor Check Before Deployment

**Goal:** Validate SDK configuration and table health before deploying a new
agent version.

```bash
$ bq-agent-sdk doctor \
    --project-id=myproject \
    --dataset-id=analytics \
    --format=text

╔══════════════════════════════════════════════════╗
║         Agent Analytics Health Check             ║
╠══════════════════════════════════════════════════╣
║ Table: myproject.analytics.agent_events          ║
║ Schema: ✓ OK (16/16 required columns present)   ║
║                                                  ║
║ Event Coverage (last 24h):                       ║
║   USER_MESSAGE_RECEIVED    1,234                 ║
║   LLM_REQUEST              2,456                 ║
║   LLM_RESPONSE             2,450                 ║
║   TOOL_STARTING              890                 ║
║   TOOL_COMPLETED             875                 ║
║   TOOL_ERROR                  15                 ║
║   AGENT_STARTING             620                 ║
║   AGENT_COMPLETED            618                 ║
║   HITL_CONFIRMATION_REQ       42                 ║
║   STATE_DELTA                310                 ║
║                                                  ║
║ AI.GENERATE: ✓ Available (gemini-2.5-flash)      ║
║ Connection:  ✓ us-central1.analytics-conn        ║
║                                                  ║
║ Warnings:                                        ║
║   ⚠ 2 AGENT_STARTING events without matching    ║
║     AGENT_COMPLETED (possible timeout)           ║
║   ⚠ TOOL_ERROR rate: 1.7% (15/890)              ║
╚══════════════════════════════════════════════════╝
```

---

#### CUJ-B7: Marcus Creates BigQuery Views via CLI

```bash
# Create all per-event-type views
$ bq-agent-sdk views create-all \
    --project-id=myproject \
    --dataset-id=analytics \
    --prefix=adk_

Created 15 views:
  ✓ adk_llm_requests
  ✓ adk_llm_responses
  ✓ adk_llm_errors
  ✓ adk_tool_starts
  ✓ adk_tool_completions
  ✓ adk_tool_errors
  ✓ adk_user_messages
  ✓ adk_agent_starts
  ✓ adk_agent_completions
  ✓ adk_invocation_starts
  ✓ adk_invocation_completions
  ✓ adk_state_deltas
  ✓ adk_hitl_credential_requests
  ✓ adk_hitl_confirmation_requests
  ✓ adk_hitl_input_requests

# Create a single view
$ bq-agent-sdk views create LLM_RESPONSE \
    --project-id=myproject \
    --dataset-id=analytics
```

---

### 4.4 CLI Command Reference (Detailed)

#### `bq-agent-sdk get-trace`

```
Usage: bq-agent-sdk get-trace [OPTIONS]

  Retrieve and display a single trace or session.

Options:
  --trace-id TEXT       Retrieve by trace ID
  --session-id TEXT     Retrieve by session ID
  --render              Print hierarchical DAG tree [default: false]
  --format TEXT         json | text | tree [default: json]
```

**Examples:**
```bash
# JSON output for agent consumption
bq-agent-sdk get-trace --session-id=sess-001 --format=json

# Tree rendering for human debugging
bq-agent-sdk get-trace --trace-id=trace-abc --render --format=tree
```

---

#### `bq-agent-sdk list-traces`

```
Usage: bq-agent-sdk list-traces [OPTIONS]

  List recent traces matching filter criteria.

Options:
  --agent-id TEXT       Filter by agent name
  --user-id TEXT        Filter by user ID
  --session-ids TEXT    Comma-separated session IDs
  --last TEXT           Time window: 1h, 24h, 7d, 30d
  --start-time TEXT     ISO8601 start time
  --end-time TEXT       ISO8601 end time
  --has-error           Only sessions with errors
  --no-error            Only sessions without errors
  --min-latency INT     Minimum latency (ms)
  --max-latency INT     Maximum latency (ms)
  --event-types TEXT    Comma-separated event types
  --limit INT           Max traces [default: 20]
  --format TEXT         json | text | table [default: json]
```

**Example:**
```bash
# List error sessions from last hour
bq-agent-sdk list-traces \
  --agent-id=support_bot \
  --last=1h \
  --has-error \
  --format=table

SESSION_ID        SPANS  ERRORS  LATENCY_MS  STARTED_AT
sess-042          15     2       8400        2026-03-06T14:23:00Z
sess-047          8      1       6100        2026-03-06T14:45:00Z
sess-051          22     3       12400       2026-03-06T15:02:00Z
```

---

#### `bq-agent-sdk evaluate`

```
Usage: bq-agent-sdk evaluate [OPTIONS]

  Run code-based or LLM evaluation over traces.

Options:
  --evaluator TEXT      Evaluator type:
                          latency, error_rate, turn_count,
                          token_efficiency, cost,
                          llm-judge
  --threshold FLOAT     Pass/fail threshold
  --criterion TEXT      LLM judge criterion:
                          correctness, hallucination,
                          sentiment, custom
  --custom-prompt TEXT  Custom LLM judge prompt (with --criterion=custom)
  --agent-id TEXT       Filter by agent
  --last TEXT           Time window
  --start-time TEXT     ISO8601 start
  --end-time TEXT       ISO8601 end
  --limit INT           Max sessions [default: 100]
  --exit-code           Return exit code 1 on failure
  --format TEXT         json | text [default: json]
```

**Examples:**
```bash
# Code-based latency check (agent tool call)
bq-agent-sdk evaluate --evaluator=latency --threshold=5000 --agent-id=bot --last=1h

# LLM correctness judge (CI pipeline)
bq-agent-sdk evaluate --evaluator=llm-judge --criterion=correctness \
  --threshold=0.7 --last=24h --exit-code

# Custom LLM judge with user-defined prompt
bq-agent-sdk evaluate --evaluator=llm-judge --criterion=custom \
  --custom-prompt="Rate how well the agent handled PII. Score 0-1." \
  --threshold=0.9 --last=24h
```

---

#### `bq-agent-sdk insights`

```
Usage: bq-agent-sdk insights [OPTIONS]

  Generate comprehensive agent insights report.

Options:
  --agent-id TEXT       Filter by agent
  --last TEXT           Time window
  --max-sessions INT    Max sessions to analyze [default: 50]
  --format TEXT         json | text [default: json]
```

**Example:**
```bash
bq-agent-sdk insights --agent-id=support_bot --last=24h --format=text

══════════════════════════════════════════════════
          Agent Insights — support_bot
══════════════════════════════════════════════════
Sessions analyzed: 48 / 1,234 total

Goal Distribution:
  question_answering    62%  (30 sessions)
  task_automation       25%  (12 sessions)
  data_retrieval        13%  (6 sessions)

Outcome Distribution:
  success               78%
  partial_success       12%
  failure                8%
  abandoned              2%

Top Friction Points:
  1. high_latency         15 sessions (31%)
  2. too_many_tool_calls   8 sessions (17%)
  3. repetitive_responses  4 sessions  (8%)

Executive Summary:
  The support_bot agent shows strong overall performance
  with 78% success rate. Primary area for improvement is
  latency — 31% of sessions experienced high latency,
  particularly in multi-tool workflows. Consider caching
  frequently-accessed data or parallelizing tool calls.
══════════════════════════════════════════════════
```

---

#### `bq-agent-sdk drift`

```
Usage: bq-agent-sdk drift [OPTIONS]

  Run drift detection against a golden question set.

Options:
  --golden-dataset TEXT     Golden questions table (required)
  --agent-id TEXT           Filter by agent
  --last TEXT               Time window
  --embedding-model TEXT    Model for semantic matching
  --min-coverage FLOAT      Minimum coverage to pass [default: 0.0]
  --exit-code               Return exit code 1 if below min-coverage
  --format TEXT             json | text [default: json]
```

---

#### `bq-agent-sdk distribution`

```
Usage: bq-agent-sdk distribution [OPTIONS]

  Analyze question distribution patterns.

Options:
  --mode TEXT           Analysis mode:
                          frequently_asked, frequently_unanswered,
                          auto_group_using_semantics, custom
  --categories TEXT     Comma-separated custom categories (with --mode=custom)
  --top-k INT           Top items per category [default: 10]
  --agent-id TEXT       Filter by agent
  --last TEXT           Time window
  --format TEXT         json | text [default: json]
```

---

## 5. Implementation Roadmap

### Phase 1: Core Refactoring (1 week)

- [ ] Extract filter-building helpers (`--last`, `--agent-id`, etc.) into
      shared utility that constructs `TraceFilter` from CLI args or remote
      function params
- [ ] Ensure all `Client` methods return serializable objects (JSON-safe dicts
      or Pydantic models with `.model_dump()`)
- [ ] Add `--format` output formatting layer (JSON, text table, tree)

### Phase 2: CLI (`bq-agent-sdk`) (2 weeks)

- [ ] Add `click` or `typer` dependency (optional `[cli]` extra)
- [ ] Implement CLI entry point in `pyproject.toml` `[project.scripts]`
- [ ] Implement commands: `doctor`, `get-trace`, `list-traces`, `evaluate`,
      `insights`, `drift`, `distribution`, `hitl-metrics`, `views`
- [ ] Add `--exit-code` support for CI/CD integration
- [ ] Add `--last` time window parser (`1h`, `24h`, `7d`, `30d`)
- [ ] Write CLI integration tests (mock BQ client)
- [ ] Document LLM tool-calling schema for agent integration

### Phase 3: Remote Function (2 weeks)

- [ ] Create `deploy/remote_function/` directory with:
      - `main.py` (functions-framework entry point)
      - `requirements.txt`
      - `deploy.sh` (gcloud deployment script)
      - `register.sql` (CREATE FUNCTION DDL templates)
- [ ] Implement dispatch for: `analyze_session`, `evaluate_session`,
      `judge_session`, `session_insights`, `check_drift`
- [ ] Add Terraform/gcloud deployment automation
- [ ] Write integration tests with BigQuery Remote Function simulator
- [ ] Document deployment guide with prerequisites

### Phase 4: Documentation & Polish (1 week)

- [ ] Update SDK.md with CLI and Remote Function sections
- [ ] Add `examples/cli_agent_tool.py` — example ADK agent using CLI as tool
- [ ] Add `examples/ci_eval_pipeline.sh` — example CI/CD script
- [ ] Add `examples/remote_function_dashboard.sql` — example Looker queries
- [ ] Update README.md with new interfaces

---

## 6. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| CLI adoption | 20% of SDK users use CLI within 3 months | PyPI download stats for `[cli]` extra |
| Remote Function deployments | 10 production deployments within 6 months | Deployment telemetry |
| Agent tool integration | 5 agents use CLI for self-diagnostics | Community feedback / GitHub issues |
| CI/CD integration | 3 orgs use `--exit-code` in pipelines | Community feedback |
| Token savings for agents | 60% fewer tokens vs SQL generation | Benchmarked comparison |

---

## 7. Non-Goals (Out of Scope)

- **Web UI / dashboard** — Use Looker/Data Studio with remote functions instead
- **Real-time streaming** — SDK operates on stored BigQuery data; real-time is
  the plugin's job
- **Agent framework integration** — The CLI is framework-agnostic; specific ADK
  tool wrappers are a separate effort
- **Multi-cloud** — BigQuery-only for now

---

## 8. Open Questions

1. **CLI framework:** `click` vs `typer` — typer has better auto-generated
   help and type inference, but click has broader ecosystem support.
   **Recommendation:** `typer` (better developer experience, auto-complete).

2. **Authentication:** Should the CLI handle `gcloud auth` automatically, or
   require users to have Application Default Credentials configured?
   **Recommendation:** Require ADC; add `bq-agent-sdk auth check` command.

3. **Remote function granularity:** One function per operation vs one
   multiplexed function?
   **Recommendation:** One multiplexed function with operation parameter
   (simpler deployment, single connection).

4. **Versioning:** Should the CLI version be tied to the SDK version?
   **Recommendation:** Yes, single version number for all interfaces.
