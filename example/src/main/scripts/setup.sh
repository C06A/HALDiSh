#!/bin/bash

# Source at the beginning of each *Spec.sh script and execute `setup <folderName>`
# to install HALDiSh if needed and set environment variables.
#
# The single argument for 'setup' function is the name of the folder in the `build/test'
# folder, to execute the spec in and collect resulting files.
#

set -eu -o pipefail

setup() {
  subf=$1

  SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)"
  RESOURCES_DIR="file://$(cd -- $SCRIPT_DIR/../resources >/dev/null 2>&1 && pwd)"

  cd $SCRIPT_DIR/../../../build
  [ -e "$subf" ] || mkdir -p $subf

  . haldish/validator.sh >/dev/null

  cd $subf
}
