"""Страница управления загрузкой (АБД, лаб. 1): SRC -> STAGING -> ODS -> DDS."""
from datetime import date
from pathlib import Path

import streamlit as st

from modules import etl
from modules.db import query_df
from modules.loader import load_csv_to_source

st.set_page_config(page_title="ETL · music_tracks", page_icon="🏗️", layout="wide")
st.title("🏗️ Загрузка данных: SRC → STAGING → ODS → DDS")

CSV_PATH = Path(__file__).resolve().parent.parent / "data" / "music_project.csv"


def run(label, fn, *args):
    try:
        with st.spinner(label):
            res = fn(*args)
        st.success(f"{label}: {res}")
    except Exception as exc:  # noqa: BLE001
        st.error(f"{label}: {exc}")


st.subheader("1. Инициализация и загрузка источника")
c1, c2 = st.columns(2)
if c1.button("Создать схемы, таблицы и функции"):
    run("Инициализация БД", etl.init_db)
if c2.button("Загрузить CSV → src.music_tracks"):
    run("Загрузка CSV", load_csv_to_source, CSV_PATH)

st.subheader("2. STAGING")
if st.button("load_staging()"):
    run("STAGING", etl.load_staging)

st.subheader("3. ODS и DDS за период")
d1, d2 = st.columns(2)
sdt = d1.date_input("p_sdt (начало)", date(2026, 1, 5))
edt = d2.date_input("p_edt (конец)", date(2026, 4, 3))
b1, b2 = st.columns(2)
if b1.button("load_ods(p_sdt, p_edt)"):
    run("ODS", etl.load_ods, sdt, edt)
if b2.button("load_dds(p_sdt, p_edt)"):
    run("DDS", etl.load_dds, sdt, edt)

st.subheader("Контроль: количество строк по слоям")
if st.button("Обновить"):
    try:
        st.dataframe(query_df("""
            SELECT 'src' AS layer, count(*) AS rows FROM src.music_tracks
            UNION ALL SELECT 'stg', count(*) FROM stg.music_tracks
            UNION ALL SELECT 'ods', count(*) FROM ods.music_tracks
            UNION ALL SELECT 'dds.fact_listening', count(*) FROM dds.fact_listening"""),
            hide_index=True)
    except Exception as exc:  # noqa: BLE001
        st.error(exc)
