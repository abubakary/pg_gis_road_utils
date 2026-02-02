#!/usr/bin/env python3
"""
Generate sample shapefile for testing pg_gis_road_utils shapefile reader

This script creates a simple test shapefile with roads data that can be used
to test the shapefile reader functions without needing real data.

Requirements:
    pip install pyshp

Usage:
    python3 generate_sample_shapefile.py
    
Output:
    Creates sample_roads.shp, sample_roads.dbf, sample_roads.shx
    in /tmp/test_data/ directory
"""

import shapefile
import os

def create_sample_roads():
    """Create a sample roads shapefile for testing"""
    
    # Create output directory
    output_dir = "/tmp/test_data"
    os.makedirs(output_dir, exist_ok=True)
    
    output_file = os.path.join(output_dir, "sample_roads")
    
    # Create shapefile writer
    w = shapefile.Writer(output_file, shapeType=shapefile.POLYLINE)
    
    # Define fields (DBF columns)
    w.field('ROAD_CODE', 'C', 10)   # Character field, width 10
    w.field('ROAD_CLASS', 'C', 20)   # Road classification
    w.field('SURFACE', 'C', 15)      # Surface type
    w.field('LENGTH_KM', 'N', 10, 2) # Numeric field, 10 digits, 2 decimals
    
    # Add sample roads
    roads_data = [
        {
            'code': 'T1',
            'class': 'Trunk Road',
            'surface': 'Paved',
            'coords': [
                [39.2083, -6.7924],  # Dar es Salaam
                [39.2500, -6.8000],
                [39.3000, -6.8500]
            ]
        },
        {
            'code': 'T7',
            'class': 'Trunk Road',
            'surface': 'Paved',
            'coords': [
                [34.8833, -6.1667],  # Dodoma area
                [34.9000, -6.2000],
                [34.9500, -6.2500]
            ]
        },
        {
            'code': 'R127',
            'class': 'Regional Road',
            'surface': 'Gravel',
            'coords': [
                [33.4167, -7.2500],
                [33.5000, -7.3000],
                [33.6000, -7.3500]
            ]
        },
        {
            'code': 'R301',
            'class': 'Regional Road',
            'surface': 'Paved',
            'coords': [
                [35.7500, -5.0833],  # Arusha area
                [35.8000, -5.1000],
                [35.8500, -5.1500]
            ]
        },
        {
            'code': 'D450',
            'class': 'District Road',
            'surface': 'Gravel',
            'coords': [
                [36.8167, -3.3833],  # Moshi area
                [36.8500, -3.4000],
                [36.9000, -3.4500]
            ]
        }
    ]
    
    # Write records
    for i, road in enumerate(roads_data, 1):
        # Add geometry (polyline)
        w.line([road['coords']])
        
        # Calculate approximate length
        length = len(road['coords']) * 5.0  # Rough estimate in km
        
        # Add attributes
        w.record(
            road['code'],
            road['class'],
            road['surface'],
            length
        )
    
    # Close the writer
    w.close()
    
    print(f"✓ Sample shapefile created: {output_file}.shp")
    print(f"✓ Created {len(roads_data)} road features")
    print(f"\nFiles created:")
    print(f"  - {output_file}.shp (geometry)")
    print(f"  - {output_file}.dbf (attributes)")
    print(f"  - {output_file}.shx (index)")
    print(f"\nTest the data:")
    print(f"  SELECT * FROM read_shapefile_wkt('{output_file}');")


def create_sample_districts():
    """Create a sample districts shapefile for testing"""
    
    output_dir = "/tmp/test_data"
    os.makedirs(output_dir, exist_ok=True)
    
    output_file = os.path.join(output_dir, "sample_districts")
    
    # Create shapefile writer for polygons
    w = shapefile.Writer(output_file, shapeType=shapefile.POLYGON)
    
    # Define fields
    w.field('DISTRICT', 'C', 20)
    w.field('REGION', 'C', 20)
    w.field('POPULATION', 'N', 10)
    
    # Sample districts (simplified polygons)
    districts_data = [
        {
            'name': 'Ilala',
            'region': 'Dar es Salaam',
            'population': 634924,
            'coords': [
                [39.20, -6.80],
                [39.25, -6.80],
                [39.25, -6.85],
                [39.20, -6.85],
                [39.20, -6.80]  # Close polygon
            ]
        },
        {
            'name': 'Kinondoni',
            'region': 'Dar es Salaam',
            'population': 1775049,
            'coords': [
                [39.20, -6.75],
                [39.25, -6.75],
                [39.25, -6.80],
                [39.20, -6.80],
                [39.20, -6.75]
            ]
        },
        {
            'name': 'Temeke',
            'region': 'Dar es Salaam',
            'population': 1368881,
            'coords': [
                [39.20, -6.85],
                [39.25, -6.85],
                [39.25, -6.90],
                [39.20, -6.90],
                [39.20, -6.85]
            ]
        }
    ]
    
    # Write records
    for district in districts_data:
        w.poly([district['coords']])
        w.record(
            district['name'],
            district['region'],
            district['population']
        )
    
    w.close()
    
    print(f"\n✓ Sample districts shapefile created: {output_file}.shp")
    print(f"✓ Created {len(districts_data)} district features")


if __name__ == '__main__':
    print("=" * 60)
    print("Sample Shapefile Generator for pg_gis_road_utils Testing")
    print("=" * 60)
    print()
    
    try:
        import shapefile
        print("✓ pyshp library found")
    except ImportError:
        print("✗ pyshp library not found")
        print("\nPlease install it:")
        print("  pip install pyshp")
        print("\nOr:")
        print("  sudo apt install python3-pip")
        print("  pip3 install pyshp")
        exit(1)
    
    print()
    print("Creating sample data...")
    print()
    
    create_sample_roads()
    create_sample_districts()
    
    print()
    print("=" * 60)
    print("Done! Sample shapefiles created in /tmp/test_data/")
    print("=" * 60)
    print()
    print("Quick test in PostgreSQL:")
    print()
    print("  -- Test WKT format")
    print("  SELECT * FROM read_shapefile_wkt('/tmp/test_data/sample_roads');")
    print()
    print("  -- Test WKB format")
    print("  SELECT * FROM read_shapefile_wkb('/tmp/test_data/sample_roads');")
    print()
    print("  -- Load into table")
    print("  CREATE TABLE roads AS")
    print("  SELECT")
    print("    attributes[1] AS road_code,")
    print("    attributes[2] AS road_class,")
    print("    ST_GeomFromText(geom_wkt, 4326) AS geom")
    print("  FROM read_shapefile_wkt('/tmp/test_data/sample_roads');")
    print()
