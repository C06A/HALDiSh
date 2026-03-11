#!/usr/bin/env bats
# =============================================================================
# uritemplate.bats — unit tests for uritemplate.sh (RFC 6570)
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

URITEMPLATE_SH="${SCRIPTS_DIR}/uritemplate.sh"

# ── Level 1: simple string expansion ─────────────────────────────────────────

@test "uritemplate.sh: {var} simple value" {
    run bash "$URITEMPLATE_SH" '{var}' 'var=value'
    [ "$status" -eq 0 ]
    [ "$output" = 'value' ]
}

@test "uritemplate.sh: {hello} encodes space as %20" {
    run bash "$URITEMPLATE_SH" '{hello}' 'hello=Hello World'
    [ "$status" -eq 0 ]
    [ "$output" = 'Hello%20World' ]
}

@test "uritemplate.sh: {half} encodes percent as %25" {
    run bash "$URITEMPLATE_SH" '{half}' 'half=50%'
    [ "$status" -eq 0 ]
    [ "$output" = '50%25' ]
}

@test "uritemplate.sh: unreserved chars pass through unencoded" {
    run bash "$URITEMPLATE_SH" '{safe}' 'safe=ABCabc012-._~'
    [ "$status" -eq 0 ]
    [ "$output" = 'ABCabc012-._~' ]
}

@test "uritemplate.sh: {var} encodes plus sign as %2B" {
    run bash "$URITEMPLATE_SH" '{var}' 'var=1+2'
    [ "$status" -eq 0 ]
    [ "$output" = '1%2B2' ]
}

@test "uritemplate.sh: undefined variable expands to empty" {
    run bash "$URITEMPLATE_SH" '{undef}'
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

@test "uritemplate.sh: literal text passes through unchanged" {
    run bash "$URITEMPLATE_SH" 'http://example.com/{path}' 'path=index'
    [ "$status" -eq 0 ]
    [ "$output" = 'http://example.com/index' ]
}

@test "uritemplate.sh: multiple expressions in one template" {
    run bash "$URITEMPLATE_SH" '{x},{y}' 'x=1024' 'y=768'
    [ "$status" -eq 0 ]
    [ "$output" = '1024,768' ]
}

@test "uritemplate.sh: empty template returns empty string" {
    run bash "$URITEMPLATE_SH" ''
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

@test "uritemplate.sh: template with no expressions returns literal" {
    run bash "$URITEMPLATE_SH" 'http://example.com/static'
    [ "$status" -eq 0 ]
    [ "$output" = 'http://example.com/static' ]
}

# ── Level 2: + operator (reserved string expansion) ──────────────────────────

@test "uritemplate.sh: {+var} passes slash through" {
    run bash "$URITEMPLATE_SH" '{+path}' 'path=/foo/bar'
    [ "$status" -eq 0 ]
    [ "$output" = '/foo/bar' ]
}

@test "uritemplate.sh: {+var} passes reserved chars through" {
    run bash "$URITEMPLATE_SH" '{+url}' 'url=http://example.com/foo'
    [ "$status" -eq 0 ]
    [ "$output" = 'http://example.com/foo' ]
}

@test "uritemplate.sh: {+var} still encodes space as %20" {
    run bash "$URITEMPLATE_SH" '{+hello}' 'hello=Hello World'
    [ "$status" -eq 0 ]
    [ "$output" = 'Hello%20World' ]
}

@test "uritemplate.sh: {+var} passes plus sign through" {
    run bash "$URITEMPLATE_SH" '{+var}' 'var=1+2'
    [ "$status" -eq 0 ]
    [ "$output" = '1+2' ]
}

@test "uritemplate.sh: {+var} undefined produces empty string" {
    run bash "$URITEMPLATE_SH" '{+undef}'
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

# ── Level 2: # operator (fragment expansion) ──────────────────────────────────

@test "uritemplate.sh: {#var} prepends hash prefix" {
    run bash "$URITEMPLATE_SH" '{#var}' 'var=value'
    [ "$status" -eq 0 ]
    [ "$output" = '#value' ]
}

@test "uritemplate.sh: {#path} passes slashes through with hash prefix" {
    run bash "$URITEMPLATE_SH" '{#path}' 'path=/foo/bar'
    [ "$status" -eq 0 ]
    [ "$output" = '#/foo/bar' ]
}

@test "uritemplate.sh: {#var} undefined produces empty string" {
    run bash "$URITEMPLATE_SH" '{#undef}'
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

# ── Level 3: multiple variables (default operator) ────────────────────────────

@test "uritemplate.sh: {x,y} joins two values with comma" {
    run bash "$URITEMPLATE_SH" '{x,y}' 'x=1024' 'y=768'
    [ "$status" -eq 0 ]
    [ "$output" = '1024,768' ]
}

@test "uritemplate.sh: {x,undef,y} skips undefined variable" {
    run bash "$URITEMPLATE_SH" '{x,undef,y}' 'x=1024' 'y=768'
    [ "$status" -eq 0 ]
    [ "$output" = '1024,768' ]
}

@test "uritemplate.sh: {+x,y} reserved with multiple vars" {
    run bash "$URITEMPLATE_SH" '{+x,y}' 'x=/foo' 'y=/bar'
    [ "$status" -eq 0 ]
    [ "$output" = '/foo,/bar' ]
}

# ── Level 3: . operator (label expansion) ────────────────────────────────────

@test "uritemplate.sh: {.var} prepends dot" {
    run bash "$URITEMPLATE_SH" '{.var}' 'var=value'
    [ "$status" -eq 0 ]
    [ "$output" = '.value' ]
}

@test "uritemplate.sh: {.x,y} joins with dot separator" {
    run bash "$URITEMPLATE_SH" '{.x,y}' 'x=foo' 'y=bar'
    [ "$status" -eq 0 ]
    [ "$output" = '.foo.bar' ]
}

@test "uritemplate.sh: {.var} undefined produces empty string" {
    run bash "$URITEMPLATE_SH" '{.undef}'
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

# ── Level 3: / operator (path segment expansion) ──────────────────────────────

@test "uritemplate.sh: {/var} produces /value" {
    run bash "$URITEMPLATE_SH" '{/var}' 'var=value'
    [ "$status" -eq 0 ]
    [ "$output" = '/value' ]
}

@test "uritemplate.sh: {/x,y,z} joins path segments" {
    run bash "$URITEMPLATE_SH" '{/x,y,z}' 'x=a' 'y=b' 'z=c'
    [ "$status" -eq 0 ]
    [ "$output" = '/a/b/c' ]
}

@test "uritemplate.sh: {/var} undefined produces empty string" {
    run bash "$URITEMPLATE_SH" '{/undef}'
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

@test "uritemplate.sh: {/x,undef,y} skips undefined in path" {
    run bash "$URITEMPLATE_SH" '{/x,undef,y}' 'x=a' 'y=c'
    [ "$status" -eq 0 ]
    [ "$output" = '/a/c' ]
}

# ── Level 3: ; operator (path-style parameter expansion) ─────────────────────

@test "uritemplate.sh: {;key} produces ;key=value" {
    run bash "$URITEMPLATE_SH" '{;key}' 'key=val'
    [ "$status" -eq 0 ]
    [ "$output" = ';key=val' ]
}

@test "uritemplate.sh: {;key} with empty value omits equals sign" {
    run bash "$URITEMPLATE_SH" '{;empty}' 'empty='
    [ "$status" -eq 0 ]
    [ "$output" = ';empty' ]
}

@test "uritemplate.sh: {;x,y} produces ;x=val;y=val" {
    run bash "$URITEMPLATE_SH" '{;x,y}' 'x=1024' 'y=768'
    [ "$status" -eq 0 ]
    [ "$output" = ';x=1024;y=768' ]
}

@test "uritemplate.sh: {;var} undefined produces empty string" {
    run bash "$URITEMPLATE_SH" '{;undef}'
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

# ── Level 3: ? operator (form-style query expansion) ─────────────────────────

@test "uritemplate.sh: {?key} produces ?key=value" {
    run bash "$URITEMPLATE_SH" '{?key}' 'key=val'
    [ "$status" -eq 0 ]
    [ "$output" = '?key=val' ]
}

@test "uritemplate.sh: {?key} with empty value produces ?key=" {
    run bash "$URITEMPLATE_SH" '{?empty}' 'empty='
    [ "$status" -eq 0 ]
    [ "$output" = '?empty=' ]
}

@test "uritemplate.sh: {?x,y} produces ?x=val&y=val" {
    run bash "$URITEMPLATE_SH" '{?x,y}' 'x=1024' 'y=768'
    [ "$status" -eq 0 ]
    [ "$output" = '?x=1024&y=768' ]
}

@test "uritemplate.sh: {?var} encodes space in value" {
    run bash "$URITEMPLATE_SH" '{?q}' 'q=hello world'
    [ "$status" -eq 0 ]
    [ "$output" = '?q=hello%20world' ]
}

@test "uritemplate.sh: {?var} undefined produces empty string" {
    run bash "$URITEMPLATE_SH" '{?undef}'
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

# ── Level 3: & operator (query continuation) ──────────────────────────────────

@test "uritemplate.sh: {&x} produces &x=value" {
    run bash "$URITEMPLATE_SH" '{&x}' 'x=val'
    [ "$status" -eq 0 ]
    [ "$output" = '&x=val' ]
}

@test "uritemplate.sh: {&x,y} produces &x=val&y=val" {
    run bash "$URITEMPLATE_SH" '{&x,y}' 'x=1024' 'y=768'
    [ "$status" -eq 0 ]
    [ "$output" = '&x=1024&y=768' ]
}

@test "uritemplate.sh: {&x} with empty value produces &x=" {
    run bash "$URITEMPLATE_SH" '{&empty}' 'empty='
    [ "$status" -eq 0 ]
    [ "$output" = '&empty=' ]
}

# ── Level 4: prefix modifier (:N) ─────────────────────────────────────────────

@test "uritemplate.sh: {var:3} truncates to 3 chars" {
    run bash "$URITEMPLATE_SH" '{var:3}' 'var=value'
    [ "$status" -eq 0 ]
    [ "$output" = 'val' ]
}

@test "uritemplate.sh: {var:30} does not exceed string length" {
    run bash "$URITEMPLATE_SH" '{var:30}' 'var=value'
    [ "$status" -eq 0 ]
    [ "$output" = 'value' ]
}

@test "uritemplate.sh: {+path:6} truncates and allows reserved" {
    run bash "$URITEMPLATE_SH" '{+path:6}' 'path=/foo/bar'
    [ "$status" -eq 0 ]
    [ "$output" = '/foo/b' ]
}

@test "uritemplate.sh: {var:3} encodes truncated value" {
    run bash "$URITEMPLATE_SH" '{var:3}' 'var=va lue'
    [ "$status" -eq 0 ]
    [ "$output" = 'va%20' ]
}

# ── Level 4: explode modifier (*) — list ──────────────────────────────────────

@test "uritemplate.sh: {list*} explodes list with comma separator" {
    run bash "$URITEMPLATE_SH" '{list*}' 'list[]=red' 'list[]=green' 'list[]=blue'
    [ "$status" -eq 0 ]
    [ "$output" = 'red,green,blue' ]
}

@test "uritemplate.sh: {list} non-explode joins list with comma" {
    run bash "$URITEMPLATE_SH" '{list}' 'list[]=red' 'list[]=green' 'list[]=blue'
    [ "$status" -eq 0 ]
    [ "$output" = 'red,green,blue' ]
}

@test "uritemplate.sh: {/list*} explodes list as path segments" {
    run bash "$URITEMPLATE_SH" '{/list*}' 'list[]=a' 'list[]=b' 'list[]=c'
    [ "$status" -eq 0 ]
    [ "$output" = '/a/b/c' ]
}

@test "uritemplate.sh: {.list*} explodes list with dot separator" {
    run bash "$URITEMPLATE_SH" '{.list*}' 'list[]=a' 'list[]=b' 'list[]=c'
    [ "$status" -eq 0 ]
    [ "$output" = '.a.b.c' ]
}

@test "uritemplate.sh: {?list*} explodes list as repeated query params" {
    run bash "$URITEMPLATE_SH" '{?list*}' 'list[]=red' 'list[]=green' 'list[]=blue'
    [ "$status" -eq 0 ]
    [ "$output" = '?list=red&list=green&list=blue' ]
}

@test "uritemplate.sh: {;list*} explodes list as path params" {
    run bash "$URITEMPLATE_SH" '{;list*}' 'list[]=red' 'list[]=green' 'list[]=blue'
    [ "$status" -eq 0 ]
    [ "$output" = ';list=red;list=green;list=blue' ]
}

@test "uritemplate.sh: {+list*} explodes list with reserved chars" {
    run bash "$URITEMPLATE_SH" '{+list*}' 'list[]=a/b' 'list[]=c/d'
    [ "$status" -eq 0 ]
    [ "$output" = 'a/b,c/d' ]
}

# ── Level 4: explode modifier (*) — map ───────────────────────────────────────

@test "uritemplate.sh: {map*} explodes map as key=value pairs" {
    run bash "$URITEMPLATE_SH" '{map*}' 'map[k1]=v1' 'map[k2]=v2'
    [ "$status" -eq 0 ]
    [[ "$output" == *'k1=v1'* ]]
    [[ "$output" == *'k2=v2'* ]]
}

@test "uritemplate.sh: {map*} sorts map keys alphabetically" {
    run bash "$URITEMPLATE_SH" '{map*}' 'map[z]=last' 'map[a]=first'
    [ "$status" -eq 0 ]
    [ "$output" = 'a=first,z=last' ]
}

@test "uritemplate.sh: {map} non-explode produces key,val interleaved" {
    run bash "$URITEMPLATE_SH" '{map}' 'map[k1]=v1' 'map[k2]=v2'
    [ "$status" -eq 0 ]
    [[ "$output" == *'k1,v1'* ]]
    [[ "$output" == *'k2,v2'* ]]
}

@test "uritemplate.sh: {?map*} explodes map as query params" {
    run bash "$URITEMPLATE_SH" '{?map*}' 'map[a]=1' 'map[b]=2'
    [ "$status" -eq 0 ]
    [[ "${output:0:1}" == '?' ]]
    [[ "$output" == *'a=1'* ]]
    [[ "$output" == *'b=2'* ]]
}

@test "uritemplate.sh: {+map*} explodes map passing reserved chars" {
    run bash "$URITEMPLATE_SH" '{+map*}' 'map[semi]=;' 'map[dot]=.' 'map[comma]=,'
    [ "$status" -eq 0 ]
    [[ "$output" == *'comma=,'* ]]
    [[ "$output" == *'dot=.'* ]]
    [[ "$output" == *'semi=;'* ]]
}

# ── Edge cases ────────────────────────────────────────────────────────────────

@test "uritemplate.sh: empty value string is defined (not skipped)" {
    run bash "$URITEMPLATE_SH" '{var}' 'var='
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

@test "uritemplate.sh: {;empty,x} omits = for empty ; value" {
    run bash "$URITEMPLATE_SH" '{;empty,x}' 'empty=' 'x=1024'
    [ "$status" -eq 0 ]
    [ "$output" = ';empty;x=1024' ]
}

@test "uritemplate.sh: undefined var in multi-var expression is skipped" {
    run bash "$URITEMPLATE_SH" '{x,y}' 'x=foo'
    [ "$status" -eq 0 ]
    [ "$output" = 'foo' ]
}

@test "uritemplate.sh: consecutive expressions expand correctly" {
    run bash "$URITEMPLATE_SH" '{/path}{?q}' 'path=search' 'q=hello'
    [ "$status" -eq 0 ]
    [ "$output" = '/search?q=hello' ]
}

@test "uritemplate.sh: encodes all non-unreserved ASCII chars" {
    run bash "$URITEMPLATE_SH" '{var}' 'var= !@#'
    [ "$status" -eq 0 ]
    [ "$output" = '%20%21%40%23' ]
}

# ── Mixed literal text and multiple expressions ───────────────────────────────

@test "mixed: scheme + host literal + path + query" {
    run bash "$URITEMPLATE_SH" 'https://api.example.com{/version}/users{?page,limit}' \
        'version=v2' 'page=3' 'limit=50'
    [ "$status" -eq 0 ]
    [ "$output" = 'https://api.example.com/v2/users?page=3&limit=50' ]
}

@test "mixed: literal prefix + simple var + literal suffix" {
    run bash "$URITEMPLATE_SH" 'Hello, {name}!' 'name=World'
    [ "$status" -eq 0 ]
    [ "$output" = 'Hello, World!' ]
}

@test "mixed: path segments with extension literal" {
    run bash "$URITEMPLATE_SH" '/files{/dir}/{name}.{ext}' \
        'dir=images' 'name=photo' 'ext=jpg'
    [ "$status" -eq 0 ]
    [ "$output" = '/files/images/photo.jpg' ]
}

@test "mixed: label + path + reserved + query" {
    run bash "$URITEMPLATE_SH" '{.env}/repo{+path}{?ref}' \
        'env=prod' 'path=/src/main' 'ref=HEAD'
    [ "$status" -eq 0 ]
    [ "$output" = '.prod/repo/src/main?ref=HEAD' ]
}

@test "mixed: multiple simple expressions interleaved with literals" {
    run bash "$URITEMPLATE_SH" '{scheme}://{host}:{port}/{path}' \
        'scheme=https' 'host=example.com' 'port=8443' 'path=api'
    [ "$status" -eq 0 ]
    [ "$output" = 'https://example.com:8443/api' ]
}

@test "mixed: undefined vars between defined ones leave no gap" {
    run bash "$URITEMPLATE_SH" 'prefix/{x}{y}{z}/suffix' 'x=A' 'z=C'
    [ "$status" -eq 0 ]
    [ "$output" = 'prefix/AC/suffix' ]
}

@test "mixed: query string appended to full URL literal" {
    run bash "$URITEMPLATE_SH" 'http://search.example.com/find{?q,lang,page}' \
        'q=uri templates' 'lang=en' 'page=1'
    [ "$status" -eq 0 ]
    [ "$output" = 'http://search.example.com/find?q=uri%20templates&lang=en&page=1' ]
}

@test "mixed: path + exploded list + query" {
    run bash "$URITEMPLATE_SH" '/items{/ids*}{?sort}' \
        'ids[]=10' 'ids[]=20' 'ids[]=30' 'sort=asc'
    [ "$status" -eq 0 ]
    [ "$output" = '/items/10/20/30?sort=asc' ]
}

@test "mixed: fragment after path with reserved passthrough" {
    run bash "$URITEMPLATE_SH" 'http://example.com{+path}{#anchor}' \
        'path=/page/about' 'anchor=section-2'
    [ "$status" -eq 0 ]
    [ "$output" = 'http://example.com/page/about#section-2' ]
}

@test "mixed: semicolon params after path literal" {
    run bash "$URITEMPLATE_SH" '/map{;lat,lon,zoom}' \
        'lat=37' 'lon=-122' 'zoom=12'
    [ "$status" -eq 0 ]
    [ "$output" = '/map;lat=37;lon=-122;zoom=12' ]
}

# ── RFC 6570 Appendix B representative cases ──────────────────────────────────
# Variables: var=value, hello=Hello World, path=/foo/bar
# list=(red, green, blue), keys=(semi=;, dot=., comma=,)

@test "RFC B: {var:3}" {
    run bash "$URITEMPLATE_SH" '{var:3}' 'var=value'
    [ "$status" -eq 0 ]
    [ "$output" = 'val' ]
}

@test "RFC B: {/var,x}/here" {
    run bash "$URITEMPLATE_SH" '{/var,x}/here' 'var=value' 'x=1024'
    [ "$status" -eq 0 ]
    [ "$output" = '/value/1024/here' ]
}

@test "RFC B: {.var:3}" {
    run bash "$URITEMPLATE_SH" 'X{.var:3}' 'var=value'
    [ "$status" -eq 0 ]
    [ "$output" = 'X.val' ]
}

@test "RFC B: {+keys*} map explode with reserved chars" {
    run bash "$URITEMPLATE_SH" '{+keys*}' \
        'keys[semi]=;' 'keys[dot]=.' 'keys[comma]=,'
    [ "$status" -eq 0 ]
    [[ "$output" == *'comma=,'* ]]
    [[ "$output" == *'dot=.'* ]]
    [[ "$output" == *'semi=;'* ]]
}

@test "RFC B: {?q,lang} form-style query" {
    run bash "$URITEMPLATE_SH" '{?q,lang}' 'q=hello world' 'lang=en'
    [ "$status" -eq 0 ]
    [ "$output" = '?q=hello%20world&lang=en' ]
}

@test "RFC B: {#path,6}/here fragment with multiple" {
    run bash "$URITEMPLATE_SH" '{#path}/here' 'path=/foo/bar'
    [ "$status" -eq 0 ]
    [ "$output" = '#/foo/bar/here' ]
}

# ── stdin template input ───────────────────────────────────────────────────────

@test "uritemplate.sh: reads template from stdin when no args given" {
    run bash "$URITEMPLATE_SH" <<< '{var}'
    [ "$status" -eq 0 ]
    [ "$output" = '' ]
}

@test "uritemplate.sh: reads template from stdin using - sentinel with bindings" {
    run bash "$URITEMPLATE_SH" - 'var=hello' <<< '{var}'
    [ "$status" -eq 0 ]
    [ "$output" = 'hello' ]
}

@test "uritemplate.sh: stdin template with query operator via - sentinel" {
    run bash "$URITEMPLATE_SH" - 'q=bash' 'lang=en' <<< '{?q,lang}'
    [ "$status" -eq 0 ]
    [ "$output" = '?q=bash&lang=en' ]
}

@test "uritemplate.sh: stdin template with list explode via - sentinel" {
    run bash "$URITEMPLATE_SH" - 'list[]=a' 'list[]=b' 'list[]=c' <<< '{/list*}'
    [ "$status" -eq 0 ]
    [ "$output" = '/a/b/c' ]
}

@test "uritemplate.sh: only first stdin line is used as template" {
    run bash "$URITEMPLATE_SH" - 'x=1' <<< $'{x}\nextra line'
    [ "$status" -eq 0 ]
    [ "$output" = '1' ]
}
