#!/bin/bash

# ============================================================
#   diskinfo v5.0 – RAID + BCACHE:Mode + downgraded NVMe
#   RAW \033 for neofetch, --print for real colors
# ============================================================

set -o pipefail

CACHE="/dev/shm/diskinfo.cache"
HIST="/var/lib/diskinfo/history.db"
LOCK="/var/lib/diskinfo/history.lock"
WINDOW_SIZE=5

READ_ONLY=0
PRINT_MODE=0

# -------------------------
# Arg parsing
# -------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --read-only)
            READ_ONLY=1
            shift
            ;;
        --print)
            PRINT_MODE=1
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if (( READ_ONLY == 0 )); then
    mkdir -p /var/lib/diskinfo
fi

# -------------------------
# Sample window helper
# -------------------------
update_window() {
    local csv="$1"
    local new="$2"

    if [[ -z "$csv" ]]; then
        echo "$new"
        return
    fi

    local updated="$csv,$new"
    local count
    count=$(echo "$updated" | awk -F',' '{print NF}')

    if (( count > WINDOW_SIZE )); then
        echo "$updated" | awk -F',' -v max="$WINDOW_SIZE" '{
            n=split($0,a,",");
            start = n-max+1;
            for (i=start;i<=n;i++) {
                printf "%s%s", a[i], (i<n ? "," : "")
            }
        }'
    else
        echo "$updated"
    fi
}

# -------------------------
# Trend evaluation
# -------------------------
trend_eval() {
    local csv="$1"
    [[ -z "$csv" ]] && { echo "stable"; return; }

    IFS=',' read -ra arr <<< "$csv"
    local len=${#arr[@]}
    if (( len == 0 )); then
        echo "stable"
        return
    fi

    local first="${arr[0]}"
    local last="${arr[$((len-1))]}"

    [[ "$first" =~ ^[0-9]+$ ]] || first=0
    [[ "$last"  =~ ^[0-9]+$ ]] || last=0

    local delta=$((last - first))

    if (( delta >= 5 )); then echo "imminent"; return; fi
    if (( delta >= 2 )); then echo "failing"; return; fi
    if (( delta >= 1 )); then echo "degraded"; return; fi

    echo "stable"
}

# -------------------------
# Load history (with lock)
# -------------------------
declare -A HISTMAP

if (( READ_ONLY == 0 )); then
    exec 9>"$LOCK"
    flock -x 9
fi

if [[ -f "$HIST" ]]; then
    while read -r serial rest; do
        [[ -z "$serial" ]] && continue
        HISTMAP["$serial"]="$rest"
    done < "$HIST"
fi

# -------------------------
# Helpers
# -------------------------

get_sata_speed() {
  local out
  out=$(sudo -n smartctl -i "$1" 2>/dev/null)

  local cur
  cur=$(echo "$out" | grep -o "current: [0-9.]\+ Gb/s")
  if [[ -n "$cur" ]]; then
    echo "@${cur#current: }"
    return
  fi

  local ver
  ver=$(echo "$out" | grep -o "[0-9.]\+ Gb/s")
  if [[ -n "$ver" ]]; then
    echo "@$ver"
    return
  fi

  echo "@N/A"
}

get_nvme_speed() {
  local disk="$1"
  local sys_path="/sys/block/$disk"
  local pci_addr

  pci_addr=$(readlink -f "$sys_path" |
    grep -oP '([0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' |
    tail -n1)

  [[ -z "$pci_addr" ]] && echo "@N/A" && return

  local line
  line=$(sudo -n lspci -s "$pci_addr" -vv 2>/dev/null |
    grep -i "LnkSta" |
    grep -o "Speed [0-9.]*GT/s[^,]*, Width x[0-9]")

  if [[ -n "$line" ]]; then
    local out="@$(echo "$line" |
      sed -E 's/Speed ([0-9.]+)GT\/s/\1 GT\/s/')"
    echo "$out"
  else
    echo "@N/A"
  fi
}

find_md_for_disk() {
  local devname="$1"
  for md in /dev/md[0-9]*; do
    [[ -b "$md" ]] || continue
    if sudo -n mdadm --detail "$md" 2>/dev/null |
       awk -v d="/dev/$devname" '$0 ~ d && /active/' |
       grep -q .; then
      echo "$md"
      return
    fi
  done
}

is_bcache_member() {
  [[ -d "/sys/block/$1/bcache" ]] && echo "yes" || echo "no"
}

get_bcache_mode_from_node() {
  local node="$1"
  local mode_raw
  mode_raw=$(cat "/sys/block/$node/bcache/cache_mode" 2>/dev/null) || { echo ""; return; }
  local first
  first=$(echo "$mode_raw" | awk '{print $1}')
  case "$first" in
    writeback)    echo "Writeback" ;;
    writethrough) echo "Writethrough" ;;
    writearound)  echo "Writearound" ;;
    none)         echo "None" ;;
    *)            echo "" ;;
  esac
}

# Finn bcache-node for gitt disk (backing eller cache)
get_bcache_node_for_disk() {
  local disk="$1"

  # Backing: /sys/block/<disk>/bcache -> ../../bcacheX
  if [[ -e "/sys/block/$disk/bcache" ]]; then
    local link
    link=$(readlink -f "/sys/block/$disk/bcache" 2>/dev/null)
    if [[ -n "$link" ]]; then
      local base
      base=$(basename "$link")
      [[ "$base" =~ ^bcache[0-9]+$ ]] && { echo "$base"; return; }
    fi
  fi

  # Cache: /sys/block/bcacheX/bcache/cache* -> /sys/block/<disk>
  local node
  for node in /sys/block/bcache*; do
    [[ -d "$node" ]] || continue
    local c
    for c in "$node"/bcache/cache*; do
      [[ -e "$c" ]] || continue
      local link
      link=$(readlink -f "$c" 2>/dev/null) || continue
      if [[ "$(basename "$link")" == "$disk" ]]; then
        basename "$node"
        return
      fi
    done
  done
}

raid_bcache_node() {
  local md="$1"
  local mdname="${md##*/}"
  lsblk -rno NAME,PKNAME |
    awk -v p="$mdname" '$2==p && $1 ~ /^bcache/ {print $1; exit}'
}

get_disk_space() {
  local dev="$1"

  # First: direct df on the disk itself (GiB, integer)
  local space
  space=$(df -BG --output=source,avail 2>/dev/null |
    awk -v d="/dev/$dev" '$1==d {print $2; exit}')

  if [[ -n "$space" ]]; then
    echo "$space"
    return
  fi

  # Sum partitions mounted, using GiB integers
  local sum=0
  while read -r part mp; do
    [[ -z "$mp" ]] && continue
    local val
    val=$(df -BG --output=source,avail "$part" 2>/dev/null |
      awk -v p="$part" '$1==p {print $2; exit}')
    [[ -z "$val" ]] && continue
    val=${val%G}
    [[ "$val" =~ ^[0-9]+$ ]] || val=0
    sum=$((sum + val))
  done < <(lsblk -rno NAME,MOUNTPOINT | awk -v d="$dev" '$1 ~ "^"d"p?[0-9]+$" && $2 != "" {print "/dev/"$1, $2}')

  if (( sum == 0 )); then
    echo "0G"
  else
    echo "${sum}G"
  fi
}

get_md_or_bcache_space() {
  local md="$1"

  local direct
  direct=$(df -BG --output=source,avail 2>/dev/null |
    awk -v m="$md" '$1==m {print $2; exit}')

  if [[ -n "$direct" ]]; then
    echo "$direct"
    return
  fi

  local mdname="${md##*/}"
  local bcache
  bcache=$(lsblk -rno NAME,PKNAME |
    awk -v p="$mdname" '$2==p && $1 ~ /^bcache/ {print $1; exit}')

  if [[ -n "$bcache" ]]; then
    df -BG --output=source,avail 2>/dev/null |
      awk -v b="/dev/$bcache" '$1==b {print $2; exit}'
    return
  fi

  echo "—"
}

get_bcache_stats() {
  local disk="$1"
  local bpath="/sys/block/$disk/bcache"

  [[ ! -d "$bpath" ]] && echo "no stats" && return

  local uuid
  uuid=$(readlink -f "$bpath/set" | awk -F/ '{print $NF}')
  local stats="/sys/fs/bcache/$uuid/stats_total"

  if [[ -r "$stats/cache_hits" && -r "$stats/cache_misses" ]]; then
    local hits misses total percent
    hits=$(<"$stats/cache_hits")
    misses=$(<"$stats/cache_misses")
    total=$((hits + misses))

    if (( total > 0 )); then
      percent=$((100 * hits / total))
      echo "${percent}% hit"
    else
      echo "0% usage"
    fi
  else
    echo "unreadable"
  fi
}

# ============================================================
#   MAIN LOOP
# ============================================================

if (( READ_ONLY == 0 )); then
    > "$CACHE"
fi

declare -A NEW_HIST

while read -r disk; do

    dev="/dev/$disk"

    mapfile -t dh < <(diskhealth --diskinfo "$dev")

    # Safety check: diskhealth must return at least header + metrics
    if (( ${#dh[@]} < 2 )); then
        label="Disk $disk"
        value="\033[1;90mERROR\033[0m, Speed @N/A, Left: — [\033[1;90mUNMOUNTED\033[0m]"
        if (( READ_ONLY == 0 )); then
            printf "%s:%s\n" "$label" "$value" >> "$CACHE"
            (( PRINT_MODE == 1 )) && echo -e "$label: $value"
        else
            if (( PRINT_MODE == 1 )); then
                echo -e "$label: $value"
            else
                printf "%s:%s\n" "$label" "$value"
            fi
        fi
        continue
    fi

    header="${dh[0]}"
    metrics="${dh[1]}"

    IFS="|" read name type health serial_kv model_kv <<< "$header"
    health="$(echo "$health" | xargs)"

    serial="${serial_kv#serial=}"
    model="${model_kv#model=}"

    declare realloc pending offline crc hours lcc
    realloc=0 pending=0 offline=0 crc=0 hours=0 lcc=0

    for kv in $metrics; do
        key="${kv%%=*}"
        val="${kv#*=}"
        case "$key" in
            realloc) realloc="$val" ;;
            pending) pending="$val" ;;
            offline) offline="$val" ;;
            crc)     crc="$val" ;;
            hours)   hours="$val" ;;
            lcc)     lcc="$val" ;;
        esac
    done

    # Load previous CSVs safely (no eval, no unsafe splitting)
    realloc_csv=""
    pending_csv=""
    offline_csv=""
    crc_csv=""
    hours_csv=""
    lcc_csv=""

    prev="${HISTMAP[$serial]}"
    if [[ -n "$prev" ]]; then
        IFS=' ' read -ra hist_parts <<< "$prev"
        for kv in "${hist_parts[@]}"; do
            k="${kv%%=*}"
            v="${kv#*=}"
            case "$k" in
                realloc_csv) realloc_csv="$v" ;;
                pending_csv) pending_csv="$v" ;;
                offline_csv) offline_csv="$v" ;;
                crc_csv)     crc_csv="$v" ;;
                hours_csv)   hours_csv="$v" ;;
                lcc_csv)     lcc_csv="$v" ;;
            esac
        done
    fi

    realloc_csv=$(update_window "$realloc_csv" "$realloc")
    pending_csv=$(update_window "$pending_csv" "$pending")
    offline_csv=$(update_window "$offline_csv" "$offline")
    crc_csv=$(update_window "$crc_csv" "$crc")
    hours_csv=$(update_window "$hours_csv" "$hours")
    lcc_csv=$(update_window "$lcc_csv" "$lcc")

    realloc_trend=$(trend_eval "$realloc_csv")
    pending_trend=$(trend_eval "$pending_csv")
    crc_trend=$(trend_eval "$crc_csv")

    # Store updated history
    NEW_HIST["$serial"]="realloc_csv=$realloc_csv pending_csv=$pending_csv offline_csv=$offline_csv crc_csv=$crc_csv hours_csv=$hours_csv lcc_csv=$lcc_csv"

    tag_list=()
    left=""

    md_dev=$(find_md_for_disk "$disk")
    if [[ -n "$md_dev" ]]; then
      left=$(get_md_or_bcache_space "$md_dev")
      tag_list+=("RAID")

      rbnode=$(raid_bcache_node "$md_dev")
      if [[ -n "$rbnode" ]]; then
        mode=$(get_bcache_mode_from_node "$rbnode")
        [[ -n "$mode" ]] && tag_list+=("BCACHE:$mode")
      fi
    fi

    # BCACHE – per-device node resolution with fallback
    if [[ $(is_bcache_member "$disk") == "yes" ]]; then
      usage=$(get_bcache_stats "$disk")
      left="$usage (cache)"

      node=$(get_bcache_node_for_disk "$disk")
      if [[ -z "$node" ]]; then
          for n in /sys/block/bcache*; do
              [[ -d "$n" ]] || continue
              node="${n##*/}"
              break
          done
      fi

      mode=""
      [[ -n "$node" ]] && mode=$(get_bcache_mode_from_node "$node")

      if [[ -n "$mode" ]]; then
          tag_list+=("BCACHE:$mode")
      else
          tag_list+=("BCACHE")
      fi
    fi

    if [[ -z "$left" ]]; then
      left=$(get_disk_space "$disk")
    fi

    if [[ ${#tag_list[@]} -eq 0 ]]; then
      if [[ "$left" != "0G" && "$left" != "—" ]]; then
        tag_list+=("ACTIVE")
      else
        tag_list+=("UNMOUNTED")
      fi
    fi

    colored_tags=()

    for t in "${tag_list[@]}"; do
      case "$t" in
        RAID)                 colored_tags+=("\033[1;35mRAID\033[0m") ;;
        ACTIVE)               colored_tags+=("\033[1;32mACTIVE\033[0m") ;;
        UNMOUNTED)            colored_tags+=("\033[1;90mUNMOUNTED\033[0m") ;;
        BCACHE:*)             colored_tags+=("\033[1;36m${t}\033[0m") ;;
        BCACHE)               colored_tags+=("\033[1;36mBCACHE\033[0m") ;;
        *)                    colored_tags+=("$t") ;;
      esac
    done

    tags=$(IFS=" "; echo "${colored_tags[*]}")

    if [[ "$disk" == nvme* ]]; then
      speed=$(get_nvme_speed "$disk")
    else
      speed=$(get_sata_speed "$dev")
    fi

    speed="${speed//$'\n'/}"
    speed="${speed//$'\r'/}"

    case "$health" in
      HEALTHY)            health_color="\033[1;32m" ;;
      ACCEPTABLE)         health_color="\033[0;92m" ;;
      DEGRADED)           health_color="\033[1;33m" ;;
      FAILING)            health_color="\033[1;31m" ;;
      "IMMINENT FAILURE") health_color="\033[1;41m" ;;
      ERROR)              health_color="\033[1;90m" ;;
      *)                  health_color="\033[1;90m" ;;
    esac

    reset_color="\033[0m"

    label="Disk $disk"
    value="${health_color}${health}${reset_color}, Speed $speed, Left: $left [$tags]"

    if (( READ_ONLY == 0 )); then
        printf "%s:%s\n" "$label" "$value" >> "$CACHE"
        if (( PRINT_MODE == 1 )); then
            echo -e "$label: $value"
        fi
    else
        if (( PRINT_MODE == 1 )); then
            echo -e "$label: $value"
        else
            printf "%s:%s\n" "$label" "$value"
        fi
    fi

done < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}')

if (( READ_ONLY == 0 )); then
    > "$HIST"
    for serial in "${!NEW_HIST[@]}"; do
        echo "$serial ${NEW_HIST[$serial]}" >> "$HIST"
    done
    flock -u 9
fi
