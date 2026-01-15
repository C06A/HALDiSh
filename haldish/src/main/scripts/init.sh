#!/usr/bin/env bash

# init.sh - Initialization script that runs automatically after extraction
#
# This script takes no parameters, makes all shell script exectutable,
# and if presented, runs setup.sh script from the same folder
#

set -e

echo "==================================="
echo "Self-Extracting Archive Initialized"
echo "==================================="
echo ""

# Display current directory
echo "Current directory: $(pwd)"
echo ""

# Execute additional setup scripts if they exist
if [ -f setup.sh ]; then
    echo "Running setup.sh..."
    chmod +x *.sh
    ./setup.sh "$@"
fi

echo ""
echo "==================================="
echo "Initialization Complete!"
echo "==================================="

exit 0
