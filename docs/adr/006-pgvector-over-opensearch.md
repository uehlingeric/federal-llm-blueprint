# ADR-006: pgvector on RDS Postgres for the Vector Store

**Status:** Accepted  
**Date:** 2026-07-04

## Context

Week 5 introduces the data layer: a vector store to hold embeddings for document similarity search in RAG workloads. The blueprint must choose between two proven patterns for production embedding storage:

1. **pgvector on RDS Postgres:** Add the pgvector extension to the Postgres instance the application already requires for relational state. Single database engine, operator-familiar surface, leverages the KMS + IAM auth patterns from weeks 3–4.

2. **Amazon OpenSearch (or OpenSearch Serverless):** Purpose-built vector engine with managed HNSW and IVF index types, integrated BM25+vector hybrid ranking, connector pipelines for ingestion. No relational workload competition; scales independently.

3. **Amazon Kendra:** Managed enterprise search with native document connectors, ACL-aware retrieval, out-of-the-box ranking. Hides the embedding choice entirely but requires the workload to be document-corpus search, not raw similarity queries.

The choice affects cost, operational surface, team ramp time, and the shape of the backup and scaling strategy. Federal deployments — especially those pursuing ATO assessment — have specific preferences about state surface and assessment burden.

## Decision

**Use pgvector on RDS Postgres 16 (db.t4g.medium instance class for demo, configurable for production). The vector index is colocated with relational state on a single Postgres instance, encrypted with the data CMK, protected by IAM authentication and Secrets Manager credential rotation, and scaled via instance-class upgrades and read replicas if needed.**

### Rationale

**Cost:** A db.t4g.medium RDS instance costs approximately $60/month in us-east-1 (on-demand, single-AZ). A production-grade OpenSearch domain with high availability (3×data nodes + 3×master nodes + 2×warm storage) costs several hundred dollars per month. For a reference blueprint and single-agency use cases (~10⁵–10⁷ vectors across a corpus of thousands of documents), the compute economics favor Postgres by an order of magnitude. Kendra is provisioned by the hour per edition (not per query) and its entry tiers alone exceed the entire RDS line item at this scale, alongside vendor lock-in.

**Operational Surface:** One relational database engine the team already operates (or learns once) for both OLTP state and vector queries. No separate query DSL (OpenSearch Query DSL is Lucene-derived, not SQL); no cluster tuning (shard sizing, node roles, bulk indexing strategies). The week-3 IAM authentication pattern (rds-db:connect token scoped to exact database user + resource ID) works directly. RDS backups are a known commodity: automated daily snapshots, point-in-time restore, cross-region copy (optional).

**Federal Assessment Familiarity:** RDS Postgres has been in commercial AWS FedRAMP assessments for a decade. Security assessors have a clear control story: relational database encryption at rest and in transit, user-based IAM authentication (no API keys), audit logging via CloudTrail and RDS enhanced monitoring. OpenSearch requires a more specialized assessment. Kendra is regional and less familiar to traditional compliance teams.

**Pattern Alignment:** pgvector works alongside the existing stack's encryption discipline (data CMK for storage + KMS calls via VPC endpoint), IAM policy structure (task role grants Bedrock invoke AND rds-db:connect), and secrets management (master password in Secrets Manager with native RDS rotation, no custom Lambda). The architecture adds no new credential-management patterns or out-of-band secret operations.

**Index Performance in the Reference Scope:** pgvector's HNSW index (pgvector 0.5+; RDS PG16 ships a qualifying version) handles approximate nearest-neighbor queries on 10⁵–10⁷ vectors at millisecond-scale latency in the single-instance-class range. Query QPS at this scale is not the bottleneck; corpus size or latency requirements would be. Multi-billion-vector workloads and stringent sub-millisecond p99 targets are the classic triggers to reconsider.

## Consequences

**Scale-Up Path:** Compute and storage grow together on the instance class (e.g., t4g.medium → r7g.xlarge). The HNSW index build is in-memory; class selection must account for `maintenance_work_mem` and `shared_buffers`. If the corpus grows beyond single-instance limits, options are: (1) read replicas for query distribution (read-only, no HNSW writes); (2) sharding by corpus partition at the application layer (complex, not abstracted); (3) eventually, migration to a purpose-built engine (one-time operational lift). These paths are documented in module README and revisit triggers below.

**Relational + Vector Workload Competition:** Both OLTP transactions and vector scans contend for buffer pool, query optimizer time, and CPU. A spike in vector query load may degrade transactional latency. Monitoring (week 6 observability) is critical; the baseline alarms include RDS CPU and connection count. In production, a separate read replica for analytical workloads (vector queries) is recommended.

**HNSW Index Maintenance:** Index builds happen on-demand (CREATE INDEX, or CREATE INDEX CONCURRENTLY for online builds). Rebuilds on large corpora take time and memory. The module documents the cost and recommends scheduling rebuilds during maintenance windows.

**No Managed Ingestion Pipeline:** Unlike OpenSearch connectors or Kendra, pgvector has no built-in document-to-embedding pipeline. The application code (the week-5 proof uses `scripts/seed-vectors.py` run as an in-VPC task) must fetch documents from S3, call a Bedrock Embeddings model, and INSERT the vectors. This is a feature in federal contexts (full audit trail of what was embedded and when), not a bug — ingestion is explicit, not opaque.

**Backup Compliance:** RDS automated backups are encrypted (data CMK) and retained per the policy floor (7 days default). Cross-region snapshot copy is deliberately NOT built in — this is a single-region reference architecture, and cross-region replication is a deployment decision (same posture as the document-store buckets). The proof procedure includes a point-in-time restore drill to measure RTO.

## Alternatives Considered

### Amazon OpenSearch (Standard, Not Serverless)

**Strengths:**
- Purpose-built for similarity and hybrid BM25+vector ranking.
- Horizontal scaling: add data nodes for more vectors, masters for cluster stability.
- No OLTP/OLAP competition: dedicated resource.
- Managed connectors for S3, RSS, web crawl (out-of-the-box ingestion).

**Why rejected for the reference architecture:**
- Cost is 3–5× higher for equivalent query throughput, especially in HA (production minimum is 3×data + 3×master nodes).
- Introduces a second query DSL and cluster-tuning surface the team must learn. Index mapping, shard sizing, segment merging are knobs a federal team likely lacks expertise in.
- Federal ATO: Assessors are less familiar with OpenSearch control stories (encryption at rest, IAM auth, audit logging are all available but less proven at scale in FedRAMP).
- For the ~10⁵–10⁷ vector range typical of a single agency, the extra features (distributed indexing, connector pipelines) are over-specified.

**When to reconsider:** Sustained >~50M vectors on a single corpus; query QPS >100 where single-node HNSW becomes the bottleneck; requirement for hybrid BM25+vector ranking where pgvector's basic text search is insufficient; team already operates OpenSearch elsewhere.

### Amazon OpenSearch Serverless

**Strengths:**
- Same query DSL and features as standard OpenSearch, but managed scaling and no cluster tuning.
- Pay only for API calls and data stored (no idle-node cost).

**Why rejected:**
- Regional availability: Not available in all GovCloud partitions as of 2026-Q2. The reference architecture targets GovCloud for maximum compliance posture; RDS Postgres is available everywhere.
- Cost model unpredictability: Consumption-based pricing is hard to forecast for federal budget cycles. The fixed instance-hour cost of RDS is predictable.
- Same assessment learning curve as standard OpenSearch; serverless does not reduce that.
- Limited customization: Can't tune index parameters or networking like you can with standard OpenSearch.

**When to reconsider:** Bursty, unpredictable query patterns where serverless cost savings clearly beat fixed RDS instance hours; requirement for use-the-latest-models on-demand without reindexing.

### Amazon Kendra

**Strengths:**
- Fully managed enterprise search. No vector engineering; Kendra chooses the embedding model and reindexes on your schedule.
- Native document connectors: drop a data source (S3, SharePoint, web) and Kendra ingests and indexes automatically.
- ACL-aware retrieval: documents inherit permissions from their source system (useful for multi-tenant doc repos).

**Why rejected for the reference architecture:**
- **Architectural mismatch:** Kendra is a document-search product, not a similarity-search engine. It's designed for FAQ retrieval, document knowledge bases, and Q&A. RAG workloads often need finer control: chunk-level embeddings, custom similarity metrics, filtered search (e.g., "embeddings from docs created after 2026-01-01"). Kendra abstracts these away.
- **No raw vector access:** You cannot issue arbitrary nearest-neighbor queries; Kendra mediates all search. This is a feature for compliance (consistent retrieval logic) but limits experimentation and custom ranking.
- **Ingestion model:** Kendra manages embeddings on your behalf. For federal workloads, explicit control over what is indexed, when, and with which model is often a compliance requirement (audit trail). Kendra's opaque ingestion pipeline is a drawback.
- **Cost:** Kendra is provisioned by the hour per edition, not per query; even its entry tiers cost several times the db.t4g.medium instance every month before connector and storage charges. At the reference scope it is the most expensive option evaluated.

**When to reconsider:** The workload is truly document-search (not semantic similarity), the team wants fully managed with minimal embedding expertise, or multi-tenant ACL-aware retrieval is a non-negotiable requirement.

## Revisit Triggers

Monitor these metrics and reconsider the architecture if any trigger is met:

1. **Corpus exceeds 50M vectors** or **p99 query latency exceeds 500ms** on the current instance class. Action: Evaluate read replicas for query distribution, or prototype a migration to OpenSearch.

2. **Hybrid BM25+vector ranking becomes a requirement** for recall or relevance. Action: Evaluate OpenSearch or add a separate search engine.

3. **Team explicitly requests managed ingestion pipelines** (connectors for Sharepoint, GCS, etc.) rather than custom application code. Action: Evaluate Kendra or OpenSearch connectors.

4. **RDS instance cost becomes a budget blocker** relative to other AWS spend. Action: Evaluate cost-per-query for OpenSearch Serverless or Kendra in your query pattern; benchmark.

5. **GovCloud becomes unavailable for the target region.** Action: Kendra or OpenSearch Serverless may offer better regional coverage; re-evaluate.

This architecture choice is not permanent; the module design allows a future migration path (backup the embeddings table, restore to a dedicated Postgres → migrate to OpenSearch, or refactor to external Kendra queries). Document that path in your runbook.
