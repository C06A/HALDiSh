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
  [ -e "deployed" ] || mkdir deployed
  [ -e "test/$subf" ] || mkdir -p test/$subf
  [ -e "distributions" ] || { echo "There is no distributions folder"; exit 249; }

  if [ $(ls -1 deployed/*.sh 2>/dev/null | wc -l) -le 1 ]
  then
    cd "deployed"
    [ $(find ../distributions -type f -iname "haldish*.sh" | wc -l) -eq 1 ] || { echo "There is not exactly 1 distribution script"; cd -; exit 250; }
    $(find ../distributions -type f -iname "haldish*.sh")
    cd - >/dev/null
  fi

  . deployed/validator.sh >/dev/null

  cd test/$subf
}
