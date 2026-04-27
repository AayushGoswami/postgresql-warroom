 
import psycopg2
import random
from datetime import datetime, timedelta

conn = psycopg2.connect(
    host="localhost",
    port=****,
    database="********",
    user="postgres",
    password="********"
#Replace the *s with your own credentials
)
cur = conn.cursor()

countries = ["India", "USA", "UK", "Germany", "Australia", "Canada", "Japan"]
categories = ["Electronics", "Clothing", "Books", "Food", "Sports", "Home"]
statuses = ["completed", "pending", "cancelled", "refunded"]
regions = ["North", "South", "East", "West", "Central"]

print("Inserting customers...")
for i in range(1, 501):
    cur.execute(
        "INSERT INTO customers (name, email, country) VALUES (%s, %s, %s)",
        (f"Customer {i}", f"customer{i}@example.com", random.choice(countries))
    )

print("Inserting products...")
for i in range(1, 101):
    cur.execute(
        "INSERT INTO products (name, category, price) VALUES (%s, %s, %s)",
        (f"Product {i}", random.choice(categories), round(random.uniform(5.0, 999.99), 2))
    )

conn.commit()

print("Inserting 150,000 order events...")
batch = []
start_date = datetime.now() - timedelta(days=365)

for i in range(150000):
    event_time = start_date + timedelta(
        seconds=random.randint(0, 365 * 24 * 3600)
    )
    qty = random.randint(1, 10)
    price = round(random.uniform(5.0, 999.99), 2)
    batch.append((
        event_time,
        random.randint(1, 500),
        random.randint(1, 100),
        qty,
        round(qty * price, 2),
        random.choice(statuses),
        random.choice(regions)
    ))

    if len(batch) == 5000:
        cur.executemany(
            """INSERT INTO order_events
               (event_time, customer_id, product_id, quantity, total_amount, status, region)
               VALUES (%s, %s, %s, %s, %s, %s, %s)""",
            batch
        )
        conn.commit()
        batch = []
        print(f"  {i+1} rows inserted...")

if batch:
    cur.executemany(
        """INSERT INTO order_events
           (event_time, customer_id, product_id, quantity, total_amount, status, region)
           VALUES (%s, %s, %s, %s, %s, %s, %s)""",
        batch
    )
    conn.commit()

cur.close()
conn.close()
print("Done! 150,000 order events inserted.")