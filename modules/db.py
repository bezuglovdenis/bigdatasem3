"""Подключение к PostgreSQL. Строка подключения берётся из переменной DATABASE_URL."""
import os
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

DEFAULT_URL = "postgresql+psycopg2://postgres:postgres@localhost:5432/music_dwh"
SQL_DIR = Path(__file__).resolve().parent.parent / "sql"

_engine: Engine | None = None


def get_engine() -> Engine:
    global _engine
    if _engine is None:
        _engine = create_engine(os.getenv("DATABASE_URL", DEFAULT_URL), pool_pre_ping=True)
    return _engine


def run_sql_file(filename: str) -> None:
    """Выполняет SQL-скрипт целиком (DDL + функции)."""
    sql = (SQL_DIR / filename).read_text(encoding="utf-8")
    raw = get_engine().raw_connection()
    try:
        with raw.cursor() as cur:
            cur.execute(sql)
        raw.commit()
    finally:
        raw.close()


def query_df(sql: str, params: dict | None = None) -> pd.DataFrame:
    with get_engine().connect() as conn:
        return pd.read_sql(text(sql), conn, params=params)
