#!/usr/bin/env bash

# uritengin.sh — RFC 6570-like URI Template expander (subset)
# Bash 3.x+ compatible (no associative arrays).
#
# Reads template from STDIN; variables -- from the command-line args
# -- Simple value: key=value
# --       Arrays: key=v1|v2|v3
# --        Dicts:  key=k1:v1|k2:v2
#
# Supported operators: {var} {+var} {#var} {.var} {/var} {;var} {?var} {&var}
# Each supports explode modifier * (per var), and multiple vars per expression.
#
# Notes:
# - Save/restore IFS carefully when splitting.
# - Unprovided variables are skipped; expression removed if it yields no output.
# - Encoding preserves unreserved: [A-Za-z0-9.~_-]; everything else -> %XX.
# - Reserved expansion {+...} and fragment {#...} skip encoding (per this script).

set -e

# ---- Read template from STDIN ----
TEMPLATE=""
if [ -t 0 ]; then
  echo "Usage: echo \"TEMPLATE\" | $0 key=value ..." >&2
  exit 1
fi
TEMPLATE="$(cat)"

# ---- Parse command-line key=value into parallel arrays ----
var_keys=()
var_vals=()
var_types=()   # "simple" | "array" | "dict"

_trim_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}";;
    \'*\') s="${s#\'}"; s="${s%\'}";;
  esac
  printf '%s' "$s"
}

for arg in "$@"; do
  case "$arg" in
    *=*)
      k="${arg%%=*}"
      v="${arg#*=}"
      k="$(_trim_quotes "$k")"
      v="$(_trim_quotes "$v")"
      if printf '%s' "$v" | grep -q ':'; then
        var_types[${#var_keys[@]}]="dict"
      elif printf '%s' "$v" | grep -q '|'; then
        var_types[${#var_keys[@]}]="array"
      else
        var_types[${#var_keys[@]}]="simple"
      fi
      var_keys[${#var_keys[@]}]="$k"
      var_vals[${#var_vals[@]}]="$v"
      ;;
    *)
      echo "Ignoring arg without '=': $arg" >&2
      ;;
  esac
done

# ---- Lookup helpers ----
_find_var_index() {
  local name="$1"
  local i
  for ((i=0; i<${#var_keys[@]}; i++)); do
    if [ "${var_keys[$i]}" = "$name" ]; then
      echo "$i"
      return 0
    fi
  done
  echo "-1"
  return 1
}

_split_pipe() {
  local s="$1"
  local oldIFS="$IFS"
  IFS='|'
  for part in $s; do
    printf '%s\n' "$part"
  done
  IFS="$oldIFS"
}

_split_dict_pairs() {
  _split_pipe "$1"
}

# Percent-encode everything except unreserved [A-Za-z0-9.~_-]
# If reserved_mode=1, return input unchanged ({+...} and {#...} here)
_url_encode() {
  local s="$1"
  local reserved_mode="${2:-0}"
  if [ "$reserved_mode" = "1" ]; then
    printf '%s' "$s"
    return 0
  fi
  local out="" c hex
  local oldLC="$LC_CTYPE"
  LC_CTYPE=C
  local i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-])
        out+="$c"
        ;;
      *)
        printf -v hex '%%%02X' "'$c"
        out+="$hex"
        ;;
    esac
  done
  LC_CTYPE="$oldLC"
  printf '%s' "$out"
}

# key=value, with control over encoding the value
# _enc_kv key value reserved preencoded_value
_enc_kv() {
  local k="$1" v="$2" reserved="${3:-0}" preencoded="${4:-0}"
  local kenc venc
  kenc="$(_url_encode "$k" "$reserved")"
  if [ "$preencoded" = "1" ]; then
    venc="$v"
  else
    venc="$(_url_encode "$v" "$reserved")"
  fi
  printf '%s=%s' "$kenc" "$venc"
}

# ---- Expand a single expression content (no braces) ----
_expand_expr() {
  local content="$1"

  # Determine operator
  local op="${content:0:1}"
  local opchars="+#./;?&"
  local operator=""
  local varlist=""

  if [[ "$opchars" == *"$op"* ]]; then
    operator="$op"
    varlist="${content:1}"
  else
    operator=""
    varlist="$content"
  fi

  # Split variable list by ',' into array of specs
  local oldIFS="$IFS"
  IFS=','; set -- $varlist; IFS="$oldIFS"
  local specs=("$@")

  local parts=()
  local query_pairs=()
  local matrix_parts=()

  local reserved_mode=0
  if [ "$operator" = "+" ] || [ "$operator" = "#" ]; then
    reserved_mode=1
  fi

  local spec name explode idx type raw
  local has_any=0

  for spec in "${specs[@]}"; do
    [ -z "$spec" ] && continue
    if [ "${spec: -1}" = "*" ]; then
      explode=1
      name="${spec%\*}"
    else
      explode=0
      name="$spec"
    fi

    idx="$(_find_var_index "$name")"
    if [ "$idx" = "-1" ]; then
      continue
    fi
    type="${var_types[$idx]}"
    raw="${var_vals[$idx]}"

    if [ "$operator" = "?" ] || [ "$operator" = "&" ]; then
      # -------------------- Query expansions --------------------
      if [ "$type" = "simple" ]; then
        query_pairs[${#query_pairs[@]}]="$(_enc_kv "$name" "$raw" 0)"
        has_any=1

      elif [ "$type" = "array" ]; then
        if [ "$explode" = "1" ]; then
          while IFS= read -r item; do
            query_pairs[${#query_pairs[@]}]="$(_enc_kv "$name" "$item" 0)"
            has_any=1
          done <<EOF
$(_split_pipe "$raw")
EOF
        else
          # single parameter with comma-joined (already encoded items)
          local joined="" item
          while IFS= read -r item; do
            [ -n "$joined" ] && joined="$joined,"
            joined="$joined$(_url_encode "$item" 0)"
          done <<EOF
$(_split_pipe "$raw")
EOF
          # key encoded; value is already encoded -> do NOT re-encode
          local key_enc
          key_enc="$(_url_encode "$name" 0)"
          query_pairs[${#query_pairs[@]}]="${key_enc}=${joined}"
          has_any=1
        fi

      elif [ "$type" = "dict" ]; then
        if [ "$explode" = "1" ]; then
          # expand to k=v & k=v
          local pair k v
          while IFS= read -r pair; do
            k="${pair%%:*}"; v="${pair#*:}"
            query_pairs[${#query_pairs[@]}]="$(_enc_kv "$k" "$v" 0)"
            has_any=1
          done <<EOF
$(_split_dict_pairs "$raw")
EOF
        else
          # single parameter name=k,v,k,v (each item encoded, joined by commas; don't re-encode)
          local acc="" pair k v
          while IFS= read -r pair; do
            k="${pair%%:*}"; v="${pair#*:}"
            [ -n "$acc" ] && acc="$acc,"
            acc="$acc$(_url_encode "$k" 0),$(_url_encode "$v" 0)"
          done <<EOF
$(_split_dict_pairs "$raw")
EOF
          local key_enc
          key_enc="$(_url_encode "$name" 0)"
          query_pairs[${#query_pairs[@]}]="${key_enc}=${acc}"
          has_any=1
        fi
      fi

    elif [ "$operator" = ";" ]; then
      # -------------------- Path-style (matrix) parameters --------------------
      if [ "$type" = "simple" ]; then
        if [ -n "$raw" ]; then
          matrix_parts[${#matrix_parts[@]}]=";$(_url_encode "$name" 0)=$(_url_encode "$raw" 0)"
        else
          matrix_parts[${#matrix_parts[@]}]=";$(_url_encode "$name" 0)"
        fi
        has_any=1

      elif [ "$type" = "array" ]; then
        if [ "$explode" = "1" ]; then
          local item
          while IFS= read -r item; do
            if [ -n "$item" ]; then
              matrix_parts[${#matrix_parts[@]}]=";$(_url_encode "$name" 0)=$(_url_encode "$item" 0)"
            else
              matrix_parts[${#matrix_parts[@]}]=";$(_url_encode "$name" 0)"
            fi
            has_any=1
          done <<EOF
$(_split_pipe "$raw")
EOF
        else
          local joined="" item
          while IFS= read -r item; do
            [ -n "$joined" ] && joined="$joined,"
            joined="$joined$(_url_encode "$item" 0)"
          done <<EOF
$(_split_pipe "$raw")
EOF
          if [ -n "$joined" ]; then
            matrix_parts[${#matrix_parts[@]}]=";$(_url_encode "$name" 0)=$joined"
          else
            matrix_parts[${#matrix_parts[@]}]=";$(_url_encode "$name" 0)"
          fi
          has_any=1
        fi

      elif [ "$type" = "dict" ]; then
        if [ "$explode" = "1" ]; then
          local pair k v
          while IFS= read -r pair; do
            k="${pair%%:*}"; v="${pair#*:}"
            if [ -n "$v" ]; then
              matrix_parts[${#matrix_parts[@]}]=";$(_url_encode "$k" 0)=$(_url_encode "$v" 0)"
            else
              matrix_parts[${#matrix_parts[@]}]=";$(_url_encode "$k" 0)"
            fi
            has_any=1
          done <<EOF
$(_split_dict_pairs "$raw")
EOF
        else
          local acc="" pair k v
          while IFS= read -r pair; do
            k="${pair%%:*}"; v="${pair#*:}"
            [ -n "$acc" ] && acc="$acc,"
            acc="$acc$(_url_encode "$k" 0),$(_url_encode "$v" 0)"
          done <<EOF
$(_split_dict_pairs "$raw")
EOF
          matrix_parts[${#matrix_parts[@]}]=";$(_url_encode "$name" 0)=$acc"
          has_any=1
        fi
      fi

    elif [ "$operator" = "/" ]; then
      # -------------------- Path segments --------------------
      if [ "$type" = "simple" ]; then
        parts[${#parts[@]}]="/$(_url_encode "$raw" 0)"; has_any=1
      elif [ "$type" = "array" ]; then
        if [ "$explode" = "1" ]; then
          local item
          while IFS= read -r item; do
            parts[${#parts[@]}]="/$(_url_encode "$item" 0)"; has_any=1
          done <<EOF
$(_split_pipe "$raw")
EOF
        else
          local joined="" item
          while IFS= read -r item; do
            [ -n "$joined" ] && joined="$joined,"
            joined="$joined$(_url_encode "$item" 0)"
          done <<EOF
$(_split_pipe "$raw")
EOF
          parts[${#parts[@]}]="/$joined"; has_any=1
        fi
      elif [ "$type" = "dict" ]; then
        if [ "$explode" = "1" ]; then
          local pair k v
          while IFS= read -r pair; do
            k="${pair%%:*}"; v="${pair#*:}"
            parts[${#parts[@]}]="/$(_enc_kv "$k" "$v" 0)"; has_any=1
          done <<EOF
$(_split_dict_pairs "$raw")
EOF
        else
          local acc="" pair k v
          while IFS= read -r pair; do
            k="${pair%%:*}"; v="${pair#*:}"
            [ -n "$acc" ] && acc="$acc,"
            acc="$acc$(_url_encode "$k" 0),$(_url_encode "$v" 0)"
          done <<EOF
$(_split_dict_pairs "$raw")
EOF
          parts[${#parts[@]}]="/$acc"; has_any=1
        fi
      fi

    elif [ "$operator" = "." ]; then
      # -------------------- Label expansion --------------------
      if [ "$type" = "simple" ]; then
        parts[${#parts[@]}]=".$(_url_encode "$raw" 0)"; has_any=1
      elif [ "$type" = "array" ]; then
        if [ "$explode" = "1" ]; then
          local item
          while IFS= read -r item; do
            parts[${#parts[@]}]=".$(_url_encode "$item" 0)"; has_any=1
          done <<EOF
$(_split_pipe "$raw")
EOF
        else
          local joined="" item
          while IFS= read -r item; do
            [ -n "$joined" ] && joined="$joined."
            joined="$joined$(_url_encode "$item" 0)"
          done <<EOF
$(_split_pipe "$raw")
EOF
          parts[${#parts[@]}]=".$joined"; has_any=1
        fi
      elif [ "$type" = "dict" ]; then
        if [ "$explode" = "1" ]; then
          local pair k v
          while IFS= read -r pair; do
            k="${pair%%:*}"; v="${pair#*:}"
            parts[${#parts[@]}]=".$(_enc_kv "$k" "$v" 0)"; has_any=1
          done <<EOF
$(_split_dict_pairs "$raw")
EOF
        else
          local acc="" pair k v
          while IFS= read -r pair; do
            k="${pair%%:*}"; v="${pair#*:}"
            [ -n "$acc" ] && acc="$acc,"
            acc="$acc$(_url_encode "$k" 0),$(_url_encode "$v" 0)"
          done <<EOF
$(_split_dict_pairs "$raw")
EOF
          parts[${#parts[@]}]=".$acc"; has_any=1
        fi
      fi

    else
      # -------------------- Simple / Reserved / Fragment --------------------
      if [ "$type" = "simple" ]; then
        parts[${#parts[@]}]="$(_url_encode "$raw" "$reserved_mode")"; has_any=1
      elif [ "$type" = "array" ]; then
        if [ "$explode" = "1" ]; then
          local item
          while IFS= read -r item; do
            parts[${#parts[@]}]="$(_url_encode "$item" "$reserved_mode")"; has_any=1
          done <<EOF
$(_split_pipe "$raw")
EOF
        else
          local joined="" item
          while IFS= read -r item; do
            [ -n "$joined" ] && joined="$joined,"
            joined="$joined$(_url_encode "$item" "$reserved_mode")"
          done <<EOF
$(_split_pipe "$raw")
EOF
          parts[${#parts[@]}]="$joined"; has_any=1
        fi
      elif [ "$type" = "dict" ]; then
        if [ "$explode" = "1" ]; then
          local pair k v
          while IFS= read -r pair; do
            k="${pair%%:*}"; v="${pair#*:}"
            if [ "$operator" = "+" ]; then
              # For reserved (+) with dict explode, use "k:v" pairs (no encoding in this script)
              parts[${#parts[@]}]="$(_url_encode "$k" "$reserved_mode"):$(_url_encode "$v" "$reserved_mode")"; has_any=1
            else
              parts[${#parts[@]}]="$(_enc_kv "$k" "$v" "$reserved_mode")"; has_any=1
            fi
          done <<EOF
$(_split_dict_pairs "$raw")
EOF
        else
          local acc="" pair k v
          while IFS= read -r pair; do
            k="${pair%%:*}"; v="${pair#*:}"
            [ -n "$acc" ] && acc="$acc,"
            acc="$acc$(_url_encode "$k" "$reserved_mode"),$(_url_encode "$v" "$reserved_mode")"
          done <<EOF
$(_split_dict_pairs "$raw")
EOF
          parts[${#parts[@]}]="$acc"; has_any=1
        fi
      fi
    fi
  done

  # Build final for this expression
  if [ "$has_any" != "1" ]; then
    printf ''
    return 0
  fi

  case "$operator" in
    "?")
      local q="" i
      for ((i=0; i<${#query_pairs[@]}; i++)); do
        [ -n "$q" ] && q="$q&"
        q="$q${query_pairs[$i]}"
      done
      printf '?%s' "$q"
      ;;
    "&")
      local q="" i
      for ((i=0; i<${#query_pairs[@]}; i++)); do
        [ -n "$q" ] && q="$q&"
        q="$q${query_pairs[$i]}"
      done
      printf '&%s' "$q"
      ;;
    ";")
      local m="" i
      for ((i=0; i<${#matrix_parts[@]}; i++)); do
        m="$m${matrix_parts[$i]}"
      done
      printf '%s' "$m"
      ;;
    "/")
      local p="" i
      for ((i=0; i<${#parts[@]}; i++)); do
        p="$p${parts[$i]}"
      done
      printf '%s' "$p"
      ;;
    ".")
      local d="" i
      for ((i=0; i<${#parts[@]}; i++)); do
        d="$d${parts[$i]}"
      done
      printf '%s' "$d"
      ;;
    "#")
      local s="" i
      for ((i=0; i<${#parts[@]}; i++)); do
        [ -n "$s" ] && s="$s,"
        s="$s${parts[$i]}"
      done
      printf '#%s' "$s"
      ;;
    "+")
      local s="" i
      for ((i=0; i<${#parts[@]}; i++)); do
        [ -n "$s" ] && s="$s,"
        s="$s${parts[$i]}"
      done
      printf '%s' "$s"
      ;;
    "")
      local s="" i
      for ((i=0; i<${#parts[@]}; i++)); do
        [ -n "$s" ] && s="$s,"
        s="$s${parts[$i]}"
      done
      printf '%s' "$s"
      ;;
  esac
}

# ---- Expand all {...} in the template ----
expand_all() {
  local t="$1"
  local re='\{[^}]*\}'
  while [[ "$t" =~ $re ]]; do
    local expr="${BASH_REMATCH[0]}"
    local content
    content="${expr#\{}"
    content="${content%\}}"
    local replacement
    replacement="$(_expand_expr "$content")"
    t="${t/$expr/$replacement}"
  done
  printf '%s' "$t"
}

final="$(expand_all "$TEMPLATE")"
printf '%s\n' "$final"
