-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_gis_road_utils" to load this file. \quit

-- ============================================
-- Function: get_section_by_chainage
-- ============================================
-- Extracts a line segment between two chainages and returns detailed information
-- Returns JSON with: start_ch, end_ch, start_lat, start_lon, end_lat, end_lon, length, geometry

CREATE OR REPLACE FUNCTION get_section_by_chainage(
    line_wkt TEXT,
    start_chainage DOUBLE PRECISION,
    end_chainage DOUBLE PRECISION
)
RETURNS JSON
AS 'MODULE_PATHNAME', 'get_section_by_chainage'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION get_section_by_chainage IS 
'Extract line segment between two chainages (in kilometers). 
Returns JSON with segment details including geometry (WKT), start/end coordinates, and length.
Example: SELECT get_section_by_chainage(''LINESTRING(0 0, 10 0, 10 10)'', 2.5, 7.5);';

-- ============================================
-- Function: cut_line_at_chainage
-- ============================================
-- Returns a point at the specified chainage along a line

CREATE OR REPLACE FUNCTION cut_line_at_chainage(
    line_wkt TEXT,
    chainage DOUBLE PRECISION
)
RETURNS TEXT
AS 'MODULE_PATHNAME', 'cut_line_at_chainage'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION cut_line_at_chainage IS 
'Returns a point (WKT) at the specified chainage (in kilometers) along a line.
Example: SELECT cut_line_at_chainage(''LINESTRING(0 0, 10 0)'', 5.0);';

-- ============================================
-- Function: calibrate_point_on_line
-- ============================================
-- Finds the closest point on a line to a reference point within a radius
-- Returns chainage, lat, lon, and index

CREATE OR REPLACE FUNCTION calibrate_point_on_line(
    line_wkt TEXT,
    point_wkt TEXT,
    radius DOUBLE PRECISION DEFAULT 1.0
)
RETURNS JSON
AS 'MODULE_PATHNAME', 'calibrate_point_on_line'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION calibrate_point_on_line IS 
'Calibrates a point on a line by finding the closest point within a radius.
Returns JSON with: chainage (km), lat, lon, and vertex index.
Example: SELECT calibrate_point_on_line(''LINESTRING(0 0, 10 0)'', ''POINT(5 0.1)'', 1.0);';

-- ============================================
-- Convenience wrapper functions using PostGIS geometries
-- ============================================

-- Get section by chainage using PostGIS geometry
CREATE OR REPLACE FUNCTION get_section_by_chainage_geom(
    line_geom GEOMETRY,
    start_chainage DOUBLE PRECISION,
    end_chainage DOUBLE PRECISION
)
RETURNS JSON
AS $$
    SELECT get_section_by_chainage(
        ST_AsText(line_geom),
        start_chainage,
        end_chainage
    );
$$ LANGUAGE SQL IMMUTABLE STRICT;

COMMENT ON FUNCTION get_section_by_chainage_geom IS 
'PostGIS geometry wrapper for get_section_by_chainage.
Example: SELECT get_section_by_chainage_geom(geom, 2.5, 7.5) FROM roads WHERE id = 1;';

-- Cut line at chainage using PostGIS geometry
CREATE OR REPLACE FUNCTION cut_line_at_chainage_geom(
    line_geom GEOMETRY,
    chainage DOUBLE PRECISION
)
RETURNS GEOMETRY
AS $$
    SELECT ST_GeomFromText(
        cut_line_at_chainage(
            ST_AsText(line_geom),
            chainage
        ),
        ST_SRID(line_geom)
    );
$$ LANGUAGE SQL IMMUTABLE STRICT;

COMMENT ON FUNCTION cut_line_at_chainage_geom IS 
'PostGIS geometry wrapper for cut_line_at_chainage. Returns a PostGIS POINT geometry.
Example: SELECT cut_line_at_chainage_geom(geom, 5.0) FROM roads WHERE id = 1;';

-- Calibrate point using PostGIS geometries
CREATE OR REPLACE FUNCTION calibrate_point_on_line_geom(
    line_geom GEOMETRY,
    point_geom GEOMETRY,
    radius DOUBLE PRECISION DEFAULT 1.0
)
RETURNS JSON
AS $$
    SELECT calibrate_point_on_line(
        ST_AsText(line_geom),
        ST_AsText(point_geom),
        radius
    );
$$ LANGUAGE SQL IMMUTABLE STRICT;

COMMENT ON FUNCTION calibrate_point_on_line_geom IS 
'PostGIS geometry wrapper for calibrate_point_on_line.
Example: SELECT calibrate_point_on_line_geom(road_geom, point_geom, 1.0) FROM roads;';

-- ============================================
-- Helper function to extract geometry from section JSON
-- ============================================

CREATE OR REPLACE FUNCTION extract_section_geometry(
    section_json JSON,
    srid INTEGER DEFAULT 4326
)
RETURNS GEOMETRY
AS $$
    SELECT ST_GeomFromText(section_json->>'geometry', srid);
$$ LANGUAGE SQL IMMUTABLE STRICT;

COMMENT ON FUNCTION extract_section_geometry IS 
'Extract geometry from section JSON returned by get_section_by_chainage.
Example: SELECT extract_section_geometry(section_json, 4326);';

-- ============================================
-- Table-based functions for road management
-- ============================================

-- Function to generate kilometer posts for a road
CREATE OR REPLACE FUNCTION generate_kilometer_posts(
    road_geom GEOMETRY,
    interval_km DOUBLE PRECISION DEFAULT 1.0,
    start_km DOUBLE PRECISION DEFAULT 0.0
)
RETURNS TABLE (
    km_post DOUBLE PRECISION,
    point_geom GEOMETRY
)
AS $$
DECLARE
    total_length_km DOUBLE PRECISION;
    current_km DOUBLE PRECISION;
    point_wkt TEXT;
BEGIN
    -- Calculate total length in km (approximate)
    total_length_km := ST_Length(road_geom::geography) / 1000.0;
    
    current_km := start_km;
    
    WHILE current_km <= total_length_km LOOP
        BEGIN
            point_wkt := cut_line_at_chainage(ST_AsText(road_geom), current_km);
            
            IF point_wkt IS NOT NULL THEN
                km_post := current_km;
                point_geom := ST_GeomFromText(point_wkt, ST_SRID(road_geom));
                RETURN NEXT;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Skip this point if it fails
            NULL;
        END;
        
        current_km := current_km + interval_km;
    END LOOP;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

COMMENT ON FUNCTION generate_kilometer_posts IS 
'Generate kilometer posts along a road at specified intervals.
Example: SELECT * FROM generate_kilometer_posts(geom, 1.0, 0.0) WHERE km_post <= 10;';

-- Grant permissions



-- ============================================
-- SHAPEFILE READER FUNCTIONS
-- ============================================

-- ============================================
-- Function: read_shapefile_wkt
-- ============================================
-- Reads a shapefile and returns records with WKT geometry
-- Returns TABLE: (record_num INT, attributes TEXT[], geom_wkt TEXT)

CREATE OR REPLACE FUNCTION read_shapefile_wkt(
    shapefile_path TEXT
)
RETURNS TABLE (
    record_num INTEGER,
    attributes TEXT[],
    geom_wkt TEXT
)
AS 'MODULE_PATHNAME', 'read_shapefile_wkt'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION read_shapefile_wkt IS
'Read shapefile and return records with WKT geometry.
Arguments:
  shapefile_path - Path to shapefile without extension (e.g., ''/data/roads'')
Returns:
  record_num - Record number from shapefile
  attributes - Array of attribute values from DBF file
  geom_wkt - Geometry in Well-Known Text format
Example:
  SELECT * FROM read_shapefile_wkt(''/data/tanzania_roads'');
  SELECT record_num, attributes[1] AS name, geom_wkt 
  FROM read_shapefile_wkt(''/data/districts'');';

-- ============================================
-- Function: read_shapefile_wkb
-- ============================================
-- Reads a shapefile and returns records with WKB geometry
-- Returns TABLE: (record_num INT, attributes TEXT[], geom_wkb BYTEA)

CREATE OR REPLACE FUNCTION read_shapefile_wkb(
    shapefile_path TEXT
)
RETURNS TABLE (
    record_num INTEGER,
    attributes TEXT[],
    geom_wkb BYTEA
)
AS 'MODULE_PATHNAME', 'read_shapefile_wkb'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION read_shapefile_wkb IS
'Read shapefile and return records with WKB (Well-Known Binary) geometry.
Arguments:
  shapefile_path - Path to shapefile without extension
Returns:
  record_num - Record number from shapefile
  attributes - Array of attribute values from DBF file
  geom_wkb - Geometry in Well-Known Binary format (BYTEA)
Example:
  SELECT * FROM read_shapefile_wkb(''/data/tanzania_roads'');
  SELECT record_num, attributes[1], ST_AsText(geom_wkb::geometry)
  FROM read_shapefile_wkb(''/data/districts'');';



-- ============================================
-- Function: read_shapefile_test
-- ============================================

CREATE OR REPLACE FUNCTION read_shapefile_test()
RETURNS TABLE (
    record_num INTEGER,
    attributes TEXT[],
    geom_wkb BYTEA
)
AS 'MODULE_PATHNAME', 'read_shapefile_test'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION read_shapefile_test IS
'Returns a small dummy shapefile with 2 records for testing WKB.';

