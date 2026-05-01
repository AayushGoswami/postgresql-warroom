import psycopg2
import time

DB_CONFIG = {
    "host": "localhost",
    "port": ****,
    "database": "*********",
    "user": "postgres",
    "password": "***********"
}
#Replace the *s with your own credentials

connections = []

print("Simulating connection leak — opening connections without closing them...")
print("Watch your pg_stat_activity in another window!\n")

for i in range(1, 25):
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        connections.append(conn)
        print(f"Connection {i} opened successfully")
        time.sleep(0.5)
    except psycopg2.OperationalError as e:
        print(f"\nConnection {i} FAILED:")
        print(f"Error: {e}")
        print("\nDatabase is now exhausted — no new connections accepted.")
        break

print(f"\nTotal connections leaked: {len(connections)}")
print("Connections are still open and holding resources...")
time.sleep(45)

print("\nCleaning up — closing all connections")
for conn in connections:
    try:
        conn.close()
    except:
        pass
print("Done.")
