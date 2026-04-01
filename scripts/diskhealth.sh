#!/bin/bash

# ============================================================
#   diskhealth v2.1 – unified disk health CLI
#
#   HEALTHY / ACCEPTABLE / DEGRADED / FAILING / IMMINENT FAILURE / FAILURE / ERROR
#
#   Modes:
#     --format human    (default)
#     --format json
#     --format diskinfo (for diskinfo.sh)
#
#   Improvements in v2.1:
#     - serial + model returned in all formats
#     - full JSON fallback restored
#     - RAM-based debug (no disk writes)
#     - debug footer only in human mode
#     - stable 7-field diskinfo format
#     - safe parsing (no eval needed in diskinfo)
# ============================================================

set -o pipefail

FORMAT="human"
TARGET_DEVICES=()
DEBUG_RAW=()

# -------------------------
# smartctl wrapper
# -------------------------
if [[ $EUID -eq 0 ]]; then
    SMARTCTL="smartctl"
else
    SMARTCTL="sudo -n smartctl"
fi

# -------------------------
# Parse CLI flags
# -------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --json)
            FORMAT="json"
            shift
            ;;
        --influx)
            FORMAT="influx"
            shift
            ;;            
        --diskinfo)
            FORMAT="diskinfo"
            shift
            ;;
        /dev/*)
            TARGET_DEVICES+=("$1")
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# -------------------------
# Device discovery
# -------------------------
if [[ ${#TARGET_DEVICES[@]} -eq 0 ]]; then
    while read -r name type; do
        [[ "$type" == "disk" ]] && TARGET_DEVICES+=("/dev/$name")
    done < <(lsblk -dn -o NAME,TYPE)
fi

# ============================================================
#   SATA health logic
# ============================================================
sata_health() {
    local realloc="$1" pending="$2" offline="$3" crc="$4" hours="$5" lcc="$6"

    if (( offline > 0 )); then echo "FAILURE|offline_unrecoverable"; return; fi

    if (( pending >= 5 )) || (( realloc >= 10 )) || { (( pending > 0 )) && (( realloc > 0 )); }; then
        echo "IMMINENT FAILURE|pending+realloc_critical"; return
    fi

    if (( hours > 100000 )) ||
       (( lcc > 3000000 )) ||
       { (( crc > 2000 )) && (( hours > 80000 )); } ||
       { (( crc > 2000 )) && (( lcc > 1000000 )); } ||
       { (( crc > 500 )) && (( hours > 50000 )); } ||
       { (( crc > 500 )) && (( lcc > 1000000 )); } ||
       { (( lcc > 1000000 )) && (( hours > 80000 )); }; then
        echo "FAILING|combined_slitasje"; return
    fi

    if (( pending > 0 )) ||
       (( realloc > 0 )) ||
       (( crc > 200 )) ||
       (( lcc > 600000 )) ||
       (( hours > 80000 )); then
        echo "DEGRADED|moderate_slitasje"; return
    fi

    if (( crc > 0 && crc <= 200 )) ||
       (( hours > 20000 && hours <= 80000 )) ||
       (( lcc > 300000 && lcc <= 600000 )); then
        echo "ACCEPTABLE|normal_aging"; return
    fi

    echo "HEALTHY|no_issues"
}

# ============================================================
#   NVMe health logic
# ============================================================
nvme_health() {
    local cw="$1" media="$2" errlog="$3" used="$4"

    if (( cw != 0 )); then echo "FAILURE|critical_warning"; return; fi
    if (( media > 10000 )) || (( used > 95 )); then echo "IMMINENT FAILURE|media_or_wear_critical"; return; fi
    if (( media >= 2000 && media <= 10000 )) || (( used > 90 && used <= 95 )); then echo "FAILING|heavy_slitasje"; return; fi
    if (( media >= 500 && media < 2000 )) || (( used > 85 && used <= 90 )); then echo "DEGRADED|moderate_slitasje"; return; fi
    if (( media > 0 && media < 500 )) ||
       (( used > 70 && used <= 85 )) ||
       { (( errlog > 0 )) && (( media == 0 )); }; then
        echo "ACCEPTABLE|normal_aging"; return; fi

    echo "HEALTHY|no_issues"
}

# ============================================================
#   Collect disk info
# ============================================================
collect_disk() {
    local dev="$1"
    local out serial model

    # -------------------------
    # NVMe
    # -------------------------
    if [[ "$dev" == /dev/nvme* ]]; then
        if ! out="$($SMARTCTL -x "$dev" 2>/dev/null)"; then
            echo "$dev|NVMe|ERROR|smartctl_failed|||"
            return
        fi

        serial=$(awk -F: '/Serial Number/ {print $2}' <<< "$out" | xargs)
        model=$(awk -F: '/Model Number/ {print $2}' <<< "$out" | xargs)

        local cw media errlog used
        read cw media errlog used <<< "$(awk '
            /Critical Warning/ {cw=$3}
            /Media and Data Integrity Errors/ {m=$6}
            /Error Information Log Entries/ {e=$6}
            /Percentage Used/ {u=$3}
            END { printf "%s %s %s %s\n", cw+0, m+0, e+0, u+0 }
        ' <<< "$out")"

        if [[ -z "$cw" ]]; then
            DEBUG_RAW+=("$dev:$out")
            echo "$dev|NVMe|ERROR|parse_failed|||"
            return
        fi

        IFS="|" read status reason <<< "$(nvme_health "$cw" "$media" "$errlog" "$used")"

        echo "$dev|NVMe|$status|$reason|cw=$cw media=$media errlog=$errlog used=$used|$serial|$model"
        return
    fi

    # -------------------------
    # SATA
    # -------------------------
    if ! out="$($SMARTCTL -A -i "$dev" 2>/dev/null)"; then
        echo "$dev|SATA|ERROR|smartctl_failed|||"
        return
    fi

    serial=$(awk -F: '/Serial Number/ {print $2}' <<< "$out" | xargs)
    model=$(awk -F: '/Device Model|Product/ {print $2}' <<< "$out" | xargs)

    local realloc pending offline crc hours lcc
    read realloc pending offline crc hours lcc <<< "$(awk '
        /Reallocated_Sector_Ct/ {r=$10}
        /Current_Pending_Sector/ {p=$10}
        /Offline_Uncorrectable/ {o=$10}
        /UDMA_CRC_Error_Count/ {c=$10}
        /Power_On_Hours/ {h=$10}
        /Load_Cycle_Count/ {l=$10}
        END { printf "%s %s %s %s %s %s\n", r+0, p+0, o+0, c+0, h+0, l+0 }
    ' <<< "$out")"

    if [[ -z "$realloc" ]]; then
        DEBUG_RAW+=("$dev:$out")
        echo "$dev|SATA|ERROR|parse_failed|||"
        return
    fi

    IFS="|" read status reason <<< "$(sata_health "$realloc" "$pending" "$offline" "$crc" "$hours" "$lcc")"

    echo "$dev|SATA|$status|$reason|realloc=$realloc pending=$pending offline=$offline crc=$crc hours=$hours lcc=$lcc|$serial|$model"
}

# ============================================================
#   Output formatters
# ============================================================
format_human() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5" serial="$6" model="$7"

    printf "\e[1m%s\e[0m (%s)\n" "$dev" "$type"
    printf "  Model:   %s\n" "$model"
    printf "  Serial:  %s\n" "$serial"
    printf "  Status:  %s\n" "$status"
    printf "  Reason:  %s\n" "$reason"
    printf "  Metrics: %s\n" "$metrics"
    echo
}

format_diskinfo() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5" serial="$6" model="$7"
    echo "$(basename "$dev") | $type | $status | serial=$serial | model=$model"
    echo "    $metrics"
}

format_json() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5" serial="$6" model="$7"

    # jq version
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg dev "$dev" \
            --arg type "$type" \
            --arg status "$status" \
            --arg reason "$reason" \
            --arg serial "$serial" \
            --arg model "$model" \
            --arg metrics "$metrics" '
        {
            device: $dev,
            type: $type,
            status: $status,
            reason: $reason,
            serial: $serial,
            model: $model,
            metrics: (
                $metrics
                | split(" ")
                | map(select(length>0))
                | map(split("="))
                | map({(.[0]): (.[1]|tonumber? // .[1])})
                | add // {}
            )
        }'
        return
    fi

    # fallback JSON
    echo "{"
    echo "  \"device\": \"$dev\","
    echo "  \"type\": \"$type\","
    echo "  \"status\": \"$status\","
    echo "  \"reason\": \"$reason\","
    echo "  \"serial\": \"$serial\","
    echo "  \"model\": \"$model\","
    echo "  \"metrics\": {"

    local first=1
    for kv in $metrics; do
        key="${kv%%=*}"
        val="${kv#*=}"
        [[ -z "$key" ]] && continue

        if [[ $first -eq 1 ]]; then
            first=0
        else
            printf ",\n"
        fi

        if [[ "$val" =~ ^[0-9]+$ ]]; then
            printf "    \"%s\": %s" "$key" "$val"
        else
            printf "    \"%s\": \"%s\"" "$key" "$val"
        fi
    done

    echo ""
    echo "  }"
    echo "}"
}


format_influx() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5" serial="$6" model="$7"

    # Gjør tag-verdier Influx-sikre (ingen mellomrom)
    dev="${dev// /_}"
    type="${type// /_}"
    status="${status// /_}"
    reason="${reason// /_}"
    serial="${serial// /_}"
    model="${model// /_}"

    # Measurement + tags
    printf 'diskhealth,device=%s,type=%s,status=%s,reason=%s,serial=%s,model=%s ' \
        "$dev" "$type" "$status" "$reason" "$serial" "$model"

    # Fields
    local first=1
    for kv in $metrics; do
        key="${kv%%=*}"
        val="${kv#*=}"

        [[ -z "$key" ]] && continue

        if [[ $first -eq 1 ]]; then
            first=0
        else
            printf ','
        fi

        if [[ "$val" =~ ^[0-9]+$ ]]; then
            printf '%s=%si' "$key" "$val"
        else
            printf '%s="%s"' "$key" "$val"
        fi
    done

    printf '\n'
}



# ============================================================
#   Main
# ============================================================
JSON_ITEMS=()
for dev in "${TARGET_DEVICES[@]}"; do
    [[ -e "$dev" ]] || continue

    IFS="|" read dev type status reason metrics serial model <<< "$(collect_disk "$dev")"

    case "$FORMAT" in
        human)    format_human "$dev" "$type" "$status" "$reason" "$metrics" "$serial" "$model" ;;
        json)     JSON_ITEMS+=("$(format_json "$dev" "$type" "$status" "$reason" "$metrics" "$serial" "$model")") ;;
        influx)   format_influx "$dev" "$type" "$status" "$reason" "$metrics" "$serial" "$model" ;;
        diskinfo) format_diskinfo "$dev" "$type" "$status" "$reason" "$metrics" "$serial" "$model" ;;
        *)        format_human "$dev" "$type" "$status" "$reason" "$metrics" "$serial" "$model" ;;
    esac
done

# Output JSON array if json mode
if [[ "$FORMAT" == "json" ]]; then
    echo "["
    for ((i=0; i<${#JSON_ITEMS[@]}; i++)); do
        echo "  ${JSON_ITEMS[$i]}"
        if (( i < ${#JSON_ITEMS[@]} - 1 )); then
            echo "  ,"
        fi
    done
    echo "]"
    exit 0
fi


# -------------------------
# Debug footer (human mode only)
# -------------------------
if [[ "$FORMAT" == "human" && ${#DEBUG_RAW[@]} -gt 0 ]]; then
    echo -e "\e[1mDebug details for failed devices:\e[0m"
    for entry in "${DEBUG_RAW[@]}"; do
        dev="${entry%%:*}"
        raw="${entry#*:}"
        echo -e "\n--- $dev ---"
        echo "$raw"
    done
fi
