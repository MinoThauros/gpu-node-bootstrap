# tuf-x570-gpu1

Former Windows 10 desktop, converted to a k3s GPU node in October 2026.

## Hardware

| Part | Detail |
|---|---|
| Motherboard | ASUS TUF GAMING X570-PLUS (WI-FI), BIOS **5021** (was 1407) |
| CPU | AMD Ryzen 7 3700X (8C/16T) |
| RAM | 32 GB (2 × 16 GB Corsair CMW32GX4M2C3200C16) @ 3200 |
| GPU | NVIDIA RTX 5070 Ti 16 GB (replaced RTX 2080 8 GB) |
| OS disk | Samsung SSD 850 EVO 500 GB — serial `S2RANX0H710744R` (**install target**) |
| Data disk | WDC WD5000AAKX 500 GB HDD — serial `WD-WMAYUP101743` (kept: old `D:` with `pc-backup`, plus UBUNTUINST partition) |
| Network | Onboard Ethernet (use this); Intel Wireless-AC 9260 Wi-Fi |

## How it was built

```powershell
.\windows\make-installer-partition.ps1 -Iso D:\Download\ubuntu-iso\ubuntu-24.04.5-live-server-amd64.iso `
    -ShrinkDrive D -InstallerDiskSerial WD-WMAYUP101743 -TargetDiskSerial S2RANX0H710744R
```

- ISO: `ubuntu-24.04.5-live-server-amd64.iso`, SHA-256 `97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8`, signature on `SHA256SUMS` verified against Ubuntu's signing key.
- D: shrunk from 465.8 GB to 459.8 GB; UBUNTUINST is a 6 GB FAT32 partition #2 on the WD disk (MBR).
- BIOS settings per [../docs/bios-settings.md](../docs/bios-settings.md).

## Before the wipe (done)

- Personal code pushed to GitHub; course files in private repo `uottawa-ee-coursework`.
- Everything else (personal docs, photos, textbooks, work code) copied to `D:\pc-backup` on the WD disk.
- The old 76 GB Linux partition on the SSD was an untouched 2019 install — nothing to keep.

## Installed state (verified 2026-10-18)

Recorded right after the install, with `nvidia-smi` working. To rebuild to the same driver branch, the first-boot
script defaults to `NVIDIA_DRIVER_BRANCH=615`. Exact package versions can drift as Ubuntu publishes updates.

| Item | Version |
|---|---|
| Hostname | `<gpu-host>` |
| Ubuntu | 24.04.5 LTS |
| Kernel | `7.0.0-38-generic` (HWE) |
| NVIDIA driver | 615.71.09, `server-open`, Ubuntu's prebuilt signed modules (`linux-modules-nvidia-615-server-open-7.0.0-38-generic`) |
| GPU VBIOS | 98.03.58.40.97 |
| NVIDIA Container Toolkit | 1.20.1 |

| Disk | Layout |
|---|---|
| `sda` Samsung 850 EVO | `sda1` 1 GB vfat `/boot/efi`, `sda2` 464.7 GB ext4 `/` |
| `sdb` WDC WD5000AAKX | `sdb1` 459.8 GB NTFS (old `D:`, holds `pc-backup`), `sdb2` 6 GB vfat UBUNTUINST |

Install notes: the GRUB entry needed `modprobe.blacklist=nouveau nouveau.modeset=0` with `gfxpayload=keep` to get a
picture (fixed in `windows/make-installer-partition.ps1`). `nomodeset` gave a black screen; forcing a resolution gave
"out of range". The card also came unseated twice (white VGA Q-LED): seat it with the PC on its side and screw the
bracket down before plugging in display cables.

## After the wipe (to do)

- [ ] Copy `pc-backup` off the WD disk to permanent storage, then repurpose the disk (e.g. k3s local storage).
- [ ] Add SSH key, disable password login.
- [ ] Join k3s as a GPU agent: `k3s/join-agent.sh` on the node, then `kubectl apply -f k3s/cluster/` ([../docs/join-cluster.md](../docs/join-cluster.md)).
- [ ] Verify: `kubectl get nodes -L nvidia.com/gpu.present`, `nvidia.com/gpu: 1` in `kubectl describe node`, `gpu-test` pod logs show the RTX 5070 Ti.
- [ ] Record here: node IP, k3s version (driver version and hostname recorded above).
