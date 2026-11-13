-- =====================================================================
-- 03. Аналитическое хранилище (DDS), схема «снежинка»
--
-- Факт:  fact_listening - одно прослушивание трека (одна очищенная запись ODS).
-- Измерения (нормализованы, образуют снежинку):
--   fact -> dim_user
--   fact -> dim_city
--   fact -> dim_track  -> dim_artist
--   fact -> dim_genre  -> dim_genre_group
--   fact -> dim_date   -> dim_month
--   fact -> dim_hour   -> dim_daypart
-- Меру в источнике взять неоткуда, поэтому используется listen_cnt = 1
-- (число прослушиваний считается как SUM/COUNT по факту).
-- =====================================================================

-- ---------- внешние уровни снежинки (самые «дальние» таблицы) ----------
CREATE TABLE IF NOT EXISTS dds.dim_genre_group (
    genre_group_key SMALLINT PRIMARY KEY,
    group_name      VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS dds.dim_daypart (
    daypart_key  SMALLINT PRIMARY KEY,
    daypart_name VARCHAR(20) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS dds.dim_month (
    month_key   INT PRIMARY KEY,               -- YYYYMM
    year_num    SMALLINT    NOT NULL,
    quarter_num SMALLINT    NOT NULL,
    month_num   SMALLINT    NOT NULL,
    month_name  VARCHAR(20) NOT NULL
);

-- ---------- измерения ----------
CREATE TABLE IF NOT EXISTS dds.dim_genre (
    genre_key       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    genre_name      VARCHAR(50) NOT NULL UNIQUE,
    genre_group_key SMALLINT    NOT NULL REFERENCES dds.dim_genre_group (genre_group_key)
);

CREATE TABLE IF NOT EXISTS dds.dim_artist (
    artist_key  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    artist_name VARCHAR(255) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS dds.dim_track (
    track_key  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    track_name TEXT NOT NULL,
    track_hash CHAR(32) GENERATED ALWAYS AS (md5(track_name)) STORED,   -- для уникальности длинных названий
    artist_key INT  NOT NULL REFERENCES dds.dim_artist (artist_key),
    CONSTRAINT ux_dim_track UNIQUE (artist_key, track_hash)
);

CREATE TABLE IF NOT EXISTS dds.dim_user (
    user_key INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id  VARCHAR(8) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS dds.dim_city (
    city_key  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city_name VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS dds.dim_hour (
    hour_key    SMALLINT PRIMARY KEY CHECK (hour_key BETWEEN 0 AND 23),
    daypart_key SMALLINT NOT NULL REFERENCES dds.dim_daypart (daypart_key)
);

CREATE TABLE IF NOT EXISTS dds.dim_date (
    date_key    INT PRIMARY KEY,               -- YYYYMMDD
    full_date   DATE        NOT NULL UNIQUE,
    day_of_week SMALLINT    NOT NULL,          -- 1=Mon..7=Sun
    day_name    VARCHAR(10) NOT NULL,
    week_num    SMALLINT    NOT NULL,
    month_key   INT         NOT NULL REFERENCES dds.dim_month (month_key)
);

-- ---------- факт ----------
CREATE TABLE IF NOT EXISTS dds.fact_listening (
    listening_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_key     INT      NOT NULL REFERENCES dds.dim_date  (date_key),
    hour_key     SMALLINT NOT NULL REFERENCES dds.dim_hour  (hour_key),
    listen_time  TIME     NOT NULL,                          -- вырожденное измерение (точное время)
    user_key     INT      NOT NULL REFERENCES dds.dim_user  (user_key),
    track_key    INT      NOT NULL REFERENCES dds.dim_track (track_key),
    genre_key    INT      NOT NULL REFERENCES dds.dim_genre (genre_key),
    city_key     SMALLINT NOT NULL REFERENCES dds.dim_city  (city_key),
    listen_cnt   SMALLINT NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS ix_fact_listening_date  ON dds.fact_listening (date_key);
CREATE INDEX IF NOT EXISTS ix_fact_listening_track ON dds.fact_listening (track_key);
CREATE INDEX IF NOT EXISTS ix_fact_listening_genre ON dds.fact_listening (genre_key);

-- ---------- справочные данные ----------
INSERT INTO dds.dim_genre_group (genre_group_key, group_name) VALUES
    (1,'Hip-hop / Rap'), (2,'Rock'), (3,'Metal'), (4,'Pop'), (5,'Electronic / Dance'),
    (6,'Classical / Soundtrack'), (7,'Jazz / Blues / RnB'), (8,'Folk / World'),
    (9,'Other'), (10,'Unknown')
ON CONFLICT DO NOTHING;

INSERT INTO dds.dim_daypart (daypart_key, daypart_name) VALUES
    (1,'Night'), (2,'Morning'), (3,'Afternoon'), (4,'Evening')
ON CONFLICT DO NOTHING;

INSERT INTO dds.dim_hour (hour_key, daypart_key)
SELECT h, CASE WHEN h < 5 THEN 1 WHEN h < 12 THEN 2 WHEN h < 18 THEN 3 ELSE 4 END
FROM generate_series(0, 23) AS h
ON CONFLICT DO NOTHING;

-- ---------- отнесение жанра к группе (правила можно подстроить под лекцию) ----------
CREATE OR REPLACE FUNCTION dds.genre_to_group(p_genre TEXT)
RETURNS SMALLINT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_genre = 'unknown'                                              THEN 10
        WHEN p_genre ~ 'hip|rap'                                              THEN 1
        WHEN p_genre ~ 'metal|hardcore'                                       THEN 3
        WHEN p_genre ~ 'rock|punk|alternative|indie|grunge'                   THEN 2
        WHEN p_genre ~ 'pop'                                                  THEN 4
        WHEN p_genre ~ 'electr|dance|house|techno|trance|ambient|dub|rave'    THEN 5
        WHEN p_genre ~ 'classic|soundtrack|film|instrumental|opera'           THEN 6
        WHEN p_genre ~ 'jazz|blues|rnb|soul|funk'                             THEN 7
        WHEN p_genre ~ 'folk|world|country|latin|reggae|shanson|ethnic|celtic' THEN 8
        ELSE 9
    END::smallint
$$;

-- ---------------------------------------------------------------------
-- Загрузка ODS -> DDS за период [p_sdt; p_edt]. Идемпотентна:
-- измерения дополняются (INSERT ... WHERE NOT EXISTS), факты периода
-- удаляются и вставляются заново.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dds.load_dds(p_sdt DATE, p_edt DATE)
RETURNS TABLE (out_deleted BIGINT, out_inserted BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_del BIGINT;
    v_ins BIGINT;
BEGIN
    IF p_sdt IS NULL OR p_edt IS NULL OR p_sdt > p_edt THEN
        RAISE EXCEPTION 'Некорректный период: p_sdt=%, p_edt=%', p_sdt, p_edt;
    END IF;

    -- dim_month / dim_date
    INSERT INTO dds.dim_month (month_key, year_num, quarter_num, month_num, month_name)
    SELECT DISTINCT to_char(o.dt,'YYYYMM')::int, extract(year FROM o.dt)::smallint,
           extract(quarter FROM o.dt)::smallint, extract(month FROM o.dt)::smallint,
           btrim(to_char(o.dt,'Month'))
    FROM ods.music_tracks o
    WHERE o.dt BETWEEN p_sdt AND p_edt
      AND NOT EXISTS (SELECT 1 FROM dds.dim_month m WHERE m.month_key = to_char(o.dt,'YYYYMM')::int);

    INSERT INTO dds.dim_date (date_key, full_date, day_of_week, day_name, week_num, month_key)
    SELECT DISTINCT to_char(o.dt,'YYYYMMDD')::int, o.dt, extract(isodow FROM o.dt)::smallint,
           btrim(to_char(o.dt,'Day')), extract(week FROM o.dt)::smallint, to_char(o.dt,'YYYYMM')::int
    FROM ods.music_tracks o
    WHERE o.dt BETWEEN p_sdt AND p_edt
      AND NOT EXISTS (SELECT 1 FROM dds.dim_date d WHERE d.full_date = o.dt);

    -- простые измерения
    INSERT INTO dds.dim_city (city_name)
    SELECT DISTINCT o.city FROM ods.music_tracks o
    WHERE o.dt BETWEEN p_sdt AND p_edt
      AND NOT EXISTS (SELECT 1 FROM dds.dim_city c WHERE c.city_name = o.city);

    INSERT INTO dds.dim_user (user_id)
    SELECT DISTINCT o.user_id FROM ods.music_tracks o
    WHERE o.dt BETWEEN p_sdt AND p_edt
      AND NOT EXISTS (SELECT 1 FROM dds.dim_user u WHERE u.user_id = o.user_id);

    INSERT INTO dds.dim_artist (artist_name)
    SELECT DISTINCT o.artist FROM ods.music_tracks o
    WHERE o.dt BETWEEN p_sdt AND p_edt
      AND NOT EXISTS (SELECT 1 FROM dds.dim_artist a WHERE a.artist_name = o.artist);

    INSERT INTO dds.dim_genre (genre_name, genre_group_key)
    SELECT DISTINCT o.genre, dds.genre_to_group(o.genre) FROM ods.music_tracks o
    WHERE o.dt BETWEEN p_sdt AND p_edt
      AND NOT EXISTS (SELECT 1 FROM dds.dim_genre g WHERE g.genre_name = o.genre);

    -- dim_track зависит от dim_artist
    INSERT INTO dds.dim_track (track_name, artist_key)
    SELECT DISTINCT o.track, a.artist_key
    FROM ods.music_tracks o
    JOIN dds.dim_artist a ON a.artist_name = o.artist
    WHERE o.dt BETWEEN p_sdt AND p_edt
      AND NOT EXISTS (SELECT 1 FROM dds.dim_track t
                      WHERE t.artist_key = a.artist_key AND t.track_hash = md5(o.track));

    -- факт: удаляем период и вставляем заново
    DELETE FROM dds.fact_listening
    WHERE date_key BETWEEN to_char(p_sdt,'YYYYMMDD')::int AND to_char(p_edt,'YYYYMMDD')::int;
    GET DIAGNOSTICS v_del = ROW_COUNT;

    INSERT INTO dds.fact_listening (date_key, hour_key, listen_time, user_key, track_key, genre_key, city_key)
    SELECT to_char(o.dt,'YYYYMMDD')::int,
           extract(hour FROM o.listen_time)::smallint,
           o.listen_time, u.user_key, t.track_key, g.genre_key, c.city_key
    FROM ods.music_tracks o
    JOIN dds.dim_user   u ON u.user_id    = o.user_id
    JOIN dds.dim_artist a ON a.artist_name = o.artist
    JOIN dds.dim_track  t ON t.artist_key = a.artist_key AND t.track_hash = md5(o.track)
    JOIN dds.dim_genre  g ON g.genre_name = o.genre
    JOIN dds.dim_city   c ON c.city_name  = o.city
    WHERE o.dt BETWEEN p_sdt AND p_edt;
    GET DIAGNOSTICS v_ins = ROW_COUNT;

    RETURN QUERY SELECT v_del, v_ins;
END;
$$;
