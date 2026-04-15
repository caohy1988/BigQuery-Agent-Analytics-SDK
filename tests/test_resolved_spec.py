"""Physical-layout equivalence tests for the resolve() builder."""

from __future__ import annotations

import textwrap

from bigquery_ontology import load_binding_from_string
from bigquery_ontology import load_ontology_from_string

from bigquery_agent_analytics.resolved_spec import resolve
from bigquery_agent_analytics.resolved_spec import ResolvedGraph


_ONTOLOGY = textwrap.dedent("""\
  ontology: finance
  entities:
    - name: Account
      keys:
        primary: [account_id]
      properties:
        - name: account_id
          type: string
        - name: opened_at
          type: timestamp
    - name: Security
      keys:
        primary: [security_id]
      properties:
        - name: security_id
          type: string
  relationships:
    - name: HOLDS
      from: Account
      to: Security
      properties:
        - name: quantity
          type: double
""")

_BINDING = textwrap.dedent("""\
  binding: finance-bq-prod
  ontology: finance
  target:
    backend: bigquery
    project: my-proj
    dataset: finance
  entities:
    - name: Account
      source: raw.accounts
      properties:
        - {name: account_id, column: acct_id}
        - {name: opened_at, column: created_ts}
    - name: Security
      source: ref.securities
      properties:
        - {name: security_id, column: cusip}
  relationships:
    - name: HOLDS
      source: raw.holdings
      from_columns: [account_id]
      to_columns: [security_id]
      properties:
        - {name: quantity, column: qty}
""")


def _load():
  ont = load_ontology_from_string(_ONTOLOGY)
  bnd = load_binding_from_string(_BINDING, ontology=ont)
  return ont, bnd


class TestResolveBuilder:

  def test_graph_name(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    assert graph.name == "finance"

  def test_entity_count(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    assert len(graph.entities) == 2

  def test_entity_source_fully_qualified(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    entity_map = {e.name: e for e in graph.entities}
    assert entity_map["Account"].source == "my-proj.raw.accounts"
    assert entity_map["Security"].source == "my-proj.ref.securities"

  def test_entity_key_columns_are_physical(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    entity_map = {e.name: e for e in graph.entities}
    assert entity_map["Account"].key_columns == ("acct_id",)
    assert entity_map["Security"].key_columns == ("cusip",)

  def test_entity_properties_are_physical(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    entity_map = {e.name: e for e in graph.entities}
    acct_cols = [p.column for p in entity_map["Account"].properties]
    assert acct_cols == ["acct_id", "created_ts"]

  def test_entity_properties_preserve_logical_names(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    entity_map = {e.name: e for e in graph.entities}
    logical = [p.logical_name for p in entity_map["Account"].properties]
    assert logical == ["account_id", "opened_at"]

  def test_entity_labels_without_extends(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    entity_map = {e.name: e for e in graph.entities}
    assert entity_map["Account"].labels == ("Account",)

  def test_entity_metadata_columns_default(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    assert graph.entities[0].metadata_columns == ("session_id", "extracted_at")

  def test_relationship_source_fully_qualified(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    holds = graph.relationships[0]
    assert holds.source == "my-proj.raw.holdings"

  def test_relationship_endpoint_columns(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    holds = graph.relationships[0]
    assert holds.from_columns == ("account_id",)
    assert holds.to_columns == ("security_id",)

  def test_relationship_properties_are_physical(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    holds = graph.relationships[0]
    assert holds.properties[0].column == "qty"
    assert holds.properties[0].logical_name == "quantity"

  def test_relationship_no_lineage_by_default(self):
    ont, bnd = _load()
    graph = resolve(ont, bnd)
    holds = graph.relationships[0]
    assert holds.from_session_column is None
    assert holds.to_session_column is None

  def test_lineage_config_applied(self):
    from bigquery_agent_analytics.resolved_spec import LineageEdgeConfig
    ont, bnd = _load()
    lineage = {"HOLDS": LineageEdgeConfig(
        from_session_column="src_sid",
        to_session_column="dst_sid",
    )}
    graph = resolve(ont, bnd, lineage_config=lineage)
    holds = graph.relationships[0]
    assert holds.from_session_column == "src_sid"
    assert holds.to_session_column == "dst_sid"

  def test_resolve_is_deterministic(self):
    ont, bnd = _load()
    g1 = resolve(ont, bnd)
    g2 = resolve(ont, bnd)
    assert g1 == g2
