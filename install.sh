#!/bin/bash
set -e  # Avslutt scriptet ved feil

# --- Sudo password prompt (kjøres før alt annet) ---
read -s -p "[sudo] password for $USER: " password
echo
until echo "$password" | sudo -S -v &>/dev/null; do
    echo "Sorry, prøv igjen."
    read -s -p "[sudo] password for $USER: " password
    echo
done

# --- Emoji shortcuts ---
CHECK="✔️"
CROSS="❌"
WARN="⚠️"
INFO="ℹ️"

# --- Funksjon: installer avhengigheter ---
install_deps() {
    echo -e "$INFO Oppdaterer pakkelister..."
    echo "$password" | sudo -S apt update -y >/dev/null

    echo -e "$INFO Installerer nødvendige pakker..."
    REQUIRED_PACKAGES=(neofetch smartmontools pciutils mdadm nvme-cli)

    INSTALLED=()
    SKIPPED=()

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            SKIPPED+=("$pkg")
        else
            echo "$password" | sudo -S apt install -y "$pkg" >/dev/null
            INSTALLED+=("$pkg")
        fi
    done

    echo -e "\n$CHECK Følgende pakker ble installert:"
    for p in "${INSTALLED[@]}"; do
        echo -e "   $CHECK $p"
    done

    echo -e "\n$INFO Følgende pakker var allerede installert:"
    for p in "${SKIPPED[@]}"; do
        echo -e "   $WARN $p"
    done
}

# --- Funksjon: opprett systemd units ---
install_diskinfo() {

    echo -e "$INFO Oppretter systemd service og timer..."

    # Lag systemd service
    echo "$password" | sudo -S tee /etc/systemd/system/diskinfo.service >/dev/null <<'EOF'
[Unit]
Description=Update disk info cache

[Service]
Type=oneshot
ExecStart=/usr/local/bin/diskinfo.sh
EOF

    # Lag systemd timer
    echo "$password" | sudo -S tee /etc/systemd/system/diskinfo.timer >/dev/null <<'EOF'
[Unit]
Description=Run diskinfo.sh every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
Unit=diskinfo.service

[Install]
WantedBy=timers.target
EOF

    # Reload systemd
    echo "$password" | sudo -S systemctl daemon-reload

    # Enable + start timer
    echo "$password" | sudo -S systemctl enable --now diskinfo.timer

    echo -e "$CHECK diskinfo.service og diskinfo.timer er installert og aktivert."
}

install_sudoers_rules() {
    echo -e "$INFO Legger til sudoers-regler for smartctl, mdadm og lspci..."

    SUDOERS_FILE="/etc/sudoers.d/sysinfo"

    RULES=$(cat <<'EOF'
ALL ALL=NOPASSWD: /usr/sbin/smartctl -H *, /usr/sbin/smartctl -i *, /usr/sbin/smartctl -A *
ALL ALL=NOPASSWD: /sbin/mdadm --detail *
ALL ALL=NOPASSWD: /usr/bin/lspci -s * -vv
EOF
)

    # Skriv filen
    echo "$password" | sudo -S tee "$SUDOERS_FILE" >/dev/null <<< "$RULES"

    # Sett riktige permissions
    echo "$password" | sudo -S chmod 440 "$SUDOERS_FILE"

    # Valider syntaks
    if echo "$password" | sudo -S visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
        echo -e "   $CHECK sudoers-regler lagt til og validert."
    else
        echo -e "   $CROSS Feil i sudoers-reglene! Fjerner filen."
        echo "$password" | sudo -S rm -f "$SUDOERS_FILE"
        exit 1
    fi
}


# --- Kjør funksjonene ---
install_deps
install_diskinfo

echo -e "\n$CHECK Alt ferdig! Systemet er konfigurert."
