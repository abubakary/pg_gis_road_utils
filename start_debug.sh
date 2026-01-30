#!/bin/bash
# Start debug server for CLion remote debugging
# Run this in WSL2, then connect from CLion on Windows

set -e

echo "=========================================="
echo "  PostgreSQL Extension Remote Debugger"
echo "=========================================="
echo ""

# Check if PostgreSQL is running
if ! sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main status > /dev/null 2>&1; then
    echo "Starting PostgreSQL..."
    sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main -l /tmp/postgres.log start
    sleep 2
fi

# Rebuild extension
echo "Rebuilding extension with debug symbols..."
make clean
CFLAGS="-g -O0 -fno-omit-frame-pointer" make
sudo make install

# Reload extension in database
echo "Reloading extension..."
sudo -u postgres psql -d test_db << 'EOF' > /dev/null 2>&1
DROP EXTENSION IF EXISTS pg_gis_road_utils CASCADE;
CREATE EXTENSION pg_gis_road_utils;
EOF

# Start a persistent PostgreSQL session
echo "Starting PostgreSQL session..."
sudo -u postgres psql -d test_db -c "SELECT pg_backend_pid() AS backend_pid;" &
PSQL_PID=$!

sleep 2

# Find the backend PID
BACKEND_PID=$(pgrep -f "postgres.*test_db" | grep -v "postgres: postgres test_db" | head -1)

if [ -z "$BACKEND_PID" ]; then
    echo "ERROR: Could not find PostgreSQL backend process"
    kill $PSQL_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo "✓ Extension loaded"
echo "✓ PostgreSQL backend PID: $BACKEND_PID"
echo ""
echo "Starting GDB server on port 1234..."
echo ""
echo "═══════════════════════════════════════════"
echo "  CLion Remote Debug Setup"
echo "═══════════════════════════════════════════"
echo ""
echo "In CLion (Windows):"
echo "  1. Run → Edit Configurations"
echo "  2. + → GDB Remote Debug"
echo "  3. 'target remote' args: localhost:1234"
echo "  4. Symbol file: \\\\wsl\$\\Ubuntu-22.04\\usr\\lib\\postgresql\\14\\lib\\pg_gis_road_utils.so"
echo "  5. Set breakpoints in pg_gis_road_utils.c"
echo "  6. Click Debug"
echo ""
echo "In another WSL2 terminal:"
echo "  sudo -u postgres psql -d test_db"
echo "  Then run: SELECT get_section_by_chainage('LINESTRING(0 0, 10 0)', 2.0, 5.0);"
echo ""
echo "Press Ctrl+C to stop the debug server"
echo "═══════════════════════════════════════════"
echo ""

# Start gdbserver
sudo gdbserver :1234 --attach $BACKEND_PID

# Cleanup
kill $PSQL_PID 2>/dev/null || true
