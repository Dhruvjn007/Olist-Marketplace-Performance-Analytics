"""
config.py - the ONLY file you need to edit.
Put the same details you use to log in to pgAdmin.
"""
from urllib.parse import quote_plus

DB_HOST = "server"
DB_PORT = 5432
DB_USER = "postgres"
DB_PASSWORD = "password"  # <-- change this
DB_NAME = "dataset"                    # create this empty database in pgAdmin first

DATABASE_URL = f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
