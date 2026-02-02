/**
 * shapefile_reader.c
 * PostgreSQL extension for reading ESRI Shapefiles (.shp + .dbf)
 * Returns records with WKT or WKB geometry
 *
 * Supports Point, MultiPoint, Polyline (LineString/MultiLineString), Polygon
 */

#include "postgres.h"
#include "fmgr.h"
#include "funcapi.h"
#include "utils/builtins.h"
#include "utils/array.h"
#include "lib/stringinfo.h"
#include "catalog/pg_type.h"
#include "access/htup_details.h"

#include <geos_c.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <arpa/inet.h>

#include "shapefile_reader.h"

/* ============================
 * Helper Functions
 * ============================ */

/* Swap endianness for big-endian integers (shapefile header) */
static uint32_t swap_endian_32(uint32_t val) {
    return ((val & 0xFF000000) >> 24) |
           ((val & 0x00FF0000) >> 8) |
           ((val & 0x0000FF00) << 8) |
           ((val & 0x000000FF) << 24);
}

/* Convert little-endian integer to host */
#define LE32TOH(x) (x)  /* adjust if necessary for your platform */

/* ============================
 * Shapefile Header
 * ============================ */

static int read_shapefile_header(FILE *fp, ShapefileHeader *header) {
    if (!fp || !header) return 0;

    uint32_t fileCode;
    if (fread(&fileCode, 4, 1, fp) != 1) return 0;
    header->fileCode = swap_endian_32(fileCode);

    if (header->fileCode != 9994) return 0;

    fseek(fp, 24, SEEK_SET);

    uint32_t fileLength;
    fread(&fileLength, 4, 1, fp);
    header->fileLength = swap_endian_32(fileLength);

    fread(&header->version, 4, 1, fp);
    fread(&header->shapeType, 4, 1, fp);

    fread(&header->xMin, 8, 1, fp);
    fread(&header->yMin, 8, 1, fp);
    fread(&header->xMax, 8, 1, fp);
    fread(&header->yMax, 8, 1, fp);
    fread(&header->zMin, 8, 1, fp);
    fread(&header->zMax, 8, 1, fp);
    fread(&header->mMin, 8, 1, fp);
    fread(&header->mMax, 8, 1, fp);

    return 1;
}

/* ============================
 * DBF reading
 * ============================ */

static DBFField *read_dbf_fields(FILE *fp, int *numFields, int *numRecords) {
    if (!fp) return NULL;

    uint8_t version;
    fread(&version, 1, 1, fp);
    fseek(fp, 3, SEEK_CUR);

    int32_t recordCount;
    fread(&recordCount, 4, 1, fp);
    *numRecords = recordCount;

    int16_t headerLength, recordLength;
    fread(&headerLength, 2, 1, fp);
    fread(&recordLength, 2, 1, fp);

    fseek(fp, 20, SEEK_CUR);

    int fieldCount = (headerLength - 33) / 32;
    *numFields = fieldCount;

    DBFField *fields = (DBFField *) palloc(fieldCount * sizeof(DBFField));

    for (int i = 0; i < fieldCount; i++) {
        fread(fields[i].name, 11, 1, fp);
        fields[i].name[11] = '\0';
        fread(&fields[i].type, 1, 1, fp);
        fseek(fp, 4, SEEK_CUR);
        fread(&fields[i].length, 1, 1, fp);
        fread(&fields[i].decimalCount, 1, 1, fp);
        fseek(fp, 14, SEEK_CUR);
    }

    fseek(fp, 1, SEEK_CUR);

    return fields;
}

static char **read_dbf_attributes(FILE *fp, DBFField *fields, int numFields) {
    char **attributes = (char **) palloc(numFields * sizeof(char *));
    fseek(fp, 1, SEEK_CUR); // skip deletion flag
    for (int i = 0; i < numFields; i++) {
        char *value = (char *) palloc(fields[i].length + 1);
        fread(value, fields[i].length, 1, fp);
        value[fields[i].length] = '\0';
        char *end = value + strlen(value) - 1;
        while (end > value && *end == ' ') *end-- = '\0';
        attributes[i] = value;
    }
    return attributes;
}

/* ============================
 * Geometry Readers
 * ============================ */

static GEOSGeometry *read_point_geometry(GEOSContextHandle_t context, FILE *fp) {
    double x, y;
    fread(&x, 8, 1, fp);
    fread(&y, 8, 1, fp);

    GEOSCoordSequence *seq = GEOSCoordSeq_create_r(context, 1, 2);
    GEOSCoordSeq_setX_r(context, seq, 0, x);
    GEOSCoordSeq_setY_r(context, seq, 0, y);

    return GEOSGeom_createPoint_r(context, seq);
}

static GEOSGeometry *read_multipoint_geometry(GEOSContextHandle_t context, FILE *fp) {
    fseek(fp, 32, SEEK_CUR); // skip bounding box
    int32_t numPoints;
    fread(&numPoints, 4, 1, fp);
    GEOSGeometry **points = (GEOSGeometry **) palloc(numPoints * sizeof(GEOSGeometry * ));

    for (int i = 0; i < numPoints; i++) {
        double x, y;
        fread(&x, 8, 1, fp);
        fread(&y, 8, 1, fp);
        GEOSCoordSequence *seq = GEOSCoordSeq_create_r(context, 1, 2);
        GEOSCoordSeq_setX_r(context, seq, 0, x);
        GEOSCoordSeq_setY_r(context, seq, 0, y);
        points[i] = GEOSGeom_createPoint_r(context, seq);
    }

    GEOSGeometry *geom = GEOSGeom_createCollection_r(context, GEOS_MULTIPOINT, points, numPoints);
    pfree(points);
    return geom;
}

static GEOSGeometry *read_polyline_geometry(GEOSContextHandle_t context, FILE *fp) {
    fseek(fp, 32, SEEK_CUR);
    int32_t numParts, numPoints;
    fread(&numParts, 4, 1, fp);
    fread(&numPoints, 4, 1, fp);
    numParts = LE32TOH(numParts);
    numPoints = LE32TOH(numPoints);

    int32_t *parts = palloc(numParts * sizeof(int32_t));
    fread(parts, 4, numParts, fp);
    for (int i = 0; i < numParts; i++) parts[i] = LE32TOH(parts[i]);

    double *coords = palloc(numPoints * 2 * sizeof(double));
    for (int i = 0; i < numPoints; i++) {
        fread(&coords[i * 2], 8, 1, fp);
        fread(&coords[i * 2 + 1], 8, 1, fp);
    }

    GEOSGeometry **lines = (GEOSGeometry **) palloc(numParts * sizeof(GEOSGeometry * ));
    int validParts = 0;

    for (int part = 0; part < numParts; part++) {
        int start = parts[part];
        int end = (part < numParts - 1) ? parts[part + 1] : numPoints;
        int size = end - start;
        if (size < 2) continue; // skip invalid
        GEOSCoordSequence *seq = GEOSCoordSeq_create_r(context, size, 2);
        for (int i = 0; i < size; i++) {
            int idx = start + i;
            GEOSCoordSeq_setX_r(context, seq, i, coords[idx * 2]);
            GEOSCoordSeq_setY_r(context, seq, i, coords[idx * 2 + 1]);
        }
        lines[validParts++] = GEOSGeom_createLineString_r(context, seq);
    }

    GEOSGeometry *geom = NULL;
    if (validParts == 0) geom = NULL;
    else if (validParts == 1) geom = lines[0];
    else geom = GEOSGeom_createCollection_r(context, GEOS_MULTILINESTRING, lines, validParts);

    pfree(lines);
    pfree(parts);
    pfree(coords);

    return geom;
}

static GEOSGeometry *read_polygon_geometry(GEOSContextHandle_t context, FILE *fp) {
    fseek(fp, 32, SEEK_CUR);
    int32_t numParts, numPoints;
    fread(&numParts, 4, 1, fp);
    fread(&numPoints, 4, 1, fp);

    int32_t *parts = palloc(numParts * sizeof(int32_t));
    fread(parts, 4, numParts, fp);

    double *coords = palloc(numPoints * 2 * sizeof(double));
    for (int i = 0; i < numPoints; i++) {
        fread(&coords[i * 2], 8, 1, fp);
        fread(&coords[i * 2 + 1], 8, 1, fp);
    }

    GEOSGeometry **rings = (GEOSGeometry **) palloc(numParts * sizeof(GEOSGeometry * ));

    for (int part = 0; part < numParts; part++) {
        int start = parts[part];
        int end = (part < numParts - 1) ? parts[part + 1] : numPoints;
        int size = end - start;
        if (size < 4) continue; // polygon ring must have >=4 points
        GEOSCoordSequence *seq = GEOSCoordSeq_create_r(context, size, 2);
        for (int i = 0; i < size; i++) {
            int idx = start + i;
            GEOSCoordSeq_setX_r(context, seq, i, coords[idx * 2]);
            GEOSCoordSeq_setY_r(context, seq, i, coords[idx * 2 + 1]);
        }
        rings[part] = GEOSGeom_createLinearRing_r(context, seq);
    }

    if (!rings[0]) {
        pfree(rings);
        pfree(parts);
        pfree(coords);
        return NULL;
    }

    GEOSGeometry *geom = GEOSGeom_createPolygon_r(context, rings[0], (numParts > 1) ? &rings[1] : NULL,
                                                  (numParts > 1) ? numParts - 1 : 0);

    pfree(rings);
    pfree(parts);
    pfree(coords);

    return geom;
}

/* ============================
 * Shapefile Record Reader
 * ============================ */

static ShapefileRecord *read_shapefile_record(
        GEOSContextHandle_t context,
        FILE *shpFile,
        FILE *dbfFile,
        DBFField *fields,
        int numFields
) {
    ShapefileRecord *record = (ShapefileRecord *) palloc(sizeof(ShapefileRecord));

    uint32_t recNum, contentLength;
    if (fread(&recNum, 4, 1, shpFile) != 1) {
        pfree(record);
        return NULL;
    }
    fread(&contentLength, 4, 1, shpFile);
    record->recordNumber = swap_endian_32(recNum);

    int32_t shapeType;
    fread(&shapeType, 4, 1, shpFile);

    switch (shapeType) {
        case SHAPE_NULL:
            record->geometry = NULL;
            break;
        case SHAPE_POINT:
            record->geometry = read_point_geometry(context, shpFile);
            break;
        case SHAPE_MULTIPOINT:
            record->geometry = read_multipoint_geometry(context, shpFile);
            break;
        case SHAPE_POLYLINE:
            record->geometry = read_polyline_geometry(context, shpFile);
            break;
        case SHAPE_POLYGON:
            record->geometry = read_polygon_geometry(context, shpFile);
            break;
        case SHAPE_POINTZ:
        case SHAPE_MULTIPOINTZ:
        case SHAPE_POLYLINEZ:
        case SHAPE_POLYGONZ:
            // ignore Z
            if (shapeType == SHAPE_POINTZ) record->geometry = read_point_geometry(context, shpFile);
            else if (shapeType == SHAPE_MULTIPOINTZ) record->geometry = read_multipoint_geometry(context, shpFile);
            else if (shapeType == SHAPE_POLYLINEZ) record->geometry = read_polyline_geometry(context, shpFile);
            else if (shapeType == SHAPE_POLYGONZ) record->geometry = read_polygon_geometry(context, shpFile);
            break;
        default:
            record->geometry = NULL;
            break;
    }

    record->attributes = read_dbf_attributes(dbfFile, fields, numFields);
    record->numAttributes = numFields;

    return record;
}

/* ============================
 * PostgreSQL SRF Functions
 * ============================ */

PG_FUNCTION_INFO_V1(read_shapefile_wkt);
PG_FUNCTION_INFO_V1(read_shapefile_wkb);

Datum read_shapefile_wkt(PG_FUNCTION_ARGS) {
    FuncCallContext *funcctx;

    if (SRF_IS_FIRSTCALL()) {
        funcctx = SRF_FIRSTCALL_INIT();  // MUST call first!

        MemoryContext oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        text *path_text = PG_GETARG_TEXT_PP(0);
        char *base_path = text_to_cstring(path_text);

        ShapefileContext *ctx = (ShapefileContext *) palloc(sizeof(ShapefileContext));
        ctx->currentRecord = 0;
        ctx->geosContext = GEOS_init_r();

        // Open files
        char shp_path[1024], dbf_path[1024];
        snprintf(shp_path, sizeof(shp_path), "%s.shp", base_path);
        snprintf(dbf_path, sizeof(dbf_path), "%s.dbf", base_path);

        ctx->shpFile = fopen(shp_path, "rb");
        ctx->dbfFile = fopen(dbf_path, "rb");
        if (!ctx->shpFile || !ctx->dbfFile) {
            if (ctx->shpFile) fclose(ctx->shpFile);
            if (ctx->dbfFile) fclose(ctx->dbfFile);
            GEOS_finish_r(ctx->geosContext);
            ereport(ERROR, (errmsg("Could not open shapefile: %s", base_path)));
        }

        // Read header & fields
        ShapefileHeader header;
        if (!read_shapefile_header(ctx->shpFile, &header)) {
            fclose(ctx->shpFile);
            fclose(ctx->dbfFile);
            GEOS_finish_r(ctx->geosContext);
            ereport(ERROR, (errmsg("Invalid shapefile header: %s", base_path)));
        }

        ctx->fields = read_dbf_fields(ctx->dbfFile, &ctx->numFields, &ctx->totalRecords);

        funcctx->user_fctx = ctx;

        TupleDesc tupdesc;
        if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
            ereport(ERROR, (errmsg("function returning record called in context that cannot accept type record")));

        funcctx->tuple_desc = BlessTupleDesc(tupdesc);

        MemoryContextSwitchTo(oldcontext);
    }

    funcctx = SRF_PERCALL_SETUP();
    ShapefileContext *ctx = (ShapefileContext *) funcctx->user_fctx;

    if (ctx->currentRecord >= ctx->totalRecords) {
        fclose(ctx->shpFile);
        fclose(ctx->dbfFile);
        GEOS_finish_r(ctx->geosContext);
        SRF_RETURN_DONE(funcctx);
    }

    ShapefileRecord *record = read_shapefile_record(ctx->geosContext, ctx->shpFile, ctx->dbfFile, ctx->fields,
                                                    ctx->numFields);
    if (!record)
        SRF_RETURN_DONE(funcctx);

    Datum values[3];
    bool nulls[3] = {false, false, false};

    values[0] = Int32GetDatum(record->recordNumber);

    int dims[1] = {record->numAttributes};
    int lbs[1] = {1};
    Datum *attr_datums = (Datum *) palloc(record->numAttributes * sizeof(Datum));
    for (int i = 0; i < record->numAttributes; i++)
        attr_datums[i] = CStringGetTextDatum(record->attributes[i]);
    ArrayType *arr = construct_md_array(attr_datums, NULL, 1, dims, lbs, TEXTOID, -1, false, 'i');
    values[1] = PointerGetDatum(arr);

    if (record->geometry) {
        GEOSWKTWriter *writer = GEOSWKTWriter_create_r(ctx->geosContext);
        char *wkt = GEOSWKTWriter_write_r(ctx->geosContext, writer, record->geometry);

        MemoryContext oldctx = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
        values[2] = CStringGetTextDatum(wkt);  // Copy to Postgres memory
        MemoryContextSwitchTo(oldctx);

        GEOSWKTWriter_destroy_r(ctx->geosContext, writer);
        GEOSGeom_destroy_r(ctx->geosContext, record->geometry);
        GEOSFree_r(ctx->geosContext, wkt);
    } else {
        nulls[2] = true;
    }

    ctx->currentRecord++;
    HeapTuple tuple = heap_form_tuple(funcctx->tuple_desc, values, nulls);
    Datum result = HeapTupleGetDatum(tuple);
    SRF_RETURN_NEXT(funcctx, result);
}


Datum
read_shapefile_wkb(PG_FUNCTION_ARGS) {
    FuncCallContext *funcctx;
    ShapefileContext *ctx;

    if (SRF_IS_FIRSTCALL()) {
        text *path_text = PG_GETARG_TEXT_PP(0);
        char *base_path = text_to_cstring(path_text);

        funcctx = SRF_FIRSTCALL_INIT();

        MemoryContext oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

        ctx = (ShapefileContext *) palloc(sizeof(ShapefileContext));
        ctx->currentRecord = 0;
        ctx->geosContext = GEOS_init_r();

        char shp_path[1024], dbf_path[1024];
        snprintf(shp_path, sizeof(shp_path), "%s.shp", base_path);
        snprintf(dbf_path, sizeof(dbf_path), "%s.dbf", base_path);

        ctx->shpFile = fopen(shp_path, "rb");
        ctx->dbfFile = fopen(dbf_path, "rb");

        if (!ctx->shpFile || !ctx->dbfFile) {
            if (ctx->shpFile) fclose(ctx->shpFile);
            if (ctx->dbfFile) fclose(ctx->dbfFile);
            GEOS_finish_r(ctx->geosContext);
            ereport(ERROR, (errmsg("Could not open shapefile: %s", base_path)));
        }

        ShapefileHeader header;
        if (!read_shapefile_header(ctx->shpFile, &header)) {
            fclose(ctx->shpFile);
            fclose(ctx->dbfFile);
            GEOS_finish_r(ctx->geosContext);
            ereport(ERROR, (errmsg("Invalid shapefile header: %s", base_path)));
        }

        ctx->fields = read_dbf_fields(ctx->dbfFile, &ctx->numFields, &ctx->totalRecords);

        funcctx->user_fctx = ctx;

        TupleDesc tupdesc;
        if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
            ereport(ERROR, (errmsg("function returning record called in context that cannot accept type record")));

        funcctx->tuple_desc = BlessTupleDesc(tupdesc);

        MemoryContextSwitchTo(oldcontext);
    }

    funcctx = SRF_PERCALL_SETUP();
    ctx = (ShapefileContext *) funcctx->user_fctx;

    if (ctx->currentRecord >= ctx->totalRecords) {
        fclose(ctx->shpFile);
        fclose(ctx->dbfFile);
        GEOS_finish_r(ctx->geosContext);
        SRF_RETURN_DONE(funcctx);
    }

    ShapefileRecord *record = read_shapefile_record(ctx->geosContext, ctx->shpFile, ctx->dbfFile, ctx->fields,
                                                    ctx->numFields);

    if (!record)
        SRF_RETURN_DONE(funcctx);

    Datum values[3];
    bool nulls[3] = {false, false, false};

    /* Record number */
    values[0] = Int32GetDatum(record->recordNumber);

    /* Attributes */
    int dims[1] = {record->numAttributes};
    int lbs[1] = {1};
    Datum *attr_datums = (Datum *) palloc(record->numAttributes * sizeof(Datum));
    for (int i = 0; i < record->numAttributes; i++)
        attr_datums[i] = CStringGetTextDatum(record->attributes[i]);
    ArrayType *arr = construct_md_array(attr_datums, NULL, 1, dims, lbs, TEXTOID, -1, false, 'i');
    values[1] = PointerGetDatum(arr);

    /* Geometry as WKB */
    if (record->geometry) {
        GEOSWKBWriter *wkbWriter = GEOSWKBWriter_create_r(ctx->geosContext);
        GEOSWKBWriter_setByteOrder_r(ctx->geosContext, wkbWriter, 1); // 1 = little-endian

        size_t wkb_size = 0;
        unsigned char *wkb_buffer = GEOSWKBWriter_write_r(ctx->geosContext, wkbWriter, record->geometry, &wkb_size);

        if (wkb_buffer && wkb_size > 0) {
            bytea *geom_bytea = (bytea *) palloc(VARHDRSZ + wkb_size);
            SET_VARSIZE(geom_bytea, VARHDRSZ + wkb_size);
            memcpy(VARDATA(geom_bytea), wkb_buffer, wkb_size);

            values[2] = PointerGetDatum(geom_bytea);
        } else {
            nulls[2] = true;
        }

        GEOSFree_r(ctx->geosContext, wkb_buffer);
        GEOSWKBWriter_destroy_r(ctx->geosContext, wkbWriter);
        GEOSGeom_destroy_r(ctx->geosContext, record->geometry);
    } else {
        nulls[2] = true;
    }

    ctx->currentRecord++;

    HeapTuple tuple = heap_form_tuple(funcctx->tuple_desc, values, nulls);
    Datum result = HeapTupleGetDatum(tuple);

    SRF_RETURN_NEXT(funcctx, result);
}

PG_FUNCTION_INFO_V1(read_shapefile_test);


Datum
read_shapefile_test(PG_FUNCTION_ARGS) {
    FuncCallContext *funcctx;

    if (SRF_IS_FIRSTCALL()) {
        funcctx = SRF_FIRSTCALL_INIT();
        funcctx->user_fctx = NULL; // no context needed for dummy data

        TupleDesc tupdesc;
        if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
            ereport(ERROR, (errmsg("Function called in context that cannot accept type record")));
        funcctx->tuple_desc = BlessTupleDesc(tupdesc);
    }

    funcctx = SRF_PERCALL_SETUP();

    static int call_count = 0;
    if (call_count >= 2) // only 2 dummy records
    {
        call_count = 0;
        SRF_RETURN_DONE(funcctx);
    }

    Datum values[3];
    bool nulls[3] = {false, false, false};

    // record number
    values[0] = Int32GetDatum(call_count + 1);

    // attributes
    Datum attrs[2];
    attrs[0] = CStringGetTextDatum("Name1");
    attrs[1] = CStringGetTextDatum("TypeA");
    ArrayType *arr = construct_array(attrs, 2, TEXTOID, -1, false, 'i');
    values[1] = PointerGetDatum(arr);

    // geometry WKB
    GEOSContextHandle_t context = GEOS_init_r();
    GEOSCoordSeq *seq;
    GEOSGeometry *line = GEOSGeom_createLineString_r(context, GEOSCoordSeq_create_r(context, 2, 2));
    seq = GEOSGeom_getCoordSeq_r(context, line);

    if (call_count == 0) {
        GEOSCoordSeq_setX_r(context, seq, 0, 0.0);
        GEOSCoordSeq_setY_r(context, seq, 0, 0.0);
        GEOSCoordSeq_setX_r(context, seq, 1, 10.0);
        GEOSCoordSeq_setY_r(context, seq, 1, 0.0);
    } else {
        GEOSCoordSeq_setX_r(context, seq, 0, 0.0);
        GEOSCoordSeq_setY_r(context, seq, 0, 0.0);
        GEOSCoordSeq_setX_r(context, seq, 1, 0.0);
        GEOSCoordSeq_setY_r(context, seq, 1, 10.0);
    }

    // modern GEOS: get WKB
    size_t wkb_size = 0;
    unsigned char *wkb = GEOSGeomToWKB_buf_r(context, line, &wkb_size);

    // copy WKB into PostgreSQL BYTEA
    bytea *result = (bytea *) palloc(wkb_size + VARHDRSZ);
    SET_VARSIZE(result, wkb_size + VARHDRSZ);
    memcpy(VARDATA(result), wkb, wkb_size);
    values[2] = PointerGetDatum(result);

    GEOSFree_r(context, wkb);
    GEOSGeom_destroy_r(context, line);
    GEOS_finish_r(context);

    HeapTuple tuple = heap_form_tuple(funcctx->tuple_desc, values, nulls);
    call_count++;
    SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(tuple));
}


