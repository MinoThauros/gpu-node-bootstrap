# BIOS settings for a GPU node

Written for ASUS AM4 boards (menu names are from the TUF GAMING X570-PLUS); other vendors use similar names.

## Update the BIOS first

Old firmware lacks years of CPU security fixes (e.g. AMD Sinkclose, fixed in AGESA 1.2.0.Cc) and may lack
Resizable BAR or a UEFI path new GPUs need. Update **before** wiping the old OS if you stage the update file on its disk.

ASUS, no USB stick: put the `.CAP` file on any FAT32 partition the firmware can see (e.g. the existing EFI
system partition), then **Tool → ASUS EZ Flash 3 → via Storage Device(s)**. Don't power off while it flashes;
the first boot afterwards can sit on a black screen for 1–2 minutes while it retrains memory.

## Settings

Load optimized defaults (**F5**) after flashing, then:

| Setting (ASUS path) | Value | Why |
|---|---|---|
| Boot → CSM | **Disabled** | Pure UEFI boot. Newer cards (RTX 50 series) may show no picture with CSM on; modern Linux expects UEFI. |
| Advanced → PCI Subsystem → Above 4G Decoding | **Enabled** | Lets the CPU address GPU memory above 4 GB. Required for Resizable BAR. |
| Advanced → PCI Subsystem → Re-Size BAR | **Enabled** | CPU sees all GPU VRAM at once instead of 256 MB windows. |
| Advanced → CPU Configuration → SVM Mode | **Enabled** | CPU virtualization (VMs, KubeVirt, etc.). |
| Advanced → APM → Restore AC Power Loss | **Power On** | After a power cut the node boots itself and rejoins the cluster. |
| Ai Tweaker → DOCP / XMP | **Enabled** | Runs RAM at its rated speed instead of the 2133 MHz fallback. |

Save with **F10**.

## Check from Linux

```bash
sudo dmidecode -s bios-version                    # firmware version
[ -d /sys/firmware/efi ] && echo UEFI             # booted in UEFI mode
sudo lspci -vv -s $(lspci | awk '/VGA.*NVIDIA/{print $1}') | grep -A2 -i "resizable bar"
grep -c svm /proc/cpuinfo                         # > 0 means virtualization is on
sudo dmidecode -t memory | grep -i "configured memory speed"
```
