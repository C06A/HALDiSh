#!/usr/bin/env bash

# nahal.sh — interactive navigator for HAL-based APIs
#
# This script accepts a single command line argument as an entry URL
# and one option "-p" with path to the plugin script (see sample-plugin.sh for contract and example)
#
# When running, this script sent GET request to provided URL and start navigation with returned HAL resource.
# For each HAL resource, this script prompt user to navigate the resource or send request to one of its links.
#

set -euo pipefail

# ----------------------------- config ----------------------------------------

DEFAULT_PLUGIN="simple-plugin.sh"

MENU_CMD="menu.sh"
YQ_CMD="yq"
PAGE_SIZE=34 # menu.sh supports <=36 options; reserve paging controls.

OPT_BACK="[ Back ]"
OPT_PRINT_LINK="[ Print link ]"
OPT_PRINT_HREF="[ Print href ]"
OPT_USE_LINK="[ Use link ]"

OPT_SET_VAR="[ Set variable ]"
OPT_PRINT_URL="[ Print current URL ]"
OPT_USE_URL="[ Use current URL ]"

OPT_PRINT="[ Print ]"
OPT_EXIT="[ Exit ]"
OPT_PREV_RESOURCE="[ Previous resource ]"

OPT_NEXT_PAGE="[ Next page ]"
OPT_PREV_PAGE="[ Previous page ]"

OPT_INDEX="[ Select index ]"

# ----------------------------- utilities -------------------------------------

die() { printf 'nahal.sh: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing dependency in PATH: $1"; }

trim() {
  # shellcheck disable=SC2001
  printf '%s' "$*" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

yq_ok() { "$YQ_CMD" -e '.' "$1" >/dev/null 2>&1; }

is_xml_file() {
  head -c 200 "$1" 2>/dev/null | tr -d '\r' | grep -Eq '^[[:space:]]*<'
}

find_payload_file() {
  local base="$1"
  local candidates=(
    "${base}.body" "${base}.json" "${base}.xml" "${base}.payload" "${base}.response"
    "${base}.content" "${base}.out" "${base}"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      if yq_ok "$c" || is_xml_file "$c"; then
        printf '%s\n' "$c"
        return 0
      fi
    fi
  done
  local f
  for f in "${base}"*; do
    [[ -f "$f" ]] || continue
    if yq_ok "$f" || is_xml_file "$f"; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}
paged_menu() {
  local prompt="$1"; shift
  local -a options=("$@")
  ((${#options[@]} > 0)) || die "paged_menu called with zero options"

  local page=0
  while :; do
    local start=$((page * PAGE_SIZE))
    local end=$((start + PAGE_SIZE))
    local -a page_opts=()

    local i
    for ((i=start; i<end && i<${#options[@]}; i++)); do
      page_opts+=("${options[i]}")
    done

    local has_prev=0 has_next=0
    ((page > 0)) && has_prev=1
    ((end < ${#options[@]})) && has_next=1

    ((has_prev)) && page_opts=("$OPT_PREV_PAGE" "${page_opts[@]}")
    ((has_next)) && page_opts+=("$OPT_NEXT_PAGE")

    # empty line before each menu
    printf '\n' >&2

    local choice
    choice="$("$MENU_CMD" "$prompt" "${page_opts[@]}")"
    choice="$(trim "$choice")"

    if [[ "$choice" == "$OPT_NEXT_PAGE" && $has_next -eq 1 ]]; then
      page=$((page + 1)); continue
    elif [[ "$choice" == "$OPT_PREV_PAGE" && $has_prev -eq 1 ]]; then
      page=$((page - 1)); continue
    else
      printf '%s\n' "$choice"
      return 0
    fi
  done
}

menu() {
  printf '\n' >&2
  "$MENU_CMD" "$@"
}

yq_keys() {
  local file="$1" path="$2"
  # Robust for yq v4: objects have type "object"
  "$YQ_CMD" -r "${path} | if type == \"object\" then keys[] else empty end" "$file" 2>/dev/null || true
}

yq_type() {
  local file="$1" path="$2"
  "$YQ_CMD" -r "${path} | type" "$file" 2>/dev/null || printf 'null\n'
}

yq_len() {
  local file="$1" path="$2"
  "$YQ_CMD" -r "${path} | length" "$file" 2>/dev/null || printf '0\n'
}

yq_exists() {
  local file="$1" path="$2"
  "$YQ_CMD" -e "${path} != null" "$file" >/dev/null 2>&1
}

yq_pretty() {
  local file="$1" path="$2"
  "$YQ_CMD" "${path}" "$file"
}

join_path_key() {
  local base="$1" key="$2"
  if [[ "$base" == "." ]]; then
    printf '.\"%s\"' "$key"
  else
    printf '%s.\"%s\"' "$base" "$key"
  fi
}

extract_template_vars() {
  local href="$1"
  printf '%s' "$href" \
    | grep -oE '\{[^}]+\}' \
    | tr -d '{}' \
    | sed 's/^[?#\/\.;&+]\{0,1\}//' \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -E '^[A-Za-z0-9_]+$' \
    | awk '!seen[$0]++' \
    || true
}

select_from_array_path() {
  local file="$1" array_path="$2"

  local len
  len="$("$YQ_CMD" -r "${array_path} | length" "$file" 2>/dev/null || echo 0)"
  is_int "$len" || len=0
  ((len > 0)) || die "array is empty at path: $array_path"

  local elem_type
  elem_type="$(yq_type "$file" "${array_path}[0]")"

  if [[ "$elem_type" != "object" ]]; then
    local idx
    while :; do
      printf 'Select index [0..%d]: ' $((len - 1)) >&2
      read -r idx
      idx="$(trim "$idx")"
      if is_int "$idx" && ((idx >= 0 && idx < len)); then
        printf '%s\n' "${array_path}[${idx}]"
        return 0
      fi
      printf 'Invalid index.\n' >&2
    done
  else
    local prop val
    printf 'Select property name to match within array elements: ' >&2
    read -r prop
    prop="$(trim "$prop")"
    [[ -n "$prop" ]] || prop="id"

    printf 'Select desired value for property "%s": ' "$prop" >&2
    read -r val
    val="$(trim "$val")"

    local found
    found="$("$YQ_CMD" -r "${array_path} | to_entries
      | map(select(.value.\"${prop}\" == \"${val}\")) | .[0].key // \"\"" "$file" 2>/dev/null || true)"

    if is_int "$found" && ((found >= 0 && found < len)); then
      printf '%s\n' "${array_path}[${found}]"
      return 0
    fi

    printf 'No match found; falling back to index selection.\n' >&2
    local idx
    while :; do
      printf 'Select index [0..%d]: ' $((len - 1)) >&2
      read -r idx
      idx="$(trim "$idx")"
      if is_int "$idx" && ((idx >= 0 && idx < len)); then
        printf '%s\n' "${array_path}[${idx}]"
        return 0
      fi
      printf 'Invalid index.\n' >&2
    done
  fi
}

# -------------------------- request execution --------------------------------

run_http_request() {
  local url="$1"
  local -a methods=(GET POST PUT PATCH DELETE HEAD OPTIONS)
  local method
  method="$(paged_menu "Select HTTP method:" "${methods[@]}")"

  command -v "$method" >/dev/null 2>&1 || die "HTTP method script not found in PATH: $method"

  local -a extra_args=()
  case "$method" in
    POST|PUT|PATCH)
      local body_mode
      body_mode="$(menu "Provide request body?" "none" "text" "file(s)")"
      body_mode="$(trim "$body_mode")"
      if [[ "$body_mode" == "text" ]]; then
        printf 'Enter body text (end with a single line containing only "."):\n' >&2
        local tmp
        tmp="$(mktemp -t nahal-body.XXXXXX)"
        while IFS= read -r line; do
          [[ "$line" == "." ]] && break
          printf '%s\n' "$line" >>"$tmp"
        done
        extra_args+=("$tmp")
      elif [[ "$body_mode" == "file(s)" ]]; then
        printf 'Enter one or more file paths (space-separated): ' >&2
        local line
        read -r line
        line="$(trim "$line")"
        if [[ -n "$line" ]]; then
          # shellcheck disable=SC2206
          local arr=( $line )
          extra_args+=("${arr[@]}")
        fi
      fi
      ;;
    *) ;;
  esac

  local out
  if ! out="$("$method" "$url" "${extra_args[@]}")"; then
    die "request failed: $method $url"
  fi
  out="$(trim "$out")"
  [[ -n "$out" ]] || die "HTTP script produced empty basename"

  local basename
  basename="$(printf '%s\n' "$out" | awk 'NF{p=$0} END{print p}')"
  basename="$(trim "$basename")"
  [[ -n "$basename" ]] || die "could not parse basename from HTTP output"

  printf '%s\n' "$basename"
}

# -------------------------- navigation logic ---------------------------------
nav_value() {
  local file="$1" start_path="$2"

  local -a PATH_STACK=("$start_path")
  local path="$start_path"

  while :; do
    echo "nav_value path: $path" >&2
    local t
    t="$(yq_type "$file" "$path")"

    case "$t" in
      object)
        local -a keys=()
        while IFS= read -r k; do
          [[ -n "$k" ]] && keys+=("$k")
        done < <(yq_keys "$file" "$path")

        local -a opts=("$OPT_BACK" "$OPT_PRINT")
        opts+=("${keys[@]}")

        local choice
        choice="$(paged_menu "Object at ${path}: choose:" "${opts[@]}")"

        case "$choice" in
          "$OPT_BACK")
            if ((${#PATH_STACK[@]} > 1)); then
              unset 'PATH_STACK[-1]'
              path="${PATH_STACK[-1]}"
              continue
            else
              return 0
            fi
            ;;
          "$OPT_PRINT")
            printf "\n==>%s\n" "$path" >&2
            yq_pretty "$file" "$path"
            ;;
          *)
            path="$(join_path_key "$path" "$choice")"
            PATH_STACK+=("$path")
            ;;
        esac
        ;;

      array)
        local len
        len="$(yq_len "$file" "$path")"

        # use menu() wrapper (blank line) if you added it; otherwise keep MENU_CMD
        local choice
        choice="$(menu "Array at ${path} (length ${len}):" "$OPT_BACK" "$OPT_PRINT" "$OPT_INDEX")"
        choice="$(trim "$choice")"

        case "$choice" in
          "$OPT_BACK")
            if ((${#PATH_STACK[@]} > 1)); then
              unset 'PATH_STACK[-1]'
              path="${PATH_STACK[-1]}"
              continue
            else
              return 0
            fi
            ;;
          "$OPT_PRINT")
            printf "\n==>%s\n" "$path" >&2
            yq_pretty "$file" "$path"
            ;;
          "$OPT_INDEX")
            local idx
            while :; do
              printf 'Select index [0..%d]: ' $((len - 1)) >&2
              read -r idx
              idx="$(trim "$idx")"
              if is_int "$idx" && ((idx >= 0 && idx < len)); then
                path="${path}[${idx}]"
                PATH_STACK+=("$path")
                break
              fi
              printf 'Invalid index.\n' >&2
            done
            ;;
        esac
        ;;

      *)
        # scalar/null — print immediately and go back one level
        yq_pretty "$file" "$path"

        if ((${#PATH_STACK[@]} > 1)); then
          unset 'PATH_STACK[-1]'
          path="${PATH_STACK[-1]}"
          continue
        else
          return 0
        fi
        ;;
    esac
  done
}

handle_embedded_path() {
  local file="$1" embedded_path="$2"
  local t
  t="$(yq_type "$file" "$embedded_path")"
  if [[ "$t" == "array" ]]; then
    embedded_path="$(select_from_array_path "$file" "$embedded_path")"
  fi
  printf '%s\n' "$embedded_path"
}

choose_link_url() {
  local file="$1" basename="$2" plugin="$3"

  # Gather rels
  local -a rels=()
  while IFS= read -r k; do
    [[ -n "$k" ]] && rels+=("$k")
  done < <(yq_keys "$file" '._links')

  ((${#rels[@]} > 0)) || return 1

  # Pick rel (with Back)
  local -a rel_opts=("$OPT_BACK")
  rel_opts+=("${rels[@]}")

  local rel
  rel="$(paged_menu "Select link relation:" "${rel_opts[@]}")"
  [[ "$rel" == "$OPT_BACK" ]] && return 1

  # Resolve rel to a specific link object path (may be array)
  local link_path="._links.\"${rel}\""
  local lt
  lt="$(yq_type "$file" "$link_path")"
  if [[ "$lt" == "array" ]]; then
    link_path="$(select_from_array_path "$file" "$link_path")"
  fi

  # Link-level menu: print link / print href / proceed / back
  while :; do
    local choice
    choice="$(paged_menu "Link '${rel}': choose:" \
      "$OPT_BACK" "$OPT_PRINT_LINK" "$OPT_PRINT_HREF" "$OPT_USE_LINK")"
    case "$choice" in
      "$OPT_BACK")
        return 1
        ;;
      "$OPT_PRINT_LINK")
        "$YQ_CMD" "$link_path" "$file" > /dev/tty
        ;;
      "$OPT_PRINT_HREF")
        "$YQ_CMD" -r "${link_path}.href // \"\"" "$file" > /dev/tty
        ;;
      "$OPT_USE_LINK")
        break
        ;;
    esac
  done

  # Read templated + href
  local templ href
  templ="$("$YQ_CMD" -r "${link_path}.templated // false" "$file" 2>/dev/null || echo false)"
  href="$("$YQ_CMD" -r "${link_path}.href // \"\"" "$file" 2>/dev/null || true)"
  [[ -n "$href" ]] || return 1

  # Non-templated: plugin builds URL directly
  if [[ "$templ" != "true" ]]; then
    printf '%s\n' "$basename" | "$plugin" "$link_path"
    return 0
  fi

  # Templated: show variable/expression chooser menu
  local -a kvpairs=()
  local -a vars=()
  while IFS= read -r v; do
    [[ -n "$v" ]] && vars+=("$v")
  done < <(extract_template_vars "$href")

  while :; do
    local -a opts=("$OPT_BACK")

    # If we could parse variables, offer them; else allow manual set-var.
    if ((${#vars[@]} > 0)); then
      opts+=("${vars[@]}")
    else
      opts+=("$OPT_SET_VAR")
    fi

    opts+=("$OPT_PRINT_URL" "$OPT_USE_URL")

    local pick
    pick="$(paged_menu "URI template: set variable(s) or use URL:" "${opts[@]}")"

    case "$pick" in
      "$OPT_BACK")
        return 1
        ;;
      "$OPT_PRINT_URL")
        # Ask plugin to render current URL with accumulated kvpairs
        printf '%s\n' "$basename" | "$plugin" "$link_path" "${kvpairs[@]}"
        ;;
      "$OPT_USE_URL")
        # Final URL
        printf '%s\n' "$basename" | "$plugin" "$link_path" "${kvpairs[@]}"
        return 0
        ;;
      "$OPT_SET_VAR")
        local key val
        printf 'Variable name: ' >&2; read -r key; key="$(trim "$key")"
        [[ -n "$key" ]] || continue
        printf 'Value for %s: ' "$key" >&2; read -r val; val="$(trim "$val")"
        kvpairs+=("${key}=${val}")
        ;;
      *)
        # Picked a known variable name
        local val
        printf 'Value for %s: ' "$pick" >&2
        read -r val
        val="$(trim "$val")"
        kvpairs+=("${pick}=${val}")
        ;;
    esac
  done
}

has_nonempty_object_keys() {
  local file="$1" path="$2"
  local n

  # If path is missing or not an object => n becomes 0
  n="$("$YQ_CMD" -r "${path} | if type == \"object\" then (keys | length) else 0 end" "$file" 2>/dev/null || echo 0)"

  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  (( n > 0 ))
}

properties_menu() {
  local file="$1"

  while :; do
    local -a props=()
    while IFS= read -r k; do
      [[ -n "$k" ]] || continue
      [[ "$k" == "_links" || "$k" == "_embedded" ]] && continue
      props+=("$k")
    done < <(yq_keys "$file" '.')

    if ((${#props[@]} == 0)); then
      # If no non-HAL props, still provide useful navigation
      local -a opts=("$OPT_BACK" "$OPT_PRINT")
#      has_nonempty_object_keys "$file" '._links' && opts+=("_links")
#      has_nonempty_object_keys "$file" '._embedded' && opts+=("_embedded")

      local c
      c="$(paged_menu "No non-HAL top-level properties. Choose:" "${opts[@]}")"
      case "$c" in
        "$OPT_BACK") return 0 ;;
        "$OPT_PRINT") yq_pretty "$file" '.' ;;
        "_links") nav_value "$file" '._links' ;;
        "_embedded") nav_value "$file" '._embedded' ;;
      esac
      continue
    fi

    local -a opts=("$OPT_BACK" "$OPT_PRINT")
    opts+=("${props[@]}")

    local pick
    pick="$(paged_menu "Top-level properties: select one:" "${opts[@]}")"

    case "$pick" in
      "$OPT_BACK") return 0 ;;
      "$OPT_PRINT") yq_pretty "$file" '.' ;;
      *)
        # After nav_value returns, loop repeats and shows this same properties list again
        nav_value "$file" ".\"${pick}\""
        ;;
    esac
  done
}

handle_resource() {
  local basename="$1" plugin="$2"

  local file
  file="$(find_payload_file "$basename" 2>/dev/null || true)"
  [[ -n "${file:-}" ]] || { printf 'Could not locate JSON/XML payload for: %s\n' "$basename" >&2; return 1; }

  if ! yq_ok "$file" && ! is_xml_file "$file"; then
    printf 'Payload not valid JSON/XML for navigation: %s\n' "$file" >&2
    return 1
  fi

  if is_xml_file "$file" && ! yq_ok "$file"; then
    local c
    c="$(menu "XML payload detected. What to do?" "print" "back")"
    c="$(trim "$c")"
    [[ "$c" == "print" ]] && sed -n '1,200p' "$file"
    return 1
  fi

  while :; do
    local show_links=0 show_embedded=0
    has_nonempty_object_keys "$file" '._links' && show_links=1
    has_nonempty_object_keys "$file" '._embedded' && show_embedded=1

    local -a main_opts=()
    main_opts+=("$OPT_EXIT")
    ((${#STACK[@]} > 0)) && main_opts+=("$OPT_PREV_RESOURCE")
    main_opts+=("properties")
    ((show_embedded)) && main_opts+=("embedded")
    ((show_links)) && main_opts+=("links")

    local main_choice
    main_choice="$(paged_menu "Resource: ${basename} — choose:" "${main_opts[@]}")"

    case "$main_choice" in
      "$OPT_EXIT") exit 0 ;;
      "$OPT_PREV_RESOURCE") return 2 ;;
      properties)
        properties_menu "$file"
        ;;
      embedded)
        # safe because option only shown when non-empty
        local -a embs=()
        while IFS= read -r k; do
          [[ -n "$k" ]] && embs+=("$k")
        done < <(yq_keys "$file" '._embedded')

        local e
        e="$(paged_menu "Select embedded rel:" "${embs[@]}")"
        local ep="._embedded.\"${e}\""
        ep="$(handle_embedded_path "$file" "$ep")"
        nav_value "$file" "$ep"
        ;;
      links)
        local url
        url="$(choose_link_url "$file" "$basename" "$plugin" || true)"
        url="$(trim "$url")"
        [[ -n "$url" ]] || continue

        printf 'URL: %s\n' "$url" >&2

        local new_base
        new_base="$(run_http_request "$url")"
        new_base="$(trim "$new_base")"
        [[ -n "$new_base" ]] || { printf 'No new basename returned.\n' >&2; continue; }

        local new_file
        new_file="$(find_payload_file "$new_base" 2>/dev/null || true)"

        local can_nav=0
        if [[ -n "$new_file" ]] && ( yq_ok "$new_file" || is_xml_file "$new_file" ); then
          can_nav=1
        fi

        if ((can_nav)); then
          local after
          after="$(menu "Response recorded as: ${new_base}. What next?" "exit" "continue-new" "continue-previous")"
          after="$(trim "$after")"
          case "$after" in
            exit) exit 0 ;;
            continue-previous) ;;
            continue-new)
              STACK+=("$basename")
              basename="$new_base"
              file="$new_file"
              ;;
          esac
        else
          local after
          after="$(menu "Response recorded as: ${new_base} (not JSON/XML navigable). What next?" "exit" "continue-previous")"
          after="$(trim "$after")"
          case "$after" in
            exit) exit 0 ;;
            continue-previous) ;;
          esac
        fi
        ;;
    esac
  done
}

# ------------------------------- main ----------------------------------------

PLUGIN="$DEFAULT_PLUGIN"

if (($# < 1)); then
  die "usage: $0 <entry_url> [-p <plugin_script>]"
fi

ENTRY_URL="$1"; shift

while (($# > 0)); do
  case "$1" in
    -p|--plugin)
      shift
      [[ $# -gt 0 ]] || die "missing value for -p/--plugin"
      PLUGIN="$1"
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

need_cmd "$YQ_CMD"
need_cmd menu
command -v "$PLUGIN" >/dev/null 2>&1 || die "plugin script not found in PATH: $PLUGIN"
command -v GET >/dev/null 2>&1 || die "GET script not found in PATH (HALDiSh HTTP scripts expected)"

declare -a STACK=()

BASE="$(run_http_request "$ENTRY_URL")"
BASE="$(trim "$BASE")"
[[ -n "$BASE" ]] || die "initial request did not produce a basename"

while :; do
  if handle_resource "$BASE" "$PLUGIN"; then
    :
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then
      if ((${#STACK[@]} > 0)); then
        BASE="${STACK[-1]}"
        unset 'STACK[-1]'
      else
        printf 'No previous resource.\n' >&2
      fi
    else
      local_choice="$(menu "Unable to navigate current payload. What next?" "exit" "previous-resource")"
      local_choice="$(trim "$local_choice")"
      [[ "$local_choice" == "exit" ]] && exit 0
      if ((${#STACK[@]} > 0)); then
        BASE="${STACK[-1]}"
        unset 'STACK[-1]'
      else
        die "no previous resource to return to"
      fi
    fi
  fi
done
