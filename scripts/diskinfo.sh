#!/bin/bash

get_sata_speed() {
  sudo smartctl -i "$1" 2>/dev/null | grep -o "current: [0-9.]\+ Gb/s" | awk '{print "@" $2 " " $3}' || echo "@N/A"
}

get_nvme_speed() {
  local disk="$1"
  local sys_path="/sys/block/$disk"
  local pci_addr
  pci_addr=$(readlink -f "$sys_path" | grep -oP '([0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -n1)
  [[ -z "$pci_addr" ]] && echo "@N/A" && return
  sudo lspci -s "$pci_addr" -vv 2>/dev/null | grep -i "LnkSta" |
    grep -o "Speed [0-9.]*GT/s.*Width x[0-9]" |
    sed -E 's/Speed ([0-9.]+)GT\/s/Speed \1 GT\/s/' |
    sed 's/Speed /@/' || echo "@N/A"
}


find_md_for_disk() {
  local devname="$1"
  for md in /dev/md[0-9]*; do
    [[ -b "$md" ]] || continue
    if sudo mdadm --detail "$md" 2>/dev/null | awk -v d="/dev/$devname" '$0 ~ d && /active/' | grep -q .; then
      echo "$md"
      return
    fi
  done
}

is_bcache_member() {
  [[ -d "/sys/block/$1/bcache" ]] && echo "yes" || echo "no"
}

#get_disk_space() {
#  local dev="$1"
#
#  # 1. Check direct mount
#  local space=$(df -h --output=source,avail | awk -v d="/dev/$dev" '$1==d {print $2; exit}')
#  if [[ -n "$space" ]]; then
#    echo "$space"
#    return
#  fi
#
#  # 2. Check mounted partitions (handles sda1, nvme0n1p1, etc.)
#  space=$(lsblk -rno NAME,MOUNTPOINT | awk -v d="$dev" '
#    $1 ~ "^"d"p?[0-9]+$" && $2 != "" {
#      part="/dev/"$1
#      while (( "df -h "part | getline l ) > 0) {
#        if (l ~ part) {
#          split(l, a, /[[:space:]]+/); sum += a[4]
#        }
#      }
#    } END {printf "%.0fG", sum}')
#
#  [[ -z "$space" ]] && echo "0G" || echo "$space"
#}

get_disk_space() {
  local dev="$1"

  # 1. Check direct mount
  local space=$(df -h --output=source,avail | awk -v d="/dev/$dev" '$1==d {print $2; exit}')
  if [[ -n "$space" ]]; then
    echo "$space"
    return
  fi

  # 2. Check mounted partitions (handles sda1, nvme0n1p1, etc.)
  space=$(lsblk -rno NAME,MOUNTPOINT | awk -v d="$dev" '$1 ~ "^"d"p?[0-9]+$" && $2 != "" {print "/dev/"$1}' | while read -r part; do
    df -h "$part" | awk -v p="$part" '$1==p {print $4}'
  done | awk '{sum+=$1} END {printf "%.0fG", sum}')

  [[ -z "$space" ]] && echo "0G" || echo "$space"
}


get_md_or_bcache_space() {
  local md="$1"
  # Try direct df lookup for md device
  local direct
  direct=$(df -h --output=source,avail | awk -v m="$md" '$1==m {print $2; exit}')
  if [[ -n "$direct" ]]; then
    echo "$direct"
    return
  fi

  # If not mounted directly, try any bcache device on top of md
  local mdname="${md##*/}"
  local bcache
  bcache=$(lsblk -rno NAME,PKNAME | awk -v p="$mdname" '$2==p && $1 ~ /^bcache/ {print $1; exit}')
  if [[ -n "$bcache" ]]; then
    df -h --output=source,avail | awk -v b="/dev/$bcache" '$1==b {print $2; exit}'
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


# Main disk loop
lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | while read -r disk; do
  dev="/dev/$disk"

  # Health
  health=$(sudo smartctl -H "$dev" 2>/dev/null | awk -F: '/SMART.*health/ {print $2}' | xargs)
  [[ -z "$health" ]] && health="Unknown"


  # Speed
  if [[ "$disk" == nvme* ]]; then
    speed=$(get_nvme_speed "$disk")
  else
    speed=$(get_sata_speed "$dev")
  fi

  tag_list=()
  left=""

  # RAID logic
  md_dev=$(find_md_for_disk "$disk")
  if [[ -n "$md_dev" ]]; then
    left=$(get_md_or_bcache_space "$md_dev")
    [[ -z "$left" ]] && left="—"
    tag_list+=("RAID")
  fi

  # bcache membership
  if [[ $(is_bcache_member "$disk") == "yes" ]]; then
    tag_list+=("BCACHE")
  fi

  if [[ $(is_bcache_member "$disk") == "yes" ]]; then
    usage=$(get_bcache_stats "$disk")
    left="$usage (cache)"
  fi



  # If neither RAID nor bcache reported anything usable
  if [[ -z "$left" ]]; then
    left=$(get_disk_space "$disk")
    [[ -z "$left" ]] && left="0G"
  fi

  # Final tag logic
  if [[ ${#tag_list[@]} -eq 0 ]]; then
    if [[ "$left" != "0G" && "$left" != "—" ]]; then
      tag_list+=("ACTIVE")
    else
      tag_list+=("UNMOUNTED")
    fi
  fi



  # Output
  tags=$(IFS=" "; echo "${tag_list[*]}")



[[ "$tags" == *RAID* ]] && tags="\033[1;35m$tags\033[0m"       # Magenta
[[ "$tags" == *BCACHE* ]] && tags="\033[1;36m$tags\033[0m"     # Cyan
[[ "$tags" == *UNMOUNTED* ]] && tags="\033[1;90m$tags\033[0m"  # Dim gray

if [[ "$health" == "PASSED" ]]; then
  health_color="\033[1;32m"
else
  health_color="\033[1;31m"
fi

reset_color="\033[0m"



#  echo "$disk: Health $health, Speed $speed, Left: $left [$tags]"
#  echo "Disk $disk:$health, Speed $speed, Left: $left [$tags]"
# Final output (use %b to interpret ANSI codes)

label="Disk $disk"
value="${health_color}${health}${reset_color}, Speed $speed, Left: $left [$tags]"

echo "$label:$value"


done > /dev/shm/diskinfo.cache
