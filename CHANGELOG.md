# Changelog

All notable changes to pg_gis_road_utils extension.

## [1.0.1] - 2025-01-29

### Fixed
- **Schema Issue**: Removed `pg_` prefix from schema name (PostgreSQL reserves `pg_` for system schemas)
  - All functions now in public schema (no schema prefix required)
  - Updated all SQL files and examples
  
- **GEOS Linking**: Fixed library linking for Ubuntu 22.04
  - Changed from `-lgeos-3` to `-lgeos_c`
  - Works with standard Ubuntu GEOS packages
  
- **PostgreSQL on WSL2**: Added support for WSL2 environment
  - Direct `pg_ctl` commands instead of systemd service
  - Custom cluster initialization with `initdb`
  - Auto-start scripts for convenience

- **PostGIS Dependency**: Made PostGIS optional
  - Extension works with just GEOS library
  - PostGIS can be added if needed but not required

### Added
- **setup_wsl2.sh**: One-command setup script for WSL2
- **start_debug.sh**: Remote debugging server for CLion
- **WSL2_QUICKSTART.md**: Quick start guide for WSL2 users
- **DEBUG_WINDOWS_CLION.md**: Complete CLion debugging guide for Windows
- **DEBUG_NATIVE_WINDOWS.md**: Native Windows debugging (not recommended)

### Changed
- **Function Names**: Simplified without schema prefix
  - Old: `pg_gis_road_utils.get_section_by_chainage()`
  - New: `get_section_by_chainage()`
  
- **Installation**: Streamlined for WSL2/Ubuntu
  - Single setup script
  - No systemd dependencies
  - Clear error messages

- **Documentation**: Updated all examples and guides
  - WSL2-first approach
  - Windows + CLion debugging workflow
  - Troubleshooting for common issues

### Technical Details

**Before (didn't work on WSL2/Ubuntu 22.04)**:
```makefile
SHLIB_LINK = $(shell geos-config --libs) $(shell pkg-config --libs geos)
# Returns: -lgeos-3 -lgeos_c
# Error: cannot find -lgeos-3
```

```sql
CREATE FUNCTION pg_gis_road_utils.get_section_by_chainage(...)
-- Error: schema "pg_gis_road_utils" does not exist
-- Error: The prefix "pg_" is reserved for system schemas
```

**After (works perfectly)**:
```makefile
SHLIB_LINK = -lgeos_c
# Uses only libgeos_c.so which exists on Ubuntu
```

```sql
CREATE FUNCTION get_section_by_chainage(...)
-- Works in public schema
```

### Migration from 1.0.0

If you have the old version installed:

```sql
-- Drop old extension
DROP EXTENSION IF EXISTS pg_gis_road_utils CASCADE;

-- Update function calls in your code
-- Old: SELECT pg_gis_road_utils.get_section_by_chainage(...)
-- New: SELECT get_section_by_chainage(...)

-- Install new version
CREATE EXTENSION pg_gis_road_utils;
```

### Tested On

- ✅ Ubuntu 22.04 (WSL2)
- ✅ Ubuntu 20.04 (WSL2)
- ✅ PostgreSQL 14
- ✅ GEOS 3.10.2
- ✅ Windows 11 + CLion (remote debugging)

### Known Issues

None currently. All major setup issues have been resolved.

### Performance

No changes - algorithm implementation is identical to 1.0.0.

---

## [1.0.0] - 2025-01-28

### Initial Release

- Converted from JNI/Java implementation to PostgreSQL extension
- Core functions:
  - `get_section_by_chainage`: Extract line segments
  - `cut_line_at_chainage`: Get point at chainage
  - `calibrate_point_on_line`: Find point position on line
- GEOS-based algorithms preserved from original implementation
- JSON output format
- Complete documentation
- Test suite included

### Known Issues (Fixed in 1.0.1)

- ❌ Schema prefix `pg_` not allowed in PostgreSQL
- ❌ GEOS linking fails on Ubuntu 22.04
- ❌ PostgreSQL service won't start on WSL2
- ❌ PostGIS marked as required but not needed
