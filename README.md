# Music tracks: хранилище данных + аналитическое приложение

Одно Streamlit-приложение для двух лабораторных работ:

* **ВОиАД, ЛР 1** — страница «Исследовательский анализ данных» (`pages/1_EDA.py`), проблемы качества, алгоритм очистки.
* **АБД, ЛР 1** — модуль загрузки (`modules/loader.py`, `modules/etl.py`, страница `pages/2_ETL.py`) и SQL-слои (`sql/`).

Набор данных: `data/music_project.csv` (65 079 прослушиваний: userID, Track, artist, genre, City, time, Day).

## Архитектура

```mermaid
flowchart LR
    CSV[music_project.csv] -->|Python: modules/loader.py, COPY| SRC[(src.music_tracks<br/>всё TEXT, as is)]
    SRC -->|stg.load_staging<br/>без параметров, as is + dt| STG[(stg.music_tracks)]
    STG -->|ods.load_ods p_sdt, p_edt<br/>очистка R1-R7| ODS[(ods.music_tracks)]
    ODS -->|dds.load_dds p_sdt, p_edt| DDS[(DDS: снежинка)]
    EDA[Streamlit: EDA] -. правила очистки .-> ODS
```

### Схема DDS («снежинка»)

```mermaid
erDiagram
    fact_listening }o--|| dim_user : user_key
    fact_listening }o--|| dim_city : city_key
    fact_listening }o--|| dim_track : track_key
    dim_track }o--|| dim_artist : artist_key
    fact_listening }o--|| dim_genre : genre_key
    dim_genre }o--|| dim_genre_group : genre_group_key
    fact_listening }o--|| dim_date : date_key
    dim_date }o--|| dim_month : month_key
    fact_listening }o--|| dim_hour : hour_key
    dim_hour }o--|| dim_daypart : daypart_key
```

Гранулярность факта: одно прослушивание (одна очищенная запись ODS). Мера: `listen_cnt = 1`.

## Запуск

```bash
python -m venv .venv && source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
createdb music_dwh                                      # PostgreSQL 13+
export DATABASE_URL=postgresql+psycopg2://postgres:postgres@localhost:5432/music_dwh
streamlit run app.py
```

Порядок в странице **ETL**: инициализация БД → загрузка CSV → `load_staging()` → `load_ods` → `load_dds`.
То же из консоли:

```bash
psql -d music_dwh -f sql/01_source_staging.sql -f sql/02_ods.sql -f sql/03_dds.sql
python -m modules.loader data/music_project.csv
psql -d music_dwh -c "SELECT stg.load_staging();" \
  -c "SELECT * FROM ods.load_ods('2026-01-05','2026-04-03');" \
  -c "SELECT * FROM dds.load_dds('2026-01-05','2026-04-03');"
psql -d music_dwh -f sql/04_checks.sql                  # проверочные запросы
```

## Синтетическая дата `dt`

В источнике даты нет. `dt` формируется в `stg.load_staging()` как технический атрибут:
13 недель с 2026-01-05, неделя выбирается по хэшу содержимого строки (дубликаты получают одну дату и схлопываются при очистке),
день недели берётся из поля `Day` (в данных только Mon/Wed/Fri) — дата не противоречит исходным значениям.
Поле переносится в ODS и используется как ключ инкрементальной загрузки.

## Правила очистки (R1–R7)

| Код | Проблема | Обработка |
|---|---|---|
| R1 | Полные дубликаты (3 826) | оставить одну запись |
| R2 | Пробелы в track/artist (32/36) | TRIM, схлопывание пробелов, '' → NULL |
| R3 | userID короче 8 символов (4 078) | LPAD нулями до 8, не-HEX исключить |
| R4 | Нет названия трека (1 231) | исключить запись |
| R5 | Нет artist (7 203) / genre (1 198) | заменить на `unknown` |
| R6 | Жанры `hip`, `электроника`, `ïîï` | `hiphop`, `electronic`, `unknown` |
| R7 | Формат времени / день недели | валидация, `TIME` |

## Структура

```
app.py · pages/1_EDA.py · pages/2_ETL.py
modules/{db,loader,etl,eda_utils}.py
sql/01_source_staging.sql · 02_ods.sql · 03_dds.sql · 04_checks.sql
data/music_project.csv
```
