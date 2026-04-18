#!/usr/bin/env bash
# =============================================================================
# prettyprint.sh — detect content type and pretty-print body files
#
# Usage:
#   prettyprint.sh [options] [base_name...]
#   printf 'base1\nbase2\n' | prettyprint.sh [options]
#
# For each base name, detects the content type of <base>.body (or the source
# extension set by -e), then copies or moves it to <base>.<detected-ext>.
# JSON, YAML, and XML files are reformatted to pretty-print form (UTF-8 output).
# Other text encodings are converted to UTF-8 for text formats.
#
# Options are positional and affect every base name that follows them:
#   -c              copy mode — keep the source file (default)
#   -m              move mode — remove the source file after conversion
#   -e <ext>        source extension to use instead of "body"
#
# Multiple -c, -m, and -e flags may appear; each one changes the mode or
# extension for all subsequent base names on the command line.
# When base names come from stdin, the final mode and extension apply to all.
#
# Stdout: base name for each processed file (one per line)
# Stderr: progress and warning messages
#
# Detected extensions (sample):
#   Text  : json yaml xml html csv txt svg
#   Image : jpg png gif webp bmp tif svg
#   Office: pdf docx xlsx pptx doc xls ppt odt ods odp epub
#   Archive: zip gz bz2 xz tar
#
# Pretty-print tools used (first available wins):
#   JSON : jq, python3 -m json.tool
#   XML  : xmllint --format, python3 xml.dom.minidom
#   YAML : yq, python3 yaml (PyYAML)
# =============================================================================
set -euo pipefail

. hal_utils.sh

# ── tool discovery ─────────────────────────────────────────────────────────────
_PP_JQ=$(command -v jq       2>/dev/null || true)
_PP_YQ=$(command -v yq       2>/dev/null || true)
_PP_XMLLINT=$(command -v xmllint 2>/dev/null || true)
_PP_PYTHON3=$(command -v python3 2>/dev/null || true)
_PP_UNZIP=$(command -v unzip   2>/dev/null || true)
_PP_ICONV=$(command -v iconv   2>/dev/null || true)

# ── content detection ─────────────────────────────────────────────────────────

# _pp_detect_zip <file>
# Peeks inside a ZIP archive and returns the most specific extension it can
# identify: docx, xlsx, pptx, odt, ods, odp, epub, or zip.
_pp_detect_zip() {
    local file="$1"
    [[ -z "$_PP_UNZIP" ]] && { printf 'zip'; return; }

    local listing
    listing=$(unzip -l "$file" 2>/dev/null) || { printf 'zip'; return; }

    if printf '%s' "$listing" | grep -q ' word/'; then
        printf 'docx'
    elif printf '%s' "$listing" | grep -q ' xl/'; then
        printf 'xlsx'
    elif printf '%s' "$listing" | grep -q ' ppt/'; then
        printf 'pptx'
    else
        # ODF and EPUB store a plain-text "mimetype" entry at the root
        local mimetype
        mimetype=$(unzip -p "$file" mimetype 2>/dev/null || true)
        case "$mimetype" in
            *opendocument.text*)         printf 'odt'  ;;
            *opendocument.spreadsheet*)  printf 'ods'  ;;
            *opendocument.presentation*) printf 'odp'  ;;
            *epub*)                      printf 'epub' ;;
            *)                           printf 'zip'  ;;
        esac
    fi
}

# _pp_read_utf8 <file> <encoding>
# Outputs file content as UTF-8.  Converts via iconv when encoding differs.
_pp_read_utf8() {
    local file="$1" enc="$2"
    case "$enc" in
        us-ascii|utf-8|unknown-8bit|'')
            cat "$file" ;;
        *)
            if [[ -n "$_PP_ICONV" ]]; then
                iconv -f "$enc" -t utf-8 "$file" 2>/dev/null || cat "$file"
            else
                cat "$file"
            fi ;;
    esac
}

# _pp_probe_text <file> <encoding>
# Further classifies a text file when MIME type alone is not specific enough.
# Prints "ext:text:<encoding>".
_pp_probe_text() {
    local file="$1" enc="$2"
    local content first

    content=$(_pp_read_utf8 "$file" "$enc")
    # First non-blank, non-whitespace character
    first=$(printf '%s' "$content" | grep -m1 -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//' | cut -c1)

    # JSON: starts with { or [
    if [[ "$first" == '{' || "$first" == '[' ]]; then
        if [[ -n "$_PP_JQ" ]] && printf '%s' "$content" \
                | "$_PP_JQ" empty >/dev/null 2>&1; then
            printf 'json:text:%s' "$enc"; return
        fi
    fi

    # XML / HTML: starts with <
    if [[ "$first" == '<' ]]; then
        if printf '%s' "$content" | grep -qiE '<!DOCTYPE[[:space:]]+html|<html[[:space:]>]'; then
            printf 'html:text:%s' "$enc"
        else
            printf 'xml:text:%s' "$enc"
        fi
        return
    fi

    # YAML: document marker or "key: value" pattern on first meaningful line
    if printf '%s' "$content" \
            | grep -qE '^---[[:space:]]*$|^[[:alpha:]][-[:alnum:]_]*:[[:space:]]'; then
        printf 'yaml:text:%s' "$enc"; return
    fi

    # CSV: first line has commas and all of the first 5 lines have the same
    #      comma count
    local first_line comma_count_0 consistent
    first_line=$(printf '%s' "$content" | head -1)
    if printf '%s' "$first_line" | grep -q ','; then
        comma_count_0=$(printf '%s' "$first_line" | tr -cd ',' | wc -c)
        consistent=$(printf '%s' "$content" | head -5 \
            | awk -F',' -v n="$comma_count_0" 'NF-1 != n {print "no"}' \
            | grep -c 'no' || true)
        if [[ "$consistent" -eq 0 && "$comma_count_0" -gt 0 ]]; then
            printf 'csv:text:%s' "$enc"; return
        fi
    fi

    printf 'txt:text:%s' "$enc"
}

# _pp_detect <file>
# Determines the content type of a file.
# Prints "ext:kind:encoding" where kind is "text" or "binary".
_pp_detect() {
    local file="$1"
    local mime enc
    mime=$(file --mime-type -b     "$file" 2>/dev/null || printf 'application/octet-stream')
    enc=$(file  --mime-encoding -b "$file" 2>/dev/null || printf 'binary')

    case "$mime" in
        application/json)                   printf 'json:text:%s'    "$enc" ;;
        text/xml|application/xml)           printf 'xml:text:%s'     "$enc" ;;
        application/xhtml+xml|text/html)    printf 'html:text:%s'    "$enc" ;;
        text/csv)                           printf 'csv:text:%s'     "$enc" ;;
        text/yaml|application/yaml|\
        application/x-yaml)                 printf 'yaml:text:%s'    "$enc" ;;
        image/svg+xml)                      printf 'svg:text:%s'     "$enc" ;;
        text/plain|text/*)                  _pp_probe_text "$file" "$enc"   ;;

        application/octet-stream)
            # Binary detector; probe as text when encoding is not 'binary'
            if [[ "$enc" != 'binary' ]]; then
                _pp_probe_text "$file" "$enc"
            else
                printf 'bin:binary:binary'
            fi ;;

        image/jpeg)   printf 'jpg:binary:binary'  ;;
        image/png)    printf 'png:binary:binary'  ;;
        image/gif)    printf 'gif:binary:binary'  ;;
        image/webp)   printf 'webp:binary:binary' ;;
        image/bmp)    printf 'bmp:binary:binary'  ;;
        image/tiff)   printf 'tif:binary:binary'  ;;
        image/*)
            printf '%s:binary:binary' "${mime#image/}" ;;

        application/pdf)           printf 'pdf:binary:binary'  ;;
        application/zip)
            printf '%s:binary:binary' "$(_pp_detect_zip "$file")" ;;
        application/x-tar|\
        application/x-gtar)        printf 'tar:binary:binary'  ;;
        application/gzip|\
        application/x-gzip)        printf 'gz:binary:binary'   ;;
        application/x-bzip2)       printf 'bz2:binary:binary'  ;;
        application/x-xz)          printf 'xz:binary:binary'   ;;
        application/vnd.ms-excel)  printf 'xls:binary:binary'  ;;
        application/msword)        printf 'doc:binary:binary'  ;;
        application/vnd.ms-powerpoint)
                                   printf 'ppt:binary:binary'  ;;
        application/vnd.openxmlformats-officedocument.wordprocessingml.document)
                                   printf 'docx:binary:binary' ;;
        application/vnd.openxmlformats-officedocument.spreadsheetml.sheet)
                                   printf 'xlsx:binary:binary' ;;
        application/vnd.openxmlformats-officedocument.presentationml.presentation)
                                   printf 'pptx:binary:binary' ;;
        application/vnd.oasis.opendocument.text)
                                   printf 'odt:binary:binary'  ;;
        application/vnd.oasis.opendocument.spreadsheet)
                                   printf 'ods:binary:binary'  ;;
        application/vnd.oasis.opendocument.presentation)
                                   printf 'odp:binary:binary'  ;;
        *)
            # Derive a best-guess extension from the MIME subtype
            local subtype="${mime#*/}"
            subtype="${subtype##*[.+]}"      # strip vnd./x- prefix parts
            printf '%s:binary:binary' "$subtype" ;;
    esac
}

# ── pretty-printers ───────────────────────────────────────────────────────────

# Each function writes pretty-printed UTF-8 output to <dest>.
# On tool failure it falls back to a plain UTF-8 copy and warns.

_pp_fmt_json() {
    local file="$1" enc="$2" dest="$3"
    if [[ -n "$_PP_JQ" ]]; then
        _pp_read_utf8 "$file" "$enc" | "$_PP_JQ" '.' > "$dest"
    elif [[ -n "$_PP_PYTHON3" ]]; then
        _pp_read_utf8 "$file" "$enc" | "$_PP_PYTHON3" -m json.tool > "$dest"
    else
        hal::log::warn "prettyprint: no JSON formatter available (jq, python3); copying as-is"
        _pp_read_utf8 "$file" "$enc" > "$dest"
    fi
}

_pp_fmt_xml() {
    local file="$1" enc="$2" dest="$3"
    if [[ -n "$_PP_XMLLINT" ]]; then
        _pp_read_utf8 "$file" "$enc" \
            | "$_PP_XMLLINT" --format - > "$dest" 2>/dev/null \
            || { hal::log::warn "prettyprint: xmllint failed; copying as-is"
                 _pp_read_utf8 "$file" "$enc" > "$dest"; }
    elif [[ -n "$_PP_PYTHON3" ]]; then
        _pp_read_utf8 "$file" "$enc" | "$_PP_PYTHON3" -c '
import sys, xml.dom.minidom
try:
    src = sys.stdin.buffer.read()
    print(xml.dom.minidom.parseString(src).toprettyxml(indent="  "),
          end="")
except Exception:
    sys.stdout.buffer.write(src)
    sys.exit(1)
' > "$dest" 2>/dev/null \
            || { hal::log::warn "prettyprint: XML formatter failed; copying as-is"
                 _pp_read_utf8 "$file" "$enc" > "$dest"; }
    else
        hal::log::warn "prettyprint: no XML formatter available (xmllint, python3); copying as-is"
        _pp_read_utf8 "$file" "$enc" > "$dest"
    fi
}

_pp_fmt_yaml() {
    local file="$1" enc="$2" dest="$3"
    if [[ -n "$_PP_YQ" ]]; then
        _pp_read_utf8 "$file" "$enc" \
            | "$_PP_YQ" '.' > "$dest" 2>/dev/null \
            || { hal::log::warn "prettyprint: yq failed; copying as-is"
                 _pp_read_utf8 "$file" "$enc" > "$dest"; }
    elif [[ -n "$_PP_PYTHON3" ]]; then
        _pp_read_utf8 "$file" "$enc" | "$_PP_PYTHON3" -c '
import sys, yaml
try:
    data = yaml.safe_load(sys.stdin.read())
    sys.stdout.write(yaml.dump(data, default_flow_style=False,
                               allow_unicode=True))
except Exception:
    sys.exit(1)
' > "$dest" 2>/dev/null \
            || { hal::log::warn "prettyprint: YAML formatter failed; copying as-is"
                 _pp_read_utf8 "$file" "$enc" > "$dest"; }
    else
        hal::log::warn "prettyprint: no YAML formatter available (yq, python3); copying as-is"
        _pp_read_utf8 "$file" "$enc" > "$dest"
    fi
}

# ── single-file processing ────────────────────────────────────────────────────

# _pp_process <mode> <src_ext> <base>
# Detects type, writes the formatted/copied file, removes source on move.
# Stdout: base name.
_pp_process() {
    local mode="$1" src_ext="$2" base="$3"
    local src="${base}.${src_ext}"

    if [[ ! -f "$src" ]]; then
        hal::log::error "prettyprint: file not found: ${src}"
        return 1
    fi

    local info ext kind enc
    info=$(_pp_detect "$src")
    ext="${info%%:*}";  info="${info#*:}"
    kind="${info%%:*}"; enc="${info#*:}"

    local dst="${base}.${ext}"

    hal::log::info "prettyprint: ${src} → ${dst} [${kind}/${enc}]"

    if [[ "$src" == "$dst" ]]; then
        # In-place: write to a temp file then replace
        if [[ "$kind" == 'text' ]]; then
            local tmp
            tmp=$(mktemp)
            case "$ext" in
                json)           _pp_fmt_json "$src" "$enc" "$tmp" ;;
                xml|html)       _pp_fmt_xml  "$src" "$enc" "$tmp" ;;
                yaml|yml)       _pp_fmt_yaml "$src" "$enc" "$tmp" ;;
                *)              _pp_read_utf8 "$src" "$enc" > "$tmp" ;;
            esac
            mv "$tmp" "$dst"
        fi
        # copy mode: nothing to remove; move mode: source == destination, done
        printf '%s\n' "$base"
        return 0
    fi

    # Source and destination differ — write then optionally remove source
    case "$kind" in
        text)
            case "$ext" in
                json)      _pp_fmt_json "$src" "$enc" "$dst" ;;
                xml|html)  _pp_fmt_xml  "$src" "$enc" "$dst" ;;
                yaml|yml)  _pp_fmt_yaml "$src" "$enc" "$dst" ;;
                *)         _pp_read_utf8 "$src" "$enc" > "$dst" ;;
            esac ;;
        binary)
            cp -- "$src" "$dst" ;;
    esac

    [[ "$mode" == 'move' ]] && rm -f -- "$src"

    printf '%s\n' "$base"
}

# ── entry point ───────────────────────────────────────────────────────────────

declare -a _pp_modes=()
declare -a _pp_exts=()
declare -a _pp_bases=()

_pp_cur_mode='copy'
_pp_cur_ext='body'

if [[ $# -gt 0 ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c)
                _pp_cur_mode='copy' ;;
            -m)
                _pp_cur_mode='move' ;;
            -e)
                if [[ $# -lt 2 ]]; then
                    hal::log::error "prettyprint: -e requires an extension argument"
                    exit 1
                fi
                shift
                _pp_cur_ext="${1#.}"   # accept both "json" and ".json"
                ;;
            -*)
                hal::log::warn "prettyprint: unknown option: $1" ;;
            *)
                _pp_modes+=("$_pp_cur_mode")
                _pp_exts+=("$_pp_cur_ext")
                _pp_bases+=("$1")
                ;;
        esac
        shift
    done
fi

# Fall back to stdin when no base names were collected from the command line
if [[ ${#_pp_bases[@]} -eq 0 ]]; then
    if [[ -t 0 ]]; then
        printf 'Usage: %s [options] [base_name...]\n' "$(basename "$0")" >&2
        printf '       printf base_name | %s [options]\n' "$(basename "$0")" >&2
        exit 1
    fi
    while IFS= read -r _pp_line || [[ -n "${_pp_line:-}" ]]; do
        [[ -z "${_pp_line:-}" ]] && continue
        _pp_modes+=("$_pp_cur_mode")
        _pp_exts+=("$_pp_cur_ext")
        _pp_bases+=("$_pp_line")
    done
fi

for (( _pp_i = 0; _pp_i < ${#_pp_bases[@]}; _pp_i++ )); do
    _pp_process "${_pp_modes[$_pp_i]}" "${_pp_exts[$_pp_i]}" "${_pp_bases[$_pp_i]}"
done
