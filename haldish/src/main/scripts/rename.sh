#!/usr/bin/env bash

# rename.sh: Renames files with a specified base name to a new base name, preserving extensions.
# Usage:
#   - Two args: ./rename.sh new_name old_name
#   - One arg: ./rename.sh old_name (new_name from STDIN)
# Outputs:
#   - Success or error messages to STDERR
#   - new_name to the STDOUT if successful
#

# Read arguments or stdin
if [ $# -eq 2 ]; then
    new_name="$1"
    old_name="$2"
elif [ $# -eq 1 ]; then
    new_name="$1"
    read -r old_name || { echo "Error: No old name provided via stdin." >&2; exit 1; }
else
    echo "Error: Incorrect number of arguments. Usage: $0 new_name old_name or $0 new_name < old_name" >&2
    exit 1
fi

# Check if old_name is provided
if [ -z "$old_name" ]; then
    echo "Error: Old name cannot be empty." >&2
    exit 1
fi

# Check if new_name is provided
if [ -z "$new_name" ]; then
    echo "Error: New name cannot be empty." >&2
    exit 1
fi

# Check if any files were found and renamed
ls "$old_name".* > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: No files found with name '$old_name' and any extension." >&2
    exit 1
fi

# Find files with the old_name and any extension, then rename them
while IFS= read -r -d '' file; do
    # Extract directory and extension
    dir=$(dirname "$file")
    ext="${file##*.}"
    # If no extension, set ext to empty
    if [ "$ext" = "$file" ]; then
        ext=""
    else
        ext=".$ext"
    fi
    # Construct new file path
    new_file="$dir/$new_name$ext"
    # Rename file
    mv -v "$file" "$new_file" >&2 || { echo "Error: Failed to rename '$file' to '$new_file'." >&2; exit 1; }
done < <(find . -type f -name "$old_name.*" -print0)

echo $new_name
