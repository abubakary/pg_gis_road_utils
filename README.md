# pg_gis_road_utils - PostgreSQL Extension for Road Network Chainage Operations

A high-performance PostgreSQL extension for advanced GIS operations on road networks, featuring chainage-based line cutting, point calibration, and segment extraction.

**Converted from JNI/Java implementation to native PostgreSQL C extension with GEOS library integration.**

## 🚀 Quick Start (WSL2/Ubuntu)

```bash
# One command setup
./setup_wsl2.sh
```

Or manually:

```bash
# Install dependencies
sudo apt install -y postgresql-14 postgresql-server-dev-14 libgeos-dev build-essential

# Start PostgreSQL (WSL2 method)
sudo -u postgres /usr/lib/postgresql/14/bin/initdb -D /var/lib/postgresql/14/main
sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main -l /tmp/postgres.log start

# Build and install
make clean && CFLAGS="-g -O0" make && sudo make install

# Create database and load extension
sudo -u postgres createdb test_db
sudo -u postgres psql -d test_db -c "CREATE EXTENSION pg_gis_road_utils;"
```

See `WSL2_QUICKSTART.md` for complete WSL2 setup instructions.

## Features

### Core Functions

- **get_section_by_chainage**: Extract line segments between two chainage points with full metadata
- **cut_line_at_chainage**: Get a point at a specific chainage along a line
- **calibrate_point_on_line**: Find the closest point on a line to a reference point and calculate its chainage
- **generate_kilometer_posts**: Automatically generate evenly-spaced kilometer posts along a road

### Key Capabilities

- ✅ Precise chainage calculations using GEOS library
- ✅ Support for both LINESTRING and MULTILINESTRING geometries
- ✅ JSON output with comprehensive segment metadata
- ✅ PostGIS geometry wrapper functions for seamless integration
- ✅ High performance C implementation
- ✅ Maintains original algorithm logic from JNI implementation

## Requirements

- PostgreSQL 12+
- PostGIS 3.0+
- GEOS 3.8+
- Development headers for PostgreSQL and GEOS

## Installation

### Ubuntu/Debian

```bash
# Install dependencies
sudo apt-get install postgresql-server-dev-all libgeos-dev postgis

# Clone and build
git clone https://github.com/yourusername/pg_gis_road_utils.git
cd pg_gis_road_utils

# Build and install
make
sudo make install

# Enable extension in your database
psql -U postgres -d your_database -c "CREATE EXTENSION pg_gis_road_utils;"
```

### CentOS/RHEL

```bash
# Install dependencies
sudo yum install postgresql-devel geos-devel postgis

# Build and install
make
sudo make install

# Enable extension
psql -U postgres -d your_database -c "CREATE EXTENSION pg_gis_road_utils;"
```

### Verify Installation

```sql
-- Check extension is installed
SELECT * FROM pg_available_extensions WHERE name = 'pg_gis_road_utils';

-- List available functions
\df pg_gis_road_utils.*
```

## Usage Examples

### 1. Extract Line Segment by Chainage (WKT Input)

```sql
-- Get road segment between km 2.5 and km 7.5
SELECT get_section_by_chainage(
    'LINESTRING(32.8 -6.8, 33.0 -6.9, 33.2 -7.0, 33.5 -7.1)',
    2.5,  -- Start chainage (km)
    7.5   -- End chainage (km)
);

-- Result (JSON):
{
  "start_ch": 2.5,
  "end_ch": 7.5,
  "start_lat": -6.85,
  "start_lon": 32.95,
  "end_lat": -7.05,
  "end_lon": 33.25,
  "length": 5.0,
  "geometry": "LINESTRING(32.95 -6.85, 33.0 -6.9, 33.2 -7.0, 33.25 -7.05)"
}
```

### 2. Extract Line Segment Using PostGIS Geometry

```sql
-- Using geometry from a roads table
SELECT 
    road_code,
    road_name,
    get_section_by_chainage_geom(geom, 5.0, 15.0) AS section
FROM roads
WHERE road_code = 'T1';

-- Extract just the geometry from result
SELECT 
    road_code,
    extract_section_geometry(
        get_section_by_chainage_geom(geom, 10.0, 20.0),
        4326
    ) AS segment_geom
FROM roads
WHERE road_code = 'T1';
```

### 3. Get Point at Specific Chainage

```sql
-- Get point at km 5.5 (returns WKT)
SELECT cut_line_at_chainage(
    'LINESTRING(32.8 -6.8, 33.5 -7.1)',
    5.5
);
-- Result: POINT(33.1234 -6.9234)

-- Using PostGIS geometry (returns GEOMETRY)
SELECT 
    road_code,
    cut_line_at_chainage_geom(geom, 10.0) AS km_10_point
FROM roads
WHERE road_code = 'T1';
```

### 4. Calibrate Point on Line

```sql
-- Find where a GPS point falls on a road and get its chainage
SELECT calibrate_point_on_line(
    'LINESTRING(32.8 -6.8, 33.0 -6.9, 33.2 -7.0)',
    'POINT(32.95 -6.88)',
    1.0  -- Search radius in degrees
);

-- Result (JSON):
{
  "chainage": 3.456,
  "lat": -6.9,
  "lon": 33.0,
  "index": 1
}

-- Using PostGIS geometries from table
SELECT 
    gps.id,
    gps.point_name,
    calibrate_point_on_line_geom(
        r.geom,
        gps.geom,
        0.01  -- ~1km search radius
    ) AS calibrated_position
FROM gps_points gps
JOIN roads r ON r.id = 123
WHERE gps.point_type = 'bridge';
```

### 5. Generate Kilometer Posts

```sql
-- Generate kilometer posts every 1km along a road
SELECT 
    road_code,
    km_post,
    ST_AsText(point_geom) AS location
FROM roads r
CROSS JOIN LATERAL generate_kilometer_posts(r.geom, 1.0, 0.0) AS posts
WHERE road_code = 'T1'
ORDER BY km_post;

-- Insert kilometer posts into a table
INSERT INTO road_kilometer_posts (road_id, chainage, geom)
SELECT 
    r.id,
    km_post,
    point_geom
FROM roads r
CROSS JOIN LATERAL generate_kilometer_posts(r.geom, 1.0, 0.0) AS posts
WHERE r.road_code = 'T1';
```

### 6. Complex Road Management Queries

```sql
-- Find all bridges within a specific chainage range
WITH road_segment AS (
    SELECT extract_section_geometry(
        get_section_by_chainage_geom(geom, 10.0, 25.0),
        4326
    ) AS segment_geom
    FROM roads
    WHERE road_code = 'T1'
)
SELECT b.*
FROM bridges b, road_segment rs
WHERE ST_Intersects(b.geom, rs.segment_geom);

-- Calculate maintenance zones based on chainage
SELECT 
    road_code,
    FLOOR(chainage) AS km_start,
    FLOOR(chainage) + 1 AS km_end,
    COUNT(*) AS defect_count
FROM (
    SELECT 
        r.road_code,
        (calibrate_point_on_line_geom(r.geom, d.geom, 0.01)->>'chainage')::DOUBLE PRECISION AS chainage
    FROM road_defects d
    JOIN roads r ON ST_DWithin(r.geom, d.geom, 0.01)
    WHERE r.road_code = 'T1'
) subquery
GROUP BY road_code, FLOOR(chainage)
ORDER BY road_code, FLOOR(chainage);
```

### 7. Integration with Existing Road Network Systems

```sql
-- Create view combining road segments with chainages
CREATE VIEW road_sections AS
SELECT 
    r.road_code,
    r.road_name,
    gs.start_km,
    gs.end_km,
    extract_section_geometry(
        get_section_by_chainage_geom(r.geom, gs.start_km, gs.end_km),
        4326
    ) AS geom,
    (gs.end_km - gs.start_km) AS length_km
FROM roads r
CROSS JOIN LATERAL (
    SELECT 
        generate_series(0, FLOOR(ST_Length(r.geom::geography)/1000)::INTEGER, 5) AS start_km,
        generate_series(5, CEIL(ST_Length(r.geom::geography)/1000)::INTEGER, 5) AS end_km
) AS gs;

-- Calculate road condition by section
SELECT 
    rs.road_code,
    rs.start_km || '-' || rs.end_km AS section,
    AVG(rc.condition_rating) AS avg_rating,
    COUNT(rc.*) AS sample_count
FROM road_sections rs
LEFT JOIN road_conditions rc ON ST_Intersects(rc.geom, rs.geom)
GROUP BY rs.road_code, rs.start_km, rs.end_km
ORDER BY rs.road_code, rs.start_km;
```

## Function Reference

### Core C Functions

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `get_section_by_chainage` | `line_wkt TEXT, start_ch FLOAT8, end_ch FLOAT8` | `JSON` | Extract line segment with metadata |
| `cut_line_at_chainage` | `line_wkt TEXT, chainage FLOAT8` | `TEXT` | Get point WKT at chainage |
| `calibrate_point_on_line` | `line_wkt TEXT, point_wkt TEXT, radius FLOAT8` | `JSON` | Find point position and chainage |

### PostGIS Wrapper Functions

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `get_section_by_chainage_geom` | `line_geom GEOMETRY, start_ch FLOAT8, end_ch FLOAT8` | `JSON` | PostGIS geometry version |
| `cut_line_at_chainage_geom` | `line_geom GEOMETRY, chainage FLOAT8` | `GEOMETRY` | Returns PostGIS POINT |
| `calibrate_point_on_line_geom` | `line_geom GEOMETRY, point_geom GEOMETRY, radius FLOAT8` | `JSON` | PostGIS geometry version |
| `extract_section_geometry` | `section_json JSON, srid INTEGER` | `GEOMETRY` | Extract geometry from JSON |
| `generate_kilometer_posts` | `road_geom GEOMETRY, interval_km FLOAT8, start_km FLOAT8` | `TABLE` | Generate KM posts |

## Performance Considerations

- All C functions are marked as `IMMUTABLE` for query optimization
- GEOS operations are performed in reentrant context (`_r` functions)
- Memory is managed using PostgreSQL's memory contexts
- Efficient coordinate array handling with dynamic allocation

## Chainage Calculation Notes

The extension uses the following conversion factor:
- **1 degree ≈ 111.32 km** (at the equator)
- Chainages are specified in **kilometers**
- Internal GEOS calculations use **decimal degrees**
- Conversion formula: `chainage_km = (distance_degrees * 111320) / 1000`

For more accurate results on long roads:
- Use PostGIS geography type: `ST_Length(geom::geography) / 1000`
- Consider projection-based calculations for higher precision

## Troubleshooting

### Extension fails to load

```sql
-- Check GEOS is available
SELECT PostGIS_GEOS_Version();

-- Verify extension files
SELECT * FROM pg_available_extensions WHERE name LIKE '%gis%';
```

### "Invalid geometry" errors

```sql
-- Validate your geometries first
SELECT ST_IsValid(geom), ST_GeometryType(geom) FROM roads WHERE id = 1;

-- Use ST_MakeValid if needed
UPDATE roads SET geom = ST_MakeValid(geom) WHERE NOT ST_IsValid(geom);
```

### Performance issues

```sql
-- Create spatial indexes
CREATE INDEX roads_geom_idx ON roads USING GIST(geom);

-- Analyze tables
ANALYZE roads;
```

## Differences from JNI Implementation

- **Memory Management**: Uses PostgreSQL palloc/pfree instead of malloc/free
- **Error Handling**: Uses PostgreSQL ereport instead of JNI exceptions
- **JSON Output**: Uses PostgreSQL native JSON instead of cJSON library
- **No Auto-config**: Must be explicitly installed as extension
- **Same Algorithm**: Core GEOS logic is identical to JNI version

## Migration from JNI Version

If you're migrating from the JNI-based Java library:

```java
// Old Java/JNI call
String result = nativeLib.getSectionByChainage(wkt, 2.5, 7.5);

// New PostgreSQL call
SELECT get_section_by_chainage(wkt, 2.5, 7.5);
```

The JSON output format is identical, ensuring seamless migration.

## License

MIT License - See LICENSE file

## Contributing

Contributions are welcome! Please submit issues and pull requests on GitHub.

## Author

Tanzania Mining Commission (TEHAMA)  
Converted from JNI implementation to PostgreSQL extension
