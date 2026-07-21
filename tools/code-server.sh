#!/usr/bin/env bash
set -e

PORT=39217

if systemctl is-active --quiet code-server@root 2>/dev/null; then
    systemctl stop code-server@root
fi

PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)

if command -v code-server >/dev/null 2>&1; then
    echo "[+] code-server is already installed, skipping installation."
else
    echo "[+] Installing code-server..."
    curl -fsSL https://code-server.dev/install.sh | sh
fi

mkdir -p /root/.config/code-server
cat >/root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:$PORT
auth: password
password: $PASSWORD
cert: false
EOF

mkdir -p /root/.local/share/code-server/User
cat >/root/.local/share/code-server/User/settings.json <<EOF
{
  "workbench.colorTheme": "Dark 2026"
}
EOF

systemctl daemon-reload
systemctl enable code-server@root
systemctl restart code-server@root

sleep 2

if ! ss -tuln | awk '{print $5}' | grep -q ":$PORT\$"; then
    echo "[!] code-server failed to start on port $PORT."
    echo "[!] Recent logs:"
    journalctl -u code-server@root -n 30 --no-pager
    exit 1
fi

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
HANDLING=0

start_logs() {
    pkill -f "journalctl -u code-server@root" 2>/dev/null || true
    ( trap '' INT; exec journalctl -u code-server@root -f --no-pager ) &
    LOG_PID=$!
}

stop_logs() {
    if [[ -n "$LOG_PID" ]]; then
        kill "$LOG_PID" 2>/dev/null || true
        wait "$LOG_PID" 2>/dev/null || true
        LOG_PID=""
    fi
    pkill -f "journalctl -u code-server@root" 2>/dev/null || true
}

confirm_stop() {
    if [[ "$HANDLING" -eq 1 ]]; then
        return
    fi
    HANDLING=1
    trap '' SIGINT
    stop_logs
    echo
    read -rp "Are you sure you want to stop code-server? (y/n): " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        STOPPING=1
    else
        echo "Resuming logs... (press Ctrl+C again to stop)"
        start_logs
        HANDLING=0
        trap confirm_stop SIGINT
    fi
}

trap confirm_stop SIGINT
start_logs

while [[ "$STOPPING" -eq 0 ]]; do
    sleep 1
done

stop_logs
echo
echo "[+] Stopping code-server (files will not be removed)..."
systemctl stop code-server@root 2>/dev/null || true
systemctl disable code-server@root 2>/dev/null || true
pkill -f "code-server" 2>/dev/null || true
sleep 1
pkill -9 -f "code-server" 2>/dev/null || true
echo
echo "Done. code-server has been fully stopped (installation and files remain intact)."
