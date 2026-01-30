#!/bin/bash
# Complete setup script for pg_gis_road_utils on WSL2
# Run this script after extracting the package

set -e

echo "=========================================="
echo "  pg_gis_road_utils Setup for WSL2"
echo "=========================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running on WSL
if ! grep -qi microsoft /proc/version; then
    echo -e "${YELLOW}Warning: This script is designed for WSL2${NC}"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Step 1: Install Dependencies
echo -e "${YELLOW}Step 1: Installing dependencies...${NC}"
sudo apt update
sudo apt install -y \
    postgresql-14 \
    postgresql-server-dev-14 \
    libgeos-dev \
    build-essential \
    make \
    gcc

echo -e "${GREEN}✓ Dependencies installed${NC}"
echo ""

# Step 2: Initialize PostgreSQL
echo -e "${YELLOW}Step 2: Initializing PostgreSQL...${NC}"

# Check if cluster exists
if pg_lsclusters | grep -q "14.*main"; then
    echo "PostgreSQL cluster already exists"
    # Check if it's running
    if ! pg_lsclusters | grep "14.*main" | grep -q "online"; then
        echo "Starting existing cluster..."
        sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main -l /tmp/postgres.log start || true
    fi
else
    echo "Creating PostgreSQL cluster..."
    # Remove any partial installation
    sudo rm -rf /var/lib/postgresql/14/main 2>/dev/null || true
    
    # Create fresh cluster with initdb
    sudo -u postgres /usr/lib/postgresql/14/bin/initdb -D /var/lib/postgresql/14/main
    
    # Start PostgreSQL
    sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main -l /tmp/postgres.log start
fi

# Wait for PostgreSQL to be ready
sleep 2

# Verify PostgreSQL is running
if sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /var/lib/postgresql/14/main status > /dev/null 2>&1; then
    echo -e "${GREEN}✓ PostgreSQL is running${NC}"
else
    echo -e "${RED}✗ Failed to start PostgreSQL${NC}"
    echo "Check logs: sudo tail /tmp/postgres.log"
    exit 1
fi
echo ""

# Step 3: Create Test Database
echo -e "${YELLOW}Step 3: Creating test database...${NC}"
sudo -u postgres createdb test_db 2>/dev/null || echo "Database already exists"
echo -e "${GREEN}✓ Test database ready${NC}"
echo ""

# Step 4: Build Extension
echo -e "${YELLOW}Step 4: Building extension...${NC}"
make clean 2>/dev/null || true
CFLAGS="-g -O0" make

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Build successful${NC}"
else
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi
echo ""

# Step 5: Install Extension
echo -e "${YELLOW}Step 5: Installing extension...${NC}"
sudo make install

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Installation successful${NC}"
else
    echo -e "${RED}✗ Installation failed${NC}"
    exit 1
fi
echo ""

# Step 6: Load Extension in Database
echo -e "${YELLOW}Step 6: Loading extension in database...${NC}"
sudo -u postgres psql -d test_db << 'EOF'
DROP EXTENSION IF EXISTS pg_gis_road_utils CASCADE;
CREATE EXTENSION pg_gis_road_utils;
\dx pg_gis_road_utils
EOF

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Extension loaded successfully${NC}"
else
    echo -e "${RED}✗ Failed to load extension${NC}"
    exit 1
fi
echo ""

# Step 7: Run Test
echo -e "${YELLOW}Step 7: Running test query...${NC}"
sudo -u postgres psql -d test_db << 'EOF'
SELECT get_section_by_chainage(
    'LINESTRING(0 0, 10 0, 10 10)',
    2.0,
    5.0
);
EOF

echo ""
echo -e "${GREEN}=========================================="
echo "  Setup Complete! ✓"
echo "==========================================${NC}"
echo ""
echo "Extension is ready to use!"
echo ""
echo "Quick commands:"
echo "  • Rebuild:    make clean && CFLAGS='-g -O0' make && sudo make install"
echo "  • Reload:     sudo -u postgres psql -d test_db -c 'DROP EXTENSION IF EXISTS pg_gis_road_utils CASCADE; CREATE EXTENSION pg_gis_road_utils;'"
echo "  • Test:       sudo -u postgres psql -d test_db"
echo "  • Functions:  get_section_by_chainage, cut_line_at_chainage, calibrate_point_on_line"
echo ""
echo "For debugging in CLion, see DEBUG_WINDOWS_CLION.md"
echo ""
