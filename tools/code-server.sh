#!/usr/bin/env bash

set -e

PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)

echo "[+] Installing code-server..."
curl -fsSL https://code-server.dev/install.sh | sh

mkdir -p /root/.config/code-server

cat >/root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:8443
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
echo " URL      : http://$IP:8443"
echo " Password : $PASSWORD"
echo "============================================="
echo
read -rp "Press Enter when you are finished..."

echo "[+] Removing code-server..."

systemctl stop code-server@root 2>/dev/null || true
systemctl disable code-server@root 2>/dev/null || true

rm -rf /root/.config/code-server
rm -rf /root/.local/share/code-server
rm -rf /root/.cache/code-server

if command -v apt >/dev/null; then
    apt remove -y code-server >/dev/null 2>&1 || true
    apt purge -y code-server >/dev/null 2>&1 || true
    apt autoremove -y >/dev/null 2>&1 || true
fi

rm -f /usr/bin/code-server
rm -f /usr/lib/systemd/system/code-server@.service
rm -rf /usr/lib/code-server

systemctl daemon-reload

echo
echo "Done. code-server has been completely removed."
