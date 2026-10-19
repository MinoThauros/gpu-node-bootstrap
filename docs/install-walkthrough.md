# Install walkthrough

Everything after "Before you start" happens at the machine's own keyboard and screen.
Once the old OS is wiped there is nothing left on the box to run scripts from, so plan to be there.

## Before you start

- [ ] Data on the target disk is backed up (it will be erased).
- [ ] Old credentials stored on the machine are revoked in their accounts (GitHub tokens, cloud keys). Wiping the disk deletes the local copy, not the key.
- [ ] BIOS updated and configured: [bios-settings.md](bios-settings.md).
- [ ] GPU installed and powered (see "GPU swap" below). The driver supports old and new cards, so swap before installing to avoid an extra cycle.
- [ ] **Ethernet cable plugged in.** The installer and the first-boot script need internet; Wi-Fi is not configured.
- [ ] Installer ready: either the UBUNTUINST partition (`windows/make-installer-partition.ps1`) or a USB stick (below).

## GPU swap

1. Shut down, switch the PSU off, unplug.
2. Remove the old card, seat the new one in the top x16 slot.
3. Power: RTX 5070 Ti is ~300 W through a 16-pin 12V-2x6 connector. Use the adapter from the box with **one separate PSU cable per 8-pin**, no daisy-chained pigtails. NVIDIA recommends a 750 W+ PSU.
4. Plug the monitor into the **GPU**, not the motherboard.

## Boot the installer

1. Power on, tap the boot-menu key (**F8** on ASUS) at the logo.
2. Pick **`UEFI: <installer disk>, Partition N`** (with a USB stick: `UEFI: <stick name>`).
3. GRUB menu: the first entry, **AUTOINSTALL GPU node**, is pre-selected. Press **Enter** (it auto-starts after 30 s).

### Black screen or "out of range" after picking the entry

Ubuntu 24.04's built-in nouveau driver predates RTX 50 (Blackwell) cards; when it tries to take over the display it
blanks it or switches to a mode the monitor rejects ("out of range"). Both AUTOINSTALL entries boot with
`modprobe.blacklist=nouveau nouveau.modeset=0`, which keeps nouveau off so the console stays on the firmware
framebuffer, and the installed system blacklists nouveau until the NVIDIA driver is in.

Don't use `nomodeset`: in testing it gave a black screen, most likely because on 24.04 it also disables simpledrm
(the firmware-framebuffer console). Verified on an RTX 5070 Ti over HDMI to an ASUS ROG 34" ultrawide, October 2026.

If you still get a black screen:

- Wait ~2 minutes: the first screen can take a while on a slow disk.
- Check the GRUB entry (`e`) still reads `... ds=nocloud\;s=/cdrom/nocloud/ modprobe.blacklist=nouveau nouveau.modeset=0 ---`
  and `set gfxpayload=keep`. Edits made there last for one boot only.
- Try the second entry, **AUTOINSTALL GPU node - fallback: HWE kernel**.
- Try another output on the card (DisplayPort vs HDMI), and make sure the cable is in the GPU.
- A white **VGA** Q-LED on the motherboard means the card isn't seated or powered: reseat it with the PC on its side,
  screw the bracket down, and fill every socket of the power adapter with a full 8-pin PCIe plug (never a CPU/EPS cable).
- Don't change the resolution in GRUB (`gfxpayload`/`video=`): a mode the monitor can't show causes "out of range" on its own.

## What you'll be asked

| Prompt | What to do |
|---|---|
| `Continue with autoinstall? (yes\|no)` | Type **yes**. Last chance to back out — nothing has been written yet. |
| Keyboard configuration | Pick your layout (e.g. *French (Canada)* or *English (US)*). |
| Profile: name, server name, username, password | Server name e.g. `gpu-node-1`. You'll use the username/password for SSH and `sudo`. |

Then it runs on its own: partitions and formats the target SSD, installs Ubuntu, applies updates, installs SSH,
drops the first-boot script in place, and **reboots by itself** (~15–20 min).

## First boot

The `gpu-node-setup` service runs automatically (~10 min, needs internet):
updates the system, installs the NVIDIA driver and the Container Toolkit, then **reboots once more**.
You can watch it on the console or, after logging in, with:

```bash
sudo journalctl -fu gpu-node-setup
```

## Check it worked

```bash
nvidia-smi                                  # should list the GPU and driver version
nvidia-ctk --version                        # container toolkit present
cat /var/log/gpu-node-setup.log | tail -20  # setup log
hostname -I                                 # the IP to SSH to from other machines
```

If `nvidia-smi` fails, re-run the setup:

```bash
sudo rm -f /var/lib/gpu-node-setup.done && sudo systemctl start gpu-node-setup
```

## Using a USB stick instead

1. Write the Ubuntu Server ISO to the stick with Rufus in **ISO mode** (not DD), FAT32.
2. Copy `autoinstall/user-data` (with `__TARGET_DISK_SERIAL__` replaced), `autoinstall/meta-data` and both `firstboot/` files into a `nocloud/` folder at the root of the stick.
3. In `boot/grub/grub.cfg` on the stick, add `ds=nocloud\;s=/cdrom/nocloud/ modprobe.blacklist=nouveau nouveau.modeset=0` to the first `linux` line, before `---` (RTX 50 cards need the nouveau part).

## After the install

- Copy anything you need off the old data disk (`sudo mount -o ro /dev/sdX1 /mnt` for NTFS), then repurpose it.
- The UBUNTUINST partition can be deleted once you're happy.
- Add an SSH key (`ssh-copy-id user@host` from your laptop), then set `PasswordAuthentication no`.
- Next: join k3s (see README roadmap).
