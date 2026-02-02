-- ============================================
-- Shapefile Reader Test Suite
-- ============================================
-- Tests for read_shapefile_wkt and read_shapefile_wkb functions
--
-- NOTE: These tests require sample shapefile data
-- Update paths to match your data location

\echo '=========================================='
\echo 'Shapefile Reader Function Tests'
\echo '=========================================='
\echo ''

-- ============================================
-- Test 1: Basic WKT Reading
-- ============================================
\echo 'Test 1: Read shapefile with WKT format'
\echo '--------------------------------------'

-- Create test table
DROP TABLE IF EXISTS test_roads_wkt;
CREATE TEMP TABLE test_roads_wkt AS
SELECT * 
FROM read_shapefile_wkt('/data/test/sample_roads') 
LIMIT 5;

-- Verify structure
\echo 'Column info:'
\d test_roads_wkt

-- Show data
\echo 'Sample records:'
SELECT 
    record_num,
    array_length(attributes, 1) AS num_attrs,
    substring(geom_wkt, 1, 50) AS geom_preview
FROM test_roads_wkt;

\echo ''

-- ============================================
-- Test 2: Basic WKB Reading
-- ============================================
\echo 'Test 2: Read shapefile with WKB format'
\echo '--------------------------------------'

DROP TABLE IF EXISTS test_roads_wkb;
CREATE TEMP TABLE test_roads_wkb AS
SELECT * 
FROM read_shapefile_wkb('/data/test/sample_roads') 
LIMIT 5;

-- Verify binary data
\echo 'WKB sizes:'
SELECT 
    record_num,
    length(geom_wkb) AS wkb_bytes,
    length(attributes::text) AS attr_bytes
FROM test_roads_wkb;

\echo ''

-- ============================================
-- Test 3: Attribute Access
-- ============================================
\echo 'Test 3: Extract individual attributes'
\echo '--------------------------------------'

SELECT 
    record_num,
    attributes[1] AS attr_1,
    attributes[2] AS attr_2,
    attributes[3] AS attr_3
FROM read_shapefile_wkt('/data/test/sample_roads')
LIMIT 5;

\echo ''

-- ============================================
-- Test 4: Record Count
-- ============================================
\echo 'Test 4: Count total records'
\echo '--------------------------------------'

SELECT COUNT(*) AS total_records
FROM read_shapefile_wkt('/data/test/sample_roads');

\echo ''

-- ============================================
-- Test 5: PostGIS Integration (WKT)
-- ============================================
\echo 'Test 5: Convert WKT to PostGIS geometry'
\echo '--------------------------------------'

DO $$
BEGIN
    -- Check if PostGIS is available
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
        -- Create table with geometry
        DROP TABLE IF EXISTS test_postgis_wkt;
        CREATE TEMP TABLE test_postgis_wkt AS
        SELECT 
            record_num,
            attributes,
            ST_GeomFromText(geom_wkt, 4326) AS geom
        FROM read_shapefile_wkt('/data/test/sample_roads')
        LIMIT 5;
        
        -- Test geometric operations
        RAISE NOTICE 'Geometry types:';
        PERFORM 
            record_num,
            ST_GeometryType(geom) AS geom_type,
            ST_NPoints(geom) AS num_points
        FROM test_postgis_wkt;
    ELSE
        RAISE NOTICE 'PostGIS not installed - skipping geometry tests';
    END IF;
END $$;

\echo ''

-- ============================================
-- Test 6: PostGIS Integration (WKB)
-- ============================================
\echo 'Test 6: Convert WKB to PostGIS geometry'
\echo '--------------------------------------'

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
        DROP TABLE IF EXISTS test_postgis_wkb;
        CREATE TEMP TABLE test_postgis_wkb AS
        SELECT 
            record_num,
            attributes,
            geom_wkb::geometry AS geom
        FROM read_shapefile_wkb('/data/test/sample_roads')
        LIMIT 5;
        
        RAISE NOTICE 'WKB to geometry conversion successful';
        
        -- Show geometry info
        PERFORM 
            record_num,
            ST_GeometryType(geom) AS geom_type,
            ST_Length(geom) AS length
        FROM test_postgis_wkb;
    END IF;
END $$;

\echo ''

-- ============================================
-- Test 7: Filtered Loading
-- ============================================
\echo 'Test 7: Load with WHERE clause'
\echo '--------------------------------------'

-- Filter during load
SELECT COUNT(*) AS filtered_count
FROM read_shapefile_wkt('/data/test/sample_roads')
WHERE attributes[1] LIKE 'T%';  -- Roads starting with 'T'

\echo ''

-- ============================================
-- Test 8: Large Dataset Performance
-- ============================================
\echo 'Test 8: Performance test (first 1000 records)'
\echo '--------------------------------------'

\timing on

-- WKT timing
SELECT COUNT(*) AS wkt_count
FROM read_shapefile_wkt('/data/test/sample_roads')
LIMIT 1000;

-- WKB timing
SELECT COUNT(*) AS wkb_count
FROM read_shapefile_wkb('/data/test/sample_roads')
LIMIT 1000;

\timing off

\echo ''

-- ============================================
-- Test 9: Integration with Road Utilities
-- ============================================
\echo 'Test 9: Combine with get_section_by_chainage'
\echo '--------------------------------------'

-- Load a road
CREATE TEMP TABLE test_road AS
SELECT 
    attributes[1] AS road_code,
    geom_wkt
FROM read_shapefile_wkt('/data/test/sample_roads')
LIMIT 1;

-- Extract section
SELECT 
    road_code,
    get_section_by_chainage(geom_wkt, 0.0, 5.0) AS section_data
FROM test_road;

\echo ''

-- ============================================
-- Test 10: Integration with calibrate_point_on_line
-- ============================================
\echo 'Test 10: Calibrate GPS point on road'
\echo '--------------------------------------'

-- Create test point near road
CREATE TEMP TABLE test_road_for_calibration AS
SELECT 
    attributes[1] AS road_code,
    geom_wkt
FROM read_shapefile_wkt('/data/test/sample_roads')
LIMIT 1;

-- Calibrate point (use large radius for testing)
SELECT 
    road_code,
    calibrate_point_on_line(
        geom_wkt,
        'POINT(39.2083 -6.7924)',  -- Sample point
        1000000.0
    ) AS calibration_result
FROM test_road_for_calibration;

\echo ''

-- ============================================
-- Test 11: Create View from Shapefile
-- ============================================
\echo 'Test 11: Create reusable view'
\echo '--------------------------------------'

DROP VIEW IF EXISTS roads_view;
CREATE TEMP VIEW roads_view AS
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    attributes[3] AS surface,
    geom_wkt
FROM read_shapefile_wkt('/data/test/sample_roads');

-- Query the view
SELECT road_code, road_class, surface
FROM roads_view
LIMIT 5;

\echo ''

-- ============================================
-- Test 12: NULL Geometry Handling
-- ============================================
\echo 'Test 12: Handle NULL geometries'
\echo '--------------------------------------'

SELECT 
    record_num,
    CASE 
        WHEN geom_wkt IS NULL THEN 'NULL'
        WHEN geom_wkt = '' THEN 'EMPTY'
        ELSE 'VALID'
    END AS geom_status
FROM read_shapefile_wkt('/data/test/sample_roads')
LIMIT 10;

\echo ''

-- ============================================
-- Test 13: Attribute Array Operations
-- ============================================
\echo 'Test 13: Array operations on attributes'
\echo '--------------------------------------'

-- Get distinct values from first attribute
SELECT DISTINCT attributes[1] AS unique_codes
FROM read_shapefile_wkt('/data/test/sample_roads')
ORDER BY unique_codes
LIMIT 10;

-- Count by attribute
SELECT 
    attributes[2] AS category,
    COUNT(*) AS count
FROM read_shapefile_wkt('/data/test/sample_roads')
GROUP BY attributes[2]
ORDER BY count DESC;

\echo ''

-- ============================================
-- Test 14: Bounding Box Calculation
-- ============================================
\echo 'Test 14: Calculate bounding box (requires PostGIS)'
\echo '--------------------------------------'

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
        -- Get extent of all geometries
        PERFORM 
            ST_XMin(ST_Extent(ST_GeomFromText(geom_wkt))) AS min_lon,
            ST_YMin(ST_Extent(ST_GeomFromText(geom_wkt))) AS min_lat,
            ST_XMax(ST_Extent(ST_GeomFromText(geom_wkt))) AS max_lon,
            ST_YMax(ST_Extent(ST_GeomFromText(geom_wkt))) AS max_lat
        FROM read_shapefile_wkt('/data/test/sample_roads');
    ELSE
        RAISE NOTICE 'PostGIS not installed - skipping extent test';
    END IF;
END $$;

\echo ''

-- ============================================
-- Test 15: Error Handling
-- ============================================
\echo 'Test 15: Error handling for invalid path'
\echo '--------------------------------------'

-- This should fail gracefully
\set ON_ERROR_STOP off
SELECT * FROM read_shapefile_wkt('/invalid/path/to/file') LIMIT 1;
\set ON_ERROR_STOP on

\echo ''

-- ============================================
-- Summary
-- ============================================
\echo '=========================================='
\echo 'Test Summary'
\echo '=========================================='
\echo 'All basic tests completed!'
\echo ''
\echo 'To run tests with your data:'
\echo '1. Update file paths in this script'
\echo '2. Ensure .shp and .dbf files exist'
\echo '3. Run: psql -d test_db -f test_shapefile_reader.sql'
\echo ''
\echo 'For production use:'
\echo '- Use WKB format for better performance'
\echo '- Create indexes after loading'
\echo '- Use views for repeated access'
\echo '=========================================='
