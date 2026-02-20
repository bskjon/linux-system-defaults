#!/bin/bash

# whichdisk – finn modell + serienummer fra device
# eller finn device fra serienummer

query="$1"

if [[ -z "$query" ]]; then
    echo "Bruk: whichdisk <sda|nvme0n1|SERIAL>"
    exit 1
fi

# Hvis argumentet er en device (sda, sdb, nvme0n1)
if [[ "$query" =~ ^sd[a-z]$ || "$query" =~ ^nvme[0-9]n[0-9]$ ]]; then
    dev="/dev/$query"
    model=$(sudo smartctl -i "$dev" 2>/dev/null | awk -F: '/Device Model|Product/ {print $2}' | xargs)
    serial=$(sudo smartctl -i "$dev" 2>/dev/null | awk -F: '/Serial Number/ {print $2}' | xargs)
    echo "$query → $model (SN: $serial)"
    exit 0
fi

# Hvis argumentet er et serienummer
serial="$query"
for d in /dev/sd? /dev/nvme?n?; do
    [[ -e "$d" ]] || continue
    s=$(sudo smartctl -i "$d" 2>/dev/null | awk -F: '/Serial Number/ {print $2}' | xargs)
    if [[ "$s" == "$serial" ]]; then
        model=$(sudo smartctl -i "$d" 2>/dev/null | awk -F: '/Device Model|Product/ {print $2}' | xargs)
        echo "$serial → ${d#/dev/} ($model)"
        exit 0
    fi
done

echo "Fant ingen disk for: $query"
