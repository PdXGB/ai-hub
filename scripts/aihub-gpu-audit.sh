#!/usr/bin/env bash
# aihub GPU audit — read-only, changes nothing
sec(){ printf '\n===== %s =====\n' "$1"; }

sec "SYSTEM"
hostnamectl | grep -E 'hostname|Operating|Kernel'
echo "Board: $(dmidecode -s baseboard-product-name)  BIOS: $(dmidecode -s bios-version) ($(dmidecode -s bios-release-date))"
free -h | head -2

sec "NVIDIA DRIVER + PACKAGES"
cat /proc/driver/nvidia/version
dpkg -l | awk '/^ii/ && /nvidia-driver|nvidia-container-toolkit|nvidia-utils|cuda-toolkit/ {print $2, $3}'

sec "GPUS"
nvidia-smi -L
nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,power.limit,power.default_limit,persistence_mode,pcie.link.gen.current,pcie.link.width.current,pcie.link.width.max,memory.used,memory.total,temperature.gpu --format=csv

sec "GPU PROCESSES"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

sec "PCI DEVICES + GPU LINK"
lspci | grep -Ei 'vga|3d controller|non-volatile|sata|ethernet'
for d in $(lspci -D | awk '/NVIDIA/ && /VGA|3D/ {print $1}'); do
  echo "-- $d"; lspci -vv -s "$d" | grep -E 'LnkCap:|LnkSta:'
done

sec "STORAGE"
lsblk -o NAME,MODEL,SIZE,TYPE,TRAN,MOUNTPOINT
ls -l /dev/disk/by-path/ | grep -v part

sec "POWER LIMIT / NVIDIA SERVICES"
systemctl list-unit-files --no-pager | grep -i nvidia
grep -rnE 'nvidia-smi.*(-pl|--power-limit|-i )' /etc/systemd /etc/cron* /etc/rc.local /var/spool/cron 2>/dev/null

sec "DOCKER"
docker version --format 'Docker {{.Server.Version}}'
docker info 2>/dev/null | grep -iE 'runtimes|default runtime|cgroup driver'
echo "--- /etc/docker/daemon.json"; cat /etc/docker/daemon.json 2>/dev/null
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

sec "CONTAINER GPU / RESTART CONFIG"
for c in $(docker ps -aq); do
  docker inspect --format '{{.Name}} | restart={{.HostConfig.RestartPolicy.Name}} | runtime={{.HostConfig.Runtime}} | gpus={{json .HostConfig.DeviceRequests}}' "$c"
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$c" \
    | grep -E '^(NVIDIA_VISIBLE|CUDA_VISIBLE|CUDA_DEVICE_ORDER|OLLAMA_)' | sed 's/^/    /'
done

sec "COMPOSE FILES - GPU STANZAS"
for f in $(docker ps -aq | xargs -r docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' | tr ',' '\n' | sort -u); do
  [ -f "$f" ] || continue
  echo "--- $f"
  grep -nE 'deploy:|devices:|device_ids|count:|capabilities|gpus:|runtime:|NVIDIA_VISIBLE|CUDA_VISIBLE|OLLAMA_' "$f"
done

echo; echo "===== END ====="
