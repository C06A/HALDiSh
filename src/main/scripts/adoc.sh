#!/bin/bash

# adoc.sh: Appends file contents to STDOUT as ASCIIdoc tagged regions.
# Usage:
#   - With args: adoc.sh name1 name2 ...
#   - No args: adoc.sh reads the names (without extensions) from STDIN
# For each name, collects all files with that name and any extension,
# and outputs their contents as ASCIIdoc tagged regions.
# The files' names become the corresponding tags.
#
# Outputs:
#   - ASCIIdoc tagged content to STDOUT
#   - Errors to STDERR

# Function to process a single file name
process_name() {
    local name="$1"
    # Find all files matching the name with any extension
    local files
    files=$(find . -maxdepth 1 -type f -name "${name}.*" 2>/dev/null | sort )
    
    if [ -z "$files" ]; then
        echo "Error: No files found for the name '$name'" >&2
        return 255
    fi

    # Process each matching file
    for file in $files; do
        # Extract filename with extension for the tag
        local tagname
        tagname=$(basename "$file")
        
        # Output ASCIIdoc tagged region
        echo "// tag::${tagname}[]"
        cat "$file"
        local CHAR=$(tail -c 1 $file)
        [ -z "$CHAR" ] || echo ""
        echo "// end::${tagname}[]"
        echo
    done
}

# Read names from arguments or stdin
if [ $# -gt 0 ]; then
    # Process command-line arguments
    for name in "$@"; do
        process_name "$name"
    done
else
    # Process names from stdin
    while IFS= read -r name; do
        [ -z "$name" ] && continue  # Skip empty lines
        process_name "$name"
    done
fi
