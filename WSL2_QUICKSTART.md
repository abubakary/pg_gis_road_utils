# pg_gis_road_utils - Quick Start for WSL2

## One-Command Setup

```bash
./setup_wsl2.sh
```

That's it! The script will:
1. Install PostgreSQL 14 and dependencies
2. Initialize and start PostgreSQL
3. Create test database
4. Build the extension
5. Install the extension
6. Load it in the database
7. Run a test query

## Manual Setup (if you prefer)

### 1. Install Dependencies

```bash
sudo apt update
sudo apt install -y postgresql-14 postgresql-server-dev-14 libgeos-dev build-essential make gcc
```

### 2. Start PostgreSQL

```bash
# Create and start PostgreSQL cluster
sudo -u postgres /usr/lib/postgresql/14/bin/initdb -D /var/lib/postgresql/14/main
sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main -l /tmp/postgres.log start
```

### 3. Create Database

```bash
sudo -u postgres createdb test_db
```

### 4. Build and Install

```bash
make clean
CFLAGS="-g -O0" make
sudo make install
```

### 5. Load Extension

```bash
sudo -u postgres psql -d test_db -c "CREATE EXTENSION pg_gis_road_utils;"
```

### 6. Test

```bash
sudo -u postgres psql -d test_db
```

```sql
-- Extract road segment
SELECT get_section_by_chainage(
    'LINESTRING(0 0, 10 0, 10 10)',
    2.0,
    5.0
);

-- Get point at chainage
SELECT cut_line_at_chainage(
    'LINESTRING(0 0, 10 0)',
    5.0
);

-- Calibrate GPS point on road
SELECT calibrate_point_on_line(
    'LINESTRING(0 0, 10 0, 10 10)',
    'POINT(5 0.1)',
    1.0
);
```

## Available Functions

| Function | Description |
|----------|-------------|
| `get_section_by_chainage(line, start_km, end_km)` | Extract line segment between chainages, returns JSON |
| `cut_line_at_chainage(line, km)` | Get point at specific chainage, returns WKT |
| `calibrate_point_on_line(line, point, radius)` | Find point position on line, returns JSON |

## Auto-Start PostgreSQL

Add to `~/.bashrc`:

```bash
# Auto-start PostgreSQL
if ! sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main status > /dev/null 2>&1; then
    sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main -l /tmp/postgres.log start > /dev/null 2>&1
fi
```

Then:
```bash
source ~/.bashrc
```

## Development Workflow

### Rebuild After Code Changes

```bash
make clean && CFLAGS="-g -O0" make && sudo make install
sudo -u postgres psql -d test_db -c "DROP EXTENSION IF EXISTS pg_gis_road_utils CASCADE; CREATE EXTENSION pg_gis_road_utils;"
```

### Debug with CLion (Windows)

See `DEBUG_WINDOWS_CLION.md` for complete instructions.

Quick version:
1. Run `./start_debug.sh` in WSL2
2. Configure CLion remote GDB to `localhost:1234`
3. Set breakpoints in `pg_gis_road_utils.c`
4. Execute SQL queries to hit breakpoints

## Troubleshooting

### PostgreSQL won't start

```bash
# Check status
pg_lsclusters

# Check logs
sudo tail /tmp/postgres.log

# Restart
sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main restart
```

### Extension won't load

```bash
# Check if installed
ls /usr/lib/postgresql/14/lib/pg_gis_road_utils.so

# Rebuild and reinstall
make clean && CFLAGS="-g -O0" make && sudo make install
```

### Build errors

```bash
# Check dependencies
pg_config --version
geos-config --version

# Reinstall if needed
sudo apt install --reinstall postgresql-server-dev-14 libgeos-dev
```

## Common Issues

**Issue**: `make: pg_config: No such file or directory`  
**Fix**: `sudo apt install postgresql-server-dev-14`

**Issue**: `cannot find -lgeos-3`  
**Fix**: Already fixed in Makefile (uses `-lgeos_c`)

**Issue**: `schema "pg_gis_road_utils" does not exist`  
**Fix**: Already fixed - no schema prefix needed

**Issue**: PostgreSQL service fails  
**Fix**: Use direct `pg_ctl` commands instead of `service` (WSL2 limitation)

## File Locations

- **Extension library**: `/usr/lib/postgresql/14/lib/pg_gis_road_utils.so`
- **SQL file**: `/usr/share/postgresql/14/extension/pg_gis_road_utils--1.0.0.sql`
- **Control file**: `/usr/share/postgresql/14/extension/pg_gis_road_utils.control`
- **PostgreSQL data**: `/var/lib/postgresql/14/main/`
- **PostgreSQL logs**: `/tmp/postgres.log`

## Next Steps

- See `README.md` for complete documentation
- See `MIGRATION.md` for migrating from JNI version
- See `DEBUG_WINDOWS_CLION.md` for debugging setup
- See `CONVERSION_SUMMARY.md` for technical details

## Support

- Email: gis@tehama.go.tz
- GitHub Issues: https://github.com/tehama/pg_gis_road_utils/issues
