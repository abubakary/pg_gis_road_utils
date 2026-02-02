/**
 * @file shapefile_reader.h
 * @brief Shapefile reader functions for pg_gis_road_utils extension
 * 
 * Provides functions to read ESRI Shapefiles and return records with attributes
 * and geometry in WKT or WKB format.
 */

#ifndef SHAPEFILE_READER_H
#define SHAPEFILE_READER_H

#include <stdint.h>
#include <stdio.h>
#include "utils/bytea.h"

// Shapefile shape types
#define SHAPE_NULL        0
#define SHAPE_POINT       1
#define SHAPE_POLYLINE    3
#define SHAPE_POLYGON     5
#define SHAPE_MULTIPOINT  8
#define SHAPE_POINTZ      11
#define SHAPE_POLYLINEZ   13
#define SHAPE_POLYGONZ    15
#define SHAPE_MULTIPOINTZ 18
#define SHAPE_POINTM      21
#define SHAPE_POLYLINEM   23
#define SHAPE_POLYGONM    25
#define SHAPE_MULTIPOINTM 28
#define SHAPE_MULTIPATCH  31

/**
 * Shapefile header structure
 */
typedef struct {
    int32_t fileCode;
    int32_t fileLength;
    int32_t version;
    int32_t shapeType;
    double xMin, yMin, xMax, yMax;
    double zMin, zMax, mMin, mMax;
} ShapefileHeader;

/**
 * DBF field descriptor
 */
typedef struct {
    char name[12];
    char type;
    uint8_t length;
    uint8_t decimalCount;
} DBFField;

/**
 * DBF header
 */
typedef struct {
    uint8_t version;
    uint8_t lastUpdate[3];
    int32_t numRecords;
    int16_t headerLength;
    int16_t recordLength;
} DBFHeader;

/**
 * Shapefile record with attributes and geometry
 */
typedef struct {
    int recordNumber;
    char **attributes;
    int numAttributes;
    void *geometry;  // GEOSGeometry* (void* to avoid including geos_c.h here)
} ShapefileRecord;

/**
 * Shapefile context for set-returning functions
 */
typedef struct {
    FILE *shpFile;
    FILE *dbfFile;
    int currentRecord;
    int totalRecords;
    DBFField *fields;
    int numFields;
    void *geosContext;  // GEOSContextHandle_t
} ShapefileContext;

#endif /* SHAPEFILE_READER_H */