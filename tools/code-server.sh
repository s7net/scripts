#!/usr/bin/env bash
set -e

PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)

# --- pick a random free port ---
find_free_port() {
    while true; do
        PORT=$(shuf -i 20000-65000 -n 1)
        if ! ss -tuln | awk '{print $5}' | grep -q ":$PORT\$"; then
            echo "$PORT"
            return
        fi
    done
}
PORT=$(find_free_port)

echo "[+] Installing code-server..."
curl -fsSL https://code-server.dev/install.sh | sh

mkdir -p /root/.config/code-server
cat >/root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:$PORT
auth: password
password: $PASSWORD
cert: false
EOF

# --- set default theme to Dark 2026 ---
mkdir -p /root/.local/share/code-server/User
cat >/root/.local/share/code-server/User/settings.json <<EOF
{
  "workbench.colorTheme": "Dark 2026"
}
EOF

systemctl daemon-reload
systemctl enable --now code-server@root

IP=$(hostname -I | awk '{print $1}')
clear
echo "============================================="
echo " Code Server Ready"
echo
echo " URL      : http://$IP:$PORT"
echo " Password : $PASSWORD"
echo "============================================="
echo
echo "[Live logs below] Press Ctrl+C at any time to stop the service."
echo "-----------------------------------------------------------"

STOPPING=0
LOG_PID=""

start_logs() {
    ( trap '' INT; journalctl -u code-server@root -f --no-pager ) &
    LOG_PID=$!
}

stop_logs() {
    if [[ -n "$LOG_PID" ]]; then
        kill "$LOG_PID" 2>/dev/null || true
        wait "$LOG_PID" 2>/dev/null || true
        LOG_PID=""
    fi
}

confirm_stop() {
    # immediately silence logs so the prompt is clean
    stop_logs
    echo
    read -rp "Are you sure you want to stop code-server? (y/n): " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        STOPPING=1
    else
        echo "Resuming logs... (press Ctrl+C again to stop)"
        start_logs
    fi
}

trap confirm_stop SIGINT

start_logs

while [[ "$STOPPING" -eq 0 ]]; do
    sleep 1
done

echo
echo "[+] Stopping code-server (files will not be removed)..."

systemctl stop code-server@root 2>/dev/null || true
systemctl disable code-server@root 2>/dev/null || true

pkill -f "code-server" 2>/dev/null || true
sleep 1
pkill -9 -f "code-server" 2>/dev/null || true

echo
echo "Done. code-server has been fully stopped (installation and files remain intact)."
