# Developer Guide - pg_gis_road_utils Extension

## For Developers New to PostgreSQL C Extensions

This guide explains each function in the `pg_gis_road_utils` extension from input to output, assuming you have basic C knowledge but no experience with PostgreSQL extensions.

---

## Table of Contents

1. [Project Structure](#project-structure)
2. [How PostgreSQL Extensions Work](#how-postgresql-extensions-work)
3. [Function 1: get_section_by_chainage](#function-1-get_section_by_chainage)
4. [Function 2: cut_line_at_chainage](#function-2-cut_line_at_chainage)
5. [Function 3: calibrate_point_on_line](#function-3-calibrate_point_on_line)
6. [Helper Functions](#helper-functions)
7. [Data Structures](#data-structures)
8. [Memory Management](#memory-management)
9. [Error Handling](#error-handling)

---

## Project Structure

```
pg_gis_road_utils/
├── pg_gis_road_utils.c              # Main C source code (ALL functions here)
├── pg_gis_road_utils--1.0.0.sql     # SQL function declarations
├── pg_gis_road_utils.control        # Extension metadata
├── Makefile                         # Build configuration
└── test/
    └── test_pg_gis_road_utils.sql   # Test queries
```

**Important**: ALL C code is in ONE file: `pg_gis_road_utils.c`

---

## How PostgreSQL Extensions Work

### The Flow

```
SQL Query → PostgreSQL → Your C Function → Process Data → Return Result → PostgreSQL → User
```

### Example

```sql
-- User calls this in SQL
SELECT get_section_by_chainage('LINESTRING(0 0, 10 0)', 2.0, 5.0);

-- PostgreSQL calls this C function
Datum get_section_by_chainage(PG_FUNCTION_ARGS)

-- Function returns JSON
{"start_ch":2.0, "end_ch":5.0, ...}
```

### Key Concepts

**1. Datum** - PostgreSQL's generic data type (like `void*` in C)

**2. PG_FUNCTION_ARGS** - Macro that passes function arguments

**3. PG_GETARG_XXX** - Macros to extract arguments:
- `PG_GETARG_TEXT_PP(0)` - Get text argument at position 0
- `PG_GETARG_FLOAT8(1)` - Get double argument at position 1

**4. PG_RETURN_XXX** - Macros to return values:
- `PG_RETURN_TEXT_P(result)` - Return text
- `PG_RETURN_NULL()` - Return NULL

---

## Function 1: get_section_by_chainage

**Purpose**: Extract a road segment between two kilometer markers (chainages).

### SQL Interface

```sql
-- Function signature
get_section_by_chainage(
    line_wkt TEXT,           -- Road geometry as WKT string
    start_chainage FLOAT,    -- Start kilometer (e.g., 2.5 km)
    end_chainage FLOAT       -- End kilometer (e.g., 7.5 km)
) RETURNS JSON

-- Example call
SELECT get_section_by_chainage(
    'LINESTRING(0 0, 10 0, 10 10)',
    2.0,
    5.0
);

-- Returns
{
  "start_ch": 2.0,
  "end_ch": 5.0,
  "start_lat": 0.0179662,
  "start_lon": 0.0,
  "end_lat": 0.0449156,
  "end_lon": 0.0,
  "length": 3.0,
  "geometry": "LINESTRING(...)"
}
```

### C Implementation Walkthrough

#### Step 1: Function Entry Point

```c
Datum get_section_by_chainage(PG_FUNCTION_ARGS)
{
    // This is called by PostgreSQL when SQL executes the function
```

**What happens**: PostgreSQL detects the function name in the SQL query and calls this C function.

#### Step 2: Extract Input Arguments

```c
    // Get the WKT string (road geometry)
    text *wkt_text = PG_GETARG_TEXT_PP(0);
    char *wkt = text_to_cstring(wkt_text);
    
    // Get start and end chainages (in kilometers)
    float8 start_ch = PG_GETARG_FLOAT8(1);
    float8 end_ch = PG_GETARG_FLOAT8(2);
```

**Explanation**:
- `PG_GETARG_TEXT_PP(0)` - Gets first argument (position 0) as PostgreSQL text
- `text_to_cstring()` - Converts PostgreSQL text to C string
- `PG_GETARG_FLOAT8(1)` - Gets second argument as double (float8 = 8-byte float)

**Example values after this step**:
```
wkt = "LINESTRING(0 0, 10 0, 10 10)"
start_ch = 2.0
end_ch = 5.0
```

#### Step 3: Initialize GEOS Context

```c
    // Create GEOS context for geometry operations
    GEOSContextHandle_t context = GEOS_init_r();
```

**What is GEOS?**
- Geometry Engine - Open Source
- Library that handles geometric operations (points, lines, polygons)
- Needs a "context" to manage memory and state

#### Step 4: Convert WKT to Geometry

```c
    // Convert WKT string to GEOS geometry object
    GEOSGeometry* geom = getLineFromMultiline(context, wkt);
    
    if (!geom) {
        GEOS_finish_r(context);
        PG_RETURN_NULL();
    }
```

**What happens in `getLineFromMultiline()`**:
```c
static GEOSGeometry* getLineFromMultiline(GEOSContextHandle_t context, const char* wkt) {
    // 1. Create WKT reader
    GEOSWKTReader *reader = GEOSWKTReader_create_r(context);
    
    // 2. Parse WKT string into geometry
    GEOSGeometry *geom = GEOSWKTReader_read_r(context, reader, wkt);
    
    // 3. Check if it's MULTILINESTRING or LINESTRING
    int geomType = GEOSGeomTypeId_r(context, geom);
    
    if (geomType == GEOS_MULTILINESTRING) {
        // If MULTILINESTRING, extract first line
        return GEOSGeom_clone_r(context, GEOSGetGeometryN_r(context, geom, 0));
    }
    
    return geom;  // Already a LINESTRING
}
```

**After this step**: You have a GEOS geometry object representing the road line.

#### Step 5: Extract the Road Segment

```c
    SectionDto section;
    int res = extractSubLineStringByChainages(context, geom, start_ch, end_ch, &section);
    
    if (res == 0) {
        // Failed to extract
        GEOSGeom_destroy_r(context, geom);
        GEOS_finish_r(context);
        PG_RETURN_NULL();
    }
```

**What happens in `extractSubLineStringByChainages()`** - This is the CORE algorithm:

```c
static int extractSubLineStringByChainages(
    GEOSContextHandle_t context,
    const GEOSGeometry *line,
    double start_chainage,
    double end_chainage,
    SectionDto *section
) {
    // STEP 1: Convert km to degrees (Earth approximation)
    // 1 degree ≈ 111.32 km at equator
    start_chainage = (start_chainage * 1000) / 111320;  // km to degrees
    end_chainage = (end_chainage * 1000) / 111320;
    
    // STEP 2: Get coordinates from line geometry
    const GEOSCoordSequence *coords = GEOSGeom_getCoordSeq_r(context, line);
    unsigned int numPoints;
    GEOSCoordSeq_getSize_r(context, coords, &numPoints);
    
    // STEP 3: Walk through line segments, measuring distance
    double total_distance = 0.0;
    double prev_x, prev_y, curr_x, curr_y;
    
    CoordinateArray coords_arr;  // Will hold output coordinates
    coords_arr.size = 0;
    
    int startAdded = 0, endAdded = 0;
    
    GEOSCoordSeq_getX_r(context, coords, 0, &prev_x);
    GEOSCoordSeq_getY_r(context, coords, 0, &prev_y);
    
    // STEP 4: Iterate through each segment
    for (unsigned int i = 1; i < numPoints; i++) {
        GEOSCoordSeq_getX_r(context, coords, i, &curr_x);
        GEOSCoordSeq_getY_r(context, coords, i, &curr_y);
        
        // Calculate segment length
        double segment_length = compute_distance(prev_x, prev_y, curr_x, curr_y);
        
        // CASE 1: Start point is in this segment
        if (!startAdded && total_distance + segment_length >= start_chainage) {
            // Calculate exact position using interpolation
            double offset = start_chainage - total_distance;
            double factor = offset / segment_length;
            
            double start_x = prev_x + factor * (curr_x - prev_x);
            double start_y = prev_y + factor * (curr_y - prev_y);
            
            // Add start coordinate
            coords_arr.coords[coords_arr.size].x = start_x;
            coords_arr.coords[coords_arr.size].y = start_y;
            coords_arr.size++;
            
            // Store in section result
            section->startLon = start_x;
            section->startLat = start_y;
            section->startCh = start_chainage;
            
            startAdded = 1;
        }
        
        // CASE 2: We're between start and end, add all intermediate points
        if (startAdded && !endAdded && total_distance < end_chainage) {
            coords_arr.coords[coords_arr.size].x = curr_x;
            coords_arr.coords[coords_arr.size].y = curr_y;
            coords_arr.size++;
        }
        
        // CASE 3: End point is in this segment
        if (startAdded && !endAdded && total_distance + segment_length >= end_chainage) {
            // Calculate exact end position
            double offset = end_chainage - total_distance;
            double factor = offset / segment_length;
            
            double end_x = prev_x + factor * (curr_x - prev_x);
            double end_y = prev_y + factor * (curr_y - prev_y);
            
            // Add end coordinate
            coords_arr.coords[coords_arr.size].x = end_x;
            coords_arr.coords[coords_arr.size].y = end_y;
            coords_arr.size++;
            
            // Store in section result
            section->endLon = end_x;
            section->endLat = end_y;
            section->endCh = end_chainage;
            
            endAdded = 1;
            break;  // We're done
        }
        
        total_distance += segment_length;
        prev_x = curr_x;
        prev_y = curr_y;
    }
    
    // STEP 5: Create new line geometry from extracted coordinates
    GEOSGeometry *subLine = createLineStringFromArray(context, &coords_arr);
    section->geometry = geomToWKT(context, subLine);
    section->length = end_chainage - start_chainage;
    
    GEOSGeom_destroy_r(context, subLine);
    
    return 1;  // Success
}
```

**Key Algorithm Concept**:
1. Walk along the line measuring cumulative distance
2. When total distance reaches start chainage, interpolate exact point
3. Continue adding points until end chainage
4. Interpolate exact end point
5. Create new line from collected points

**Interpolation Formula**:
```
If we have segment from A to B:
- A is at (x1, y1)
- B is at (x2, y2)
- We want point P that is "factor" of the way from A to B

P_x = x1 + factor * (x2 - x1)
P_y = y1 + factor * (y2 - y1)

Example: factor = 0.5 gives midpoint
```

#### Step 6: Build JSON Response

```c
    StringInfoData buf;
    initStringInfo(&buf);
    
    appendStringInfoString(&buf, "{");
    appendStringInfo(&buf, "\"start_ch\":%.6f,", start_ch);
    appendStringInfo(&buf, "\"end_ch\":%.6f,", end_ch);
    appendStringInfo(&buf, "\"start_lat\":%.8f,", section.startLat);
    appendStringInfo(&buf, "\"start_lon\":%.8f,", section.startLon);
    appendStringInfo(&buf, "\"end_lat\":%.8f,", section.endLat);
    appendStringInfo(&buf, "\"end_lon\":%.8f,", section.endLon);
    appendStringInfo(&buf, "\"length\":%.6f,", section.length);
    appendStringInfo(&buf, "\"geometry\":\"%s\"", section.geometry);
    appendStringInfoString(&buf, "}");
    
    text *result = cstring_to_text(buf.data);
```

**What is StringInfoData?**
- PostgreSQL's dynamic string builder (like StringBuilder in Java)
- `initStringInfo()` - Initialize buffer
- `appendStringInfo()` - Add formatted string (like sprintf)
- `appendStringInfoString()` - Add plain string

**Result after this step**:
```json
{
  "start_ch": 2.000000,
  "end_ch": 5.000000,
  "start_lat": 0.01796622,
  "start_lon": 0.00000000,
  "end_lat": 0.04491556,
  "end_lon": 0.00000000,
  "length": 3.000000,
  "geometry": "LINESTRING (0.0179662 0, 0.0449156 0)"
}
```

#### Step 7: Cleanup and Return

```c
    pfree(section.geometry);
    GEOSGeom_destroy_r(context, geom);
    GEOS_finish_r(context);
    
    PG_RETURN_TEXT_P(result);
}
```

**Memory Management**:
- `pfree()` - Free PostgreSQL-allocated memory
- `GEOSGeom_destroy_r()` - Free GEOS geometry
- `GEOS_finish_r()` - Free GEOS context
- `PG_RETURN_TEXT_P()` - Return text to PostgreSQL

---

## Function 2: cut_line_at_chainage

**Purpose**: Get a single point at a specific kilometer marker on a road.

### SQL Interface

```sql
-- Function signature
cut_line_at_chainage(
    line_wkt TEXT,     -- Road geometry
    chainage FLOAT     -- Kilometer position
) RETURNS TEXT         -- Returns WKT point

-- Example
SELECT cut_line_at_chainage(
    'LINESTRING(0 0, 10 0)',
    5.0
);

-- Returns
POINT (0.0449155587495508 0.0000000000000000)
```

### C Implementation Walkthrough

#### Complete Flow

```c
Datum cut_line_at_chainage(PG_FUNCTION_ARGS)
{
    // STEP 1: Get inputs
    text *wkt_text = PG_GETARG_TEXT_PP(0);
    char *wkt = text_to_cstring(wkt_text);
    float8 chainage = PG_GETARG_FLOAT8(1);
    
    // STEP 2: Initialize GEOS
    GEOSContextHandle_t context = GEOS_init_r();
    
    // STEP 3: Convert WKT to geometry
    GEOSGeometry* line = getLineFromMultiline(context, wkt);
    
    // STEP 4: Convert chainage from km to degrees
    double chainage_degrees = (chainage * 1000) / 111320;
    
    // STEP 5: Get total line length
    double line_length;
    GEOSLength_r(context, line, &line_length);
    
    if (chainage_degrees > line_length) {
        // Chainage is beyond end of line
        GEOSGeom_destroy_r(context, line);
        GEOS_finish_r(context);
        PG_RETURN_NULL();
    }
    
    // STEP 6: Interpolate point at chainage distance
    // This is the MAGIC function from GEOS
    GEOSGeometry* point = GEOSInterpolate_r(context, line, chainage_degrees);
    
    // STEP 7: Convert point geometry to WKT string
    char *result_wkt = geomToWKT(context, point);
    
    // STEP 8: Convert to PostgreSQL text
    text *result = cstring_to_text(result_wkt);
    
    // STEP 9: Cleanup
    pfree(result_wkt);
    GEOSGeom_destroy_r(context, point);
    GEOSGeom_destroy_r(context, line);
    GEOS_finish_r(context);
    
    PG_RETURN_TEXT_P(result);
}
```

**Key Function**: `GEOSInterpolate_r()`
- Built-in GEOS function
- Takes a line and a distance
- Returns a point at that distance along the line
- Handles all the complex math internally

**Example**:
```
Line: A ---------- B ---------- C
      0km         5km         10km

GEOSInterpolate(line, 5.0) → Returns point B
GEOSInterpolate(line, 2.5) → Returns point between A and B
```

---

## Function 3: calibrate_point_on_line

**Purpose**: Find where a GPS point (e.g., from a vehicle) snaps to the road and calculate its chainage.

### SQL Interface

```sql
-- Function signature
calibrate_point_on_line(
    line_wkt TEXT,      -- Road geometry
    point_wkt TEXT,     -- GPS point location
    radius FLOAT        -- Search radius (in degrees)
) RETURNS JSON

-- Example
SELECT calibrate_point_on_line(
    'LINESTRING(0 0, 10 0)',
    'POINT(5 0.001)',    -- Point slightly off the road
    1000000.0            -- Large search radius
);

-- Returns
{
  "chainage": 5.0,
  "lat": 0.0449156,
  "lon": 0.0,
  "index": 500
}
```

### C Implementation Walkthrough

```c
Datum calibrate_point_on_line(PG_FUNCTION_ARGS)
{
    // STEP 1: Get inputs
    text *line_wkt_text = PG_GETARG_TEXT_PP(0);
    char *line_wkt = text_to_cstring(line_wkt_text);
    
    text *point_wkt_text = PG_GETARG_TEXT_PP(1);
    char *point_wkt = text_to_cstring(point_wkt_text);
    
    float8 radius = PG_GETARG_FLOAT8(2);
    
    // STEP 2: Initialize GEOS
    GEOSContextHandle_t context = GEOS_init_r();
    GEOSWKTReader *reader = GEOSWKTReader_create_r(context);
    
    // STEP 3: Parse geometries
    GEOSGeometry *line = GEOSWKTReader_read_r(context, reader, line_wkt);
    GEOSGeometry *point = GEOSWKTReader_read_r(context, reader, point_wkt);
    
    // STEP 4: Call calibration algorithm
    PointDto pointDto;
    int res = calibratePoint(context, line, point, radius, &pointDto);
    
    if (res == 0) {
        // Point not found within radius
        PG_RETURN_NULL();
    }
    
    // STEP 5: Build JSON response
    StringInfoData buf;
    initStringInfo(&buf);
    appendStringInfoString(&buf, "{");
    appendStringInfo(&buf, "\"chainage\":%.6f,", pointDto.chainage);
    appendStringInfo(&buf, "\"lat\":%.8f,", pointDto.lat);
    appendStringInfo(&buf, "\"lon\":%.8f,", pointDto.lon);
    appendStringInfo(&buf, "\"index\":%d", pointDto.index);
    appendStringInfoString(&buf, "}");
    
    text *result = cstring_to_text(buf.data);
    
    // STEP 6: Cleanup and return
    GEOSWKTReader_destroy_r(context, reader);
    GEOSGeom_destroy_r(context, line);
    GEOSGeom_destroy_r(context, point);
    GEOS_finish_r(context);
    
    PG_RETURN_TEXT_P(result);
}
```

### The Calibration Algorithm

This is the most complex algorithm:

```c
static int calibratePoint(
    GEOSContextHandle_t context,
    const GEOSGeometry *line,
    const GEOSGeometry *referencePoint,
    double radius,
    PointDto *pointDto
) {
    // STEP 1: Get line coordinates
    const GEOSCoordSequence* coordinateSequenceLine = 
        GEOSGeom_getCoordSeq_r(context, line);
    
    unsigned int numPointsLine = 0;
    GEOSCoordSeq_getSize_r(context, coordinateSequenceLine, &numPointsLine);
    
    // STEP 2: Initialize search variables
    double closestReferenceDistance = MAX_RADIUS;  // Very large number
    double chainage = 0.0;
    double prev_x, prev_y;
    int foundIndex = -1;
    
    GEOSCoordSeq_getX_r(context, coordinateSequenceLine, 0, &prev_x);
    GEOSCoordSeq_getY_r(context, coordinateSequenceLine, 0, &prev_y);
    
    // STEP 3: Walk through each vertex on the line
    for (unsigned int i = 1; i < numPointsLine; i++) {
        double x, y;
        GEOSCoordSeq_getX_r(context, coordinateSequenceLine, i, &x);
        GEOSCoordSeq_getY_r(context, coordinateSequenceLine, i, &y);
        
        // Create point geometry for this vertex
        GEOSGeometry* linePoint = GEOSGeom_createPointFromXY_r(context, x, y);
        
        if (!linePoint) continue;
        
        // STEP 4: Calculate distance from reference point to this vertex
        double distanceFromReference;
        GEOSDistance_r(context, referencePoint, linePoint, &distanceFromReference);
        
        GEOSGeom_destroy_r(context, linePoint);
        
        // STEP 5: Is this the closest vertex so far?
        if (distanceFromReference < closestReferenceDistance) {
            // Check if within search radius
            if (distanceFromReference <= radius) {
                closestReferenceDistance = distanceFromReference;
                
                // STEP 6: Calculate chainage (cumulative distance from start)
                double distanceFromPrevPoint = 
                    compute_distance(prev_x, prev_y, x, y);
                chainage += distanceFromPrevPoint;
                
                // Store results
                pointDto->lat = y;
                pointDto->lon = x;
                pointDto->index = i;
                foundIndex = i;
            }
        } else if (foundIndex != -1) {
            // We've passed the closest point, add remaining distance
            double distanceFromPrevPoint = 
                compute_distance(prev_x, prev_y, x, y);
            chainage += distanceFromPrevPoint;
        }
        
        prev_x = x;
        prev_y = y;
    }
    
    // STEP 7: Return results
    if (foundIndex == -1) {
        return 0;  // Not found
    }
    
    // Convert chainage from degrees to km
    double final_chainage = (chainage * 111320) / 1000;
    pointDto->chainage = final_chainage;
    
    return 1;  // Success
}
```

**Algorithm Explanation**:

1. **Walk Through Vertices**: Check each point on the road line
2. **Measure Distance**: Calculate how far the GPS point is from each road vertex
3. **Find Closest**: Keep track of the nearest vertex within the search radius
4. **Calculate Chainage**: Sum up distances from the start to that vertex
5. **Return Position**: GPS point is "snapped" to the closest road vertex

**Visual Example**:
```
Road:  A -------- B -------- C -------- D
       0km       5km       10km      15km

GPS Point: X (slightly above B)

Algorithm:
- Distance from X to A: 5.1 km  ← not closest
- Distance from X to B: 0.1 km  ← CLOSEST! (within radius)
- Distance from X to C: 5.1 km  ← getting farther

Result: Point calibrates to B at chainage 5.0 km
```

---

## Helper Functions

### 1. compute_distance

**Purpose**: Calculate straight-line distance between two points.

```c
static double compute_distance(double x1, double y1, double x2, double y2) {
    // Pythagorean theorem: distance = √((x2-x1)² + (y2-y1)²)
    return sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));
}
```

**Example**:
```
Point A: (0, 0)
Point B: (3, 4)

distance = √((3-0)² + (4-0)²)
        = √(9 + 16)
        = √25
        = 5
```

### 2. createLineStringFromArray

**Purpose**: Create a GEOS line geometry from an array of coordinates.

```c
static GEOSGeometry* createLineStringFromArray(
    GEOSContextHandle_t context,
    CoordinateArray *coordsArr
) {
    // STEP 1: Create coordinate sequence
    GEOSCoordSequence *coords = GEOSCoordSeq_create_r(
        context,
        coordsArr->size,  // Number of points
        2                 // 2D (x, y)
    );
    
    // STEP 2: Fill coordinate sequence
    for (int i = 0; i < coordsArr->size; i++) {
        GEOSCoordSeq_setX_r(context, coords, i, coordsArr->coords[i].x);
        GEOSCoordSeq_setY_r(context, coords, i, coordsArr->coords[i].y);
    }
    
    // STEP 3: Create line geometry
    GEOSGeometry *line = GEOSGeom_createLineString_r(context, coords);
    
    return line;
}
```

**What it does**:
```
Input:  Array of (x,y) pairs: [(0,0), (5,0), (10,0)]
Output: GEOS LineString geometry
```

### 3. geomToWKT

**Purpose**: Convert GEOS geometry to WKT string.

```c
static char* geomToWKT(GEOSContextHandle_t context, const GEOSGeometry *geometry) {
    // STEP 1: Use GEOS to convert geometry to WKT
    char *wkt = GEOSGeomToWKT_r(context, geometry);
    
    if (!wkt) {
        return NULL;
    }
    
    // STEP 2: Copy to PostgreSQL memory
    char *result = pstrdup(wkt);  // PostgreSQL memory allocator
    
    // STEP 3: Free GEOS memory
    GEOSFree_r(context, wkt);
    
    return result;
}
```

**Example**:
```
Input:  GEOS Point geometry (internal binary)
Output: "POINT (5.0 0.0)"
```

### 4. getLineFromMultiline

**Purpose**: Extract a single line from MULTILINESTRING or LINESTRING.

```c
static GEOSGeometry* getLineFromMultiline(
    GEOSContextHandle_t context,
    const char* wkt
) {
    // STEP 1: Create WKT reader
    GEOSWKTReader *reader = GEOSWKTReader_create_r(context);
    
    // STEP 2: Parse WKT string
    GEOSGeometry *geom = GEOSWKTReader_read_r(context, reader, wkt);
    
    // STEP 3: Check geometry type
    int geomType = GEOSGeomTypeId_r(context, geom);
    
    // STEP 4: Handle MULTILINESTRING
    if (geomType == GEOS_MULTILINESTRING) {
        // Extract first linestring
        const GEOSGeometry *firstLine = GEOSGetGeometryN_r(context, geom, 0);
        GEOSGeometry *clonedLine = GEOSGeom_clone_r(context, firstLine);
        
        GEOSGeom_destroy_r(context, geom);
        GEOSWKTReader_destroy_r(context, reader);
        
        return clonedLine;
    }
    
    // Already a LINESTRING
    GEOSWKTReader_destroy_r(context, reader);
    return geom;
}
```

**Example**:
```
Input:  "MULTILINESTRING((0 0, 5 0), (5 0, 10 0))"
Output: First line: (0 0, 5 0)

Input:  "LINESTRING(0 0, 10 0)"
Output: Same line: (0 0, 10 0)
```

---

## Data Structures

### 1. Coordinate

Simple 2D point:

```c
typedef struct {
    double x;  // Longitude or X coordinate
    double y;  // Latitude or Y coordinate
} Coordinate;
```

### 2. CoordinateArray

Dynamic array of coordinates:

```c
#define MAX_COORDS 10000

typedef struct {
    Coordinate coords[MAX_COORDS];  // Array of points
    int size;                       // Number of points currently stored
} CoordinateArray;
```

**Usage**:
```c
CoordinateArray arr;
arr.size = 0;

// Add point
arr.coords[arr.size].x = 5.0;
arr.coords[arr.size].y = 10.0;
arr.size++;
```

### 3. SectionDto

Holds road section information:

```c
typedef struct {
    double startCh;    // Start chainage (km)
    double endCh;      // End chainage (km)
    double startLat;   // Start latitude
    double startLon;   // Start longitude
    double endLat;     // End latitude
    double endLon;     // End longitude
    double length;     // Section length (km)
    char *geometry;    // WKT geometry string
} SectionDto;
```

**Example**:
```c
SectionDto section;
section.startCh = 2.0;
section.endCh = 5.0;
section.startLat = 0.0179662;
section.startLon = 0.0;
section.length = 3.0;
section.geometry = "LINESTRING(...)";
```

### 4. PointDto

Holds calibrated point information:

```c
typedef struct {
    double chainage;  // Distance from road start (km)
    double lat;       // Latitude
    double lon;       // Longitude
    int index;        // Vertex index on the line
} PointDto;
```

---

## Memory Management

### PostgreSQL Memory Functions

**1. palloc() - Allocate Memory**
```c
char *str = palloc(100);  // Allocate 100 bytes
```

**2. pfree() - Free Memory**
```c
pfree(str);  // Free allocated memory
```

**3. pstrdup() - Duplicate String**
```c
char *copy = pstrdup("Hello");  // Creates a copy
```

### GEOS Memory Functions

**1. GEOSGeom_destroy_r() - Free Geometry**
```c
GEOSGeom_destroy_r(context, geom);
```

**2. GEOS_finish_r() - Free Context**
```c
GEOS_finish_r(context);
```

**3. GEOSFree_r() - Free GEOS String**
```c
GEOSFree_r(context, wkt_string);
```

### Memory Management Rules

1. **Always free what you allocate**
2. **Free in reverse order of allocation**
3. **Use PostgreSQL functions (palloc/pfree) for PostgreSQL data**
4. **Use GEOS functions for GEOS data**

**Example Flow**:
```c
// Allocate
GEOSContextHandle_t context = GEOS_init_r();
GEOSGeometry *geom = ...;
char *wkt = geomToWKT(context, geom);
text *result = cstring_to_text(wkt);

// Free in reverse order
pfree(wkt);
GEOSGeom_destroy_r(context, geom);
GEOS_finish_r(context);

// Return (PostgreSQL manages 'result' now)
PG_RETURN_TEXT_P(result);
```

---

## Error Handling

### PostgreSQL Error Reporting

**Use ereport() for errors**:

```c
if (something_failed) {
    ereport(ERROR,
        (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
         errmsg("Invalid geometry: %s", wkt)));
}
```

**Error levels**:
- `ERROR` - Abort current transaction
- `WARNING` - Show warning, continue
- `NOTICE` - Show notice, continue

### Returning NULL on Failure

```c
if (result_failed) {
    // Cleanup first
    GEOSGeom_destroy_r(context, geom);
    GEOS_finish_r(context);
    
    // Return NULL
    PG_RETURN_NULL();
}
```

### NULL Check Pattern

```c
if (!geom) {
    // Handle error
    GEOS_finish_r(context);
    PG_RETURN_NULL();
}
```

---

## Common Patterns

### 1. Function Template

Every function follows this pattern:

```c
Datum function_name(PG_FUNCTION_ARGS)
{
    // 1. Extract arguments
    text *input = PG_GETARG_TEXT_PP(0);
    
    // 2. Initialize GEOS
    GEOSContextHandle_t context = GEOS_init_r();
    
    // 3. Process
    // ... do work ...
    
    // 4. Build result
    text *result = ...;
    
    // 5. Cleanup
    GEOS_finish_r(context);
    
    // 6. Return
    PG_RETURN_TEXT_P(result);
}
```

### 2. Geometry Processing Pattern

```c
// Create context
GEOSContextHandle_t context = GEOS_init_r();

// Parse WKT
GEOSWKTReader *reader = GEOSWKTReader_create_r(context);
GEOSGeometry *geom = GEOSWKTReader_read_r(context, reader, wkt);

// Use geometry
// ...

// Cleanup
GEOSWKTReader_destroy_r(context, reader);
GEOSGeom_destroy_r(context, geom);
GEOS_finish_r(context);
```

### 3. JSON Building Pattern

```c
StringInfoData buf;
initStringInfo(&buf);

appendStringInfoString(&buf, "{");
appendStringInfo(&buf, "\"key1\":%.6f,", value1);
appendStringInfo(&buf, "\"key2\":\"%s\"", value2);
appendStringInfoString(&buf, "}");

text *result = cstring_to_text(buf.data);
```

---

## Debugging Tips

### 1. Add Debug Logging

```c
elog(NOTICE, "Debug: chainage = %.2f", chainage);
elog(NOTICE, "Debug: WKT = %s", wkt);
```

### 2. Check NULL Values

```c
if (geom == NULL) {
    elog(NOTICE, "Geometry is NULL!");
}
```

### 3. Validate Inputs

```c
if (start_ch >= end_ch) {
    ereport(ERROR,
        (errmsg("Start chainage must be less than end chainage")));
}
```

### 4. Use CLion Breakpoints

Set breakpoints in CLion and inspect:
- Variable values
- Memory contents
- Call stack

---

## Summary

### Key Concepts

1. **PostgreSQL calls C functions** when SQL is executed
2. **GEOS library** handles all geometry operations
3. **Memory management** requires careful cleanup
4. **Interpolation** is used to find exact positions on lines
5. **Distance calculations** use Pythagorean theorem

### Data Flow

```
SQL Query
    ↓
PostgreSQL Extension
    ↓
Extract Arguments (PG_GETARG_*)
    ↓
Initialize GEOS Context
    ↓
Parse WKT to Geometry
    ↓
Process Geometry (algorithms)
    ↓
Build JSON/WKT Result
    ↓
Cleanup Memory
    ↓
Return Result (PG_RETURN_*)
    ↓
PostgreSQL
    ↓
User Gets Result
```

### Next Steps

1. **Read the C code** with this guide beside you
2. **Try modifying** a function to add debug logging
3. **Use CLion** to step through execution
4. **Experiment** with different inputs in SQL

---

## Questions & Answers

**Q: Why use GEOS instead of writing geometry code ourselves?**  
A: GEOS is battle-tested, optimized, and handles edge cases. It would take years to rewrite.

**Q: What's the difference between palloc and malloc?**  
A: `palloc` is PostgreSQL's allocator - it tracks memory per transaction and auto-frees on error.

**Q: Why convert km to degrees?**  
A: GEOS works in the coordinate system of the geometry. For lat/lon, that's degrees.

**Q: Can I add new functions?**  
A: Yes! Follow the same pattern: create C function, add to SQL file, rebuild.

**Q: How do I test changes?**  
A: Rebuild (`make && sudo make install`), reload extension, run SQL tests.

---

**Happy coding!** 🚀