-- =====================================================================
-- 04. Проверочные запросы (для отчёта: «примеры запросов, подтверждающих
--     корректность загрузки данных»). Период: 2026-01-05 .. 2026-04-03
-- =====================================================================

-- 1. Количество строк по слоям: SRC = STAGING >= ODS >= FACT
SELECT 'src'  AS layer, count(*) FROM src.music_tracks
UNION ALL SELECT 'stg',  count(*) FROM stg.music_tracks
UNION ALL SELECT 'ods',  count(*) FROM ods.music_tracks
UNION ALL SELECT 'dds.fact_listening', count(*) FROM dds.fact_listening;

-- 2. STAGING == SRC as is (расхождений быть не должно, ожидаем 0 строк)
SELECT s.row_id FROM src.music_tracks s
EXCEPT
SELECT t.row_id FROM stg.music_tracks t;

-- 3. Распределение синтетической даты: 13 недель, только пн/ср/пт
SELECT dt, to_char(dt, 'Dy') AS dow, count(*) FROM stg.music_tracks GROUP BY dt ORDER BY dt;

-- 4. Баланс очистки: сколько строк потеряно и по какой причине
SELECT
    count(*)                                                                  AS staging_rows,
    count(*) FILTER (WHERE btrim(track) IS NULL OR btrim(track) = '')         AS no_track_removed_R4,
    (SELECT count(*) FROM ods.music_tracks)                                   AS ods_rows
FROM stg.music_tracks;

-- 5. В ODS нет дублей и пропусков (ожидаем 0 / 0)
SELECT count(*) - count(DISTINCT (dt, user_id, md5(track), md5(artist), genre, city, listen_time)) AS dup_rows
FROM ods.music_tracks;
SELECT count(*) FILTER (WHERE track IS NULL OR artist IS NULL OR genre IS NULL) AS null_rows FROM ods.music_tracks;

-- 6. Жанры после нормализации: 'hip' должен исчезнуть, 'hiphop' - расти
SELECT genre, count(*) FROM ods.music_tracks WHERE genre IN ('hip','hiphop','unknown','электроника') GROUP BY genre;

-- 7. ИДЕМПОТЕНТНОСТЬ: повторный запуск с теми же параметрами не меняет число строк
SELECT count(*) AS before_cnt FROM ods.music_tracks;
SELECT * FROM ods.load_ods(DATE '2026-01-05', DATE '2026-04-03');
SELECT * FROM ods.load_ods(DATE '2026-01-05', DATE '2026-04-03');
SELECT count(*) AS after_cnt FROM ods.music_tracks;

-- 8. Частичная (инкрементальная) перезагрузка одной недели не затрагивает остальные
SELECT * FROM ods.load_ods(DATE '2026-01-05', DATE '2026-01-11');
SELECT count(*) FROM ods.music_tracks;

-- 9. Факт == ODS за период; ссылочная целостность
SELECT (SELECT count(*) FROM ods.music_tracks) AS ods_cnt,
       (SELECT count(*) FROM dds.fact_listening) AS fact_cnt;

SELECT count(*) AS orphans
FROM dds.fact_listening f
LEFT JOIN dds.dim_track t ON t.track_key = f.track_key
LEFT JOIN dds.dim_artist a ON a.artist_key = t.artist_key
WHERE a.artist_key IS NULL;

-- 10. Аналитические запросы по снежинке
-- 10.1 Прослушивания по группам жанров и городам
SELECT gg.group_name, c.city_name, count(*) AS listens
FROM dds.fact_listening f
JOIN dds.dim_genre g        ON g.genre_key = f.genre_key
JOIN dds.dim_genre_group gg ON gg.genre_group_key = g.genre_group_key
JOIN dds.dim_city c         ON c.city_key = f.city_key
GROUP BY gg.group_name, c.city_name
ORDER BY listens DESC;

-- 10.2 Прослушивания по времени суток и месяцам
SELECT m.year_num, m.month_name, dp.daypart_name, count(*) AS listens
FROM dds.fact_listening f
JOIN dds.dim_date d     ON d.date_key = f.date_key
JOIN dds.dim_month m    ON m.month_key = d.month_key
JOIN dds.dim_hour h     ON h.hour_key = f.hour_key
JOIN dds.dim_daypart dp ON dp.daypart_key = h.daypart_key
GROUP BY m.year_num, m.month_num, m.month_name, dp.daypart_name
ORDER BY m.month_num, dp.daypart_name;

-- 10.3 Топ-10 исполнителей (без 'unknown')
SELECT a.artist_name, count(*) AS listens
FROM dds.fact_listening f
JOIN dds.dim_track t  ON t.track_key = f.track_key
JOIN dds.dim_artist a ON a.artist_key = t.artist_key
WHERE a.artist_name <> 'unknown'
GROUP BY a.artist_name
ORDER BY listens DESC
LIMIT 10;
