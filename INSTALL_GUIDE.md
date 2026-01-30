# Installation Instructions - pg_gis_road_utils v1.0.1

## What's New in v1.0.1

✅ **Fixed all WSL2/Ubuntu 22.04 issues**  
✅ **Removed schema prefix requirement**  
✅ **Fixed GEOS library linking**  
✅ **Added one-command setup script**  
✅ **Comprehensive debugging guide for CLion on Windows**

---

## Quick Install (Recommended)

### For WSL2 on Windows (Ubuntu 22.04)

```bash
# 1. Extract the package
cd ~
tar -xzf pg_gis_road_utils-ready-to-use.tar.gz
cd pg_gis_road_utils

# 2. Run setup script
./setup_wsl2.sh
```

**That's it!** The script does everything automatically.

---

## What the Setup Script Does

1. ✅ Installs PostgreSQL 14 and dependencies
2. ✅ Initializes PostgreSQL cluster (works on WSL2)
3. ✅ Starts PostgreSQL using direct `pg_ctl` commands
4. ✅ Creates test database
5. ✅ Builds extension with debug symbols
6. ✅ Installs extension
7. ✅ Loads extension in database
8. ✅ Runs test query to verify everything works

---

## Manual Installation

If you prefer to install manually:

### Step 1: Install Dependencies

```bash
sudo apt update
sudo apt install -y \
    postgresql-14 \
    postgresql-server-dev-14 \
    libgeos-dev \
    build-essential \
    make \
    gcc
```

### Step 2: Initialize PostgreSQL

```bash
# Create PostgreSQL cluster
sudo -u postgres /usr/lib/postgresql/14/bin/initdb -D /var/lib/postgresql/14/main

# Start PostgreSQL
sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main -l /tmp/postgres.log start
```

### Step 3: Create Database

```bash
sudo -u postgres createdb test_db
```

### Step 4: Build Extension

```bash
cd ~/pg_gis_road_utils
make clean
CFLAGS="-g -O0" make
```

### Step 5: Install Extension

```bash
sudo make install
```

### Step 6: Load Extension

```bash
sudo -u postgres psql -d test_db -c "CREATE EXTENSION pg_gis_road_utils;"
```

### Step 7: Test

```bash
sudo -u postgres psql -d test_db
```

```sql
SELECT get_section_by_chainage(
    'LINESTRING(0 0, 10 0, 10 10)',
    2.0,
    5.0
);
```

---

## Available Functions

All functions are in the **public schema** (no prefix needed):

| Function | Description | Returns |
|----------|-------------|---------|
| `get_section_by_chainage(line, start_km, end_km)` | Extract line segment | JSON |
| `cut_line_at_chainage(line, km)` | Point at chainage | TEXT (WKT) |
| `calibrate_point_on_line(line, point, radius)` | Find point on line | JSON |

---

## Debugging with CLion on Windows

### Quick Setup

```bash
# In WSL2
cd ~/pg_gis_road_utils
./start_debug.sh
```

This starts GDB server on port 1234.

### CLion Configuration

1. **CLion** → Run → Edit Configurations → + → GDB Remote Debug
2. **'target remote' args**: `localhost:1234`
3. **Symbol file**: `\\wsl$\Ubuntu-22.04\usr\lib\postgresql\14\lib\pg_gis_road_utils.so`
4. Set breakpoints in `pg_gis_road_utils.c`
5. Click Debug

See `DEBUG_WINDOWS_CLION.md` for complete guide.

---

## Auto-Start PostgreSQL

Add to `~/.bashrc`:

```bash
# Auto-start PostgreSQL
if ! sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main status > /dev/null 2>&1; then
    sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main -l /tmp/postgres.log start > /dev/null 2>&1
fi
```

Apply:
```bash
source ~/.bashrc
```

---

## Development Workflow

### Rebuild After Changes

```bash
make clean && CFLAGS="-g -O0" make && sudo make install
sudo -u postgres psql -d test_db -c "DROP EXTENSION IF EXISTS pg_gis_road_utils CASCADE; CREATE EXTENSION pg_gis_road_utils;"
```

---

## File Structure

```
pg_gis_road_utils/
├── setup_wsl2.sh              # One-command setup
├── start_debug.sh             # Start debug server
├── pg_gis_road_utils.c        # C implementation
├── pg_gis_road_utils--1.0.0.sql  # SQL definitions
├── pg_gis_road_utils.control  # Extension metadata
├── Makefile                   # Build system
├── WSL2_QUICKSTART.md         # Quick start guide
├── DEBUG_WINDOWS_CLION.md     # Debugging guide
├── CHANGELOG.md               # Version history
├── README.md                  # Full documentation
└── test/
    └── test_pg_gis_road_utils.sql  # Test suite
```

---

## Troubleshooting

### PostgreSQL won't start

```bash
# Check cluster
pg_lsclusters

# Check logs
sudo tail /tmp/postgres.log

# Recreate cluster
sudo rm -rf /var/lib/postgresql/14/main
sudo -u postgres /usr/lib/postgresql/14/bin/initdb -D /var/lib/postgresql/14/main
sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main -l /tmp/postgres.log start
```

### Build fails with "cannot find -lgeos-3"

Already fixed in this version! The Makefile now uses `-lgeos_c`.

### Extension won't load - schema error

Already fixed! Functions are now in public schema (no `pg_gis_road_utils.` prefix).

### "make: pg_config: No such file or directory"

```bash
sudo apt install postgresql-server-dev-14
```

---

## System Requirements

- Ubuntu 22.04 or 20.04 (WSL2 or native)
- PostgreSQL 14
- GEOS 3.8+
- GCC compiler
- 100MB disk space

---

## What Changed from v1.0.0

### Fixed Issues

1. ❌ **Schema Error** → ✅ Functions in public schema
2. ❌ **GEOS Linking** → ✅ Uses `-lgeos_c`
3. ❌ **WSL2 PostgreSQL** → ✅ Direct `pg_ctl` commands
4. ❌ **PostGIS Required** → ✅ Now optional

### Function Names Changed

| Old (v1.0.0) | New (v1.0.1) |
|--------------|--------------|
| `pg_gis_road_utils.get_section_by_chainage()` | `get_section_by_chainage()` |
| `pg_gis_road_utils.cut_line_at_chainage()` | `cut_line_at_chainage()` |
| `pg_gis_road_utils.calibrate_point_on_line()` | `calibrate_point_on_line()` |

---

## Success Indicators

After running `./setup_wsl2.sh`, you should see:

```
✓ Dependencies installed
✓ PostgreSQL is running
✓ Test database ready
✓ Build successful
✓ Installation successful
✓ Extension loaded successfully

Setup Complete! ✓
```

And a test query result showing JSON output.

---

## Next Steps

- See `WSL2_QUICKSTART.md` for usage examples
- See `DEBUG_WINDOWS_CLION.md` for debugging
- See `README.md` for complete API documentation
- See `MIGRATION.md` for migrating from JNI version

---

## Support

- Email: gis@tehama.go.tz
- GitHub: https://github.com/tehama/pg_gis_road_utils

**Enjoy building with pg_gis_road_utils!** 🚀
