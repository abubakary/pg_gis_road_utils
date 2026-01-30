/*
 * pg_gis_road_utils - PostgreSQL Extension for Road Network Chainage Operations
 * 
 * This extension provides advanced GIS utilities for road management,
 * including chainage-based operations, line cutting, and point calibration.
 * 
 * Converted from JNI-based implementation to PostgreSQL C extension.
 */

#include "postgres.h"
#include "fmgr.h"
#include "utils/builtins.h"
#include "utils/geo_decls.h"
#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "access/htup_details.h"
#include "utils/json.h"

#include <geos_c.h>
#include <math.h>
#include <string.h>

#ifdef PG_MODULE_MAGIC
PG_MODULE_MAGIC;
#endif

/* ========== Type Definitions ========== */

typedef struct {
    double x;
    double y;
} Coordinate;

typedef struct {
    Coordinate *data;
    size_t size;
    size_t capacity;
} CoordinateArray;

typedef struct {
    double startLat;
    double startLon;
    double endLat;
    double endLon;
    double startCh;
    double endCh;
    double length;
    char *geometry;
} SectionDto;

typedef struct {
    double lat;
    double lon;
    double chainage;
    int index;
} PointDto;

/* ========== Global GEOS Handlers ========== */

static void geos_notice_handler(const char *fmt, ...) {
    // Suppress GEOS notices
}

static void geos_error_handler(const char *fmt, ...) {
    va_list ap;
    char buf[1024];
    
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    
    ereport(ERROR, (errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
                    errmsg("GEOS error: %s", buf)));
}

/* ========== CoordinateArray Functions ========== */

static void initCoordinateArray(CoordinateArray *arr, size_t initialCapacity) {
    arr->data = (Coordinate *)palloc(initialCapacity * sizeof(Coordinate));
    arr->size = 0;
    arr->capacity = initialCapacity;
}

static void addCoordinate(CoordinateArray *arr, double x, double y) {
    if (arr->size >= arr->capacity) {
        size_t newCapacity = arr->capacity * 2;
        arr->data = (Coordinate *)repalloc(arr->data, newCapacity * sizeof(Coordinate));
        arr->capacity = newCapacity;
    }
    arr->data[arr->size].x = x;
    arr->data[arr->size].y = y;
    arr->size++;
}

static void freeCoordinateArray(CoordinateArray *arr) {
    if (arr->data) {
        pfree(arr->data);
        arr->data = NULL;
    }
    arr->size = 0;
    arr->capacity = 0;
}

/* ========== GEOS Helper Functions ========== */

static GEOSGeometry* createLineStringFromArray(GEOSContextHandle_t context, CoordinateArray *coordsArr) {
    if (!coordsArr || !coordsArr->data || coordsArr->size < 2) {
        return NULL;
    }

    GEOSCoordSequence *coords = GEOSCoordSeq_create_r(context, coordsArr->size, 2);
    if (!coords) {
        return NULL;
    }

    for (size_t i = 0; i < coordsArr->size; i++) {
        GEOSCoordSeq_setX_r(context, coords, i, coordsArr->data[i].x);
        GEOSCoordSeq_setY_r(context, coords, i, coordsArr->data[i].y);
    }

    return GEOSGeom_createLineString_r(context, coords);
}

static char* geomToWKT(GEOSContextHandle_t context, GEOSGeometry *geometry) {
    if (!geometry) {
        return NULL;
    }

    char *wkt = GEOSGeomToWKT_r(context, geometry);
    if (!wkt) {
        return NULL;
    }

    /* Copy to PostgreSQL memory context */
    char *result = pstrdup(wkt);
    GEOSFree_r(context, wkt);
    
    return result;
}

static GEOSGeometry* getLineFromMultiline(GEOSContextHandle_t context, const char* wkt) {
    GEOSWKTReader *reader = GEOSWKTReader_create_r(context);
    if (!reader) {
        return NULL;
    }

    GEOSGeometry *geom = GEOSWKTReader_read_r(context, reader, wkt);
    GEOSWKTReader_destroy_r(context, reader);

    if (!geom) {
        return NULL;
    }

    int geomType = GEOSGeomTypeId_r(context, geom);

    if (geomType == GEOS_LINESTRING) {
        return geom;
    } else if (geomType == GEOS_MULTILINESTRING) {
        int numGeoms = GEOSGetNumGeometries_r(context, geom);
        if (numGeoms > 0) {
            const GEOSGeometry *firstLine = GEOSGetGeometryN_r(context, geom, 0);
            GEOSGeometry *result = GEOSGeom_clone_r(context, firstLine);
            GEOSGeom_destroy_r(context, geom);
            return result;
        }
    }

    GEOSGeom_destroy_r(context, geom);
    return NULL;
}

static double compute_distance(double x1, double y1, double x2, double y2) {
    return sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));
}

/* ========== Core Implementation Functions ========== */

#define MAX_RADIUS 1000000

static int calibratePoint(GEOSContextHandle_t context, const GEOSGeometry* line, 
                         const GEOSGeometry* referencePoint, double radius, PointDto* pointDto) {
    if (!line || !referencePoint || !pointDto) {
        return 0;
    }

    const GEOSCoordSequence* coordinateSequenceLine = GEOSGeom_getCoordSeq_r(context, line);
    if (!coordinateSequenceLine) {
        return 0;
    }

    unsigned int numPointsLine = 0;
    GEOSCoordSeq_getSize_r(context, coordinateSequenceLine, &numPointsLine);

    double closestReferenceDistance = MAX_RADIUS;
    double chainage = MAX_RADIUS;
    double lengthFromStart = 0.0;
    double prev_x, prev_y;
    double lat, lon;
    int index;

    GEOSCoordSeq_getX_r(context, coordinateSequenceLine, 0, &prev_x);
    GEOSCoordSeq_getY_r(context, coordinateSequenceLine, 0, &prev_y);

    for (unsigned int i = 0; i < numPointsLine; i++) {
        double x, y;

        if (!GEOSCoordSeq_getX_r(context, coordinateSequenceLine, i, &x) ||
            !GEOSCoordSeq_getY_r(context, coordinateSequenceLine, i, &y)) {
            return 0;
        }

        GEOSGeometry* linePoint = GEOSGeom_createPointFromXY_r(context, x, y);
        GEOSGeometry* prevPoint = GEOSGeom_createPointFromXY_r(context, prev_x, prev_y);

        if (!linePoint) {
            GEOSGeom_destroy_r(context, linePoint);
            return 0;
        }

        double distanceFromReference;
        if (!GEOSDistance_r(context, referencePoint, linePoint, &distanceFromReference)) {
            GEOSGeom_destroy_r(context, linePoint);
            GEOSGeom_destroy_r(context, prevPoint);
            return 0;
        }

        double distanceFromPrevPoint;
        GEOSDistance_r(context, prevPoint, linePoint, &distanceFromPrevPoint);
        lengthFromStart += distanceFromPrevPoint;

        if (distanceFromReference <= radius && distanceFromReference < closestReferenceDistance) {
            closestReferenceDistance = distanceFromReference;
            chainage = lengthFromStart;
            lon = x;
            lat = y;
            index = i;
        }

        prev_x = x;
        prev_y = y;
        GEOSGeom_destroy_r(context, linePoint);
        GEOSGeom_destroy_r(context, prevPoint);
    }

    if (closestReferenceDistance == MAX_RADIUS) {
        return 0;
    }

    double final_chainage = (chainage * 111320) / 1000;

    pointDto->chainage = final_chainage;
    pointDto->lat = lat;
    pointDto->lon = lon;
    pointDto->index = index;

    return 1;
}

static int extractSubLineStringByChainages(GEOSContextHandle_t context, GEOSGeometry *line, 
                                           double start_chainage, double end_chainage, SectionDto *sectionDto) {
    if (!sectionDto || !line || start_chainage >= end_chainage) {
        return 0;
    }

    start_chainage = (start_chainage * 1000) / 111320;
    end_chainage = (end_chainage * 1000) / 111320;

    const GEOSCoordSequence *coords = GEOSGeom_getCoordSeq_r(context, line);
    if (!coords) return 0;

    unsigned int numPoints;
    GEOSCoordSeq_getSize_r(context, coords, &numPoints);

    double total_distance = 0.0;
    double prev_x, prev_y, curr_x, curr_y;
    GEOSCoordSeq_getX_r(context, coords, 0, &prev_x);
    GEOSCoordSeq_getY_r(context, coords, 0, &prev_y);

    CoordinateArray coords_arr;
    initCoordinateArray(&coords_arr, 2);

    int startAdded = 0, endAdded = 0;
    double startLat, startLon, endLat, endLon;

    for (unsigned int i = 1; i < numPoints; i++) {
        GEOSCoordSeq_getX_r(context, coords, i, &curr_x);
        GEOSCoordSeq_getY_r(context, coords, i, &curr_y);

        double segment_length = compute_distance(prev_x, prev_y, curr_x, curr_y);
        total_distance += segment_length;

        if (!startAdded && total_distance >= start_chainage) {
            double factor = (start_chainage - (total_distance - segment_length)) / segment_length;
            double start_x = prev_x + factor * (curr_x - prev_x);
            double start_y = prev_y + factor * (curr_y - prev_y);
            addCoordinate(&coords_arr, start_x, start_y);
            startAdded = 1;
            startLon = start_x;
            startLat = start_y;
        }

        if (startAdded && total_distance <= end_chainage) {
            addCoordinate(&coords_arr, curr_x, curr_y);
        }

        if (!endAdded && total_distance >= end_chainage) {
            double factor = (end_chainage - (total_distance - segment_length)) / segment_length;
            double end_x = prev_x + factor * (curr_x - prev_x);
            double end_y = prev_y + factor * (curr_y - prev_y);
            addCoordinate(&coords_arr, end_x, end_y);
            endAdded = 1;
            endLat = end_y;
            endLon = end_x;
            break;
        }

        prev_x = curr_x;
        prev_y = curr_y;
    }

    if (coords_arr.size < 2) {
        freeCoordinateArray(&coords_arr);
        return 0;
    }

    GEOSGeometry *subLine = createLineStringFromArray(context, &coords_arr);
    freeCoordinateArray(&coords_arr);

    if (!subLine) {
        return 0;
    }

    sectionDto->startCh = start_chainage * 111320 / 1000;
    sectionDto->endCh = end_chainage * 111320 / 1000;
    sectionDto->startLat = startLat;
    sectionDto->startLon = startLon;
    sectionDto->endLat = endLat;
    sectionDto->endLon = endLon;
    sectionDto->length = (end_chainage * 111320 / 1000) - (start_chainage * 111320 / 1000);
    sectionDto->geometry = geomToWKT(context, subLine);

    GEOSGeom_destroy_r(context, subLine);

    return 1;
}

/* ========== PostgreSQL Function Implementations ========== */

PG_FUNCTION_INFO_V1(get_section_by_chainage);

Datum
get_section_by_chainage(PG_FUNCTION_ARGS)
{
    text *wkt_text = PG_GETARG_TEXT_PP(0);
    float8 start_ch = PG_GETARG_FLOAT8(1);
    float8 end_ch = PG_GETARG_FLOAT8(2);
    
    char *wkt = text_to_cstring(wkt_text);
    
    /* Initialize GEOS */
    GEOSContextHandle_t context = GEOS_init_r();
    GEOSContext_setNoticeHandler_r(context, geos_notice_handler);
    GEOSContext_setErrorHandler_r(context, geos_error_handler);
    
    GEOSGeometry* geom = getLineFromMultiline(context, wkt);
    
    if (!geom || GEOSGeomTypeId_r(context, geom) != GEOS_LINESTRING) {
        if (geom) GEOSGeom_destroy_r(context, geom);
        GEOS_finish_r(context);
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                        errmsg("Invalid geometry: must be LINESTRING or MULTILINESTRING")));
    }
    
    SectionDto section;
    memset(&section, 0, sizeof(SectionDto));
    
    int res = extractSubLineStringByChainages(context, geom, start_ch, end_ch, &section);
    
    if (!res) {
        GEOSGeom_destroy_r(context, geom);
        GEOS_finish_r(context);
        ereport(ERROR, (errcode(ERRCODE_INTERNAL_ERROR),
                        errmsg("Failed to extract sub-line")));
    }
    
    /* Build JSON result */
    StringInfoData buf;
    initStringInfo(&buf);
    
    appendStringInfo(&buf, "{");
    appendStringInfo(&buf, "\"start_ch\":%.6f,", section.startCh);
    appendStringInfo(&buf, "\"end_ch\":%.6f,", section.endCh);
    appendStringInfo(&buf, "\"start_lat\":%.8f,", section.startLat);
    appendStringInfo(&buf, "\"start_lon\":%.8f,", section.startLon);
    appendStringInfo(&buf, "\"end_lat\":%.8f,", section.endLat);
    appendStringInfo(&buf, "\"end_lon\":%.8f,", section.endLon);
    appendStringInfo(&buf, "\"length\":%.6f,", section.length);
    appendStringInfo(&buf, "\"geometry\":\"%s\"", section.geometry ? section.geometry : "");
    appendStringInfo(&buf, "}");
    
    text *result = cstring_to_text(buf.data);
    
    if (section.geometry) pfree(section.geometry);
    GEOSGeom_destroy_r(context, geom);
    GEOS_finish_r(context);
    
    PG_RETURN_TEXT_P(result);
}

PG_FUNCTION_INFO_V1(cut_line_at_chainage);

Datum
cut_line_at_chainage(PG_FUNCTION_ARGS)
{
    text *wkt_text = PG_GETARG_TEXT_PP(0);
    float8 chainage = PG_GETARG_FLOAT8(1);
    
    char *wkt = text_to_cstring(wkt_text);
    
    GEOSContextHandle_t context = GEOS_init_r();
    GEOSContext_setNoticeHandler_r(context, geos_notice_handler);
    GEOSContext_setErrorHandler_r(context, geos_error_handler);
    
    GEOSGeometry* line = getLineFromMultiline(context, wkt);
    
    if (!line || GEOSGeomTypeId_r(context, line) != GEOS_LINESTRING) {
        if (line) GEOSGeom_destroy_r(context, line);
        GEOS_finish_r(context);
        PG_RETURN_NULL();
    }
    
    /* Convert chainage to degrees */
    double chainage_degrees = (chainage * 1000) / 111320;
    
    /* Use GEOSInterpolate to get point at chainage */
    double total_length;
    GEOSLength_r(context, line, &total_length);
    
    if (chainage_degrees < 0 || chainage_degrees > total_length) {
        GEOSGeom_destroy_r(context, line);
        GEOS_finish_r(context);
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                        errmsg("Chainage out of bounds")));
    }
    
    GEOSGeometry* point = GEOSInterpolate_r(context, line, chainage_degrees);
    
    if (!point) {
        GEOSGeom_destroy_r(context, line);
        GEOS_finish_r(context);
        PG_RETURN_NULL();
    }
    
    char *result_wkt = geomToWKT(context, point);
    text *result = cstring_to_text(result_wkt);
    
    if (result_wkt) pfree(result_wkt);
    GEOSGeom_destroy_r(context, point);
    GEOSGeom_destroy_r(context, line);
    GEOS_finish_r(context);
    
    PG_RETURN_TEXT_P(result);
}

PG_FUNCTION_INFO_V1(calibrate_point_on_line);

Datum
calibrate_point_on_line(PG_FUNCTION_ARGS)
{
    text *line_wkt_text = PG_GETARG_TEXT_PP(0);
    text *point_wkt_text = PG_GETARG_TEXT_PP(1);
    float8 radius = PG_GETARG_FLOAT8(2);
    
    char *line_wkt = text_to_cstring(line_wkt_text);
    char *point_wkt = text_to_cstring(point_wkt_text);
    
    GEOSContextHandle_t context = GEOS_init_r();
    GEOSContext_setNoticeHandler_r(context, geos_notice_handler);
    GEOSContext_setErrorHandler_r(context, geos_error_handler);
    
    GEOSWKTReader *reader = GEOSWKTReader_create_r(context);
    GEOSGeometry* line = GEOSWKTReader_read_r(context, reader, line_wkt);
    GEOSGeometry* point = GEOSWKTReader_read_r(context, reader, point_wkt);
    GEOSWKTReader_destroy_r(context, reader);
    
    if (!line || !point) {
        if (line) GEOSGeom_destroy_r(context, line);
        if (point) GEOSGeom_destroy_r(context, point);
        GEOS_finish_r(context);
        PG_RETURN_NULL();
    }
    
    PointDto pointDto;
    memset(&pointDto, 0, sizeof(PointDto));
    
    int res = calibratePoint(context, line, point, radius, &pointDto);
    
    if (!res) {
        GEOSGeom_destroy_r(context, line);
        GEOSGeom_destroy_r(context, point);
        GEOS_finish_r(context);
        PG_RETURN_NULL();
    }
    
    /* Build JSON result */
    StringInfoData buf;
    initStringInfo(&buf);
    
    appendStringInfo(&buf, "{");
    appendStringInfo(&buf, "\"chainage\":%.6f,", pointDto.chainage);
    appendStringInfo(&buf, "\"lat\":%.8f,", pointDto.lat);
    appendStringInfo(&buf, "\"lon\":%.8f,", pointDto.lon);
    appendStringInfo(&buf, "\"index\":%d", pointDto.index);
    appendStringInfo(&buf, "}");
    
    text *result = cstring_to_text(buf.data);
    
    GEOSGeom_destroy_r(context, line);
    GEOSGeom_destroy_r(context, point);
    GEOS_finish_r(context);
    
    PG_RETURN_TEXT_P(result);
}
