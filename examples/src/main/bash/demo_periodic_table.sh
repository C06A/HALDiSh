#!/usr/bin/env bash
# =============================================================================
# demo_periodic_table.sh — browse the periodic table interactively with menu.sh
#
# Run after installing the archive:
#   bash HALDiSh-0.1.0.run --prefix ~/mylibs
#   bash demo_periodic_table.sh
# =============================================================================
set -euo pipefail

# ── load the library (also adds the install dir to PATH) ─────────────────────
LIB_DIR="${HAL_LIB_DIR:-${HOME}/.local/lib/haldish}"
source "${LIB_DIR}/env.sh"

# ── element database: "Z|Symbol|Name|Weight|Category" ────────────────────────
ELEMENTS=(
    "1|H|Hydrogen|1.008|Reactive nonmetal"
    "2|He|Helium|4.003|Noble gas"
    "3|Li|Lithium|6.941|Alkali metal"
    "4|Be|Beryllium|9.012|Alkaline earth metal"
    "5|B|Boron|10.811|Metalloid"
    "6|C|Carbon|12.011|Reactive nonmetal"
    "7|N|Nitrogen|14.007|Reactive nonmetal"
    "8|O|Oxygen|15.999|Reactive nonmetal"
    "9|F|Fluorine|18.998|Halogen"
    "10|Ne|Neon|20.180|Noble gas"
    "11|Na|Sodium|22.990|Alkali metal"
    "12|Mg|Magnesium|24.305|Alkaline earth metal"
    "13|Al|Aluminum|26.982|Post-transition metal"
    "14|Si|Silicon|28.086|Metalloid"
    "15|P|Phosphorus|30.974|Reactive nonmetal"
    "16|S|Sulfur|32.065|Reactive nonmetal"
    "17|Cl|Chlorine|35.453|Halogen"
    "18|Ar|Argon|39.948|Noble gas"
    "19|K|Potassium|39.098|Alkali metal"
    "20|Ca|Calcium|40.078|Alkaline earth metal"
    "21|Sc|Scandium|44.956|Transition metal"
    "22|Ti|Titanium|47.867|Transition metal"
    "23|V|Vanadium|50.942|Transition metal"
    "24|Cr|Chromium|51.996|Transition metal"
    "25|Mn|Manganese|54.938|Transition metal"
    "26|Fe|Iron|55.845|Transition metal"
    "27|Co|Cobalt|58.933|Transition metal"
    "28|Ni|Nickel|58.693|Transition metal"
    "29|Cu|Copper|63.546|Transition metal"
    "30|Zn|Zinc|65.38|Transition metal"
    "31|Ga|Gallium|69.723|Post-transition metal"
    "32|Ge|Germanium|72.630|Metalloid"
    "33|As|Arsenic|74.922|Metalloid"
    "34|Se|Selenium|78.971|Reactive nonmetal"
    "35|Br|Bromine|79.904|Halogen"
    "36|Kr|Krypton|83.798|Noble gas"
    "37|Rb|Rubidium|85.468|Alkali metal"
    "38|Sr|Strontium|87.62|Alkaline earth metal"
    "39|Y|Yttrium|88.906|Transition metal"
    "40|Zr|Zirconium|91.224|Transition metal"
    "41|Nb|Niobium|92.906|Transition metal"
    "42|Mo|Molybdenum|95.96|Transition metal"
    "43|Tc|Technetium|98|Transition metal"
    "44|Ru|Ruthenium|101.07|Transition metal"
    "45|Rh|Rhodium|102.906|Transition metal"
    "46|Pd|Palladium|106.42|Transition metal"
    "47|Ag|Silver|107.868|Transition metal"
    "48|Cd|Cadmium|112.411|Transition metal"
    "49|In|Indium|114.818|Post-transition metal"
    "50|Sn|Tin|118.710|Post-transition metal"
    "51|Sb|Antimony|121.760|Metalloid"
    "52|Te|Tellurium|127.60|Metalloid"
    "53|I|Iodine|126.904|Halogen"
    "54|Xe|Xenon|131.293|Noble gas"
    "55|Cs|Cesium|132.905|Alkali metal"
    "56|Ba|Barium|137.327|Alkaline earth metal"
    "57|La|Lanthanum|138.905|Lanthanide"
    "58|Ce|Cerium|140.116|Lanthanide"
    "59|Pr|Praseodymium|140.908|Lanthanide"
    "60|Nd|Neodymium|144.242|Lanthanide"
    "61|Pm|Promethium|145|Lanthanide"
    "62|Sm|Samarium|150.36|Lanthanide"
    "63|Eu|Europium|151.964|Lanthanide"
    "64|Gd|Gadolinium|157.25|Lanthanide"
    "65|Tb|Terbium|158.925|Lanthanide"
    "66|Dy|Dysprosium|162.500|Lanthanide"
    "67|Ho|Holmium|164.930|Lanthanide"
    "68|Er|Erbium|167.259|Lanthanide"
    "69|Tm|Thulium|168.934|Lanthanide"
    "70|Yb|Ytterbium|173.054|Lanthanide"
    "71|Lu|Lutetium|174.967|Lanthanide"
    "72|Hf|Hafnium|178.49|Transition metal"
    "73|Ta|Tantalum|180.948|Transition metal"
    "74|W|Tungsten|183.84|Transition metal"
    "75|Re|Rhenium|186.207|Transition metal"
    "76|Os|Osmium|190.23|Transition metal"
    "77|Ir|Iridium|192.217|Transition metal"
    "78|Pt|Platinum|195.084|Transition metal"
    "79|Au|Gold|196.967|Transition metal"
    "80|Hg|Mercury|200.592|Transition metal"
    "81|Tl|Thallium|204.383|Post-transition metal"
    "82|Pb|Lead|207.2|Post-transition metal"
    "83|Bi|Bismuth|208.980|Post-transition metal"
    "84|Po|Polonium|209|Post-transition metal"
    "85|At|Astatine|210|Halogen"
    "86|Rn|Radon|222|Noble gas"
    "87|Fr|Francium|223|Alkali metal"
    "88|Ra|Radium|226|Alkaline earth metal"
    "89|Ac|Actinium|227|Actinide"
    "90|Th|Thorium|232.038|Actinide"
    "91|Pa|Protactinium|231.036|Actinide"
    "92|U|Uranium|238.029|Actinide"
    "93|Np|Neptunium|237|Actinide"
    "94|Pu|Plutonium|244|Actinide"
    "95|Am|Americium|243|Actinide"
    "96|Cm|Curium|247|Actinide"
    "97|Bk|Berkelium|247|Actinide"
    "98|Cf|Californium|251|Actinide"
    "99|Es|Einsteinium|252|Actinide"
    "100|Fm|Fermium|257|Actinide"
    "101|Md|Mendelevium|258|Actinide"
    "102|No|Nobelium|259|Actinide"
    "103|Lr|Lawrencium|266|Actinide"
    "104|Rf|Rutherfordium|267|Transition metal"
    "105|Db|Dubnium|268|Transition metal"
    "106|Sg|Seaborgium|271|Transition metal"
    "107|Bh|Bohrium|272|Transition metal"
    "108|Hs|Hassium|277|Transition metal"
    "109|Mt|Meitnerium|278|Transition metal"
    "110|Ds|Darmstadtium|281|Transition metal"
    "111|Rg|Roentgenium|282|Transition metal"
    "112|Cn|Copernicium|285|Transition metal"
    "113|Nh|Nihonium|286|Post-transition metal"
    "114|Fl|Flerovium|289|Post-transition metal"
    "115|Mc|Moscovium|290|Post-transition metal"
    "116|Lv|Livermorium|293|Post-transition metal"
    "117|Ts|Tennessine|294|Halogen"
    "118|Og|Oganesson|294|Noble gas"
)

# ── helpers ───────────────────────────────────────────────────────────────────

# Print all element data sorted by the given order (name|symbol|number|weight).
_sorted_elements() {
    local order=$1
    local -a flags
    case "$order" in
        name)   flags=(-t'|' -k3,3)  ;;
        symbol) flags=(-t'|' -k2,2)  ;;
        number) flags=(-t'|' -k1,1n) ;;
        weight) flags=(-t'|' -k4,4n) ;;
    esac
    printf '%s\n' "${ELEMENTS[@]}" | sort "${flags[@]}"
}

# Emit one menu option line per element in the requested sort order.
# All lines except number-order contain [Z=N] for reverse-lookup.
_element_options() {
    local order=$1
    _sorted_elements "$order" | while IFS='|' read -r z sym name weight cat; do
        case "$order" in
            name)   printf '%-14s  %-4s  %8s u  [Z=%3d]\n' "$name"   "$sym"  "$weight" "$z" ;;
            symbol) printf '%-4s  %-14s  %8s u  [Z=%3d]\n' "$sym"    "$name" "$weight" "$z" ;;
            number) printf '%3d.  %-4s  %-14s  %8s u\n'    "$z"      "$sym"  "$name"   "$weight" ;;
            weight) printf '%8s u  %-4s  %-14s  [Z=%3d]\n' "$weight" "$sym"  "$name"   "$z" ;;
        esac
    done
}

# Print a formatted info card for an element entry (Z|Sym|Name|Weight|Cat).
_show_element() {
    local z sym name weight cat
    IFS='|' read -r z sym name weight cat <<< "$1"
    printf '\n'
    printf '  ┌──────────────────────────────────────┐\n'
    printf '  │  %-4s  %-30s  │\n' "$sym" "$name"
    printf '  │  Atomic number : %-20d  │\n' "$z"
    printf '  │  Atomic weight : %-18s u  │\n' "$weight"
    printf '  │  Category      : %-20s  │\n' "$cat"
    printf '  └──────────────────────────────────────┘\n'
    printf '\n'
}

# Open the Wikipedia page for the element, or print the URL as a fallback.
_open_wiki() {
    local name=$1
    local url="https://en.wikipedia.org/wiki/${name}"
    if command -v open >/dev/null 2>&1; then
        open "$url"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url"
    else
        hal::log::warn "No browser opener found. Wiki URL:"
        printf '  %s\n' "$url"
    fi
}

# Return the element entry string for a given atomic number Z.
_find_by_z() {
    local target=$1 entry
    for entry in "${ELEMENTS[@]}"; do
        [[ "${entry%%|*}" == "$target" ]] && { printf '%s' "$entry"; return 0; }
    done
    return 1
}

# ── main loop ─────────────────────────────────────────────────────────────────

while true; do

    # ── level 1: choose sort order ────────────────────────────────────────────
    sort_choice=$(menu.sh "Periodic table — browse by" \
        "Element name" \
        "Element symbol" \
        "Atomic number" \
        "Atomic weight" \
        "Exit")

    echo

    [[ "$sort_choice" == "Exit" ]] && break

    case "$sort_choice" in
        "Element name")   order=name   ;;
        "Element symbol") order=symbol ;;
        "Atomic number")  order=number ;;
        "Atomic weight")  order=weight ;;
    esac

    # ── level 2: choose an element ────────────────────────────────────────────
    while true; do
        elem_choice=$({
            printf '← Back to sort menu\n'
            _element_options "$order"
        } | menu.sh "Select an element")

        echo

        [[ "$elem_choice" == "← Back to sort menu" ]] && break

        # Resolve atomic number from the selected option text.
        if [[ "$order" == "number" ]]; then
            # Format: "  N.  Sym  Name  Weight u" — Z is the number before the dot.
            z="${elem_choice%%.*}"
            z="${z// /}"
        else
            # All other formats end with [Z=  N].
            if [[ "$elem_choice" =~ \[Z=[[:space:]]*([0-9]+)\] ]]; then
                z="${BASH_REMATCH[1]}"
            else
                hal::log::warn "Could not determine element — please try again."
                continue
            fi
        fi

        if ! elem_entry=$(_find_by_z "$z"); then
            hal::log::warn "Element Z=$z not found in database."
            continue
        fi

        # ── level 3: show info and offer actions ──────────────────────────────
        while true; do
            _show_element "$elem_entry"

            IFS='|' read -r _ _ elem_name _ _ <<< "$elem_entry"
            action=$(menu.sh "What next?" \
                "Open Wikipedia page for ${elem_name}" \
                "← Back to element list")

                echo

            if [[ "$action" == "← Back to element list" ]]; then
                break
            else
                _open_wiki "$elem_name"
            fi
        done
    done

done

hal::log::ok "Goodbye!"
