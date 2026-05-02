import psycopg2
import random
import math

DB_CONFIG = {
    "host": "localhost",
    "port": ****,
    "database": "********",
    "user": "postgres",
    "password": "**************"
}

def normalize_vector(vec):
    magnitude = math.sqrt(sum(x * x for x in vec))
    if magnitude == 0:
        return vec
    return [x / magnitude for x in vec]

def generate_embedding(category, dimensions=128):
    random.seed(hash(category) % 10000)
    base = [random.gauss(0, 1) for _ in range(dimensions)]
    noise = [random.gauss(0, 0.3) for _ in range(dimensions)]
    vec = [b + n for b, n in zip(base, noise)]
    return normalize_vector(vec)

conn = psycopg2.connect(**DB_CONFIG)
cur = conn.cursor()

cur.execute("SELECT product_id, name, category FROM products")
products = cur.fetchall()

print(f"Generating embeddings for {len(products)} products...")

for product_id, name, category in products:
    embedding = generate_embedding(category)
    embedding_str = "[" + ",".join(f"{x:.6f}" for x in embedding) + "]"
    description = f"High quality {category.lower()} product — {name}"

    cur.execute("""
        INSERT INTO product_embeddings
            (product_id, product_name, category, description, embedding)
        VALUES (%s, %s, %s, %s, %s::vector)
    """, (product_id, name, category, description, embedding_str))

conn.commit()

print(f"Inserting 9,900 additional embeddings for similarity search testing...")

categories = ["Electronics", "Clothing", "Books", "Food", "Sports", "Home"]
batch = []

for i in range(9900):
    category = random.choice(categories)
    embedding = generate_embedding(category)
    noise = [x + random.gauss(0, 0.1) for x in embedding]
    embedding = normalize_vector(noise)
    embedding_str = "[" + ",".join(f"{x:.6f}" for x in embedding) + "]"

    batch.append((
        random.randint(1, 100),
        f"Product Variant {i}",
        category,
        f"Variant of {category.lower()} product",
        embedding_str
    ))

    if len(batch) == 1000:
        cur.executemany("""
            INSERT INTO product_embeddings
                (product_id, product_name, category, description, embedding)
            VALUES (%s, %s, %s, %s, %s::vector)
        """, batch)
        conn.commit()
        batch = []
        print(f"  {i+1} variants inserted...")

if batch:
    cur.executemany("""
        INSERT INTO product_embeddings
            (product_id, product_name, category, description, embedding)
        VALUES (%s, %s, %s, %s, %s::vector)
    """, batch)
    conn.commit()

cur.close()
conn.close()
print("Done — 10,000 product embeddings generated.")
