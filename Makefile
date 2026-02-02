# Makefile for pg_gis_road_utils PostgreSQL extension

EXTENSION = pg_gis_road_utils
DATA = pg_gis_road_utils--1.0.0.sql
MODULE_big = pg_gis_road_utils
OBJS = pg_gis_road_utils.o shapefile_reader.o

# GEOS library configuration
PG_CPPFLAGS = -I$(shell geos-config --includes) -I$(shell pkg-config --cflags geos)
#SHLIB_LINK = $(shell geos-config --libs) $(shell pkg-config --libs geos)
SHLIB_LINK = -lgeos_c
# PostgreSQL build system
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Additional targets
.PHONY: test clean-test

test: install
	@echo "Running tests..."
	psql -U postgres -d test_db -c "DROP EXTENSION IF EXISTS pg_gis_road_utils CASCADE;"
	psql -U postgres -d test_db -c "CREATE EXTENSION pg_gis_road_utils;"
	psql -U postgres -d test_db -f test/test_pg_gis_road_utils.sql

clean-test:
	psql -U postgres -d test_db -c "DROP EXTENSION IF EXISTS pg_gis_road_utils CASCADE;" || true
