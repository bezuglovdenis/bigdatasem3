"""Страница «Исследовательский анализ данных» (ВОиАД, лаб. 1)."""
from pathlib import Path

import pandas as pd
import plotly.express as px
import streamlit as st

from modules import eda_utils as eu
from modules.loader import read_raw_csv

st.set_page_config(page_title="EDA · music_tracks", page_icon="🔎", layout="wide")
st.title("🔎 Исследовательский анализ данных: music_tracks")

CSV_PATH = Path(__file__).resolve().parent.parent / "data" / "music_project.csv"


@st.cache_data(show_spinner="Загрузка данных…")
def load_raw(uploaded=None) -> pd.DataFrame:
    # данные читаются «как есть» (то же, что попадает в src.music_tracks)
    return read_raw_csv(uploaded if uploaded is not None else CSV_PATH)


with st.sidebar:
    st.header("Источник")
    up = st.file_uploader("Другой CSV (необязательно)", type="csv")
df = load_raw(up)
n = len(df)

# ------------------------------------------------------------------ 1. Общие показатели
st.header("1. Общие показатели источника")
dups = eu.full_duplicates(df)
c1, c2, c3, c4, c5 = st.columns(5)
c1.metric("Записей", f"{n:,}".replace(",", " "))
c2.metric("Атрибутов", df.shape[1])
c3.metric("Полных дубликатов", f"{int(dups.sum()):,}".replace(",", " "), f"{dups.mean()*100:.1f}%")
c4.metric("Строк с пропуском", f"{int(df[['track','artist','genre']].isna().any(axis=1).sum()):,}".replace(",", " "))
c5.metric("Пользователей (userID)", f"{df['user_id'].nunique():,}".replace(",", " "))
st.caption("Колонка `row_id` (в файле — безымянный индекс) — технический номер строки и в анализе дублей не участвует. "
           "В заголовке файла есть пробелы (`  userID`, `  City  `) — нормализуются при загрузке.")

# ------------------------------------------------------------------ 2. Структура и заполненность
st.header("2. Структура, типы и заполненность")
prof = eu.column_profile(df)
st.dataframe(prof, use_container_width=True, hide_index=True)
col_a, col_b = st.columns(2)
with col_a:
    fig = px.bar(prof[prof["пропусков"] > 0], x="колонка", y="доля пропусков, %", text="доля пропусков, %",
                 title="Доля пропущенных значений по колонкам")
    st.plotly_chart(fig, use_container_width=True)
with col_b:
    st.subheader("Комбинации пропусков")
    st.dataframe(eu.missing_patterns(df), use_container_width=True, hide_index=True)
    st.caption("661 строка не содержит ни трека, ни исполнителя, ни жанра — осмысленной информации в ней нет, кроме пользователя и времени.")

# ------------------------------------------------------------------ 3. Дубликаты
st.header("3. Дубликаты")
pd_stats = eu.potential_duplicates(df)
d1, d2, d3 = st.columns(3)
d1.metric("Полные дубли (все поля, кроме row_id)", pd_stats["full"])
d2.metric("Совпадение user+track+artist+time+day", pd_stats["same_without_genre_city"],
          help="отличаются только жанром/городом — потенциальные дубли")
d3.metric("Один user в одно и то же время, разные записи", pd_stats["same_user_moment_other_track"],
          help="один пользователь не может слушать несколько разных треков одновременно")
top_dup = (df[dups | df.duplicated(eu.BUSINESS_COLS, keep=False)]
           .groupby(eu.BUSINESS_COLS, dropna=False).size().reset_index(name="повторов")
           .sort_values("повторов", ascending=False).head(15))
st.write("Наиболее повторяющиеся записи")
st.dataframe(top_dup, use_container_width=True, hide_index=True)

# ------------------------------------------------------------------ 4. Распределения
st.header("4. Распределения признаков")
tab_cat, tab_time, tab_len = st.tabs(["Категориальные", "Время", "Длина строк"])
with tab_cat:
    cat_col = st.selectbox("Признак", ["genre", "artist", "city", "day_name", "track", "user_id"])
    top_n = st.slider("Сколько значений показать (top-N)", 5, 50, 15)
    vc = df[cat_col].value_counts(dropna=False).head(top_n).rename_axis(cat_col).reset_index(name="кол-во")
    vc[cat_col] = vc[cat_col].astype(str)
    st.plotly_chart(px.bar(vc, x="кол-во", y=cat_col, orientation="h", title=f"Top-{top_n}: {cat_col}")
                    .update_yaxes(autorange="reversed"), use_container_width=True)
    st.caption(f"Уникальных значений: {df[cat_col].nunique()}; значение NaN учтено как отдельная категория.")
with tab_time:
    hours = pd.to_numeric(df["listen_time"].str[:2], errors="coerce")
    st.plotly_chart(px.histogram(hours, nbins=24, title="Прослушивания по часам суток",
                                 labels={"value": "час"}), use_container_width=True)
    st.write(f"Диапазон времени: **{df['listen_time'].min()} – {df['listen_time'].max()}**. "
             "Дней недели в данных всего три (Monday, Wednesday, Friday) — это выборка, а не полный календарь.")
with tab_len:
    len_col = st.selectbox("Колонка для длины строки", ["track", "artist", "genre", "user_id"])
    lens = df[len_col].dropna().str.len()
    log_y = st.checkbox("Логарифмическая шкала", value=True)
    st.plotly_chart(px.histogram(lens, nbins=60, log_y=log_y, title=f"Длина значений: {len_col}"),
                    use_container_width=True)

# ------------------------------------------------------------------ 5. Выбросы и форматы
st.header("5. Выбросы, некорректные форматы и противоречия")
tl = df["track"].dropna().str.len()
thr = st.slider("Порог аномальной длины названия трека (символов)", 50, 500, 200)
o1, o2, o3 = st.columns(3)
o1.metric("Медиана длины трека", int(tl.median()))
o2.metric(f"Треков длиннее {thr}", int((tl > thr).sum()))
o3.metric("Максимальная длина", int(tl.max()))
st.dataframe(df.loc[tl[tl > thr].index, ["row_id", "track"]].assign(длина=tl[tl > thr]).sort_values("длина", ascending=False).head(10),
             use_container_width=True, hide_index=True)

st.subheader("Некорректные форматы")
st.dataframe(eu.format_checks(df), use_container_width=True, hide_index=True)
st.caption("`user_id` должен быть 8-символьным HEX; более короткие значения — вероятно, потеряны ведущие нули "
           "(типичный эффект при открытии CSV в табличном редакторе).")

st.subheader("Потенциально противоречивые значения")
ct = eu.contradictions(df)
k1, k2, k3 = st.columns(3)
k1.metric("Пользователей более чем в одном городе", ct["users_in_several_cities"])
k2.metric("Треков с несколькими жанрами", ct["tracks_with_several_genres"])
k3.metric("Жанр `hip` / `hiphop`", f'{ct["hip_vs_hiphop"]["hip"]} / {ct["hip_vs_hiphop"]["hiphop"]}',
          help="`hip` — вероятно, обрезанное `hip-hop`")
st.caption("Жанр `hip` (3147 записей) и `hiphop` (88) — один жанр в двух написаниях. Жанров 287, при этом "
           "85 из них (≈30%) встречаются по 1–2 раза — «хвост» редких и шумных значений "
           "(`электроника`, `ïîï` — битая кодировка).")

# ------------------------------------------------------------------ 6. Проблемы
st.header("6. Выявленные проблемы качества данных")
problems = pd.DataFrame([
    ("R1", "Полные дубликаты", f"{pd_stats['full']} строк", "Высокая"),
    ("R2", "Лишние пробелы в track/artist", "32 / 36 строк", "Низкая"),
    ("R3", "userID короче 8 символов (потеряны ведущие нули)", "4 078 строк", "Средняя"),
    ("R4", "Пропуск названия трека", "1 231 строка", "Высокая"),
    ("R5", "Пропуск исполнителя / жанра", "7 203 / 1 198 строк", "Средняя"),
    ("R6", "Несогласованные жанры (hip/hiphop, электроника, ïîï)", "≈3 150 строк", "Средняя"),
    ("R7", "Формат времени HH:MM:SS", "нарушений нет (проверка включена)", "Контроль"),
    ("—", "Длинные названия треков (> 255 символов)", "1 строка", "Низкая"),
    ("—", "Один пользователь в двух городах", "33 пользователя", "Информационно"),
], columns=["Код", "Проблема", "Масштаб", "Критичность"])
st.dataframe(problems, use_container_width=True, hide_index=True)

# ------------------------------------------------------------------ 7. Выводы
st.header("7. Итоговые выводы")
st.markdown(
    f"""
- Источник содержит **{n:,}** записей о прослушиваниях и 7 содержательных атрибутов; **даты нет**, есть только день недели (3 значения) и время.
- Критичные проблемы — **полные дубликаты ({pd_stats['full']})** и **пропуск названия трека (1 231)**: такие записи нельзя использовать в аналитике треков.
- Пропуски исполнителя (11%) и жанра (1,8%) не мешают учёту прослушиваний → заполняются значением `unknown`.
- Жанровый справочник шумный (287 значений, длинный хвост) → нужна нормализация и группировка жанров в DDS.
- После очистки источник пригоден для построения хранилища и аналитики по пользователям, трекам, жанрам, городам и времени суток.
""".replace(",", " ")
)

# ------------------------------------------------------------------ 8. Алгоритм очистки
st.header("Предлагаемый алгоритм очистки данных")
algo = pd.DataFrame([
    ("R1", "все бизнес-поля", "Совпадение user_id, track, artist, genre, city, time, day", "Оставить одну запись (с мин. row_id)",
     "Повтор — артефакт выгрузки; искажает счётчики прослушиваний"),
    ("R2", "track, artist, user_id, genre, city", "Пробелы по краям, повторные пробелы, пустая строка", "TRIM, схлопывание пробелов, '' → NULL",
     "Один и тот же объект не должен храниться в разных написаниях"),
    ("R3", "user_id", "Длина < 8 или не HEX", "LPAD нулями до 8; не-HEX — исключить запись",
     "ID — 8-символьный HEX, короткие значения — потерянные нули"),
    ("R4", "track", "NULL / пустое значение", "Исключить запись",
     "Без названия трека запись не несёт информации о прослушивании"),
    ("R5", "artist, genre", "NULL / пустое значение", "Заменить на 'unknown'",
     "Прослушивание состоялось, терять строку нецелесообразно"),
    ("R6", "genre", "Значения hip, электроника, ïîï; регистр", "hip→hiphop, электроника→electronic, ïîï→unknown, lower()",
     "Несколько вариантов записи одного значения"),
    ("R7", "time, day", "Не HH:MM:SS; день не из списка", "Исключить запись; time → TIME",
     "Защита от некорректного формата; в текущих данных нарушений нет"),
], columns=["Код", "Признак(и)", "Критерий выявления", "Способ обработки", "Обоснование"])
st.dataframe(algo, use_container_width=True, hide_index=True)
st.info("Эти правила реализованы в SQL-функции `ods.load_ods(p_sdt, p_edt)` (файл `sql/02_ods.sql`), "
        "нумерация R1–R7 совпадает с комментариями в коде.")
