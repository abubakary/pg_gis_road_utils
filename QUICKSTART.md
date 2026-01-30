# Quick Start Guide

## 5-Minute Setup

### 1. Install (Ubuntu/Debian)

```bash
# Install dependencies
sudo apt-get install postgresql postgis libgeos-dev postgresql-server-dev-all

# Build and install extension
cd pg_gis_road_utils
make
sudo make install
```

### 2. Enable in Database

```sql
-- Connect to database
psql -U postgres -d your_database

-- Enable extensions
CREATE EXTENSION postgis;
CREATE EXTENSION pg_gis_road_utils;
```

### 3. First Query

```sql
-- Extract road segment between km 5 and km 10
SELECT pg_gis_road_utils.get_section_by_chainage(
    'LINESTRING(32.8 -6.8, 33.5 -7.1)',
    5.0,
    10.0
);
```

## Common Use Cases

### Use Case 1: Get Point at Kilometer Post

```sql
-- Get exact location of km 15 marker
SELECT 
    ST_AsText(
        pg_gis_road_utils.cut_line_at_chainage_geom(geom, 15.0)
    ) AS km_15_location
FROM roads
WHERE road_code = 'T1';
```

### Use Case 2: Generate All KM Posts

```sql
-- Create km posts table
CREATE TABLE kilometer_posts AS
SELECT 
    road_code,
    km_post AS chainage,
    point_geom AS geom
FROM roads
CROSS JOIN LATERAL pg_gis_road_utils.generate_kilometer_posts(geom, 1.0, 0.0) AS posts;
```

### Use Case 3: Find Where GPS Point Falls on Road

```sql
-- Calibrate GPS tracking point
SELECT 
    (calibration->>'chainage')::NUMERIC AS km_position,
    (calibration->>'lat')::NUMERIC AS calibrated_lat,
    (calibration->>'lon')::NUMERIC AS calibrated_lon
FROM (
    SELECT pg_gis_road_utils.calibrate_point_on_line_geom(
        road.geom,
        gps.point_geom,
        0.01  -- 1km search radius
    ) AS calibration
    FROM roads road, gps_points gps
    WHERE road.id = 1 AND gps.id = 100
) t;
```

### Use Case 4: Extract Road Segments for Maintenance

```sql
-- Get 5km segments for each road
SELECT 
    road_code,
    segment_id,
    start_chainage,
    end_chainage,
    segment_geom
FROM roads
CROSS JOIN LATERAL (
    SELECT 
        generate_series(1, (ST_Length(geom::geography)/5000)::INT) AS segment_id,
        generate_series(0, (ST_Length(geom::geography)/1000)::INT, 5) AS start_chainage,
        generate_series(5, (ST_Length(geom::geography)/1000)::INT + 5, 5) AS end_chainage
) AS segments
CROSS JOIN LATERAL (
    SELECT pg_gis_road_utils.extract_section_geometry(
        pg_gis_road_utils.get_section_by_chainage_geom(
            roads.geom,
            segments.start_chainage,
            segments.end_chainage
        ),
        4326
    ) AS segment_geom
) AS geoms;
```

## Integration with Spring Boot

```java
@Service
public class RoadService {
    
    @Autowired
    private JdbcTemplate jdbcTemplate;
    
    public JSONObject getRoadSegment(Long roadId, double startKm, double endKm) {
        String sql = """
            SELECT pg_gis_road_utils.get_section_by_chainage_geom(
                geom, ?, ?
            )::text
            FROM roads WHERE id = ?
        """;
        
        String json = jdbcTemplate.queryForObject(
            sql, String.class, startKm, endKm, roadId
        );
        
        return new JSONObject(json);
    }
}
```

## Next Steps

- Read [README.md](README.md) for complete documentation
- See [MIGRATION.md](MIGRATION.md) if migrating from JNI version
- Check [INSTALL.md](INSTALL.md) for detailed installation guide
- Run tests: `make test`

## Support

- GitHub: https://github.com/tehama/pg_gis_road_utils
- Email: gis@tehama.go.tz
