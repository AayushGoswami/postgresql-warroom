# Incident 07 — pgvector AI Similarity Search Optimization

## Symptoms
Customer reports their AI-powered product recommendation feature
is degrading in performance as the product catalog grows.
Similarity search queries are timing out on tables with 10,000+
embeddings. Dashboard showing "similar products" section is slow.

## Environment
- Database: PostgreSQL 18 + TimescaleDB + pgvector [your version]
- Table: product_embeddings (10,000 rows, 128-dimensional vectors)
- Operation: Cosine similarity search using <=> operator
- Index state at incident: None

## Background — What Vector Embeddings Are
Embeddings are numerical representations of text, images, or other
data as high-dimensional vectors. Similar content produces vectors
that are close together in vector space. pgvector enables PostgreSQL
to store and search these vectors natively — powering AI features
like semantic search, recommendations, and RAG applications.

## Diagnosis Steps

### Step 1 — Run EXPLAIN ANALYZE on similarity query
```sql
EXPLAIN ANALYZE
SELECT embedding_id, product_name, category,
       embedding <=> $query_vector AS distance
FROM product_embeddings
ORDER BY embedding <=> $query_vector
LIMIT 10;
```

### Observations BEFORE index
- Scan type: Seq Scan
- Rows scanned: 10000
- Planning time: 0.762 ms
- Execution time: 16.503 ms

## Root Cause
No vector index existed. pgvector performed an exact exhaustive
search across all 10,000 rows for every query — O(n) complexity.
Performance degrades linearly as the table grows.

## Resolution

### Step 1 — IVFFlat Index (Approximate Nearest Neighbor)
```sql
CREATE INDEX idx_embeddings_ivfflat ON product_embeddings
USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);

SET ivfflat.probes = 10;
```

### Step 2 — HNSW Index (Higher Performance Alternative)
```sql
CREATE INDEX idx_embeddings_hnsw ON product_embeddings
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);
```

## Performance Comparison

| Method | Execution Time | Accuracy |
|---|---|---|
| No index (exact) | 17.265 ms | 100% exact |
| IVFFlat (probes=10) | 5..860 ms | ~95% approximate |
| HNSW (m=16) | 1.344 ms | ~98% approximate |

## Index Selection Guide

### Use IVFFlat when:
- Dataset is relatively static (index must be rebuilt if data
  changes significantly)
- Memory is constrained
- Build time matters more than query time

### Use HNSW when:
- Fastest query performance is the priority
- Dataset grows incrementally (handles inserts better)
- Memory is available (HNSW uses more RAM than IVFFlat)

## Advanced — Hybrid SQL + Vector Search
pgvector supports combining vector similarity with standard
SQL filters in a single query:
```sql
SELECT product_name, price, embedding <=> $vec AS distance
FROM product_embeddings pe
JOIN products p ON p.product_id = pe.product_id
WHERE p.price < 500
  AND pe.category = 'Electronics'
ORDER BY distance
LIMIT 5;
```
This powers real-world AI recommendation features where business
rules (price, category, availability) must be combined with
semantic similarity.

## Connection to Tiger Data Agentic PostgreSQL
Tiger Data is building Agentic PostgreSQL — AI agents that
query databases using natural language and vector similarity.
pgvector is the foundational extension enabling this capability.
Optimizing vector search queries is directly relevant to
supporting Tiger Data's next-generation product features.

## Prevention
Always create a vector index before going to production:
- Tables under 1,000 rows: exact search is acceptable, no index needed
- Tables 1,000–1,000,000 rows: IVFFlat with lists = sqrt(row_count)
- Tables over 1,000,000 rows: HNSW with tuned m and ef_construction
- Always benchmark with EXPLAIN ANALYZE before and after