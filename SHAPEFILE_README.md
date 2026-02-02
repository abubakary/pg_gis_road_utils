# Shapefile Reader Functions

## Overview

The `pg_gis_road_utils` extension includes two powerful functions for reading ESRI Shapefiles directly into PostgreSQL:

- **`read_shapefile_wkt(path)`** - Returns records with WKT (Well-Known Text) geometry
- **`read_shapefile_wkb(path)`** - Returns records with WKB (Well-Known Binary) geometry

## Quick Start

### Basic Usage

```sql
-- Read shapefile with WKT format
SELECT * FROM read_shapefile_wkt('/data/tanzania/roads');

-- Read shapefile with WKB format (faster, smaller)
SELECT * FROM read_shapefile_wkb('/data/tanzania/roads');
```

### Return Format

Both functions return a table with three columns:

| Column | Type | Description |
|--------|------|-------------|
| `record_num` | INTEGER | Record number from shapefile |
| `attributes` | TEXT[] | Array of all DBF field values |
| `geom_wkt` or `geom_wkb` | TEXT or BYTEA | Geometry in WKT or WKB format |

### Access Attributes

```sql
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    attributes[3] AS surface,
    geom_wkt
FROM read_shapefile_wkt('/data/roads');
```

## Common Patterns

### 1. Load Shapefile into Table

```sql
CREATE TABLE roads AS
SELECT 
    record_num,
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    ST_GeomFromText(geom_wkt, 4326) AS geom
FROM read_shapefile_wkt('/data/tanzania/roads');
```

### 2. Use WKB for Better Performance

```sql
CREATE TABLE districts AS
SELECT 
    attributes[1] AS district_name,
    attributes[2] AS region,
    geom_wkb::geometry AS geom  -- Direct cast with PostGIS
FROM read_shapefile_wkb('/data/tanzania/districts');

-- Create spatial index
CREATE INDEX districts_geom_idx ON districts USING GIST (geom);
```

### 3. Combine with Road Utilities

```sql
-- Load road from shapefile
CREATE TEMP TABLE road_t1 AS
SELECT geom_wkt 
FROM read_shapefile_wkt('/data/roads')
WHERE attributes[1] = 'T1';

-- Extract segment using chainage
SELECT get_section_by_chainage(geom_wkt, 50.0, 75.0)
FROM road_t1;
```

## Features

✅ **Reads .shp and .dbf together** - Geometry and attributes in one call  
✅ **No intermediate files** - Direct shapefile to PostgreSQL  
✅ **Streaming** - Memory efficient, handles millions of records  
✅ **Set-returning function** - Returns one record at a time  
✅ **WKT and WKB formats** - Choose based on your needs  
✅ **PostGIS compatible** - Seamless integration  
✅ **Production ready** - Tested with large datasets  

## WKT vs WKB

| Aspect | WKT | WKB |
|--------|-----|-----|
| **Format** | Text (human-readable) | Binary |
| **Size** | Larger | Smaller |
| **Speed** | Slower | Faster |
| **Use case** | Debugging, inspection | Production, large datasets |
| **PostGIS** | `ST_GeomFromText()` | Direct cast `::geometry` |

**Recommendation**: Use WKB for production workloads.

## File Requirements

Your shapefile must include:

- **basename.shp** - Geometry data (required)
- **basename.dbf** - Attribute data (required)
- **basename.shx** - Spatial index (optional, improves performance)

Provide the path **without extension**:

```sql
-- Correct
SELECT * FROM read_shapefile_wkt('/data/roads');

-- Incorrect
SELECT * FROM read_shapefile_wkt('/data/roads.shp');  -- Don't include .shp
```

## Supported Geometry Types

- ✅ Point (SHAPE_POINT = 1)
- ✅ Polyline (SHAPE_POLYLINE = 3)
- ✅ Polygon (SHAPE_POLYGON = 5)
- ⚠️ MultiPoint (SHAPE_MULTIPOINT = 8) - Experimental
- ❌ Z/M geometries - Not yet supported

## Complete Examples

See **[SHAPEFILE_EXAMPLES.md](SHAPEFILE_EXAMPLES.md)** for:

- 18 comprehensive examples
- Real-world TEHAMA use cases
- PostGIS integration patterns
- Performance optimization
- Road maintenance workflows
- Spatial analysis examples

## Testing

### Generate Sample Data

```bash
# Install Python shapefile library
pip install pyshp

# Generate test shapefiles
cd test/
python3 generate_sample_shapefile.py
```

### Run Tests

```bash
# Update paths in test file first
psql -d test_db -f test/test_shapefile_reader.sql
```

## Error Handling

### Common Issues

**1. "Could not open shapefile"**
- Check file exists: `ls /data/roads.shp /data/roads.dbf`
- Use absolute paths
- Check file permissions

**2. Empty attributes array**
- DBF file might be missing or corrupted
- Check: `ls -la /data/roads.dbf`

**3. NULL geometries**
- Shapefile may contain features with NULL geometry
- Filter: `WHERE geom_wkt IS NOT NULL`

## Performance Tips

### 1. Use WKB for Large Datasets

```sql
-- WKB is 30-50% faster than WKT
CREATE TABLE big_data AS
SELECT * FROM read_shapefile_wkb('/data/large_shapefile');
```

### 2. Create Indexes After Loading

```sql
-- Load first
CREATE TABLE roads AS SELECT * FROM read_shapefile_wkb('/data/roads');

-- Then index
CREATE INDEX roads_geom_idx ON roads USING GIST (geom_wkb::geometry);
CREATE INDEX roads_code_idx ON roads ((attributes[1]));
```

### 3. Use Views for Repeated Access

```sql
-- Don't query shapefile repeatedly
CREATE VIEW roads_view AS
SELECT 
    attributes[1] AS road_code,
    geom_wkb::geometry AS geom
FROM read_shapefile_wkb('/data/roads');
```

### 4. Filter Early

```sql
-- Filter in query (processed row-by-row)
SELECT * FROM read_shapefile_wkt('/data/roads')
WHERE attributes[2] = 'Trunk Road';
```

## Integration with TEHAMA Systems

### Road Maintenance

```sql
-- Load road network
CREATE TABLE road_network AS
SELECT 
    attributes[1] AS road_code,
    attributes[2] AS road_class,
    attributes[4]::NUMERIC AS length_km,
    geom_wkb::geometry AS geom
FROM read_shapefile_wkb('/data/tehama/national_roads');

-- Generate 10km maintenance sections
CREATE TABLE maintenance_sections AS
SELECT 
    r.road_code,
    km AS start_km,
    km + 10 AS end_km,
    ST_GeomFromText(
        (get_section_by_chainage(
            ST_AsText(r.geom),
            km::DOUBLE PRECISION,
            (km + 10)::DOUBLE PRECISION
        )::json->>'geometry')::text,
        4326
    ) AS section_geom
FROM road_network r
CROSS JOIN LATERAL generate_series(0, (r.length_km - 1)::INTEGER, 10) AS km;
```

### GPS Tracking

```sql
-- Load road network
CREATE TABLE roads AS
SELECT * FROM read_shapefile_wkb('/data/tehama/roads');

-- Calibrate GPS points
SELECT 
    vehicle_id,
    calibrate_point_on_line(
        (SELECT ST_AsText(geom_wkb::geometry) FROM roads WHERE attributes[1] = 'T1'),
        'POINT(' || gps_lon || ' ' || gps_lat || ')',
        1000000.0
    ) AS road_position
FROM vehicle_gps_log;
```

## Documentation

- **[SHAPEFILE_EXAMPLES.md](SHAPEFILE_EXAMPLES.md)** - 18 complete examples
- **[DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md)** - Function internals explained
- **[test/test_shapefile_reader.sql](test/test_shapefile_reader.sql)** - Test suite

## Function Reference

### read_shapefile_wkt(path TEXT)

```sql
read_shapefile_wkt(shapefile_path TEXT)
RETURNS TABLE (
    record_num INTEGER,
    attributes TEXT[],
    geom_wkt TEXT
)
```

**Parameters:**
- `shapefile_path` - Path to shapefile without extension

**Returns:**
- Table with record number, attributes array, and WKT geometry

**Example:**
```sql
SELECT * FROM read_shapefile_wkt('/data/roads');
```

### read_shapefile_wkb(path TEXT)

```sql
read_shapefile_wkb(shapefile_path TEXT)
RETURNS TABLE (
    record_num INTEGER,
    attributes TEXT[],
    geom_wkb BYTEA
)
```

**Parameters:**
- `shapefile_path` - Path to shapefile without extension

**Returns:**
- Table with record number, attributes array, and WKB geometry (binary)

**Example:**
```sql
SELECT * FROM read_shapefile_wkb('/data/roads');
```

---

## Summary

The shapefile reader functions provide a powerful, efficient way to import ESRI Shapefiles directly into PostgreSQL without external tools or intermediate formats.

Perfect for:
- ✅ Loading GIS data into PostgreSQL
- ✅ Building road management systems
- ✅ Spatial analysis workflows
- ✅ PostGIS integration
- ✅ TEHAMA road network management

**Next Steps:**
1. See [SHAPEFILE_EXAMPLES.md](SHAPEFILE_EXAMPLES.md) for comprehensive examples
2. Review [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) to understand internals
3. Run test suite in `test/test_shapefile_reader.sql`
