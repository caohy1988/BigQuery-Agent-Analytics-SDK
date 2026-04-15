# src/bigquery_agent_analytics/resolved_spec.py
"""Resolved runtime specification built from Ontology + Binding.

A ``ResolvedGraph`` is the internal runtime currency of the SDK. It
fuses an upstream ``Ontology`` (logical schema) with a ``Binding``
(physical mapping) into a single resolved view where:

  - Sources are fully qualified (``project.dataset.table``).
  - Property names are physical column names (from the binding).
  - Key columns are remapped to physical column names.
  - Labels are derived from ``extends`` chains.
  - Lineage session columns are carried as SDK-specific config.
  - Metadata columns (``session_id``, ``extracted_at``) are declared.

The ``resolve()`` builder is the single place where ontology/binding
impedance matching happens. All downstream consumers read resolved
fields without reimplementing the mapping logic.
"""

from __future__ import annotations

import dataclasses
from typing import Optional


@dataclasses.dataclass(frozen=True)
class ResolvedProperty:
  """One property in the resolved runtime view.

  ``column`` is the physical column name (from the binding).
  ``logical_name`` is the ontology property name (may differ from
  column when the binding renames). ``sdk_type`` is the SDK type
  string (e.g. ``"string"``, ``"int64"``, ``"timestamp"``).
  """

  column: str
  logical_name: str
  sdk_type: str
  description: str = ""


@dataclasses.dataclass(frozen=True)
class ResolvedEntity:
  """One entity in the resolved runtime view.

  ``source`` is the fully qualified BigQuery table reference.
  ``key_columns`` are physical column names for the primary key.
  ``labels`` are derived from the entity name and ``extends`` chain.
  ``properties`` are in ontology declaration order.
  ``metadata_columns`` lists runtime columns the SDK injects
  (default: ``session_id``, ``extracted_at``).
  """

  name: str
  source: str
  key_columns: tuple[str, ...]
  labels: tuple[str, ...]
  properties: tuple[ResolvedProperty, ...]
  description: str = ""
  extends: Optional[str] = None
  metadata_columns: tuple[str, ...] = ("session_id", "extracted_at")


@dataclasses.dataclass(frozen=True)
class ResolvedRelationship:
  """One relationship in the resolved runtime view.

  ``from_columns`` / ``to_columns`` are the binding's endpoint join
  columns. ``from_session_column`` / ``to_session_column`` are the
  SDK-specific lineage session overrides (None if not configured).
  ``properties`` are in ontology declaration order.
  """

  name: str
  source: str
  from_entity: str
  to_entity: str
  from_columns: tuple[str, ...]
  to_columns: tuple[str, ...]
  properties: tuple[ResolvedProperty, ...]
  description: str = ""
  from_session_column: Optional[str] = None
  to_session_column: Optional[str] = None
  metadata_columns: tuple[str, ...] = ("session_id", "extracted_at")


@dataclasses.dataclass(frozen=True)
class ResolvedGraph:
  """Complete resolved runtime specification.

  Built once from ``Ontology`` + ``Binding`` via ``resolve()``.
  All downstream SDK modules consume this — extraction, materialization,
  DDL compilation, GQL generation.
  """

  name: str
  entities: tuple[ResolvedEntity, ...]
  relationships: tuple[ResolvedRelationship, ...]
