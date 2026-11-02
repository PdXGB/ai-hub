#!/usr/bin/env bash
# install-aichat.sh - terminal agent for the server (docs/13 §5). Run as your own user, not root:
#
#   AIHUB_TERMINAL_KEY=sk-... bash scripts/install-aichat.sh      (key: LiteLLM virtual key "terminal")
#
# Installs aichat (single binary, github.com/sigoden/aichat) to ~/.local/bin, points it at LiteLLM,
# and lets plain ssh / aichat reach the Remote Shell inventory (/srv/ai/ssh/hosts.conf) with your own
# key (~/.ssh/aihub-terminal). Re-runs keep an existing config. AICHAT_VERSION=v0.x.y pins a version.
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "Run as your own user, not root." >&2; exit 1; }
BIN=$HOME/.local/bin
CONF=$HOME/.config/aichat/config.yaml
SSH_DIR=${AIHUB_SSH_DIR:-/srv/ai/ssh}
ARCH=$(uname -m)   # x86_64 / aarch64

# 1. binary
VER=${AICHAT_VERSION:-$(curl -fsSL https://api.github.com/repos/sigoden/aichat/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')}
URL="https://github.com/sigoden/aichat/releases/download/$VER/aichat-$VER-$ARCH-unknown-linux-musl.tar.gz"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "Downloading aichat $VER ($ARCH)…"
curl -fsSL "$URL" -o "$tmp/a.tgz"
tar -xzf "$tmp/a.tgz" -C "$tmp" aichat
install -D -m 755 "$tmp/aichat" "$BIN/aichat"
echo "Installed $BIN/aichat ($("$BIN/aichat" --version)); sha256 $(sha256sum "$tmp/a.tgz" | cut -c1-16)…"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Add to PATH: echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.bashrc" ;; esac

# 2. config (LiteLLM on localhost; the key decides which routes it may use)
if [ -e "$CONF" ]; then
  echo "Kept existing $CONF"
else
  KEY=${AIHUB_TERMINAL_KEY:-}
  [ -n "$KEY" ] || { read -r -s -p "LiteLLM virtual key for aichat (docs/13 §5): " KEY; echo; }
  install -d -m 700 "$(dirname "$CONF")"
  umask 077
  cat > "$CONF" <<EOF
# aichat -> LiteLLM (docs/13 §5). Pick a model per call: aichat -m litellm:claude -e "…"
model: litellm:local-fast
save: false
clients:
  - type: openai-compatible
    name: litellm
    api_base: http://127.0.0.1:4000/v1
    api_key: $KEY
    models:
      - name: local-fast
        supports_function_calling: true
      - name: local-deep
      - name: claude
        supports_function_calling: true
      - name: gemini
        supports_function_calling: true
EOF
  echo "Wrote $CONF (mode 600)"
fi

# 3. ssh: your own key + the shared inventory and pinned host keys
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
[ -f "$HOME/.ssh/aihub-terminal" ] || ssh-keygen -q -t ed25519 -N '' -C "aihub-terminal@$(hostname)" -f "$HOME/.ssh/aihub-terminal"
CFG=$HOME/.ssh/config; touch "$CFG"; chmod 600 "$CFG"
if ! grep -qF "Include $SSH_DIR/hosts.conf" "$CFG"; then
  # Include must come first: an Include after a Host line would only apply inside that Host block
  { echo "Include $SSH_DIR/hosts.conf   # Remote Shell inventory (aihub-enroll)"; echo; cat "$CFG"; } > "$CFG.new" && mv "$CFG.new" "$CFG"
  # Any IdentityFile switches off ssh's default keys, so list the ones you already have first (missing ones would warn)
  IDS=""; for k in id_ed25519 id_ecdsa id_rsa; do [ -f "$HOME/.ssh/$k" ] && IDS+="  IdentityFile ~/.ssh/$k"$'\n'; done
  cat >> "$CFG" <<EOF

# Remote Shell (docs/13): your usual keys, then the aihub-terminal key; pinned inventory host keys
Host *
${IDS}  IdentityFile ~/.ssh/aihub-terminal
  UserKnownHostsFile ~/.ssh/known_hosts $SSH_DIR/known_hosts
EOF
  echo "Updated $CFG"
fi
cat <<EOF

Done. Try:
  ssh <alias> uptime                             (any host added with aihub-enroll)
  aichat -e "how much disk is free on nas"       (shows the command; you pick execute / revise / describe)
  aichat -m litellm:claude -e "…"                (a cloud model for harder ones)
EOF
