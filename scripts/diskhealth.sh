#!/bin/bash

# ============================================================
#   diskhealth – unified disk health CLI
#   HEALTHY / ACCEPTABLE / DEGRADED / FAILING / IMMINENT FAILURE / FAILURE / ERROR
#   Modes:
#     --format human    (default)
#     --format json
#     --format diskinfo (for diskinfo.sh)
# ============================================================

set -o pipefail

FORMAT="human"
TARGET_DEVICES=()

# -------------------------
# smartctl command wrapper
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

# -------------------------
# Debug logging for parse issues
# -------------------------
save_debug() {
    local dev="$1"
    local data="$2"
    mkdir -p /var/log/diskhealth
    echo "$data" > "/var/log/diskhealth/$(basename "$dev").log"
}

# ============================================================
#   SATA health logic (your model)
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
#   NVMe health logic (your model)
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
#   Collect and evaluate (single smartctl call per disk)
# ============================================================
collect_disk() {
    local dev="$1"
    local out

    # NVMe
    if [[ "$dev" == /dev/nvme* ]]; then
        if ! out="$($SMARTCTL -x "$dev" 2>/dev/null)"; then
            echo "$dev|NVMe|ERROR|smartctl_failed|"
            return
        fi

        local cw media errlog used
        read cw media errlog used <<< "$(awk '
            /Critical Warning/ {cw=$3}
            /Media and Data Integrity Errors/ {m=$6}
            /Error Information Log Entries/ {e=$6}
            /Percentage Used/ {u=$3}
            END { printf "%s %s %s %s\n", cw+0, m+0, e+0, u+0 }
        ' <<< "$out")"

        if [[ -z "$cw" || -z "$media" || -z "$errlog" || -z "$used" ]]; then
            save_debug "$dev" "$out"
            echo "$dev|NVMe|ERROR|parse_failed|"
            return
        fi

        IFS="|" read status reason <<< "$(nvme_health "$cw" "$media" "$errlog" "$used")"

        echo "$dev|NVMe|$status|$reason|cw=$cw media=$media errlog=$errlog used=$used"
        return
    fi

    # SATA (default)
    if ! out="$($SMARTCTL -A "$dev" 2>/dev/null)"; then
        echo "$dev|SATA|ERROR|smartctl_failed|"
        return
    fi

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

    if [[ -z "$realloc" || -z "$pending" || -z "$offline" || -z "$crc" || -z "$hours" || -z "$lcc" ]]; then
        save_debug "$dev" "$out"
        echo "$dev|SATA|ERROR|parse_failed|"
        return
    fi

    IFS="|" read status reason <<< "$(sata_health "$realloc" "$pending" "$offline" "$crc" "$hours" "$lcc")"

    echo "$dev|SATA|$status|$reason|realloc=$realloc pending=$pending offline=$offline crc=$crc hours=$hours lcc=$lcc"
}

# ============================================================
#   Output formatters
# ============================================================
format_human() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5"

    printf "\e[1m%s\e[0m (%s)\n" "$dev" "$type"
    printf "  Status:  %s\n" "$status"
    printf "  Reason:  %s\n" "$reason"
    if [[ -n "$metrics" ]]; then
        printf "  Metrics: %s\n" "$metrics"
    else
        printf "  Metrics: (none)\n"
    fi
    if [[ "$reason" == "parse_failed" ]]; then
        printf "  Debug:   /var/log/diskhealth/%s.log\n" "$(basename "$dev")"
    fi
    echo
}

format_diskinfo() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5"
    echo "$(basename "$dev") | $type | $status"
    if [[ -n "$metrics" ]]; then
        echo "    $metrics"
    else
        echo "    reason=$reason"
    fi
}

format_json() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5"

    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg dev "$dev" \
            --arg type "$type" \
            --arg status "$status" \
            --arg reason "$reason" \
            --arg metrics "$metrics" '
        {
            device: $dev,
            type: $type,
            status: $status,
            reason: $reason,
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

    echo "{"
    echo "  \"device\": \"$dev\","
    echo "  \"type\": \"$type\","
    echo "  \"status\": \"$status\","
    echo "  \"reason\": \"$reason\","
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
        printf "    \"%s\": %s" "$key" "$val"
    done

    echo ""
    echo "  }"
    echo "}"
}

# ============================================================
#   Main
# ============================================================
for dev in "${TARGET_DEVICES[@]}"; do
    [[ -e "$dev" ]] || continue

    IFS="|" read dev type status reason metrics <<< "$(collect_disk "$dev")"

    case "$FORMAT" in
        human)    format_human "$dev" "$type" "$status" "$reason" "$metrics" ;;
        json)     format_json "$dev" "$type" "$status" "$reason" "$metrics" ;;
        diskinfo) format_diskinfo "$dev" "$type" "$status" "$reason" "$metrics" ;;
        *)        format_human "$dev" "$type" "$status" "$reason" "$metrics" ;;
    esac
done
