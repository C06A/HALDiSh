#!/usr/bin/env bash

VALIDATOR_SCRIPT=validator.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

cd $SCRIPT_DIR
if [ -f http.sh ]; then
  mv http.sh .http.sh
  for cmd in "GET" "POST" "PUT" "PATCH" "DELETE" "OPTIONS"
    do
      [ -f $cmd ] || ln .http.sh $cmd
    done
else
  echo no http.sh file in $(pwd)
fi

CHECKSUMCMD=$(./checksummer.sh $SCRIPT_DIR -e VALIDATOR_SCRIPT)
CHECKSUM=$(eval $CHECKSUMCMD)

cat >$VALIDATOR_SCRIPT <<EOF
#!/usr/bin/env bash

PATH=$SCRIPT_DIR:\$PATH

cd $SCRIPT_DIR
NEW_CHECKSUM=\$(eval $CHECKSUMCMD)
cd -

if [ "\$NEW_CHECKSUM" != "$CHECKSUM" ]
then
  echo "The HALDiSh installation was corrupted after installation" >&2
  exit 255
fi
EOF

cd - >/dev/null
