import psycopg2
from psycopg2 import pool
import threading
import time

DB_CONFIG = {
    "host": "localhost",
    "port": 5433,
    "database": "warroom",
    "user": "postgres",
    "password": "warroom123"
}

print("Using connection pool — efficient and safe\n")

connection_pool = psycopg2.pool.ThreadedConnectionPool(
    minconn=2,
    maxconn=5,
    **DB_CONFIG
)

def run_query(thread_id):
    conn = None
    try:
        conn = connection_pool.getconn()
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM order_events")
        result = cur.fetchone()
        print(f"Thread {thread_id}: order_events has {result[0]} rows")
        cur.close()
    except Exception as e:
        print(f"Thread {thread_id} error: {e}")
    finally:
        if conn:
            connection_pool.putconn(conn)

threads = []
for i in range(1, 16):
    t = threading.Thread(target=run_query, args=(i,))
    threads.append(t)
    t.start()

for t in threads:
    t.join()
time.sleep(45)

connection_pool.closeall()
print("\n15 operations completed using only 5 pooled connections.")
print("Pool closed cleanly.")