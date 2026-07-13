# manifests/backend/app/app.py
# FastAPI with connection pooling and structured error handling.
# Each uvicorn worker is a separate process — psycopg2 connections are per-process,
# so pool size of 5 * num_workers is a reasonable max_connections ceiling.
 
import os
import logging
import time
from contextlib import asynccontextmanager
 
import psycopg2
from psycopg2 import pool as pg_pool
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import uvicorn
 
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger(__name__)
 
# ─── Config ───────────────────────────────────────────────────────────────────
DB_HOST = os.getenv("DB_HOST", "postgres-service")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "appdb")
DB_USER = os.getenv("DB_USER", "appuser")
DB_PASS = os.getenv("DB_PASS", "apppassword")
POOL_MIN = int(os.getenv("DB_POOL_MIN", "1"))
POOL_MAX = int(os.getenv("DB_POOL_MAX", "5"))
 
# ─── Connection Pool ──────────────────────────────────────────────────────────
_connection_pool: pg_pool.ThreadedConnectionPool | None = None
 
 
def init_pool() -> pg_pool.ThreadedConnectionPool:
    """Initialize connection pool with retry logic for cold-start race conditions."""
    max_retries = 10
    for attempt in range(max_retries):
        try:
            conn_pool = pg_pool.ThreadedConnectionPool(
                minconn=POOL_MIN,
                maxconn=POOL_MAX,
                host=DB_HOST,
                port=DB_PORT,
                dbname=DB_NAME,
                user=DB_USER,
                password=DB_PASS,
                connect_timeout=5,
            )
            logger.info(f"DB pool initialized (min={POOL_MIN}, max={POOL_MAX})")
            return conn_pool
        except psycopg2.OperationalError as e:
            wait = 2 ** attempt
            logger.warning(f"DB connection attempt {attempt+1}/{max_retries} failed: {e}. Retrying in {wait}s")
            time.sleep(wait)
    raise RuntimeError("Could not connect to database after retries")
 
 
@asynccontextmanager
async def lifespan(app: FastAPI):
    global _connection_pool
    _connection_pool = init_pool()
    logger.info("Backend startup complete")
    yield
    if _connection_pool:
        _connection_pool.closeall()
    logger.info("Backend shutdown complete")
 
 
# ─── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(title="Three-Tier Backend", version="1.0.0", lifespan=lifespan)
 
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)
 
 
@app.middleware("http")
async def add_request_timing(request: Request, call_next):
    start = time.time()
    response = await call_next(request)
    duration = (time.time() - start) * 1000
    response.headers["X-Response-Time-ms"] = f"{duration:.2f}"
    return response
 
 
# ─── Health endpoints ─────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    """Liveness probe — is the process alive?"""
    return {"status": "alive", "service": "backend"}
 
 
@app.get("/ready")
async def ready():
    """Readiness probe — can we serve traffic? Requires DB connectivity."""
    if _connection_pool is None:
        raise HTTPException(status_code=503, detail="Connection pool not initialized")
    try:
        conn = _connection_pool.getconn()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        _connection_pool.putconn(conn)
        return {"status": "ready"}
    except Exception as e:
        logger.error(f"Readiness check failed: {e}")
        raise HTTPException(status_code=503, detail=f"DB check failed: {e}")
 
 
# ─── Application endpoints ────────────────────────────────────────────────────
@app.get("/api/items")
async def get_items(limit: int = 50, offset: int = 0):
    conn = _connection_pool.getconn()
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, name, value, created FROM items ORDER BY created DESC LIMIT %s OFFSET %s",
            (min(limit, 500), offset),   # cap at 500 to prevent accidental full scans
        )
        rows = cur.fetchall()
        cur.close()
        return {
            "items": [
                {"id": r[0], "name": r[1], "value": r[2], "created": r[3].isoformat()}
                for r in rows
            ],
            "count": len(rows),
        }
    except Exception as e:
        logger.error(f"GET /api/items failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        _connection_pool.putconn(conn)
 
 
@app.post("/api/items")
async def create_item(name: str, value: str = ""):
    conn = _connection_pool.getconn()
    try:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO items (name, value) VALUES (%s, %s) RETURNING id, created",
            (name, value),
        )
        row = cur.fetchone()
        conn.commit()
        cur.close()
        return {"id": row[0], "name": name, "value": value, "created": row[1].isoformat()}
    except Exception as e:
        conn.rollback()
        logger.error(f"POST /api/items failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        _connection_pool.putconn(conn)
 
 
@app.get("/api/stats")
async def db_stats():
    """Endpoint used by load tests to observe DB behavior under pressure."""
    conn = _connection_pool.getconn()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT
              (SELECT count(*) FROM items) AS item_count,
              (SELECT count(*) FROM pg_stat_activity WHERE datname = %s) AS active_connections,
              (SELECT pg_size_pretty(pg_database_size(%s))) AS db_size
        """, (DB_NAME, DB_NAME))
        row = cur.fetchone()
        cur.close()
        return {
            "item_count": row[0],
            "active_connections": row[1],
            "db_size": row[2],
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        _connection_pool.putconn(conn)
 
 
if __name__ == "__main__":
    uvicorn.run(
        "app:app",
        host="0.0.0.0",
        port=8000,
        workers=4,
        access_log=True,
    )
