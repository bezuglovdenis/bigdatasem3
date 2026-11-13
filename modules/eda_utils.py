"""Функции расчёта показателей для страницы «Исследовательский анализ данных».
Работают на pandas, не зависят от Streamlit (их можно тестировать отдельно)."""
import re

import pandas as pd

BUSINESS_COLS = ["user_id", "track", "artist", "genre", "city", "listen_time", "day_name"]
TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d:[0-5]\d$")
HEX8_RE = re.compile(r"^[0-9A-F]{8}$")


def column_profile(df: pd.DataFrame) -> pd.DataFrame:
    n = len(df)
    rows = []
    for c in df.columns:
        s = df[c]
        nn = int(s.notna().sum())
        rows.append({
            "колонка": c,
            "тип в источнике": "TEXT (str)",
            "заполнено": nn,
            "пропусков": n - nn,
            "доля пропусков, %": round((n - nn) / n * 100, 2),
            "уникальных": int(s.nunique(dropna=True)),
            "пример": s.dropna().iloc[0] if nn else None,
        })
    return pd.DataFrame(rows)


def missing_patterns(df: pd.DataFrame) -> pd.DataFrame:
    """Комбинации пропусков в track / artist / genre."""
    m = df[["track", "artist", "genre"]].isna()
    key = m.apply(lambda r: ", ".join(c for c in m.columns if r[c]) or "нет пропусков", axis=1)
    return key.value_counts().rename_axis("пропущено").reset_index(name="строк")


def full_duplicates(df: pd.DataFrame) -> pd.Series:
    """Полные дубли по бизнес-полям (row_id - технический индекс и не учитывается)."""
    return df.duplicated(BUSINESS_COLS, keep="first")


def potential_duplicates(df: pd.DataFrame) -> dict:
    """Потенциальные дубли: совпадение более узкого набора полей."""
    full = full_duplicates(df)
    no_genre_city = df.duplicated(["user_id", "track", "artist", "listen_time", "day_name"], keep="first")
    same_moment = df.duplicated(["user_id", "listen_time", "day_name"], keep=False) & ~df.duplicated(BUSINESS_COLS, keep=False)
    return {
        "full": int(full.sum()),
        "same_without_genre_city": int(no_genre_city.sum()),
        "same_user_moment_other_track": int(same_moment.sum()),
    }


def format_checks(df: pd.DataFrame) -> pd.DataFrame:
    def cnt(mask):
        return int(mask.sum())

    uid = df["user_id"].dropna()
    t = df["listen_time"].dropna()
    ws = {c: cnt(df[c].dropna() != df[c].dropna().str.strip()) for c in ["user_id", "track", "artist", "genre", "city"]}
    genre = df["genre"].dropna()
    rows = [
        ("user_id", "длина не 8 символов (потеряны ведущие нули?)", cnt(uid.str.len() != 8)),
        ("user_id", "не соответствует HEX-формату (0-9A-F)", cnt(~uid.str.upper().str.match(r"^[0-9A-F]+$"))),
        ("listen_time", "не соответствует HH:MM:SS", cnt(~t.str.match(TIME_RE))),
        ("track", "лишние пробелы по краям", ws["track"]),
        ("artist", "лишние пробелы по краям", ws["artist"]),
        ("genre", "значения с нелатинскими символами (кодировка/язык)", cnt(genre.str.contains(r"[^\x00-\x7f]"))),
        ("genre", "регистр/пробелы отличаются от lower+trim", cnt(genre != genre.str.strip().str.lower())),
    ]
    return pd.DataFrame(rows, columns=["колонка", "проблема формата", "строк"])


def contradictions(df: pd.DataFrame) -> dict:
    users_multi_city = int((df.groupby("user_id")["city"].nunique() > 1).sum())
    g = df.dropna(subset=["track", "artist", "genre"]).groupby(["track", "artist"])["genre"].nunique()
    return {
        "users_in_several_cities": users_multi_city,
        "tracks_with_several_genres": int((g > 1).sum()),
        "hip_vs_hiphop": {"hip": int((df["genre"] == "hip").sum()), "hiphop": int((df["genre"] == "hiphop").sum())},
    }
