# 02 — Ubuntu + NVIDIA driver

Bare metal to a host that can hand a GPU to a container. Everything except the NVIDIA driver runs in Docker, so the host stays small and a rebuild is repeatable.

| Component | Version on groot |
|---|---|
| OS | Ubuntu Server 26.04.1 LTS, kernel 7.0 |
| NVIDIA driver | 595.91.07, open kernel modules, from Ubuntu's repo (`nvidia-utils-595-server`) |
| Docker | Docker CE 29.9, from Docker's apt repo |
| nvidia-container-toolkit | 1.20.1 |

**One driver source.** Use Ubuntu's packaged driver only. Mixing the NVIDIA `.run` installer, NVIDIA's CUDA apt repo and Ubuntu packages is the classic way to break a GPU box. Don't:

- use the NVIDIA `.run` installer;
- add NVIDIA's CUDA apt repo;
- install the CUDA toolkit on the host. Containers bring their own CUDA; the host only needs the driver.

## 1. BIOS

MSI Z490-A PRO (see [01-hardware.md](01-hardware.md)):

| Setting | Value | Why |
|---|---|---|
| Boot mode | UEFI, CSM off | |
| Secure Boot | Off | Ubuntu's driver modules are signed, but off removes the most common cause of "No devices were found" on a headless server |
| Above 4G Decoding | On | |
| Resizable BAR | On | |
| Initiate Graphic Adapter | PEG | The i7-10700KF has no iGPU; plug the install monitor into the main GPU |
| Fast Boot, Memory Fast Boot | Off | |
| Restore after AC Power Loss | On | Comes back after an outage |
| ErP | Off | |

**Memory.** Four 32 GB DDR4-3600 sticks are past what the 10700KF's memory controller is rated for (2933), so aim for stability:

1. XMP (3600) with Memory Fast Boot off. groot runs here.
2. If it fails to train or memtest throws errors: 3200 with the XMP timings and voltage.
3. Still unstable: 2933.

Run [memtest86+](https://www.memtest.org/) for at least one full pass, overnight if possible. The 3600 vs 3200 difference (~11% bandwidth) only matters for models that spill into system RAM, like `local-deep`. _On groot this pass is still to do._

## 2. Disk layout

| Drive | Slot | Mount | Holds |
|---|---|---|---|
| Samsung 970 EVO 500 GB (NVMe) | M2_1 | `/` (LVM) | OS, Docker, `/srv/ai`, `/srv/data` |
| WD SN750 500 GB (NVMe) | M2_2 | `/srv/models/ollama` | LLMs (fastest load for the models you switch between) |
| Crucial BX500 2 TB (SATA) | SATA1 | `/srv/models/comfyui` | Image/video models, render outputs |
| Crucial BX500 1 TB (SATA) | SATA3 | `/srv/backup` | Local nightly backups |

Video models load once per render, so SATA speed costs a few seconds against a multi-minute job. `ollama-ha`'s model store (`/srv/models/ollama-ha`, one 8B model) has no mount of its own and lives on the OS disk.

## 3. Install Ubuntu Server

Stock installer. In the installer:

- set up **only the OS drive** (the default LVM layout); leave the other three untouched;
- choose **OpenSSH server**;
- leave **third-party drivers unchecked**, so you pick the driver branch yourself in step 5;
- give it a static address (or set it afterwards, step 4).

After the first boot:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo hostnamectl set-hostname groot
sudo timedatectl set-timezone <your timezone>          # e.g. Europe/London
sudo apt install -y build-essential linux-headers-$(uname -r) git curl htop nvtop
```

Format the three data drives **with labels** and mount them by label. Device names (`nvme0n1`, `sda`) can change between boots; labels don't.

```bash
lsblk -o NAME,MODEL,SIZE                                # identify the drives by model

sudo mkfs.ext4 -L ollama  /dev/nvmeXn1                  # WD SN750 500 GB
sudo mkfs.ext4 -L comfyui /dev/sdX                      # 2 TB SATA
sudo mkfs.ext4 -L backup  /dev/sdX                      # 1 TB SATA

sudo mkdir -p /srv/models/ollama /srv/models/comfyui /srv/backup /srv/data
sudo tee -a /etc/fstab <<EOT
LABEL=ollama  /srv/models/ollama  ext4 defaults,noatime 0 2
LABEL=comfyui /srv/models/comfyui ext4 defaults,noatime 0 2
LABEL=backup  /srv/backup         ext4 defaults,noatime 0 2
EOT
sudo systemctl daemon-reload && sudo mount -a
sudo chown -R $USER: /srv/models/comfyui /srv/backup
df -h | grep /srv
```

## 4. Static IP

groot uses the onboard Realtek RTL8125 2.5GbE (`enp111s0` on this board; check yours with `ip -br link`). If the installer set the address, it's in `/etc/netplan/00-installer-config.yaml`. Otherwise:

```yaml
network:
  version: 2
  ethernets:
    enp111s0:                       # from ip -br link
      dhcp4: false
      addresses: [<groot LAN IP>/<prefix>]
      routes:
        - to: default
          via: <gateway IP>
      nameservers:
        addresses: [<DNS IP>]
```

```bash
sudo netplan apply
```

Keep the address outside your router's DHCP pool. A new motherboard means a new NIC name, so update the netplan file after a board swap.

## 5. NVIDIA driver

```bash
sudo ubuntu-drivers list --gpgpu                        # what's offered for your card
sudo ubuntu-drivers install --gpgpu nvidia:595-server-open
# no -server-open entry listed?  sudo ubuntu-drivers install nvidia:595-open
sudo reboot
```

- `--gpgpu` installs the compute/headless driver, with no desktop stack.
- `-open` is NVIDIA's open kernel module, the recommended choice for Turing and newer (both the 3090 and the 2060).
- The modules come prebuilt and signed (`linux-modules-nvidia-595-server-open-*`) and are updated together with each kernel, so a kernel update doesn't need a DKMS rebuild.
- A 615 server-open branch was also offered; groot stays on 595, the more established branch.

**`--gpgpu` leaves out the CLI tools**, including `nvidia-smi`. Install the utils package whose version matches the loaded driver:

```bash
cat /proc/driver/nvidia/version                         # e.g. 595.91.07
apt policy nvidia-utils-595-server                      # Candidate must match it
sudo apt install -y nvidia-utils-595-server
nvidia-smi                                              # card(s), memory, driver 595.x
```

### Persistence mode

Ubuntu starts `nvidia-persistenced` with `--no-persistence-mode`, so the driver tears down state when the GPU goes idle. The drop-in [`systemd/nvidia-persistenced.service.d/override.conf`](../systemd/nvidia-persistenced.service.d/override.conf) replaces the start command:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --verbose
```

From the repo clone:

```bash
sudo install -D -m 644 systemd/nvidia-persistenced.service.d/override.conf \
  /etc/systemd/system/nvidia-persistenced.service.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart nvidia-persistenced
nvidia-smi --query-gpu=persistence_mode --format=csv    # Enabled
```

(`scripts/setup.sh` installs this drop-in too; if it's already there, setup leaves it alone.)

The GPU **power limit** is set per card by UUID: see [04-multi-gpu.md](04-multi-gpu.md#1-power-limit-target-one-card).

### If `nvidia-smi` fails

| Symptom | Check | Fix |
|---|---|---|
| "No devices were found", module not loaded | `lsmod \| grep nvidia`, `mokutil --sb-state` | Turn Secure Boot off, or enroll the MOK key when prompted at boot |
| Nouveau still loaded | `lsmod \| grep nouveau` | `sudo update-initramfs -u` and reboot (the driver package blacklists it) |
| Errors after an update | `dmesg \| grep -i nvidia` | `sudo apt purge 'nvidia-*' 'libnvidia-*' && sudo apt autoremove`, reboot, reinstall as above |
| A second card is missing, "fallen off the bus" | `lspci`, `dmesg` | Hardware, not driver: see [troubleshooting](troubleshooting.md#gpu-fallen-off-the-bus-after-installing-a-second-card) |

## 6. Docker CE + NVIDIA Container Toolkit

The official commands from Docker and NVIDIA. They read the release codename from the system, so nothing changes for 26.04.

```bash
# Docker CE
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<EOT
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOT
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER                           # log out and back in

# NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### Log rotation: `daemon.json`

Docker's default `json-file` logs grow forever. [`host/docker-daemon.json`](../host/docker-daemon.json) keeps the `nvidia` runtime entry that `nvidia-ctk` just wrote and caps each container's logs at 3 × 10 MB:

```json
{
  "runtimes": {
    "nvidia": { "args": [], "path": "nvidia-container-runtime" }
  },
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

```bash
sudo install -m 644 host/docker-daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
```

`nvidia-ctk` has already created `/etc/docker/daemon.json`. `scripts/setup.sh` adds `log-driver` and `log-opts` to it if they're missing (the original is saved as `daemon.json.pre-setup`) and changes nothing else; or install the repo file by hand as above. Either way, restart Docker. Log options apply to new containers, so after the stack is up once, recreate it: `cd /srv/ai && docker compose up -d --force-recreate`.

### Verify

```bash
docker run --rm --gpus all ubuntu nvidia-smi
```

The same table as on the host means the GPU plumbing is done.

## 7. Updates: blacklist kernel and NVIDIA, don't hold them

Unattended-upgrades installs security updates daily. Left alone, it can update the NVIDIA userspace libraries while the old kernel module is still loaded, and every GPU job fails with "Driver/library version mismatch" until a reboot.

[`host/51unattended-nvidia`](../host/51unattended-nvidia) keeps those packages out of unattended runs:

```
Unattended-Upgrade::Package-Blacklist {
    "linux-";
    "nvidia-";
    "libnvidia-";
};
```

```bash
sudo install -m 644 host/51unattended-nvidia /etc/apt/apt.conf.d/51unattended-nvidia
```

**Why a blacklist, not `apt-mark hold`:** the driver's kernel modules are Ubuntu's prebuilt, signed packages, which already move in lockstep with the kernel, so there's nothing to freeze. The only risk is the *timing*: userspace updated in the background while the old module is loaded. The blacklist removes exactly that and leaves the packages upgradable. Once a month, update kernel and driver together, by hand:

```bash
sudo apt update && sudo apt full-upgrade -y && sudo reboot
nvidia-smi                                              # after the reboot
```

`scripts/monthly-update.sh` wraps this, plus container and firmware updates.

## 8. Record the result

[`scripts/groot-gpu-audit.sh`](../scripts/groot-gpu-audit.sh) prints the board and BIOS, driver and package versions, every GPU (UUID, power limit, PCIe link), GPU processes, storage, the power-limit and NVIDIA services, Docker runtimes, and the GPU sections of the compose file. It's read-only.

```bash
sudo bash scripts/groot-gpu-audit.sh > ~/gpu-audit-$(date +%F).txt
```

Keep the output; it's the "before" to compare against after any hardware or driver change.

Next: [03 — Docker stack](03-docker-stack.md), or run `sudo bash scripts/setup.sh` (see the [README](../README.md#quick-start)).
