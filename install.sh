#!/bin/bash
set -e  # Avslutt scriptet ved feil

if [[ $EUID -eq 0 ]]; then
    echo "❌ Dette scriptet må IKKE kjøres som root. Avslutter."
    exit 1
fi


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
    REQUIRED_PACKAGES=(neofetch smartmontools pciutils mdadm nvme-cli curl)

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

# --- Funksjon: sudoers-regler ---
install_sudoers_rules() {
    echo -e "$INFO Legger til sudoers-regler for smartctl, mdadm, lspci, nvme og systemkontroll..."

    SUDOERS_FILE="/etc/sudoers.d/sysinfo"

    CURRENT_USER="$USER"

    RULES=$(cat <<EOF
# Diskinfo / systeminfo
ALL ALL=NOPASSWD: /usr/sbin/smartctl -H *, /usr/sbin/smartctl -i *, /usr/sbin/smartctl -A *
ALL ALL=NOPASSWD: /sbin/mdadm --detail *
ALL ALL=NOPASSWD: /usr/bin/lspci -s * -vv

# Telegraf sensorer
telegraf ALL=(ALL) NOPASSWD: /usr/sbin/smartctl
telegraf ALL=(ALL) NOPASSWD: /usr/sbin/nvme

# Bruker-spesifikke kommandoer
$CURRENT_USER ALL=(ALL) NOPASSWD: /sbin/shutdown, /sbin/reboot
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl reboot --firmware-setup
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


# --- Funksjon: last ned scripts og config ---
install_files() {
    echo -e "$INFO Laster ned neofetch config og scripts..."

    # Neofetch config
    NEO_DIR="/etc/neofetch"
    NEO_CONF="$NEO_DIR/config.conf"
    echo "$password" | sudo -S mkdir -p "$NEO_DIR"

    if [[ -f "$NEO_CONF" ]]; then
        echo "$password" | sudo -S mv "$NEO_CONF" "$NEO_CONF.bak"
        echo -e "   $WARN Backup av eksisterende neofetch config"
    fi

    echo "$password" | sudo -S curl -fsSL \
        https://raw.githubusercontent.com/bskjon/linux-system-defaults/refs/heads/master/neofetch.config \
        -o "$NEO_CONF"

    echo -e "   $CHECK Neofetch config installert"

    # Diskinfo script
    echo "$password" | sudo -S curl -fsSL \
        https://raw.githubusercontent.com/bskjon/linux-system-defaults/refs/heads/master/scripts/diskinfo.sh \
        -o /usr/local/bin/diskinfo.sh
    echo "$password" | sudo -S chmod +x /usr/local/bin/diskinfo.sh
    echo -e "   $CHECK diskinfo.sh installert"

    # HDD temp script
    echo "$password" | sudo -S curl -fsSL \
        https://raw.githubusercontent.com/bskjon/linux-system-defaults/refs/heads/master/scripts/hddtemp.sh \
        -o /usr/local/bin/hddtemp.sh
    echo "$password" | sudo -S chmod +x /usr/local/bin/hddtemp.sh
    echo -e "   $CHECK hddtemp.sh installert"

    # NVMe temp script
    echo "$password" | sudo -S curl -fsSL \
        https://raw.githubusercontent.com/bskjon/linux-system-defaults/refs/heads/master/scripts/nvmetemp.sh \
        -o /usr/local/bin/nvmetemp.sh
    echo "$password" | sudo -S chmod +x /usr/local/bin/nvmetemp.sh
    echo -e "   $CHECK nvmetemp.sh installert"
}

# --- Funksjon: opprett MOTD pipeline ---
install_motd() {
    echo -e "$INFO Oppretter MOTD pipeline..."

    MOTD_DIR="/etc/update-motd.d"

    # Neofetch
    echo "$password" | sudo -S tee "$MOTD_DIR/01-neofetch" >/dev/null <<'EOF'
#!/bin/bash
/usr/bin/neofetch --config /etc/neofetch/config.conf
EOF
    echo "$password" | sudo -S chmod +x "$MOTD_DIR/01-neofetch"

    # HDD temp
    echo "$password" | sudo -S tee "$MOTD_DIR/02-hddtemp" >/dev/null <<'EOF'
#!/bin/bash
/usr/local/bin/hddtemp.sh
EOF
    echo "$password" | sudo -S chmod +x "$MOTD_DIR/02-hddtemp"

    # NVMe temp
    echo "$password" | sudo -S tee "$MOTD_DIR/03-nvmetemp" >/dev/null <<'EOF'
#!/bin/bash
/usr/local/bin/nvmetemp.sh
EOF
    echo "$password" | sudo -S chmod +x "$MOTD_DIR/03-nvmetemp"

    echo -e "   $CHECK MOTD pipeline opprettet"
}

# --- Funksjon: opprett systemd units ---
install_diskinfo() {
    echo -e "$INFO Oppretter systemd service og timer..."

    echo "$password" | sudo -S tee /etc/systemd/system/diskinfo.service >/dev/null <<'EOF'
[Unit]
Description=Update disk info cache

[Service]
Type=oneshot
ExecStart=/usr/local/bin/diskinfo.sh
EOF

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

    echo "$password" | sudo -S systemctl daemon-reload
    echo "$password" | sudo -S systemctl enable --now diskinfo.timer

    echo -e "$CHECK diskinfo.service og diskinfo.timer er installert og aktivert."
}

# --- Kjør funksjonene ---
install_deps
install_sudoers_rules
install_files
install_motd
install_diskinfo

echo -e "\n$CHECK Alt ferdig! Systemet er konfigurert."
