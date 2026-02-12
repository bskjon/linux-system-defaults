#!/bin/bash

# Farger
RED="\e[91m"
YELLOW="\e[93m"
GREEN="\e[92m"
CYAN="\e[96m"
GRAY="\e[90m"
BOLD="\e[1m"
RESET="\e[0m"

TMPFILE="/tmp/nvmetemp_previous"

echo -e "${CYAN}${BOLD}=== NVMe-temperaturer (@$(hostname)) ===${RESET}"

# Hent nåværende temperaturer
declare -A current_temp
for disk in /dev/nvme?n?; do
    temp=$(sudo smartctl -A "$disk" \
        | awk '/Temperature:/ {print $2} /Composite Temperature/ {print $3}' \
        | grep -Eo '[0-9]+' \
        | head -n1)

    [[ "$temp" =~ ^[0-9]+$ ]] && current_temp["$disk"]="$temp"
done

# Vis temperaturer med farge, emoji og trend
for disk in /dev/nvme?n?; do
    model=$(sudo smartctl -i "$disk" | grep -E "Model Number|Product:" | awk -F: '{print $2}' | xargs)
    temp="${current_temp[$disk]}"

    if [[ -z "$temp" ]]; then
        echo -e "$disk ($model): ${GRAY}Ingen temp-data${RESET}"
        continue
    fi

    # Temperaturfarge
    if (( temp >= 70 )); then color="$RED"
    elif (( temp >= 55 )); then color="$YELLOW"
    else color="$GREEN"
    fi

    # Emoji
    if (( temp >= 65 )); then emoji="🔥"
    elif (( temp <= 35 )); then emoji="❄️"
    else emoji=""
    fi

    # Trend
    previous=$(grep "$disk" "$TMPFILE" 2>/dev/null | awk '{print $2}')
    if [[ "$previous" =~ ^[0-9]+$ ]]; then
        delta=$((temp - previous))
        if (( delta > 0 )); then
            trend="${RED}↗ +$delta°C${RESET}"
        elif (( delta < 0 )); then
            trend="${GREEN}↘ $delta°C${RESET}"
        else
            trend="${GRAY}→ 0°C${RESET}"
        fi
    else
        trend="${GRAY}↻ nytt${RESET}"
    fi

    echo -e "$disk ($model): ${color}${temp}°C${RESET} $emoji  [$trend]"
done

# Lagre nye temperaturer
> "$TMPFILE"
for disk in "${!current_temp[@]}"; do
    echo "$disk ${current_temp[$disk]}" >> "$TMPFILE"
done
