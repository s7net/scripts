#!/usr/bin/env bash

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "     Fish + Starship Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Root check
if [ "$EUID" -eq 0 ]; then
    USER_HOME="/root"
    USER_NAME="root"
else
    USER_HOME="$HOME"
    USER_NAME="$(whoami)"
fi

echo
echo "📦 Installing Fish..."

if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y fish curl
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y fish curl
elif command -v yum >/dev/null 2>&1; then
    yum install -y fish curl
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm fish curl
else
    echo "Unsupported package manager."
    exit 1
fi

echo
echo "⭐ Installing Starship..."

curl -sS https://starship.rs/install.sh | sh -s -- -y

mkdir -p "$USER_HOME/.config/fish"

cat > "$USER_HOME/.config/fish/config.fish" <<'EOF'
starship init fish | source
EOF

mkdir -p "$USER_HOME/.config"

cat > "$USER_HOME/.config/starship.toml" <<'EOF'
add_newline = true

format = """
╭─$username$hostname
├─$directory$git_branch$git_status
╰─$character
"""

[username]
show_always = true
style_user = "bold #00D7C3"
style_root = "bold #00D7C3"
format = "[$user]($style)"

[hostname]
ssh_only = false
style = "bold white"
format = "[@$hostname]($style)"

[directory]
style = "#E8E8E8"
truncation_length = 3
truncate_to_repo = false
read_only = " 🔒"
format = "[$path]($style)"

[git_branch]
symbol = " ("
format = " [$branch)](bold #00D7C3)"

[git_status]
format = " [$all_status$ahead_behind](yellow)"

[character]
success_symbol = "[❯](bold #00D7C3)"
error_symbol = "[❯](bold #FF5C7A)"
vimcmd_symbol = "[❮](bold #00D7C3)"

[package]
disabled = true

[nodejs]
disabled = true

[python]
disabled = true

[rust]
disabled = true

[golang]
disabled = true

[docker_context]
disabled = true

[kubernetes]
disabled = true

[aws]
disabled = true

[gcloud]
disabled = true

[time]
disabled = true
EOF

echo
read -rp "Change default shell to Fish? (Y/n): " ans

if [[ ! "$ans" =~ ^[Nn]$ ]]; then
    FISH_PATH=$(command -v fish)

    if ! grep -q "$FISH_PATH" /etc/shells; then
        echo "$FISH_PATH" >> /etc/shells
    fi

    chsh -s "$FISH_PATH" "$USER_NAME" || true
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Installation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "Restart your SSH session or run:"
echo
echo "    exec fish"
echo
echo "Expected prompt:"
echo
echo "╭─ root@Console"
echo "├─ /opt/pasarguard (main)"
echo "╰─❯"
echo
