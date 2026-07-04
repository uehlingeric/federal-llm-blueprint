#!/usr/bin/env python3
"""
Proof-of-concept pgvector bootstrap and seed script.

Validates that pgvector works end-to-end in the vector store: creates the
embeddings table with an HNSW index, inserts deterministic sample vectors, and
runs a cosine-similarity query. See docs/verification/vector-proof.md for the
full verification procedure.

Configuration from environment variables:
  DB_HOST (required), DB_PORT (5432), DB_NAME (vectordb), DB_USER (app_user),
  AUTH_MODE (iam | password), DB_PASSWORD (password mode only), AWS_REGION,
  SSL_CERT_PATH (/tmp/rds-bundle.pem for IAM mode).
"""

import os
import sys

try:
    import psycopg
    import numpy as np
except ImportError as e:
    print(f"[seed] ERROR: Missing required package: {e}")
    print("[seed] Install with: pip install 'psycopg[binary]' boto3 numpy")
    sys.exit(1)


def generate_iam_auth_token() -> str:
    """Generate RDS IAM authentication token (valid for 15 minutes)."""
    try:
        import boto3
    except ImportError:
        print("[seed] ERROR: boto3 required for IAM auth mode")
        sys.exit(1)

    region = os.getenv("AWS_REGION", "us-east-1")
    host = os.getenv("DB_HOST")
    port = os.getenv("DB_PORT", "5432")
    user = os.getenv("DB_USER", "app_user")

    client = boto3.client("rds", region_name=region)
    token = client.generate_db_auth_token(
        DBHostname=host, Port=int(port), DBUser=user, Region=region
    )
    return token


def get_connection() -> psycopg.Connection:
    """Establish database connection with password or IAM auth."""
    host = os.getenv("DB_HOST")
    if not host:
        print("[seed] ERROR: DB_HOST environment variable not set")
        sys.exit(1)

    port = int(os.getenv("DB_PORT", "5432"))
    db_name = os.getenv("DB_NAME", "vectordb")
    user = os.getenv("DB_USER", "app_user")
    auth_mode = os.getenv("AUTH_MODE", "iam")

    print(f"[seed] Connecting to {host}:{port}/{db_name} (auth={auth_mode})")

    if auth_mode == "iam":
        password = generate_iam_auth_token()
        ssl_cert = os.getenv("SSL_CERT_PATH", "/tmp/rds-bundle.pem")
        if not os.path.exists(ssl_cert):
            print(f"[seed] Downloading RDS bundle to {ssl_cert}")
            import urllib.request
            urllib.request.urlretrieve(
                "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem",
                ssl_cert,
            )
        conn = psycopg.connect(
            host=host,
            port=port,
            dbname=db_name,
            user=user,
            password=password,
            sslmode="verify-full",
            sslrootcert=ssl_cert,
        )
    else:
        password = os.getenv("DB_PASSWORD")
        if not password:
            print("[seed] ERROR: DB_PASSWORD required for password auth mode")
            sys.exit(1)
        conn = psycopg.connect(
            host=host, port=port, dbname=db_name, user=user, password=password
        )

    print("[seed] Connection established")
    return conn


def create_table(conn: psycopg.Connection) -> None:
    """Create embeddings table if it does not exist."""
    with conn.cursor() as cur:
        print("[seed] Creating embeddings table (idempotent)")
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS embeddings (
                id bigserial PRIMARY KEY,
                doc_id text NOT NULL,
                chunk text NOT NULL,
                embedding vector(8)
            )
            """
        )

        print("[seed] Creating HNSW index for cosine distance (idempotent)")
        cur.execute(
            """
            CREATE INDEX IF NOT EXISTS embeddings_embedding_hnsw
            ON embeddings USING hnsw (embedding vector_cosine_ops)
            """
        )
        conn.commit()
        print("[seed] Table and HNSW index created/verified")


def seed_vectors(conn: psycopg.Connection) -> None:
    """Truncate and insert 8 deterministic sample vectors."""
    with conn.cursor() as cur:
        print("[seed] Truncating embeddings table")
        cur.execute("TRUNCATE TABLE embeddings")

        print("[seed] Inserting 8 sample vectors (8-dimensional proof-of-concept)")
        # Fixed seed for reproducibility; real embeddings are 256–3072 dims
        rng = np.random.RandomState(42)
        samples = [
            ("doc_1", "chunk_1", rng.randn(8).tolist()),
            ("doc_1", "chunk_2", rng.randn(8).tolist()),
            ("doc_2", "chunk_1", rng.randn(8).tolist()),
            ("doc_2", "chunk_2", rng.randn(8).tolist()),
            ("doc_3", "chunk_1", rng.randn(8).tolist()),
            ("doc_3", "chunk_2", rng.randn(8).tolist()),
            ("doc_4", "chunk_1", rng.randn(8).tolist()),
            ("doc_4", "chunk_2", rng.randn(8).tolist()),
        ]

        for doc_id, chunk, embedding in samples:
            # Insert as string literal: pgvector parses "[0.1, 0.2, ...]"
            emb_str = "[" + ",".join(f"{x:.6f}" for x in embedding) + "]"
            cur.execute(
                "INSERT INTO embeddings (doc_id, chunk, embedding) VALUES (%s, %s, %s)",
                (doc_id, chunk, emb_str),
            )

        conn.commit()
        print(f"[seed] Inserted {len(samples)} vectors")


def query_neighbors(conn: psycopg.Connection) -> None:
    """Query 3 nearest neighbors via cosine similarity and verify."""
    with conn.cursor() as cur:
        # Fixed probe vector (first vector from the seed set)
        rng = np.random.RandomState(42)
        probe = rng.randn(8)
        probe_str = "[" + ",".join(f"{x:.6f}" for x in probe) + "]"

        print("[seed] Querying 3 nearest neighbors to probe vector")
        cur.execute(
            """
            SELECT id, doc_id, chunk, embedding <=> %s::vector AS distance
            FROM embeddings
            ORDER BY embedding <=> %s::vector
            LIMIT 3
            """,
            (probe_str, probe_str),
        )

        results = cur.fetchall()
        if not results:
            print("[seed] ERROR: No results returned from query")
            sys.exit(1)

        print("[seed] Query results:")
        for id_, doc_id, chunk, distance in results:
            print(f"  [seed]   id={id_}, doc_id={doc_id}, chunk={chunk}, distance={distance:.6f}")

        # Verify: first result should have id=1 (doc_1, chunk_1, the exact probe vector)
        if results[0][0] != 1:
            print(
                f"[seed] ERROR: Expected nearest neighbor id=1, got id={results[0][0]}"
            )
            sys.exit(1)

        print("[seed] ✓ Nearest neighbor assertion passed (id=1 is closest)")


def main() -> None:
    """Main seed workflow."""
    try:
        conn = get_connection()
        create_table(conn)
        seed_vectors(conn)
        query_neighbors(conn)
        conn.close()
        print("[seed] SUCCESS: pgvector bootstrap complete")
        sys.exit(0)
    except Exception as e:
        print(f"[seed] ERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
