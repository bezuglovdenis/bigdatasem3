"""Вызов SQL-функций конвейера: SRC -> STAGING -> ODS -> DDS."""
from datetime import date

from sqlalchemy import text

from modules.db import get_engine, run_sql_file

SQL_FILES = ["01_source_staging.sql", "02_ods.sql", "03_dds.sql"]


def init_db() -> None:
    for f in SQL_FILES:
        run_sql_file(f)


def load_staging() -> int:
    with get_engine().begin() as conn:
        return conn.execute(text("SELECT stg.load_staging()")).scalar()


def load_ods(p_sdt: date, p_edt: date) -> dict:
    with get_engine().begin() as conn:
        r = conn.execute(text("SELECT * FROM ods.load_ods(:s, :e)"), {"s": p_sdt, "e": p_edt}).one()
    return {"deleted": r[0], "staged": r[1], "inserted": r[2]}


def load_dds(p_sdt: date, p_edt: date) -> dict:
    with get_engine().begin() as conn:
        r = conn.execute(text("SELECT * FROM dds.load_dds(:s, :e)"), {"s": p_sdt, "e": p_edt}).one()
    return {"deleted": r[0], "inserted": r[1]}
