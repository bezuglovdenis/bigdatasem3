-- =====================================================================
-- 02. Слой ODS и инкрементальная загрузка STAGING -> ODS
-- Правила очистки R1..R7 взяты из страницы «Исследовательский анализ данных»
-- (ВОиАД, лаб. 1); нумерация совпадает с таблицей на странице.
-- =====================================================================
CREATE TABLE IF NOT EXISTS ods.music_tracks (
    ods_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dt          DATE         NOT NULL,                -- синтетическая дата события
    src_row_id  INT          NOT NULL,                -- ссылка на строку источника
    user_id     VARCHAR(8)   NOT NULL,                -- 8 hex-символов
    track       TEXT         NOT NULL,
    artist      VARCHAR(255) NOT NULL,
    genre       VARCHAR(50)  NOT NULL,
    city        VARCHAR(50)  NOT NULL,
    listen_time TIME         NOT NULL,
    day_name    VARCHAR(10)  NOT NULL,
    loaded_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_ods_day  CHECK (day_name IN ('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')),
    CONSTRAINT ck_ods_time CHECK (listen_time >= TIME '08:00:00' AND listen_time < TIME '23:00:00')
);
CREATE INDEX IF NOT EXISTS ix_ods_music_tracks_dt ON ods.music_tracks (dt);
-- страховка от дублей (md5, потому что track может быть очень длинным)
CREATE UNIQUE INDEX IF NOT EXISTS ux_ods_music_tracks_nk
    ON ods.music_tracks (dt, user_id, md5(track), md5(artist), genre, city, listen_time);

-- ---------------------------------------------------------------------
-- Инкрементальная загрузка за период [p_sdt; p_edt].
-- Повторный вызов с теми же параметрами даёт тот же результат (идемпотентно).
-- Возвращает: сколько удалено из ODS, сколько взято из STAGING, сколько вставлено.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ods.load_ods(p_sdt DATE, p_edt DATE)
RETURNS TABLE (out_deleted BIGINT, out_staged BIGINT, out_inserted BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_del BIGINT;
    v_stg BIGINT;
    v_ins BIGINT;
BEGIN
    IF p_sdt IS NULL OR p_edt IS NULL OR p_sdt > p_edt THEN
        RAISE EXCEPTION 'Некорректный период: p_sdt=%, p_edt=%', p_sdt, p_edt;
    END IF;

    -- 1. Удаляем ранее загруженные данные периода
    DELETE FROM ods.music_tracks WHERE dt BETWEEN p_sdt AND p_edt;
    GET DIAGNOSTICS v_del = ROW_COUNT;

    -- 2. Выбираем данные периода из STAGING
    DROP TABLE IF EXISTS tmp_stg;
    CREATE TEMP TABLE tmp_stg ON COMMIT DROP AS
    SELECT * FROM stg.music_tracks WHERE dt BETWEEN p_sdt AND p_edt;
    GET DIAGNOSTICS v_stg = ROW_COUNT;

    -- 3-4. Очистка и преобразование типов
    DROP TABLE IF EXISTS tmp_clean;
    CREATE TEMP TABLE tmp_clean ON COMMIT DROP AS
    WITH t AS (
        SELECT
            s.dt,
            s.row_id::int AS src_row_id,
            -- R2: trim, пустая строка -> NULL
            upper(nullif(btrim(s.user_id), ''))                              AS user_id_raw,
            -- R2: trim + схлопывание повторных пробелов
            nullif(regexp_replace(btrim(s.track),  '\s+', ' ', 'g'), '')     AS track,
            nullif(regexp_replace(btrim(s.artist), '\s+', ' ', 'g'), '')     AS artist,
            lower(nullif(btrim(s.genre), ''))                                AS genre_raw,
            initcap(nullif(btrim(s.city), ''))                               AS city,
            nullif(btrim(s.listen_time), '')                                 AS time_raw,
            initcap(nullif(btrim(s.day_name), ''))                           AS day_name
        FROM tmp_stg s
    )
    SELECT
        dt, src_row_id,
        lpad(user_id_raw, 8, '0')                          AS user_id,       -- R3: восстановление ведущих нулей
        track,
        COALESCE(artist, 'unknown')                        AS artist,        -- R5: пропуск исполнителя
        CASE                                                                 -- R5 + R6: жанр
            WHEN genre_raw IS NULL         THEN 'unknown'
            WHEN genre_raw = 'hip'         THEN 'hiphop'                     -- R6: обрезанное значение
            WHEN genre_raw = 'электроника' THEN 'electronic'                 -- R6: другой язык записи
            WHEN genre_raw = 'ïîï'         THEN 'unknown'                    -- R6: битая кодировка
            ELSE genre_raw
        END                                                AS genre,
        city,
        time_raw::time                                     AS listen_time,
        day_name
    FROM t
    WHERE track IS NOT NULL                                                  -- R4: нет названия трека
      AND user_id_raw ~ '^[0-9A-F]{1,8}$'                                    -- R3: некорректный userID
      AND time_raw    ~ '^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$'         -- R7: формат времени
      AND city IS NOT NULL
      AND day_name IN ('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday');

    -- 5. Загрузка в ODS; R1: полные дубликаты схлопываем (остаётся строка с мин. row_id)
    INSERT INTO ods.music_tracks
        (dt, src_row_id, user_id, track, artist, genre, city, listen_time, day_name)
    SELECT DISTINCT ON (dt, user_id, md5(track), md5(artist), genre, city, listen_time)
           dt, src_row_id, user_id, track, artist, genre, city, listen_time, day_name
    FROM tmp_clean
    ORDER BY dt, user_id, md5(track), md5(artist), genre, city, listen_time, src_row_id;
    GET DIAGNOSTICS v_ins = ROW_COUNT;

    RETURN QUERY SELECT v_del, v_stg, v_ins;
END;
$$;
