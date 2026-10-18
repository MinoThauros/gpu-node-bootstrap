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
3. In `boot/grub/grub.cfg` on the stick, add `ds=nocloud\;s=/cdrom/nocloud/` to the first `linux` line, before `---`.

## After the install

- Copy anything you need off the old data disk (`sudo mount -o ro /dev/sdX1 /mnt` for NTFS), then repurpose it.
- The UBUNTUINST partition can be deleted once you're happy.
- Add an SSH key (`ssh-copy-id user@host` from your laptop), then set `PasswordAuthentication no`.
- Next: join k3s (see README roadmap).
