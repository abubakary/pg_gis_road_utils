-- ============================================
-- Shapefile Reader Examples
-- pg_gis_road_utils Extension
-- ============================================

-- This file demonstrates how to use the shapefile reader functions
-- to load and work with ESRI Shapefiles in PostgreSQL

-- ============================================
-- PREREQUISITES
-- ============================================

-- 1. Extension must be installed:
--    CREATE EXTENSION pg_gis_road_utils;

-- 2. You need shapefile data (.shp + .dbf files)
--    Example paths used in this file:
--    - /data/tanzania_roads.shp
--    - /data/tanzania_roads.dbf
--    - /data/districts.shp
--    - /data/districts.dbf

-- ============================================
-- EXAMPLE 1: Basic Shapefile Reading (WKT)
-- ============================================

-- Read all records from a shapefile
SELECT * FROM read_shapefile_wkt('/data/tanzania_roads')
LIMIT 5;

-- Expected output:
-- record_num |        attributes         |           geom_wkt
-- -----------+---------------------------+--------------------------------
--          1 | {T1,Primary,Paved}       | LINESTRING(34.5 -6.8, 34.6...)
--          2 | {T7,Primary,Paved}       | LINESTRING(39.2 -6.8, 39.3...)
--          3 | {B127,Secondary,Gravel}  | LINESTRING(33.1 -7.2, 33.2...)

-- ============================================
-- EXAMPLE 2: Accessing Specific Attributes
-- ============================================

-- Extract individual attribute columns
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    attributes[3] AS surface,
    attributes[4] AS length_km,
    geom_wkt
FROM read_shapefile_wkt('/data/tanzania_roads')
LIMIT 10;

-- ============================================
-- EXAMPLE 3: Filtering During Read
-- ============================================

-- Load only paved primary roads
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    geom_wkt
FROM read_shapefile_wkt('/data/tanzania_roads')
WHERE attributes[2] = 'Primary' 
  AND attributes[3] = 'Paved';

-- ============================================
-- EXAMPLE 4: Create Table from Shapefile
-- ============================================

-- Method 1: Using WKT
DROP TABLE IF EXISTS roads;
CREATE TABLE roads (
    id SERIAL PRIMARY KEY,
    road_code TEXT,
    road_class TEXT,
    surface TEXT,
    length_km NUMERIC,
    geom GEOMETRY(LINESTRING, 4326)
);

-- Load data
INSERT INTO roads (road_code, road_class, surface, length_km, geom)
SELECT 
    attributes[1],
    attributes[2],
    attributes[3],
    attributes[4]::NUMERIC,
    ST_GeomFromText(geom_wkt, 4326)
FROM read_shapefile_wkt('/data/tanzania_roads');

-- Verify
SELECT COUNT(*) FROM roads;
SELECT * FROM roads LIMIT 5;

-- Create spatial index
CREATE INDEX roads_geom_idx ON roads USING GIST (geom);

-- ============================================
-- EXAMPLE 5: Using WKB (Better Performance)
-- ============================================

-- Method 2: Using WKB (faster, smaller)
DROP TABLE IF EXISTS districts;
CREATE TABLE districts (
    id SERIAL PRIMARY KEY,
    district_name TEXT,
    region TEXT,
    population INTEGER,
    area_sqkm NUMERIC,
    geom GEOMETRY(POLYGON, 4326)
);

-- Load data with WKB
INSERT INTO districts (district_name, region, population, area_sqkm, geom)
SELECT 
    attributes[1],
    attributes[2],
    attributes[3]::INTEGER,
    attributes[4]::NUMERIC,
    geom_wkb::geometry  -- Direct cast from WKB
FROM read_shapefile_wkb('/data/districts');

-- Create spatial index
CREATE INDEX districts_geom_idx ON districts USING GIST (geom);

-- ============================================
-- EXAMPLE 6: Create View for Easy Access
-- ============================================

-- Create view that always reflects shapefile
CREATE OR REPLACE VIEW roads_live AS
SELECT 
    record_num AS id,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    attributes[3] AS surface,
    attributes[4]::NUMERIC AS length_km,
    ST_GeomFromText(geom_wkt, 4326) AS geometry
FROM read_shapefile_wkt('/data/tanzania_roads');

-- Query the view
SELECT * FROM roads_live WHERE road_class = 'Primary' LIMIT 5;

-- ============================================
-- EXAMPLE 7: Spatial Queries
-- ============================================

-- Find roads within 10km of Dar es Salaam
SELECT 
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    ST_Distance(
        ST_GeomFromText(geom_wkt, 4326)::geography,
        ST_MakePoint(39.2083, -6.7924)::geography  -- Dar es Salaam
    ) / 1000 AS distance_km
FROM read_shapefile_wkt('/data/tanzania_roads')
WHERE ST_DWithin(
    ST_GeomFromText(geom_wkt, 4326)::geography,
    ST_MakePoint(39.2083, -6.7924)::geography,
    10000  -- 10km in meters
)
ORDER BY distance_km
LIMIT 10;

-- ============================================
-- EXAMPLE 8: Combine with Road Utils Functions
-- ============================================

-- Load roads and extract segments using chainage
WITH road_data AS (
    SELECT 
        attributes[1] AS road_code,
        geom_wkt
    FROM read_shapefile_wkt('/data/tanzania_roads')
    WHERE attributes[1] = 'T1'
)
SELECT 
    road_code,
    get_section_by_chainage(geom_wkt, 10.0, 50.0) AS section_info
FROM road_data;

-- ============================================
-- EXAMPLE 9: Get Point at Chainage
-- ============================================

-- For each road, get point at 25km mark
SELECT 
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    cut_line_at_chainage(geom_wkt, 25.0) AS point_at_25km
FROM read_shapefile_wkt('/data/tanzania_roads')
WHERE attributes[2] = 'Primary'
  AND attributes[4]::NUMERIC > 25.0;  -- Only roads longer than 25km

-- ============================================
-- EXAMPLE 10: GPS Point Calibration
-- ============================================

-- Calibrate GPS points to nearest road
-- Assume you have GPS readings
CREATE TEMP TABLE gps_readings (
    vehicle_id TEXT,
    reading_time TIMESTAMP,
    latitude NUMERIC,
    longitude NUMERIC
);

INSERT INTO gps_readings VALUES
    ('TRUCK001', NOW(), -6.7924, 39.2083),
    ('TRUCK002', NOW(), -6.8000, 39.2500),
    ('TRUCK003', NOW(), -6.7500, 39.2000);

-- Calibrate each GPS point to roads
SELECT 
    g.vehicle_id,
    g.reading_time,
    r.road_code,
    calibrate_point_on_line(
        r.geom_wkt,
        ST_AsText(ST_MakePoint(g.longitude, g.latitude)),
        1000000.0  -- Large radius in degrees
    ) AS calibration_result
FROM gps_readings g
CROSS JOIN LATERAL (
    SELECT 
        attributes[1] AS road_code,
        geom_wkt
    FROM read_shapefile_wkt('/data/tanzania_roads')
    WHERE ST_DWithin(
        ST_GeomFromText(geom_wkt, 4326),
        ST_MakePoint(g.longitude, g.latitude),
        0.1  -- ~10km
    )
    ORDER BY ST_Distance(
        ST_GeomFromText(geom_wkt, 4326),
        ST_MakePoint(g.longitude, g.latitude)
    )
    LIMIT 1
) r;

-- ============================================
-- EXAMPLE 11: Count Records
-- ============================================

-- Count total records in shapefile
SELECT COUNT(*) AS total_records
FROM read_shapefile_wkt('/data/tanzania_roads');

-- Count by road class
SELECT 
    attributes[2] AS road_class,
    COUNT(*) AS count
FROM read_shapefile_wkt('/data/tanzania_roads')
GROUP BY attributes[2]
ORDER BY count DESC;

-- ============================================
-- EXAMPLE 12: Inspect Shapefile Structure
-- ============================================

-- See what attributes are available
SELECT 
    record_num,
    attributes
FROM read_shapefile_wkt('/data/tanzania_roads')
LIMIT 1;

-- Example output:
-- record_num |              attributes
-- -----------+----------------------------------------
--          1 | {T1,Primary,Paved,145.5,Dar-Morogoro}

-- This shows the shapefile has 5 fields:
-- 1. Road code
-- 2. Road class
-- 3. Surface type
-- 4. Length
-- 5. Route name

-- ============================================
-- EXAMPLE 13: Performance Comparison
-- ============================================

-- Compare WKT vs WKB loading speed

-- WKT version (text)
\timing on
SELECT COUNT(*) FROM (
    SELECT geom_wkt FROM read_shapefile_wkt('/data/tanzania_roads')
) t;
\timing off

-- WKB version (binary - usually faster)
\timing on
SELECT COUNT(*) FROM (
    SELECT geom_wkb FROM read_shapefile_wkb('/data/tanzania_roads')
) t;
\timing off

-- ============================================
-- EXAMPLE 14: Materialized View for Performance
-- ============================================

-- For frequently accessed data, use materialized view
DROP MATERIALIZED VIEW IF EXISTS roads_materialized;
CREATE MATERIALIZED VIEW roads_materialized AS
SELECT 
    record_num AS id,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    attributes[3] AS surface,
    attributes[4]::NUMERIC AS length_km,
    geom_wkb::geometry AS geom
FROM read_shapefile_wkb('/data/tanzania_roads');

-- Create index
CREATE INDEX roads_mat_geom_idx ON roads_materialized USING GIST (geom);

-- Refresh when shapefile changes
REFRESH MATERIALIZED VIEW roads_materialized;

-- Query is now much faster
SELECT * FROM roads_materialized WHERE road_class = 'Primary';

-- ============================================
-- EXAMPLE 15: Error Handling
-- ============================================

-- Handle missing files gracefully
DO $$
BEGIN
    PERFORM * FROM read_shapefile_wkt('/data/nonexistent');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Shapefile not found: %', SQLERRM;
END $$;

-- ============================================
-- EXAMPLE 16: Export Results
-- ============================================

-- Export specific roads to CSV
COPY (
    SELECT 
        attributes[1] AS road_code,
        attributes[2] AS road_class,
        ST_AsText(geom_wkb::geometry) AS geometry_wkt
    FROM read_shapefile_wkb('/data/tanzania_roads')
    WHERE attributes[2] = 'Primary'
) TO '/tmp/primary_roads.csv' WITH CSV HEADER;

-- ============================================
-- EXAMPLE 17: Integration with Existing Tables
-- ============================================

-- Join shapefile data with existing database tables
-- Assume you have a table with road maintenance records
CREATE TEMP TABLE road_maintenance (
    road_code TEXT,
    last_maintenance DATE,
    condition TEXT
);

INSERT INTO road_maintenance VALUES
    ('T1', '2024-01-15', 'Good'),
    ('T7', '2023-11-20', 'Fair'),
    ('B127', '2024-02-10', 'Excellent');

-- Join with shapefile data
SELECT 
    s.attributes[1] AS road_code,
    s.attributes[2] AS road_class,
    m.last_maintenance,
    m.condition,
    s.geom_wkt
FROM read_shapefile_wkt('/data/tanzania_roads') s
JOIN road_maintenance m ON s.attributes[1] = m.road_code;

-- ============================================
-- EXAMPLE 18: Aggregate Statistics
-- ============================================

-- Calculate total road length by class
SELECT 
    attributes[2] AS road_class,
    COUNT(*) AS road_count,
    SUM(attributes[4]::NUMERIC) AS total_length_km,
    AVG(attributes[4]::NUMERIC) AS avg_length_km
FROM read_shapefile_wkt('/data/tanzania_roads')
GROUP BY attributes[2]
ORDER BY total_length_km DESC;

-- ============================================
-- EXAMPLE 19: Spatial Analysis
-- ============================================

-- Find which districts each road passes through
SELECT 
    r.attributes[1] AS road_code,
    d.district_name,
    ST_Length(
        ST_Intersection(
            ST_GeomFromText(r.geom_wkt, 4326),
            d.geom
        )::geography
    ) / 1000 AS length_in_district_km
FROM read_shapefile_wkt('/data/tanzania_roads') r
CROSS JOIN districts d
WHERE ST_Intersects(
    ST_GeomFromText(r.geom_wkt, 4326),
    d.geom
)
ORDER BY r.attributes[1], length_in_district_km DESC;

-- ============================================
-- EXAMPLE 20: Complete Workflow
-- ============================================

-- Complete workflow: Load shapefile → Process → Export

-- Step 1: Load roads
CREATE TABLE IF NOT EXISTS processed_roads AS
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    attributes[3] AS surface,
    attributes[4]::NUMERIC AS length_km,
    geom_wkb::geometry AS geom
FROM read_shapefile_wkb('/data/tanzania_roads');

-- Step 2: Add chainage markers every 10km
CREATE TABLE IF NOT EXISTS chainage_markers AS
SELECT 
    road_code,
    chainage_km,
    cut_line_at_chainage(ST_AsText(geom), chainage_km) AS marker_point
FROM processed_roads
CROSS JOIN generate_series(0, 1000, 10) AS chainage_km
WHERE chainage_km <= length_km;

-- Step 3: Identify maintenance zones (sections needing work)
CREATE TABLE IF NOT EXISTS maintenance_zones AS
SELECT 
    road_code,
    start_km,
    end_km,
    get_section_by_chainage(ST_AsText(geom), start_km, end_km) AS section_info
FROM processed_roads
CROSS JOIN LATERAL (
    VALUES 
        (0, 10),
        (10, 20),
        (20, 30)
    -- Add more sections as needed
) AS zones(start_km, end_km)
WHERE end_km <= length_km;

-- Step 4: Generate report
SELECT 
    road_code,
    road_class,
    COUNT(DISTINCT chainage_km) AS chainage_markers,
    COUNT(DISTINCT start_km) AS maintenance_zones,
    length_km
FROM processed_roads
LEFT JOIN chainage_markers USING (road_code)
LEFT JOIN maintenance_zones USING (road_code)
GROUP BY road_code, road_class, length_km
ORDER BY length_km DESC;

-- ============================================
-- CLEANUP
-- ============================================

-- Drop temporary tables/views when done
-- DROP TABLE IF EXISTS roads CASCADE;
-- DROP TABLE IF EXISTS districts CASCADE;
-- DROP VIEW IF EXISTS roads_live CASCADE;
-- DROP MATERIALIZED VIEW IF EXISTS roads_materialized CASCADE;
-- DROP TABLE IF EXISTS gps_readings CASCADE;
-- DROP TABLE IF EXISTS processed_roads CASCADE;
-- DROP TABLE IF EXISTS chainage_markers CASCADE;
-- DROP TABLE IF EXISTS maintenance_zones CASCADE;

-- ============================================
-- END OF EXAMPLES
-- ============================================
