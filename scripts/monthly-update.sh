#!/usr/bin/env bash
# monthly-update.sh — the whole monthly routine for the server, with a prompt at each step.
#   1. containers (one at a time, health check between each)
#   2. Ollama models (optional)
#   3. Ubuntu incl. kernel + NVIDIA (the packages unattended-upgrades skips)
#   4. firmware check (report only)
#   5. reboot + post-reboot check
set -uo pipefail
cd /srv/ai
ask() { local a; read -rp "$1 " a </dev/tty; echo "${a,,}"; }
step() { echo; printf '═%.0s' {1..70}; echo; echo "  $*"; printf '═%.0s' {1..70}; echo; }

step "1/5  Containers"
./update-image.sh --all

step "2/5  Ollama models"
if [[ $(ask "Re-pull Ollama models? Only changed layers download; gpt-oss:120b can be large. [y/N]") == y ]]; then
  docker exec ai-ollama-1 ollama list | awk 'NR>1{print $1}' | while read -r m; do
    echo "-> $m"; docker exec ai-ollama-1 ollama pull "$m" </dev/null
  done
fi

step "3/5  Ubuntu packages (kernel + NVIDIA included)"
sudo apt update
apt list --upgradable 2>/dev/null | tail -n +2
if [[ $(ask "Run apt full-upgrade? [y/N]") == y ]]; then
  sudo apt full-upgrade
fi

step "4/5  Firmware (report only)"
fwupdmgr refresh --force >/dev/null 2>&1 || true
fwupdmgr get-upgrades 2>/dev/null | grep -E '^\S|New version|Summary' || echo "No firmware updates."
echo "Install with: sudo fwupdmgr update   (BIOS: use MSI M-Flash, not fwupd)"

step "5/5  Reboot"
if [[ -f /var/run/reboot-required ]]; then
  echo "A reboot is required:"; cat /var/run/reboot-required.pkgs 2>/dev/null | sed 's/^/  /'
fi
echo "After reboot, check with:"
echo "  nvidia-smi && docker compose -f /srv/ai/compose.yaml ps && sudo /usr/local/bin/aihub-mon --dry-run"
if [[ $(ask "Reboot now? [y/N]") == y ]]; then sudo reboot; fi
