"""Модуль загрузки (дисциплина «Администрирование больших данных»):
CSV -> таблица-источник src.music_tracks. Значения не меняются (всё как TEXT),
переименовываются только колонки.

Запуск из консоли:  python -m modules.loader data/music_project.csv
"""
import io
import sys

import pandas as pd

# исходное имя колонки (после strip) -> имя колонки в таблице-источнике
COLUMN_MAP = {
    "Unnamed: 0": "row_id",
    "userID": "user_id",
    "Track": "track",
    "artist": "artist",
    "genre": "genre",
    "City": "city",
    "time": "listen_time",
    "Day": "day_name",
}
TARGET_COLS = list(COLUMN_MAP.values())


def read_raw_csv(path) -> pd.DataFrame:
    """Читает файл «как есть»: всё строки, 'NA'/'None' не превращаются в NaN,
    пустые поля -> NULL. Пробелы внутри значений сохраняются."""
    df = pd.read_csv(path, dtype=str, keep_default_na=False, na_values=[""])
    df.columns = [c.strip() for c in df.columns]
    missing = set(COLUMN_MAP) - set(df.columns)
    if missing:
        raise ValueError(f"В файле нет ожидаемых колонок: {sorted(missing)}")
    return df.rename(columns=COLUMN_MAP)[TARGET_COLS]


def load_csv_to_source(path, truncate: bool = True) -> int:
    """Загружает CSV в src.music_tracks через COPY. Возвращает число строк."""
    from modules.db import get_engine  # импорт здесь: read_raw_csv работает и без БД

    df = read_raw_csv(path)
    buf = io.StringIO()
    df.to_csv(buf, index=False, header=False)  # NaN -> пустое поле -> NULL
    buf.seek(0)

    raw = get_engine().raw_connection()
    try:
        with raw.cursor() as cur:
            if truncate:
                cur.execute("TRUNCATE TABLE src.music_tracks")
            cur.copy_expert(
                f"COPY src.music_tracks ({', '.join(TARGET_COLS)}) "
                "FROM STDIN WITH (FORMAT csv, NULL '')",
                buf,
            )
        raw.commit()
    finally:
        raw.close()
    return len(df)


if __name__ == "__main__":
    file_path = sys.argv[1] if len(sys.argv) > 1 else "data/music_project.csv"
    print(f"Загружено строк в src.music_tracks: {load_csv_to_source(file_path)}")
