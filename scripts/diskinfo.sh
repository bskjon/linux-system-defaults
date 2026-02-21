#!/bin/bash

# ============================================================
#   Diskinfo v3 – systemd compatible
#
#   Trend + Sample Window + RAID/BCACHE/Speed/Space/Tags
#   Health from diskhealth (single source of truth)
#   History stored in /var/lib/diskinfo/history.db
#   --read-only = no writes (cache OR history)
# ============================================================

CACHE="/dev/shm/diskinfo.cache"
HIST="/var/lib/diskinfo/history.db"
WINDOW_SIZE=5

mkdir -p /var/lib/diskinfo

# -------------------------
# Flags
# -------------------------
READ_ONLY=0
if [[ "$1" == "--read-only" ]]; then
    READ_ONLY=1
    shift
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
    IFS=',' read -ra arr <<< "$csv"

    local first="${arr[0]}"
    local last="${arr[-1]}"
    local delta=$((last - first))

    if (( delta >= 5 )); then echo "imminent"; return; fi
    if (( delta >= 2 )); then echo "failing"; return; fi
    if (( delta >= 1 )); then echo "degraded"; return; fi

    echo "stable"
}

# -------------------------
# Load previous history (READ-ONLY still loads)
# -------------------------
declare -A HISTMAP

if [[ -f "$HIST" ]]; then
    while read -r serial rest; do
        [[ -z "$serial" ]] && continue
        HISTMAP["$serial"]="$rest"
    done < "$HIST"
fi

# -------------------------
# Helpers (unchanged)
# -------------------------
get_sata_speed() {
  sudo -n smartctl -i "$1" 2>/dev/null |
    grep -o "current: [0-9.]\+ Gb/s" |
    awk '{print "@" $2 " " $3}' || echo "@N/A"
}

get_nvme_speed() {
  local disk="$1"
  local sys_path="/sys/block/$disk"
  local pci_addr

  pci_addr=$(readlink -f "$sys_path" |
    grep -oP '([0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' |
    tail -n1)

  [[ -z "$pci_addr" ]] && echo "@N/A" && return

  sudo -n lspci -s "$pci_addr" -vv 2>/dev/null |
    grep -i "LnkSta" |
    grep -o "Speed [0-9.]*GT/s.*Width x[0-9]" |
    sed -E 's/Speed ([0-9.]+)GT\/s/@\1 GT\/s/' ||
    echo "@N/A"
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

get_disk_space() {
  local dev="$1"

  local space=$(df -h --output=source,avail |
    awk -v d="/dev/$dev" '$1==d {print $2; exit}')

  if [[ -n "$space" ]]; then
    echo "$space"
    return
  fi

  space=$(lsblk -rno NAME,MOUNTPOINT |
    awk -v d="$dev" '$1 ~ "^"d"p?[0-9]+$" && $2 != "" {print "/dev/"$1}' |
    while read -r part; do
      df -h "$part" | awk -v p="$part" '$1==p {print $4}'
    done |
    awk '{sum+=$1} END {printf "%.0fG", sum}')

  [[ -z "$space" ]] && echo "0G" || echo "$space"
}

get_md_or_bcache_space() {
  local md="$1"

  local direct=$(df -h --output=source,avail |
    awk -v m="$md" '$1==m {print $2; exit}')

  if [[ -n "$direct" ]]; then
    echo "$direct"
    return
  fi

  local mdname="${md##*/}"
  local bcache=$(lsblk -rno NAME,PKNAME |
    awk -v p="$mdname" '$2==p && $1 ~ /^bcache/ {print $1; exit}')

  if [[ -n "$bcache" ]]; then
    df -h --output=source,avail |
      awk -v b="/dev/$bcache" '$1==b {print $2; exit}'
    return
  fi

  echo "—"
}

get_bcache_stats() {
  local disk="$1"
  local bpath="/sys/block/$disk/bcache"

  [[ ! -d "$bpath" ]] && echo "no stats" && return

  local uuid=$(readlink -f "$bpath/set" | awk -F/ '{print $NF}')
  local stats="/sys/fs/bcache/$uuid/stats_total"

  if [[ -r "$stats/cache_hits" && -r "$stats/cache_misses" ]]; then
    local hits=$(<"$stats/cache_hits")
    local misses=$(<"$stats/cache_misses")
    local total=$((hits + misses))

    if (( total > 0 )); then
      local percent=$((100 * hits / total))
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

lsblk -ndo NAME,TYPE |
  awk '$2=="disk"{print $1}' |
  while read -r disk; do

    dev="/dev/$disk"

    # --------------------------------------------------------
    # 1. HEALTH + METRICS from diskhealth
    # --------------------------------------------------------
    mapfile -t dh < <(diskhealth --diskinfo "$dev")

    header="${dh[0]}"
    metrics="${dh[1]}"

    health=$(echo "$header" | awk -F'|' '{print $3}' | xargs)

    eval "$metrics"

    # --------------------------------------------------------
    # 2. SERIAL (for history)
    # --------------------------------------------------------
    serial=$(sudo -n smartctl -i "$dev" |
             awk -F: '/Serial Number/ {print $2}' | xargs)

    [[ -z "$serial" ]] && continue

    # --------------------------------------------------------
    # 3. Load previous window
    # --------------------------------------------------------
    prev="${HISTMAP[$serial]}"

    if [[ -n "$prev" ]]; then
        eval "$prev"
    else
        realloc_csv=""
        pending_csv=""
        offline_csv=""
        crc_csv=""
        hours_csv=""
        lcc_csv=""
    fi

    # --------------------------------------------------------
    # 4. Update windows
    # --------------------------------------------------------
    realloc_csv=$(update_window "$realloc_csv" "$realloc")
    pending_csv=$(update_window "$pending_csv" "$pending")
    offline_csv=$(update_window "$offline_csv" "$offline")
    crc_csv=$(update_window "$crc_csv" "$crc")
    hours_csv=$(update_window "$hours_csv" "$hours")
    lcc_csv=$(update_window "$lcc_csv" "$lcc")

    # --------------------------------------------------------
    # 5. Trend evaluation
    # --------------------------------------------------------
    realloc_trend=$(trend_eval "$realloc_csv")
    pending_trend=$(trend_eval "$pending_csv")
    crc_trend=$(trend_eval "$crc_csv")

    # --------------------------------------------------------
    # 6. RAID / BCACHE / SPACE / SPEED
    # --------------------------------------------------------
    tag_list=()
    left=""

    md_dev=$(find_md_for_disk "$disk")
    if [[ -n "$md_dev" ]]; then
      left=$(get_md_or_bcache_space "$md_dev")
      tag_list+=("RAID")
    fi

    if [[ $(is_bcache_member "$disk") == "yes" ]]; then
      tag_list+=("BCACHE")
      usage=$(get_bcache_stats "$disk")
      left="$usage (cache)"
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

    tags=$(IFS=" "; echo "${tag_list[*]}")

    # SPEED
    if [[ "$disk" == nvme* ]]; then
      speed=$(get_nvme_speed "$disk")
    else
      speed=$(get_sata_speed "$dev")
    fi

    # --------------------------------------------------------
    # 7. Save new history (ONLY if not read-only)
    # --------------------------------------------------------
    if (( READ_ONLY == 0 )); then
        NEW_HIST["$serial"]="realloc_csv=\"$realloc_csv\" pending_csv=\"$pending_csv\" offline_csv=\"$offline_csv\" crc_csv=\"$crc_csv\" hours_csv=\"$hours_csv\" lcc_csv=\"$lcc_csv\""
    fi

    # --------------------------------------------------------
    # 8. COLORING
    # --------------------------------------------------------
    [[ "$tags" == *RAID* ]] && tags="\033[1;35m$tags\033[0m"
    [[ "$tags" == *BCACHE* ]] && tags="\033[1;36m$tags\033[0m"
    [[ "$tags" == *UNMOUNTED* ]] && tags="\033[1;90m$tags\033[0m"

    case "$health" in
      HEALTHY) health_color="\033[1;32m" ;;
      ACCEPTABLE) health_color="\033[1;33m" ;;
      DEGRADED) health_color="\033[1;35m" ;;
      FAILING) health_color="\033[1;31m" ;;
      "IMMINENT FAILURE") health_color="\033[1;41m" ;;
      ERROR) health_color="\033[1;90m" ;;
      *) health_color="\033[1;90m" ;;
    esac

    reset_color="\033[0m"

    # --------------------------------------------------------
    # 9. OUTPUT
    # --------------------------------------------------------
    label="Disk $disk"
    value="${health_color}${health}${reset_color}, Speed $speed, Left: $left [$tags]"

    if (( READ_ONLY == 0 )); then
        echo -e "$label:$value" >> "$CACHE"
    else
        echo -e "$label:$value"
    fi

done

# ------------------------------------------------------------
#  Write updated history (ONLY if not read-only)
# ------------------------------------------------------------
if (( READ_ONLY == 0 )); then
    > "$HIST"
    for serial in "${!NEW_HIST[@]}"; do
        echo "$serial ${NEW_HIST[$serial]}" >> "$HIST"
    done
fi
