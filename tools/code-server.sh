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

# --- wait for user to type STOP ---
while true; do
    read -rp "Type STOP and press Enter to stop the service: " CONFIRM
    if [[ "$CONFIRM" == "STOP" ]]; then
        break
    else
        echo "Invalid input. Please type STOP exactly."
    fi
done

echo "[+] Stopping code-server (files will not be removed)..."
systemctl stop code-server@root 2>/dev/null || true
systemctl disable code-server@root 2>/dev/null || true

echo
echo "Done. code-server has been stopped, but installation and files remain intact."
