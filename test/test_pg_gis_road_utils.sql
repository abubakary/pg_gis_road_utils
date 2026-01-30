-- Test suite for pg_gis_road_utils extension
-- Run with: psql -U postgres -d test_db -f test/test_pg_gis_road_utils.sql

\echo '========================================'
\echo 'Testing pg_gis_road_utils Extension'
\echo '========================================'

-- Ensure extension is installed
DROP EXTENSION IF EXISTS pg_gis_road_utils CASCADE;
CREATE EXTENSION pg_gis_road_utils;
CREATE EXTENSION IF NOT EXISTS postgis;

\echo ''
\echo 'Test 1: get_section_by_chainage (WKT input)'
\echo '-------------------------------------------'

SELECT pg_gis_road_utils.get_section_by_chainage(
    'LINESTRING(0 0, 10 0, 10 10, 20 10)',
    2.0,
    8.0
) AS result;

\echo ''
\echo 'Test 2: cut_line_at_chainage (WKT input)'
\echo '-----------------------------------------'

SELECT pg_gis_road_utils.cut_line_at_chainage(
    'LINESTRING(0 0, 10 0, 10 10)',
    5.0
) AS point_wkt;

\echo ''
\echo 'Test 3: calibrate_point_on_line (WKT input)'
\echo '--------------------------------------------'

SELECT pg_gis_road_utils.calibrate_point_on_line(
    'LINESTRING(0 0, 10 0, 10 10)',
    'POINT(5.1 0.1)',
    1.0
) AS calibrated;

\echo ''
\echo 'Test 4: PostGIS geometry wrappers'
\echo '----------------------------------'

-- Create test table
DROP TABLE IF EXISTS test_roads;
CREATE TABLE test_roads (
    id SERIAL PRIMARY KEY,
    road_code VARCHAR(10),
    geom GEOMETRY(LINESTRING, 4326)
);

-- Insert test data
INSERT INTO test_roads (road_code, geom) VALUES
('T1', ST_GeomFromText('LINESTRING(32.8 -6.8, 33.0 -6.9, 33.2 -7.0, 33.5 -7.1)', 4326)),
('T2', ST_GeomFromText('LINESTRING(35.0 -7.0, 35.5 -7.2, 36.0 -7.5)', 4326));

-- Test get_section_by_chainage_geom
SELECT 
    road_code,
    pg_gis_road_utils.get_section_by_chainage_geom(geom, 2.0, 5.0) AS section_json
FROM test_roads
WHERE road_code = 'T1';

-- Test cut_line_at_chainage_geom
SELECT 
    road_code,
    ST_AsText(pg_gis_road_utils.cut_line_at_chainage_geom(geom, 3.0)) AS point_at_3km
FROM test_roads
WHERE road_code = 'T1';

\echo ''
\echo 'Test 5: extract_section_geometry'
\echo '---------------------------------'

SELECT 
    road_code,
    ST_AsText(
        pg_gis_road_utils.extract_section_geometry(
            pg_gis_road_utils.get_section_by_chainage_geom(geom, 1.0, 4.0),
            4326
        )
    ) AS extracted_geom
FROM test_roads
WHERE road_code = 'T1';

\echo ''
\echo 'Test 6: generate_kilometer_posts'
\echo '---------------------------------'

SELECT 
    road_code,
    posts.*
FROM test_roads
CROSS JOIN LATERAL pg_gis_road_utils.generate_kilometer_posts(geom, 1.0, 0.0) AS posts
WHERE road_code = 'T1'
LIMIT 10;

\echo ''
\echo 'Test 7: MULTILINESTRING support'
\echo '--------------------------------'

SELECT pg_gis_road_utils.get_section_by_chainage(
    'MULTILINESTRING((0 0, 10 0), (10 0, 10 10))',
    2.0,
    6.0
) AS multiline_section;

\echo ''
\echo 'Test 8: Edge cases'
\echo '------------------'

-- Test start = end (should fail or return minimal segment)
\echo 'Testing start_ch = end_ch:'
SELECT pg_gis_road_utils.get_section_by_chainage(
    'LINESTRING(0 0, 10 0)',
    5.0,
    5.0
) AS same_chainage;

-- Test chainage beyond line length
\echo 'Testing chainage beyond line:'
DO $$
BEGIN
    PERFORM pg_gis_road_utils.cut_line_at_chainage(
        'LINESTRING(0 0, 10 0)',
        1000.0
    );
    RAISE NOTICE 'ERROR: Should have raised exception for out of bounds chainage';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'SUCCESS: Correctly raised exception: %', SQLERRM;
END $$;

\echo ''
\echo 'Test 9: Real-world Tanzania roads example'
\echo '------------------------------------------'

-- Simulate Tanzania road data (Dar es Salaam to Morogoro)
DROP TABLE IF EXISTS tanzania_roads;
CREATE TABLE tanzania_roads (
    id SERIAL PRIMARY KEY,
    road_code VARCHAR(20),
    road_name VARCHAR(100),
    geom GEOMETRY(LINESTRING, 4326)
);

INSERT INTO tanzania_roads (road_code, road_name, geom) VALUES
('T7', 'Dar es Salaam - Morogoro Highway', 
 ST_GeomFromText('LINESTRING(39.2083 -6.8161, 39.1 -6.9, 38.9 -7.0, 38.7 -7.1, 38.5 -7.2, 37.8 -6.9)', 4326));

-- Get road segment km 20-50
SELECT 
    road_code,
    road_name,
    pg_gis_road_utils.get_section_by_chainage_geom(geom, 20.0, 50.0)->'length' AS segment_length_km,
    ST_AsText(
        pg_gis_road_utils.extract_section_geometry(
            pg_gis_road_utils.get_section_by_chainage_geom(geom, 20.0, 50.0),
            4326
        )
    ) AS segment_wkt
FROM tanzania_roads
WHERE road_code = 'T7';

-- Generate kilometer posts
\echo 'Kilometer posts for T7 highway:'
SELECT 
    road_code,
    km_post,
    ST_Y(point_geom) AS latitude,
    ST_X(point_geom) AS longitude
FROM tanzania_roads
CROSS JOIN LATERAL pg_gis_road_utils.generate_kilometer_posts(geom, 10.0, 0.0) AS posts
WHERE road_code = 'T7'
ORDER BY km_post
LIMIT 15;

\echo ''
\echo 'Test 10: Performance test'
\echo '-------------------------'

-- Create larger test dataset
DROP TABLE IF EXISTS roads_performance;
CREATE TABLE roads_performance AS
SELECT 
    i AS road_id,
    ST_MakeLine(
        ST_MakePoint(30 + random() * 10, -10 + random() * 5),
        ST_MakePoint(30 + random() * 10, -10 + random() * 5),
        ST_MakePoint(30 + random() * 10, -10 + random() * 5),
        ST_MakePoint(30 + random() * 10, -10 + random() * 5)
    )::GEOMETRY(LINESTRING, 4326) AS geom
FROM generate_series(1, 1000) AS i;

-- Benchmark
\timing on

\echo 'Extracting 1000 road segments:'
SELECT COUNT(*) 
FROM roads_performance
CROSS JOIN LATERAL (
    SELECT pg_gis_road_utils.get_section_by_chainage_geom(geom, 1.0, 3.0) AS section
) AS sections;

\echo 'Cutting 1000 lines at chainage:'
SELECT COUNT(*) 
FROM roads_performance
CROSS JOIN LATERAL (
    SELECT pg_gis_road_utils.cut_line_at_chainage_geom(geom, 2.0) AS point
) AS points;

\timing off

\echo ''
\echo 'Test 11: Integration with actual calibration use case'
\echo '------------------------------------------------------'

-- Simulate GPS tracking points
DROP TABLE IF EXISTS gps_points;
CREATE TABLE gps_points (
    id SERIAL PRIMARY KEY,
    vehicle_id INTEGER,
    recorded_at TIMESTAMP,
    geom GEOMETRY(POINT, 4326)
);

INSERT INTO gps_points (vehicle_id, recorded_at, geom) VALUES
(1, NOW(), ST_GeomFromText('POINT(39.0 -6.95)', 4326)),
(1, NOW() - INTERVAL '5 minutes', ST_GeomFromText('POINT(38.9 -7.0)', 4326)),
(2, NOW(), ST_GeomFromText('POINT(38.7 -7.1)', 4326));

-- Calibrate GPS points on T7 highway
SELECT 
    gps.id,
    gps.vehicle_id,
    tr.road_code,
    (pg_gis_road_utils.calibrate_point_on_line_geom(tr.geom, gps.geom, 0.1)->>'chainage')::NUMERIC(10,3) AS chainage_km,
    (pg_gis_road_utils.calibrate_point_on_line_geom(tr.geom, gps.geom, 0.1)->>'lat')::NUMERIC(10,6) AS calibrated_lat,
    (pg_gis_road_utils.calibrate_point_on_line_geom(tr.geom, gps.geom, 0.1)->>'lon')::NUMERIC(10,6) AS calibrated_lon
FROM gps_points gps
CROSS JOIN tanzania_roads tr
WHERE tr.road_code = 'T7'
  AND ST_DWithin(tr.geom, gps.geom, 0.1);

\echo ''
\echo 'Test 12: JSON parsing and extraction'
\echo '-------------------------------------'

WITH section_data AS (
    SELECT pg_gis_road_utils.get_section_by_chainage(
        'LINESTRING(0 0, 10 0, 10 10)',
        2.0,
        7.0
    ) AS section_json
)
SELECT 
    section_json->>'start_ch' AS start_chainage,
    section_json->>'end_ch' AS end_chainage,
    section_json->>'length' AS length,
    section_json->>'geometry' AS wkt_geometry,
    (section_json->>'start_lat')::DOUBLE PRECISION AS start_latitude,
    (section_json->>'start_lon')::DOUBLE PRECISION AS start_longitude
FROM section_data;

\echo ''
\echo '========================================'
\echo 'All tests completed!'
\echo '========================================'

-- Cleanup
DROP TABLE IF EXISTS test_roads CASCADE;
DROP TABLE IF EXISTS tanzania_roads CASCADE;
DROP TABLE IF EXISTS roads_performance CASCADE;
DROP TABLE IF EXISTS gps_points CASCADE;

\echo ''
\echo 'Extension info:'
SELECT * FROM pg_available_extensions WHERE name = 'pg_gis_road_utils';
