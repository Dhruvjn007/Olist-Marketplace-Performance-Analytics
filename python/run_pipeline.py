"""
run_pipeline.py
---------------
One command builds the whole project from the raw CSVs:

  1. creates the staging tables       (sql/01_staging_tables.sql)
  2. loads the 9 CSVs into them       (done here in Python, replaces sql/02)
  3. runs data-quality checks         (sql/03)
  4. builds the star schema           (sql/04)
  5. runs the 3 analyses              (sql/05, 06, 07)
  6. exports results + charts         (python/export_results.py)

Usage (from the project folder):
    pip install -r requirements.txt
    python python/run_pipeline.py

Connection details live in python/config.py - edit the password there.
The database "olist" must already exist (create it in pgAdmin).
"""

import time
from pathlib import Path

import psycopg

import export_results
from config import DATABASE_URL, DB_HOST, DB_NAME, DB_PORT, DB_USER

ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "sql"
DATA = ROOT / "data"

# staging table  ->  CSV file
CSV_FILES = {
    "staging.customers":            "olist_customers_dataset.csv",
    "staging.geolocation":          "olist_geolocation_dataset.csv",
    "staging.order_items":          "olist_order_items_dataset.csv",
    "staging.order_payments":       "olist_order_payments_dataset.csv",
    "staging.order_reviews":        "olist_order_reviews_dataset.csv",
    "staging.orders":               "olist_orders_dataset.csv",
    "staging.products":             "olist_products_dataset.csv",
    "staging.sellers":              "olist_sellers_dataset.csv",
    "staging.category_translation": "product_category_name_translation.csv",
}


def run_sql_file(conn, name: str) -> None:
    """Run every statement in a .sql file."""
    start = time.time()
    conn.execute((SQL / name).read_text(encoding="utf-8"))
    print(f"  {name:<30} done in {time.time() - start:.1f}s")


def load_csvs(conn) -> None:
    """Stream each CSV into its staging table with Postgres COPY (fast bulk load)."""
    missing = [f for f in CSV_FILES.values() if not (DATA / f).exists()]
    if missing:
        raise SystemExit(f"Missing CSVs in data/: {missing}\nDownload the Olist dataset from Kaggle first.")

    for table, file in CSV_FILES.items():
        # utf-8-sig strips the hidden BOM character at the start of one of the files
        with open(DATA / file, encoding="utf-8-sig") as f, conn.cursor() as cur:
            with cur.copy(f"COPY {table} FROM STDIN WITH (FORMAT csv, HEADER true)") as copy:
                while chunk := f.read(1 << 20):          # 1 MB at a time
                    copy.write(chunk)
            rows = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        print(f"  {table:<30} {rows:>9,} rows")


def main() -> None:
    print(f"Connecting to {DB_HOST}:{DB_PORT}/{DB_NAME} as {DB_USER} ...")
    with psycopg.connect(DATABASE_URL, autocommit=True) as conn:
        print("1. Staging tables")
        run_sql_file(conn, "01_staging_tables.sql")
        print("2. Loading CSVs")
        load_csvs(conn)
        print("3-5. Quality checks, star schema, analyses")
        for name in ["03_data_quality_checks.sql", "04_star_schema.sql",
                     "05_mom_growth.sql", "06_rfm_segmentation.sql", "07_delivery_delay.sql"]:
            run_sql_file(conn, name)

    print("6. Exporting results and charts")
    export_results.main()


if __name__ == "__main__":
    main()
