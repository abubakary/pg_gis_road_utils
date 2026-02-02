# Shapefile Reader Examples

## Complete guide to using the shapefile reader functions in pg_gis_road_utils extension

---

## Prerequisites

Before running these examples, ensure you have:

1. ✅ Extension installed: `CREATE EXTENSION pg_gis_road_utils;`
2. ✅ PostGIS installed (optional but recommended): `CREATE EXTENSION postgis;`
3. ✅ Shapefile data with .shp and .dbf files

---

## Table of Contents

1. [Basic Usage](#basic-usage)
2. [Loading Data into Tables](#loading-data-into-tables)
3. [PostGIS Integration](#postgis-integration)
4. [Combining with Road Utilities](#combining-with-road-utilities)
5. [Performance Examples](#performance-examples)
6. [Real-World Tanzania Examples](#real-world-tanzania-examples)

---

## Basic Usage

### Example 1: Read First 10 Records (WKT)

```sql
-- See what's in the shapefile
SELECT * 
FROM read_shapefile_wkt('/data/tanzania/roads') 
LIMIT 10;

-- Returns:
 record_num |           attributes            |              geom_wkt
------------+---------------------------------+-------------------------------------
          1 | {T1,Trunk Road,Paved,150}      | LINESTRING(39.2083 -6.7924, ...)
          2 | {T7,Trunk Road,Paved,230}      | LINESTRING(34.8833 -6.1667, ...)
          3 | {R127,Regional Road,Gravel,85} | LINESTRING(33.4167 -7.2500, ...)
```

### Example 2: Access Specific Attributes

```sql
-- Extract individual attribute columns
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    attributes[3] AS surface,
    attributes[4] AS length_km,
    geom_wkt
FROM read_shapefile_wkt('/data/tanzania/roads')
LIMIT 5;
```

### Example 3: Count Records

```sql
-- How many features in the shapefile?
SELECT COUNT(*) AS total_features
FROM read_shapefile_wkt('/data/tanzania/roads');

-- Returns:
 total_features
----------------
           1547
```

### Example 4: Using WKB Format

```sql
-- WKB is binary format (faster, smaller)
SELECT 
    record_num,
    attributes[1] AS district_name,
    length(geom_wkb) AS wkb_size_bytes
FROM read_shapefile_wkb('/data/tanzania/districts')
LIMIT 5;

-- Returns:
 record_num | district_name | wkb_size_bytes
------------+---------------+----------------
          1 | Ilala         |           2458
          2 | Kinondoni     |           3892
          3 | Temeke        |           2156
```

---

## Loading Data into Tables

### Example 5: Create Table from Shapefile (WKT)

```sql
-- Create table with proper types
CREATE TABLE roads (
    id SERIAL PRIMARY KEY,
    record_num INTEGER,
    road_code TEXT,
    road_class TEXT,
    surface TEXT,
    length_km NUMERIC,
    geom_wkt TEXT
);

-- Load data from shapefile
INSERT INTO roads (record_num, road_code, road_class, surface, length_km, geom_wkt)
SELECT 
    record_num,
    attributes[1],
    attributes[2],
    attributes[3],
    attributes[4]::NUMERIC,
    geom_wkt
FROM read_shapefile_wkt('/data/tanzania/roads');

-- Verify
SELECT COUNT(*) FROM roads;
```

### Example 6: Create Table with PostGIS Geometry (WKB)

```sql
-- Create table with PostGIS geometry column
CREATE TABLE districts (
    id SERIAL PRIMARY KEY,
    record_num INTEGER,
    district_name TEXT,
    region TEXT,
    population INTEGER,
    geom GEOMETRY(POLYGON, 4326)
);

-- Load data (WKB casts directly to geometry)
INSERT INTO districts (record_num, district_name, region, population, geom)
SELECT 
    record_num,
    attributes[1],
    attributes[2],
    attributes[3]::INTEGER,
    geom_wkb::geometry  -- Direct cast!
FROM read_shapefile_wkb('/data/tanzania/districts');

-- Create spatial index
CREATE INDEX districts_geom_idx ON districts USING GIST (geom);

-- Verify
SELECT COUNT(*) FROM districts;
```

### Example 7: Filtered Loading

```sql
-- Load only paved trunk roads
CREATE TABLE trunk_roads AS
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    ST_GeomFromText(geom_wkt, 4326) AS geom
FROM read_shapefile_wkt('/data/tanzania/roads')
WHERE attributes[2] = 'Trunk Road' 
  AND attributes[3] = 'Paved';

-- Check what we loaded
SELECT road_code, road_class FROM trunk_roads;
```

---

## PostGIS Integration

### Example 8: Spatial Query - Find Districts Containing Point

```sql
-- Load districts
CREATE TEMP TABLE temp_districts AS
SELECT 
    attributes[1] AS district_name,
    geom_wkb::geometry AS geom
FROM read_shapefile_wkb('/data/tanzania/districts');

-- Find which district contains Dar es Salaam center
SELECT district_name
FROM temp_districts
WHERE ST_Contains(
    geom,
    ST_SetSRID(ST_MakePoint(39.2083, -6.7924), 4326)
);

-- Returns:
 district_name
---------------
 Ilala
```

### Example 9: Calculate Road Lengths

```sql
-- Load roads and calculate actual lengths
CREATE TABLE roads_with_length AS
SELECT 
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    geom_wkb::geometry AS geom,
    ST_Length(
        ST_Transform(geom_wkb::geometry, 32737)  -- Transform to UTM Zone 37S for meters
    ) / 1000.0 AS length_km
FROM read_shapefile_wkb('/data/tanzania/roads');

-- Find total road length by class
SELECT 
    road_class,
    COUNT(*) AS num_roads,
    ROUND(SUM(length_km)::numeric, 2) AS total_length_km
FROM roads_with_length
GROUP BY road_class
ORDER BY total_length_km DESC;

-- Returns:
    road_class     | num_roads | total_length_km
-------------------+-----------+-----------------
 Trunk Road        |       147 |        12458.34
 Regional Road     |       453 |         8932.17
 District Road     |       947 |         5623.89
```

### Example 10: Buffer Analysis

```sql
-- Find settlements within 5km of trunk roads
CREATE TEMP TABLE roads_buffered AS
SELECT 
    attributes[1] AS road_code,
    ST_Buffer(
        ST_Transform(geom_wkb::geometry, 32737),
        5000  -- 5km buffer in meters
    ) AS geom_buffer
FROM read_shapefile_wkb('/data/tanzania/roads')
WHERE attributes[2] = 'Trunk Road';

CREATE TEMP TABLE settlements AS
SELECT 
    attributes[1] AS settlement_name,
    geom_wkb::geometry AS geom
FROM read_shapefile_wkb('/data/tanzania/settlements');

-- Find settlements within buffer
SELECT DISTINCT s.settlement_name
FROM settlements s
JOIN roads_buffered r ON ST_Intersects(
    ST_Transform(s.geom, 32737),
    r.geom_buffer
);
```

---

## Combining with Road Utilities

### Example 11: Extract Road Segments by Chainage

```sql
-- Load a specific road
CREATE TEMP TABLE road_t1 AS
SELECT 
    attributes[1] AS road_code,
    geom_wkt
FROM read_shapefile_wkt('/data/tanzania/roads')
WHERE attributes[1] = 'T1';

-- Extract segment from km 50 to km 75
SELECT 
    road_code,
    get_section_by_chainage(geom_wkt, 50.0, 75.0) AS section_info
FROM road_t1;

-- Returns JSON:
{
  "start_ch": 50.0,
  "end_ch": 75.0,
  "start_lat": -6.8234,
  "start_lon": 39.2567,
  "end_lat": -6.9123,
  "end_lon": 39.3456,
  "length": 25.0,
  "geometry": "LINESTRING(...)"
}
```

### Example 12: Generate Kilometer Posts

```sql
-- Load road network
CREATE TABLE road_network AS
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    ST_GeomFromText(geom_wkt, 4326) AS geom,
    attributes[4]::NUMERIC AS total_length_km
FROM read_shapefile_wkt('/data/tanzania/roads');

-- Generate kilometer posts for trunk roads
CREATE TABLE kilometer_posts AS
SELECT 
    r.road_code,
    km_num,
    cut_line_at_chainage(ST_AsText(r.geom), km_num::DOUBLE PRECISION) AS post_location
FROM road_network r
CROSS JOIN LATERAL generate_series(0, r.total_length_km::INTEGER) AS km_num
WHERE r.road_class = 'Trunk Road';

-- Convert WKT to geometry
ALTER TABLE kilometer_posts ADD COLUMN geom GEOMETRY(POINT, 4326);
UPDATE kilometer_posts SET geom = ST_GeomFromText(post_location, 4326);

-- View posts for Road T1
SELECT road_code, km_num, ST_AsText(geom)
FROM kilometer_posts
WHERE road_code = 'T1'
ORDER BY km_num
LIMIT 10;
```

### Example 13: Calibrate GPS Points on Roads

```sql
-- Load roads
CREATE TEMP TABLE roads AS
SELECT 
    attributes[1] AS road_code,
    geom_wkt
FROM read_shapefile_wkt('/data/tanzania/roads');

-- Sample GPS points from vehicles
CREATE TEMP TABLE gps_points (
    vehicle_id TEXT,
    timestamp TIMESTAMP,
    lat DOUBLE PRECISION,
    lon DOUBLE PRECISION
);

INSERT INTO gps_points VALUES
    ('BUS-001', '2025-01-30 10:15:00', -6.7950, 39.2100),
    ('BUS-001', '2025-01-30 10:20:00', -6.8100, 39.2200),
    ('BUS-002', '2025-01-30 10:15:00', -6.8300, 39.2400);

-- Calibrate GPS points to nearest road
SELECT 
    g.vehicle_id,
    g.timestamp,
    r.road_code,
    calibrate_point_on_line(
        r.geom_wkt,
        'POINT(' || g.lon || ' ' || g.lat || ')',
        1000000.0  -- Large search radius
    ) AS calibration_info
FROM gps_points g
CROSS JOIN LATERAL (
    SELECT road_code, geom_wkt
    FROM roads
    WHERE road_code IN ('T1', 'T7')  -- Check main roads
    LIMIT 1
) r;

-- Returns:
 vehicle_id |      timestamp      | road_code |           calibration_info
------------+---------------------+-----------+-------------------------------------
 BUS-001    | 2025-01-30 10:15:00 | T1        | {"chainage":45.234,"lat":-6.7951,...}
```

---

## Performance Examples

### Example 14: Efficient Large Dataset Loading

```sql
-- For large shapefiles (millions of records), use COPY
-- First, create a view
CREATE VIEW roads_from_shapefile AS
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    attributes[3] AS surface,
    geom_wkb
FROM read_shapefile_wkb('/data/tanzania/roads_large');

-- Then load with single transaction
BEGIN;

CREATE TABLE roads_large (
    id SERIAL PRIMARY KEY,
    record_num INTEGER,
    road_code TEXT,
    road_class TEXT,
    surface TEXT,
    geom GEOMETRY(LINESTRING, 4326)
);

INSERT INTO roads_large (record_num, road_code, road_class, surface, geom)
SELECT 
    record_num,
    road_code,
    road_class,
    surface,
    geom_wkb::geometry
FROM roads_from_shapefile;

CREATE INDEX roads_large_geom_idx ON roads_large USING GIST (geom);
CREATE INDEX roads_large_road_code_idx ON roads_large (road_code);

COMMIT;

-- Check performance
EXPLAIN ANALYZE
SELECT road_code, ST_Length(geom)
FROM roads_large
WHERE ST_DWithin(geom, ST_MakePoint(39.2083, -6.7924), 0.1);
```

### Example 15: Parallel Processing

```sql
-- Enable parallel workers
SET max_parallel_workers_per_gather = 4;

-- Load with parallel processing
CREATE TABLE roads_parallel AS
SELECT 
    record_num,
    attributes[1] AS road_code,
    ST_Transform(geom_wkb::geometry, 32737) AS geom
FROM read_shapefile_wkb('/data/tanzania/roads_very_large')
WHERE record_num % 4 = 0;  -- Partition hint for parallel

-- Verify parallel execution
EXPLAIN (ANALYZE, BUFFERS)
SELECT road_code, ST_Length(geom)
FROM roads_parallel;
```

---

## Real-World Tanzania Examples

### Example 16: TEHAMA Road Maintenance System

```sql
-- Complete workflow for road maintenance planning

-- Step 1: Load road network
CREATE TABLE tehama_roads (
    road_id SERIAL PRIMARY KEY,
    road_code TEXT UNIQUE,
    road_name TEXT,
    road_class TEXT,
    surface_type TEXT,
    total_length_km NUMERIC,
    last_maintained DATE,
    condition TEXT,
    geom GEOMETRY(LINESTRING, 4326)
);

INSERT INTO tehama_roads (road_code, road_name, road_class, surface_type, total_length_km, geom)
SELECT 
    attributes[1],  -- ROAD_CODE
    attributes[2],  -- ROAD_NAME
    attributes[3],  -- ROAD_CLASS
    attributes[4],  -- SURFACE
    attributes[5]::NUMERIC,  -- LENGTH_KM
    geom_wkb::geometry
FROM read_shapefile_wkb('/data/tehama/national_roads');

-- Step 2: Define maintenance sections (every 10km)
CREATE TABLE maintenance_sections (
    section_id SERIAL PRIMARY KEY,
    road_code TEXT,
    section_number INTEGER,
    start_km NUMERIC,
    end_km NUMERIC,
    section_geom GEOMETRY(LINESTRING, 4326),
    last_inspection DATE,
    condition_rating INTEGER  -- 1-5 scale
);

INSERT INTO maintenance_sections (road_code, section_number, start_km, end_km, section_geom)
SELECT 
    r.road_code,
    (km / 10) + 1 AS section_number,
    km AS start_km,
    LEAST(km + 10, r.total_length_km) AS end_km,
    ST_GeomFromText(
        (get_section_by_chainage(
            ST_AsText(r.geom),
            km::DOUBLE PRECISION,
            LEAST(km + 10, r.total_length_km)::DOUBLE PRECISION
        )::json->>'geometry')::text,
        4326
    ) AS section_geom
FROM tehama_roads r
CROSS JOIN LATERAL generate_series(0, (r.total_length_km - 1)::INTEGER, 10) AS km;

-- Step 3: Assign regions and regions
UPDATE maintenance_sections ms
SET condition_rating = (
    CASE 
        WHEN r.surface_type = 'Paved' AND r.last_maintained > CURRENT_DATE - INTERVAL '2 years' THEN 5
        WHEN r.surface_type = 'Paved' THEN 3
        WHEN r.surface_type = 'Gravel' THEN 2
        ELSE 1
    END
)
FROM tehama_roads r
WHERE ms.road_code = r.road_code;

-- Step 4: Generate maintenance report
SELECT 
    road_code,
    COUNT(*) AS total_sections,
    SUM(CASE WHEN condition_rating <= 2 THEN 1 ELSE 0 END) AS critical_sections,
    AVG(condition_rating) AS avg_condition,
    SUM(end_km - start_km) AS total_km
FROM maintenance_sections
GROUP BY road_code
ORDER BY avg_condition ASC, critical_sections DESC
LIMIT 20;
```

### Example 17: Regional Road Coverage Analysis

```sql
-- Load administrative boundaries
CREATE TABLE regions AS
SELECT 
    attributes[1] AS region_name,
    attributes[2] AS region_code,
    attributes[3]::INTEGER AS population,
    geom_wkb::geometry AS geom
FROM read_shapefile_wkb('/data/tehama/regions');

-- Load roads
CREATE TABLE roads AS
SELECT 
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    geom_wkb::geometry AS geom
FROM read_shapefile_wkb('/data/tehama/roads');

-- Calculate road coverage per region
SELECT 
    r.region_name,
    r.population,
    COUNT(DISTINCT rd.road_code) AS num_roads,
    ROUND(
        SUM(
            ST_Length(
                ST_Transform(
                    ST_Intersection(rd.geom, r.geom),
                    32737
                )
            )
        ) / 1000.0, 2
    ) AS total_road_km,
    ROUND(
        (SUM(ST_Length(ST_Transform(ST_Intersection(rd.geom, r.geom), 32737))) / 1000.0) 
        / (r.population::NUMERIC / 1000.0),
        4
    ) AS km_per_1000_people
FROM regions r
LEFT JOIN roads rd ON ST_Intersects(r.geom, rd.geom)
GROUP BY r.region_name, r.population
ORDER BY km_per_1000_people ASC;
```

### Example 18: Export to GeoJSON for Web Maps

```sql
-- Create GeoJSON for web application
SELECT json_build_object(
    'type', 'FeatureCollection',
    'features', json_agg(
        json_build_object(
            'type', 'Feature',
            'geometry', ST_AsGeoJSON(geom)::json,
            'properties', json_build_object(
                'road_code', road_code,
                'road_class', road_class,
                'surface', surface,
                'length_km', length_km
            )
        )
    )
)
FROM (
    SELECT 
        attributes[1] AS road_code,
        attributes[2] AS road_class,
        attributes[3] AS surface,
        attributes[4]::NUMERIC AS length_km,
        geom_wkb::geometry AS geom
    FROM read_shapefile_wkb('/data/tehama/trunk_roads')
    WHERE attributes[2] = 'Trunk Road'
) AS roads;

-- Save to file (psql)
\o /tmp/trunk_roads.geojson
-- Run the above query
\o
```

---

## Best Practices

### 1. Always Check Shapefile Structure First

```sql
-- Inspect first record
SELECT * FROM read_shapefile_wkt('/path/to/file') LIMIT 1;

-- Check attribute count
SELECT 
    record_num,
    array_length(attributes, 1) AS num_attributes
FROM read_shapefile_wkt('/path/to/file')
LIMIT 1;
```

### 2. Use WKB for Production

```sql
-- WKB is faster and smaller
-- Use for large datasets and production loads
CREATE TABLE prod_data AS
SELECT * FROM read_shapefile_wkb('/data/production/roads');
```

### 3. Create Indexes After Loading

```sql
-- Load first, index after
CREATE TABLE roads AS SELECT * FROM read_shapefile_wkb('/data/roads');

-- Then create indexes
CREATE INDEX roads_geom_idx ON roads USING GIST (geom_wkb::geometry);
CREATE INDEX roads_code_idx ON roads ((attributes[1]));
```

### 4. Use Views for Repeated Access

```sql
-- Instead of querying shapefile repeatedly
CREATE VIEW roads_view AS
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    geom_wkb::geometry AS geom
FROM read_shapefile_wkb('/data/roads');

-- Now query the view
SELECT * FROM roads_view WHERE road_class = 'Trunk Road';
```

---

## Troubleshooting

### Issue: "Could not open shapefile"

```sql
-- Check file permissions
\! ls -la /data/roads.shp
\! ls -la /data/roads.dbf

-- Try absolute path
SELECT * FROM read_shapefile_wkt('/full/absolute/path/to/roads');
```

### Issue: Attributes show as NULL

```sql
-- DBF file might be missing or corrupted
-- Check if .dbf exists
\! ls -la /data/roads.dbf

-- Try reading just geometry
SELECT record_num, geom_wkt 
FROM read_shapefile_wkt('/data/roads') 
LIMIT 5;
```

### Issue: Geometry appears incorrect

```sql
-- Check geometry type
SELECT 
    record_num,
    ST_GeometryType(ST_GeomFromText(geom_wkt)) AS geom_type
FROM read_shapefile_wkt('/data/file')
LIMIT 5;

-- Check if coordinates make sense
SELECT 
    ST_XMin(ST_GeomFromText(geom_wkt)) AS min_x,
    ST_YMin(ST_GeomFromText(geom_wkt)) AS min_y,
    ST_XMax(ST_GeomFromText(geom_wkt)) AS max_x,
    ST_YMax(ST_GeomFromText(geom_wkt)) AS max_y
FROM read_shapefile_wkt('/data/file')
LIMIT 1;
```

---

## Summary

The shapefile reader functions provide powerful capabilities for:

✅ Reading ESRI Shapefiles directly into PostgreSQL  
✅ Preserving all attributes from DBF files  
✅ Supporting both WKT and WKB geometry formats  
✅ Integrating seamlessly with PostGIS  
✅ Combining with road chainage utilities  
✅ Building production GIS applications  

Perfect for TEHAMA's road management system! 🛣️🗺️
