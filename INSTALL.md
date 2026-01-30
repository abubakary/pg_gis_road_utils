# Installation and Build Guide

## Prerequisites

### System Requirements

- PostgreSQL 12 or higher
- PostGIS 3.0 or higher  
- GEOS 3.8 or higher
- C compiler (gcc or clang)
- make

### Ubuntu/Debian Installation

```bash
# Install PostgreSQL and PostGIS
sudo apt-get update
sudo apt-get install -y postgresql postgresql-contrib postgis

# Install development headers
sudo apt-get install -y \
    postgresql-server-dev-all \
    libgeos-dev \
    libgeos++-dev \
    build-essential

# Verify GEOS installation
geos-config --version
pkg-config --modversion geos
```

### CentOS/RHEL Installation

```bash
# Enable PostgreSQL repository
sudo yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# Install PostgreSQL and PostGIS
sudo yum install -y postgresql15-server postgresql15-contrib postgis33_15

# Install development tools
sudo yum install -y \
    postgresql15-devel \
    geos-devel \
    gcc \
    make
```

### macOS Installation

```bash
# Using Homebrew
brew install postgresql postgis geos

# Install development headers
brew install postgresql@15
```

## Building from Source

### 1. Clone the Repository

```bash
git clone https://github.com/tehama/pg_gis_road_utils.git
cd pg_gis_road_utils
```

### 2. Build the Extension

```bash
# Standard build
make

# Clean previous builds
make clean

# Build with custom PostgreSQL
PG_CONFIG=/usr/pgsql-15/bin/pg_config make
```

### 3. Install the Extension

```bash
# System-wide installation (requires sudo)
sudo make install

# Verify installation
ls $(pg_config --sharedir)/extension/ | grep pg_gis_road_utils
```

Expected output:
```
pg_gis_road_utils--1.0.0.sql
pg_gis_road_utils.control
```

### 4. Enable in Database

```sql
-- Connect to your database
psql -U postgres -d your_database

-- Create extension
CREATE EXTENSION postgis;  -- If not already installed
CREATE EXTENSION pg_gis_road_utils;

-- Verify
\dx pg_gis_road_utils
```

## Testing

### Run Test Suite

```bash
# Create test database
createdb -U postgres test_db

# Run tests
make test

# Or manually
psql -U postgres -d test_db -f test/test_pg_gis_road_utils.sql
```

## Troubleshooting

### Error: "pg_config not found"

```bash
# Find pg_config location
sudo find / -name pg_config 2>/dev/null

# Add to PATH or specify explicitly
export PATH=/usr/pgsql-15/bin:$PATH
# OR
make PG_CONFIG=/usr/pgsql-15/bin/pg_config
```

### Error: "geos_c.h not found"

```bash
# Find GEOS headers
dpkg -L libgeos-dev | grep geos_c.h

# Install if missing
sudo apt-get install libgeos-dev

# Verify
geos-config --includes
```

### Error: "undefined reference to GEOS functions"

```bash
# Check GEOS library
geos-config --libs

# Rebuild with verbose output
make clean
make V=1
```

### Permission Denied During Install

```bash
# Use sudo for system directories
sudo make install

# Or install to custom directory
make install DESTDIR=/custom/path
```

## Uninstallation

### Remove from Database

```sql
DROP EXTENSION pg_gis_road_utils CASCADE;
```

### Remove from System

```bash
sudo make uninstall

# Verify removal
ls $(pg_config --sharedir)/extension/ | grep pg_gis_road_utils
# Should return nothing
```

## Development Build

### Build with Debug Symbols

```bash
# Add debug flags
CFLAGS="-g -O0" make clean all
```

### Check for Memory Leaks

```bash
# Using valgrind
valgrind --leak-check=full \
    psql -U postgres -d test_db \
    -c "SELECT pg_gis_road_utils.get_section_by_chainage('LINESTRING(0 0, 10 0)', 2.0, 5.0);"
```

## Platform-Specific Notes

### Windows (MinGW)

```bash
# Using MSYS2
pacman -S mingw-w64-x86_64-postgresql mingw-w64-x86_64-geos

# Build
make PG_CONFIG=/mingw64/bin/pg_config
```

### Docker Installation

```dockerfile
FROM postgres:15

RUN apt-get update && apt-get install -y \
    postgresql-server-dev-15 \
    libgeos-dev \
    build-essential \
    git

WORKDIR /tmp
RUN git clone https://github.com/tehama/pg_gis_road_utils.git
WORKDIR /tmp/pg_gis_road_utils
RUN make && make install

# Enable extension on startup
RUN echo "CREATE EXTENSION IF NOT EXISTS postgis;" > /docker-entrypoint-initdb.d/10-postgis.sql
RUN echo "CREATE EXTENSION IF NOT EXISTS pg_gis_road_utils;" > /docker-entrypoint-initdb.d/20-pg_gis_road_utils.sql
```

## Upgrading

### From Version 1.0.0 to Future Versions

```sql
-- Check current version
SELECT * FROM pg_extension WHERE extname = 'pg_gis_road_utils';

-- Upgrade (when available)
ALTER EXTENSION pg_gis_road_utils UPDATE TO '1.1.0';
```

## Distribution Packaging

### Create Debian Package

```bash
# Install packaging tools
sudo apt-get install devscripts debhelper

# Build package
dpkg-buildpackage -us -uc

# Install
sudo dpkg -i ../postgresql-15-pg-gis-road-utils_1.0.0_amd64.deb
```

### Create RPM Package

```bash
# Create SPEC file
rpmbuild -ba pg_gis_road_utils.spec

# Install
sudo rpm -ivh RPMS/x86_64/pg_gis_road_utils-1.0.0-1.el7.x86_64.rpm
```

## Getting Help

- GitHub Issues: https://github.com/tehama/pg_gis_road_utils/issues
- Email: gis@tehama.go.tz
- Documentation: README.md
