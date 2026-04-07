#!/bin/bash
# diskhealth v2.4.1 – robust SMART health checker

set -o pipefail
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

FORMAT="human"
TARGET_DEVICES=()
DEBUG_RAW=()

if [[ $EUID -eq 0 ]]; then
    SMARTCTL="smartctl"
else
    SMARTCTL="sudo -n smartctl"
fi

PROFILE="auto"

# -----------------------------
# Profile thresholds
# -----------------------------
declare -A THRESH_REALLOC_IMMINENT=(
    [nas]=5 [nas_pro]=5 [enterprise]=3 [desktop]=10 [green]=20
)
declare -A THRESH_PENDING_IMMINENT=(
    [nas]=1 [nas_pro]=1 [enterprise]=1 [desktop]=2 [green]=3
)
declare -A THRESH_FAIL_HOURS=(
    [nas]=120000 [nas_pro]=140000 [enterprise]=180000 [desktop]=90000 [green]=60000
)
declare -A THRESH_FAIL_LCC=(
    [nas]=400000 [nas_pro]=500000 [enterprise]=800000 [desktop]=1500000 [green]=6000000
)
declare -A THRESH_DEGRADED_REALLOC=(
    [nas]=1 [nas_pro]=1 [enterprise]=1 [desktop]=1 [green]=5
)
declare -A THRESH_DEGRADED_HOURS=(
    [nas]=60000 [nas_pro]=80000 [enterprise]=120000 [desktop]=40000 [green]=30000
)
declare -A THRESH_DEGRADED_LCC=(
    [nas]=200000 [nas_pro]=200000 [enterprise]=300000 [desktop]=500000 [green]=2000000
)
declare -A THRESH_DEGRADED_CRC=(
    [nas]=50 [nas_pro]=50 [enterprise]=20 [desktop]=100 [green]=100
)
declare -A THRESH_ACCEPTABLE_HOURS_MIN=(
    [nas]=20000 [nas_pro]=20000 [enterprise]=30000 [desktop]=15000 [green]=10000
)
declare -A THRESH_ACCEPTABLE_HOURS_MAX=(
    [nas]=60000 [nas_pro]=80000 [enterprise]=120000 [desktop]=60000 [green]=30000
)
declare -A THRESH_ACCEPTABLE_LCC_MAX=(
    [nas]=200000 [nas_pro]=250000 [enterprise]=300000 [desktop]=300000 [green]=2000000
)
declare -A THRESH_ACCEPTABLE_CRC_MAX=(
    [nas]=10 [nas_pro]=10 [enterprise]=5 [desktop]=20 [green]=20
)

# -----------------------------
# Model → profile
# -----------------------------
classify_disk_type() {
    local model="$1"
    shopt -s nocasematch

    [[ "$model" =~ (RE|ABYX|Gold|Ultrastar) ]] && echo "enterprise" && return
    [[ "$model" =~ (Red.Pro) ]] && echo "nas_pro" && return
    [[ "$model" =~ (Red) ]] && echo "nas" && return
    [[ "$model" =~ (Green|EARS|EARX|EZRX|EZRZ) ]] && echo "green" && return
    [[ "$model" =~ (Blue|Black) ]] && echo "desktop" && return

    [[ "$model" =~ (NE[0-9]+) ]] && echo "nas_pro" && return
    [[ "$model" =~ (VN[0-9]+) ]] && echo "nas" && return
    [[ "$model" =~ (DM[0-9]+) ]] && echo "desktop" && return
    [[ "$model" =~ (Exos|Constellation) ]] && echo "enterprise" && return

    [[ "$model" =~ (MG[0-9]+) ]] && echo "enterprise" && return
    [[ "$model" =~ (N300) ]] && echo "nas" && return
    [[ "$model" =~ (P300|X300) ]] && echo "desktop" && return

    echo "nas"
}

select_profile() {
    [[ "$PROFILE" != "auto" ]] && { echo "$PROFILE"; return; }
    echo "$(classify_disk_type "$1")"
}

# -----------------------------
# USB bridge detection
# -----------------------------
detect_usb_id() {
    local dev="$1" info
    command -v udevadm >/dev/null 2>&1 || return
    info=$(udevadm info -q property -n "$dev" 2>/dev/null) || return
    grep -q '^ID_BUS=usb' <<<"$info" || return
    local vid pid
    vid=$(grep '^ID_VENDOR_ID=' <<<"$info" | cut -d= -f2)
    pid=$(grep '^ID_MODEL_ID='  <<<"$info" | cut -d= -f2)
    echo "${vid}:${pid}"
}

classify_usb_bridge() {
    case "$1" in
        0b05:1932) echo "ASUS_ROG_STRIX_ARION" ;;
        3346:1009) echo "SIPEED_NANO_KVM_STORAGE" ;;
        *)         echo "UNKNOWN_USB" ;;
    esac
}

# -----------------------------
# JSON helper
# -----------------------------
json_get() {
    local json="$1" key="$2"
    jq -r "$key // empty" <<<"$json" 2>/dev/null
}

# -----------------------------
# NVMe health (fixed)
# -----------------------------
nvme_health() {
    local cw="$1" media="$2" errlog="$3" used="$4"

    if (( cw != 0 )); then
        echo "FAILURE|critical_warning"
        return
    fi

    if (( media > 10000 )) || (( used > 95 )); then
        echo "IMMINENT FAILURE|media_or_wear_critical"
        return
    fi

    if (( media >= 2000 && media <= 10000 )) || (( used > 90 )); then
        echo "FAILING|heavy_slitasje"
        return
    fi

    if (( media >= 500 && media < 2000 )) || (( used > 85 )); then
        echo "DEGRADED|moderate_slitasje"
        return
    fi

    if (( media > 0 && media < 500 )) ||
       (( used > 70 )) ||
       (( errlog > 0 )); then
        echo "ACCEPTABLE|normal_aging"
        return
    fi

    echo "HEALTHY|no_issues"
}

# -----------------------------
# SATA HDD health
# -----------------------------
sata_hdd_health() {
    local realloc="$1" pending="$2" offline="$3" crc="$4" hours="$5" lcc="$6" model="$7"
    local prof; prof=$(select_profile "$model")

    (( offline > 0 )) && { echo "FAILURE|offline_unrecoverable"; return; }

    if (( realloc >= THRESH_REALLOC_IMMINENT[$prof] )) ||
       (( pending >= THRESH_PENDING_IMMINENT[$prof] )); then
        echo "IMMINENT FAILURE|realloc_or_pending_critical"; return
    fi

    if (( hours >= THRESH_FAIL_HOURS[$prof] )) ||
       (( lcc   >= THRESH_FAIL_LCC[$prof] )); then
        echo "FAILING|combined_slitasje"; return
    fi

    if (( realloc >= THRESH_DEGRADED_REALLOC[$prof] )) ||
       (( hours   >= THRESH_DEGRADED_HOURS[$prof] )) ||
       (( lcc     >= THRESH_DEGRADED_LCC[$prof] )) ||
       (( crc     >= THRESH_DEGRADED_CRC[$prof] )); then
        echo "DEGRADED|moderate_slitasje"; return
    fi

    if { (( hours >= THRESH_ACCEPTABLE_HOURS_MIN[$prof] )) &&
         (( hours <= THRESH_ACCEPTABLE_HOURS_MAX[$prof] )); } ||
       (( lcc > 0 && lcc <= THRESH_ACCEPTABLE_LCC_MAX[$prof] )) ||
       (( crc > 0 && crc <= THRESH_ACCEPTABLE_CRC_MAX[$prof] )); then
        echo "ACCEPTABLE|normal_aging"; return
    fi

    echo "HEALTHY|no_issues"
}

# -----------------------------
# SATA SSD health
# -----------------------------
sata_ssd_health() {
    local realloc="$1" pending="$2" offline="$3" crc="$4" hours="$5" model="$6"
    local prof; prof=$(select_profile "$model")

    (( offline > 0 )) && { echo "FAILURE|offline_unrecoverable"; return; }
    (( realloc >= 5 )) || (( pending >= 1 )) && { echo "IMMINENT FAILURE|ssd_nand_errors"; return; }
    (( hours >= THRESH_FAIL_HOURS[$prof] )) && { echo "FAILING|heavy_aging"; return; }

    if (( hours >= THRESH_DEGRADED_HOURS[$prof] )) ||
       (( crc   >= THRESH_DEGRADED_CRC[$prof] )); then
        echo "DEGRADED|moderate_aging"; return
    fi

    if (( hours >= THRESH_ACCEPTABLE_HOURS_MIN[$prof] )) &&
       (( hours <= THRESH_ACCEPTABLE_HOURS_MAX[$prof] )); then
        echo "ACCEPTABLE|normal_aging"; return
    fi

    echo "HEALTHY|no_issues"
}

sata_health() {
    local media="$1"; shift
    if [[ "$media" == "SSD" ]]; then
        sata_ssd_health "$@"
    else
        sata_hdd_health "$@"
    fi
}

# -----------------------------
# Device validation
# -----------------------------
valid_dev() {
    [[ "$1" =~ ^/dev/[a-zA-Z0-9]+$ ]]
}

# -----------------------------
# Collect disk info
# -----------------------------
collect_disk() {
    local dev="$1"
    valid_dev "$dev" || return

    # USB detection
    local usb_id usb_class
    usb_id=$(detect_usb_id "$dev")
    if [[ -n "$usb_id" ]]; then
        usb_class=$(classify_usb_bridge "$usb_id")
        case "$usb_class" in
            ASUS_ROG_STRIX_ARION|SIPEED_NANO_KVM_STORAGE)
                echo "$dev|USB|UNSUPPORTED|usb_bridge_no_smart|bridge=$usb_class||"
                return
                ;;
            UNKNOWN_USB)
                if ! timeout 5 $SMARTCTL -A -d sat "$dev" >/dev/null 2>&1; then
                    echo "$dev|USB|UNSUPPORTED|usb_bridge_no_smart|bridge=UNKNOWN_USB||"
                    return
                fi
                ;;
        esac
    fi

    # NVMe
    if [[ "$dev" == /dev/nvme* ]]; then
        local json
        json=$(timeout 10 $SMARTCTL -j -x "$dev" 2>/dev/null) || {
            echo "$dev|NVMe|ERROR|smartctl_failed|||"; return; }

        local serial model cw media errlog used
        serial=$(json_get "$json" '.serial_number')
        model=$(json_get "$json" '.model_name')
        cw=$(json_get "$json" '.nvme_smart_health_information_log.critical_warning')
        media=$(json_get "$json" '.nvme_smart_health_information_log.media_errors')
        errlog=$(json_get "$json" '.error_log.entries')
        used=$(json_get "$json" '.nvme_smart_health_information_log.percentage_used')

        cw=${cw:-0}; media=${media:-0}; errlog=${errlog:-0}; used=${used:-0}

        if [[ -z "$serial" || -z "$model" ]]; then
            DEBUG_RAW+=("$dev:$json")
        fi

        IFS="|" read status reason <<< "$(nvme_health "$cw" "$media" "$errlog" "$used")"
        echo "$dev|NVMe|$status|$reason|cw=$cw media=$media errlog=$errlog used=$used|$serial|$model"
        return
    fi

    # SATA JSON
    local json
    json=$(timeout 10 $SMARTCTL -j -A -i "$dev" 2>/dev/null)

    if [[ -n "$json" && $(command -v jq) ]]; then
        local serial model media_type realloc pending offline crc hours lcc rotation

        serial=$(json_get "$json" '.serial_number')
        model=$(json_get "$json" '.model_name')
        rotation=$(json_get "$json" '.rotation_rate')

        if [[ "$rotation" == "0" ]]; then
            media_type="SSD"
        else
            media_type="HDD"
        fi

        realloc=$(json_get "$json" '.ata_smart_attributes.table[] | select(.name=="Reallocated_Sector_Ct").raw.value')
        pending=$(json_get "$json" '.ata_smart_attributes.table[] | select(.name=="Current_Pending_Sector").raw.value')
        offline=$(json_get "$json" '.ata_smart_attributes.table[] | select(.name=="Offline_Uncorrectable").raw.value')
        crc=$(json_get "$json" '.ata_smart_attributes.table[] | select(.name=="UDMA_CRC_Error_Count").raw.value')
        hours=$(json_get "$json" '.power_on_time.hours')
        lcc=$(json_get "$json" '.ata_smart_attributes.table[] | select(.name=="Load_Cycle_Count").raw.value')

        realloc=${realloc:-0}; pending=${pending:-0}; offline=${offline:-0}
        crc=${crc:-0}; hours=${hours:-0}; lcc=${lcc:-0}

        if [[ -z "$serial" || -z "$model" ]]; then
            DEBUG_RAW+=("$dev:$json")
        fi


        IFS="|" read status reason <<< "$(sata_health "$media_type" "$realloc" "$pending" "$offline" "$crc" "$hours" "$lcc" "$model")"
        echo "$dev|SATA-$media_type|$status|$reason|realloc=$realloc pending=$pending offline=$offline crc=$crc hours=$hours lcc=$lcc|$serial|$model"
        return
    fi

    # Fallback plain text
    local out
    out=$(timeout 10 $SMARTCTL -A -i "$dev" 2>/dev/null) || {
        echo "$dev|SATA|ERROR|smartctl_failed|||"; return; }

    local serial model
    serial=$(awk -F: '/Serial Number/ {print $2}' <<<"$out" | xargs)
    model=$(awk -F: '/Device Model|Product/ {print $2}' <<<"$out" | xargs)

    local realloc pending offline crc hours lcc
    realloc=$(awk '/Reallocated_Sector_Ct/ {print $NF}' <<<"$out")
    pending=$(awk '/Current_Pending_Sector/ {print $NF}' <<<"$out")
    offline=$(awk '/Offline_Uncorrectable/ {print $NF}' <<<"$out")
    crc=$(awk '/UDMA_CRC_Error_Count/ {print $NF}' <<<"$out")
    hours=$(awk '/Power_On_Hours/ {print $NF}' <<<"$out")
    lcc=$(awk '/Load_Cycle_Count/ {print $NF}' <<<"$out")

    realloc=${realloc:-0}; pending=${pending:-0}; offline=${offline:-0}
    crc=${crc:-0}; hours=${hours:-0}; lcc=${lcc:-0}

    if [[ -z "$serial" || -z "$model" ]]; then
        DEBUG_RAW+=("$dev:$out")
    fi

    local media_type
    if grep -qi "Solid State Device" <<<"$out" || grep -qi "Non-rotating media" <<<"$out" || grep -qi "SSD" <<<"$model"; then
        media_type="SSD"
    else
        media_type="HDD"
    fi

    IFS="|" read status reason <<< "$(sata_health "$media_type" "$realloc" "$pending" "$offline" "$crc" "$hours" "$lcc" "$model")"
    echo "$dev|SATA-$media_type|$status|$reason|realloc=$realloc pending=$pending offline=$offline crc=$crc hours=$hours lcc=$lcc|$serial|$model"
}

# -----------------------------
# JSON escaping
# -----------------------------
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# -----------------------------
# Output formatting
# -----------------------------
format_human() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5" serial="$6" model="$7"
    printf "\e[1m%s\e[0m (%s)\n" "$dev" "$type"
    printf "  Model:   %s\n" "$model"
    printf "  Serial:  %s\n" "$serial"
    printf "  Status:  %s\n" "$status"
    printf "  Reason:  %s\n" "$reason"
    printf "  Metrics: %s\n\n" "$metrics"
}

print_debug_raw() {
    echo "----- DEBUG RAW BEGIN -----" >&2
    for entry in "${DEBUG_RAW[@]}"; do
        echo "$entry" >&2
        echo "---------------------------" >&2
    done
    echo "----- DEBUG RAW END -----" >&2
}


format_diskinfo() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5" serial="$6" model="$7"
    echo "$(basename "$dev") | $type | $status | serial=$serial | model=$model"
    echo "    $metrics"
}

format_json() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5" serial="$6" model="$7"

    # If jq exists, use proper JSON construction
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
                | map({(.[0]): (.[1] | tonumber? // .[1])})
                | add
            )
        }'
        return
    fi

    # Manual JSON fallback
    echo "{"
    echo "  \"device\": \"$(json_escape "$dev")\","
    echo "  \"type\": \"$(json_escape "$type")\","
    echo "  \"status\": \"$(json_escape "$status")\","
    echo "  \"reason\": \"$(json_escape "$reason")\","
    echo "  \"serial\": \"$(json_escape "$serial")\","
    echo "  \"model\": \"$(json_escape "$model")\","
    echo "  \"metrics\": {"

    local first=1
    for kv in $metrics; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        [[ -z "$key" ]] && continue

        [[ $first -eq 1 ]] || printf ",\n"
        first=0

        if [[ "$val" =~ ^[0-9]+$ ]]; then
            printf "    \"%s\": %s" "$key" "$val"
        else
            printf "    \"%s\": \"%s\"" "$key" "$(json_escape "$val")"
        fi
    done

    echo ""
    echo "  }"
    echo "}"
}

format_influx() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5" serial="$6" model="$7"

    printf 'diskhealth,device=%s,type=%s,status=%s,reason=%s,serial=%s,model=%s ' \
        "${dev// /_}" "${type// /_}" "${status// /_}" "${reason// /_}" "${serial// /_}" "${model// /_}"

    printf 'device="%s",type="%s",status="%s",reason="%s",serial="%s",model="%s"' \
        "$dev" "$type" "$status" "$reason" "$serial" "$model"

    for kv in $metrics; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        [[ -z "$key" ]] && continue
        printf ',%s=%si' "$key" "$val"
    done

    printf '\n'
}

format_diskinfo() {
    local dev="$1" type="$2" status="$3" reason="$4" metrics="$5" serial="$6" model="$7"
    echo "$(basename "$dev") | $type | $status | serial=$serial | model=$model"
    echo "    $metrics"
}

# -----------------------------
# Argument parsing
# -----------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            DEBUG_MODE=1
            shift
            ;;
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
        --profile)
            PROFILE="$2"
            shift 2
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

# -----------------------------
# Auto-detect disks if none provided
# -----------------------------
if [[ ${#TARGET_DEVICES[@]} -eq 0 ]]; then
    while read -r name type; do
        [[ "$type" == "disk" ]] && TARGET_DEVICES+=("/dev/$name")
    done < <(lsblk -dn -o NAME,TYPE)
fi


JSON_ITEMS=()

for dev in "${TARGET_DEVICES[@]}"; do
    [[ -e "$dev" ]] || continue

    IFS="|" read dev type status reason metrics serial model <<< "$(collect_disk "$dev")"

    case "$FORMAT" in
        human)
            format_human "$dev" "$type" "$status" "$reason" "$metrics" "$serial" "$model"
            ;;
        diskinfo)
            format_diskinfo "$dev" "$type" "$status" "$reason" "$metrics" "$serial" "$model"
            ;;
        influx)
            format_influx "$dev" "$type" "$status" "$reason" "$metrics" "$serial" "$model"
            ;;
        json)
            JSON_ITEMS+=("$(format_json "$dev" "$type" "$status" "$reason" "$metrics" "$serial" "$model")")
            ;;
        *)
            format_human "$dev" "$type" "$status" "$reason" "$metrics" "$serial" "$model"
            ;;
    esac
done

if [[ "$FORMAT" == "json" ]]; then
    echo "["
    for ((i=0; i<${#JSON_ITEMS[@]}; i++)); do
        echo "  ${JSON_ITEMS[$i]}"
        (( i < ${#JSON_ITEMS[@]} - 1 )) && echo "  ,"
    done
    echo "]"
fi

if [[ "$DEBUG_MODE" == 1 ]]; then
    print_debug_raw
fi