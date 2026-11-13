-- =====================================================================
-- 01. Схемы, таблица-источник (SRC) и слой STAGING
-- СУБД: PostgreSQL 13+
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS src;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS ods;
CREATE SCHEMA IF NOT EXISTS dds;

-- ---------------------------------------------------------------------
-- SRC: максимально близко к файлу. Все поля TEXT, значения не меняются.
-- Меняются только имена колонок (в заголовке файла есть пробелы:
-- "  userID", "  City  ", а первая колонка без имени -> Unnamed: 0).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS src.music_tracks (
    row_id      TEXT,   -- "Unnamed: 0" (сквозной индекс файла)
    user_id     TEXT,   -- "  userID"
    track       TEXT,   -- "Track"
    artist      TEXT,   -- "artist"
    genre       TEXT,   -- "genre"
    city        TEXT,   -- "  City  "
    listen_time TEXT,   -- "time"
    day_name    TEXT,   -- "Day"
    src_loaded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- STAGING: копия источника as is + два технических поля.
--   dt        - синтетическая дата события (в источнике даты нет).
--               Нужна здесь, чтобы ODS мог выбирать данные за период.
--   loaded_at - время загрузки в STAGING.
-- Содержательные поля не очищаются и не преобразуются.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg.music_tracks (
    row_id      TEXT,
    user_id     TEXT,
    track       TEXT,
    artist      TEXT,
    genre       TEXT,
    city        TEXT,
    listen_time TEXT,
    day_name    TEXT,
    dt          DATE        NOT NULL,
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_stg_music_tracks_dt ON stg.music_tracks (dt);

-- ---------------------------------------------------------------------
-- Функция без входных параметров: SRC -> STAGING (полная перезагрузка).
--
-- Синтетическая дата dt:
--   * 13 недель, начиная с понедельника 2026-01-05 (2026-01-05..2026-04-03);
--   * неделя выбирается детерминированно по хэшу содержимого строки,
--     поэтому полные дубликаты получают ОДИНАКОВУЮ дату и корректно
--     схлопываются при очистке внутри периода;
--   * день недели берётся из поля Day (в данных только Mon/Wed/Fri), поэтому
--     dt согласована с исходным полем и не создаёт противоречий.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stg.load_staging()
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_cnt BIGINT;
BEGIN
    TRUNCATE TABLE stg.music_tracks;

    INSERT INTO stg.music_tracks
        (row_id, user_id, track, artist, genre, city, listen_time, day_name, dt)
    SELECT
        s.row_id, s.user_id, s.track, s.artist, s.genre, s.city, s.listen_time, s.day_name,
        DATE '2026-01-05'
          + 7 * (abs(hashtext(concat_ws('|', s.user_id, s.track, s.artist, s.genre,
                                            s.city, s.listen_time, s.day_name))::bigint) % 13)::int
          + CASE s.day_name WHEN 'Monday' THEN 0 WHEN 'Wednesday' THEN 2
                            WHEN 'Friday' THEN 4 ELSE 0 END
    FROM src.music_tracks s;

    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    RETURN v_cnt;
END;
$$;
