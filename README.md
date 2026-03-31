# Arch Linux Automated Installer (LVM on LUKS)

This repository contains a robust, fully automated shell script for installing Arch Linux. It is designed to take a bare metal drive and turn it into a fully configured, encrypted, and daily-driver-ready operating system with minimal user intervention.

**WARNING:** This script will permanently destroy all data on the target disk. Double-check your drive selection before proceeding.

## Features

* **Interactive Setup:** Prompts for all variables (passwords, hostnames, desktop environments) upfront, then executes the entire installation unattended.
* **Encrypted LVM (LVM on LUKS):** Creates a secure LUKS container holding Logical Volumes for `swap`, `root`, and `home`. You only need to enter your passphrase once at boot.
* **Hibernation Support:** Securely suspends to an encrypted LVM swap partition (32GB) and configures the `resume` mkinitcpio hook and kernel parameters.
* **SSD Optimization:** Automatically enables continuous TRIM (`allow-discards` parameter) and configures the weekly `fstrim.timer`.
* **Hardware Detection:** Automatically detects Intel/AMD processors and installs the appropriate microcode updates.
* **Mirror Optimization:** Uses `reflector` to fetch the 10 fastest HTTPS mirrors before downloading packages.
* **Network Discovery & Extras:** Pre-configures Avahi (mDNS), Bluetooth, NTP time synchronization, and power management daemons out of the box.
* **Desktop Environments:** Offers a choice between GNOME, KDE Plasma, or a Headless (CLI-only) installation.

---

## Prerequisites

1. Boot into the official Arch Linux live USB environment (UEFI mode).
2. Ensure you have an active internet connection (`ping archlinux.org`).
3. Download or copy the `install_arch.sh` script to the live environment.

## Usage

1. Make the script executable:
   ```bash
   chmod +x install_arch.sh
   ```
2. Run the script as root:
   ```bash
   ./install_arch.sh
   ```
3. Follow the on-screen prompts to configure your system.
4. Once the script finishes, run `umount -R /mnt` and `reboot`.

---

## What the Script Does (Phase Breakdown)

The script is divided into 8 distinct phases to keep the installation process modular and easy to read.

### Phase 1: Interactive Configuration
The script starts by listing available drives (excluding loop devices) and asks the user to select a target. It prompts for the system hostname, admin username/password, and allows the user to select a Desktop Environment and Bootloader (systemd-boot or EFISTUB). By doing this first, the rest of the script runs entirely unattended.

### Phase 2: CPU Microcode & Mirrors
* **Microcode:** Detects the CPU vendor from `/proc/cpuinfo` to stage the correct microcode package (`amd-ucode` or `intel-ucode`). 
* **Mirrors:** Runs `reflector` to find and save the 10 fastest HTTPS mirrors, heavily speeding up the pacstrap process.

### Phase 3: Partitioning, LUKS, and LVM
Uses `fdisk` to wipe the drive and create a modern GPT layout:
* **Partition 1 (Boot):** 2GB FAT32 EFI System Partition.
* **Partition 2 (LUKS Container):** The rest of the drive, encrypted with `cryptsetup luksFormat`.
It then unlocks the LUKS container and creates an LVM Volume Group (`archvg`) containing three Logical Volumes:
* `swap`: 32GB (Formatted as swap).
* `root`: 250GB (Formatted as Ext4).
* `home`: 100% of remaining free space (Formatted as Ext4).

### Phase 4: Base System Installation
Installs the core Arch Linux system using `pacstrap`. It explicitly includes tools required for this specific setup: `lvm2` (crucial for booting LVM on LUKS), `networkmanager`, `sudo`, `openssh`, `avahi`, `bluez`, and `power-profiles-daemon`. Finally, it generates the `fstab` file using UUIDs.

### Phase 5: System Configuration (Chroot)
Chroots into the new system to configure localization, identity, and the kernel:
* **Localization:** Sets the timezone to `Europe/Berlin`, syncs the hardware clock, generates English and German locales, and sets the console keymap.
* **Identity:** Configures `/etc/hostname` and maps it in `/etc/hosts`. Creates the admin user, sets passwords non-interactively, and grants `%wheel` sudo privileges.
* **Kernel Hooks:** Rebuilds the initial ramdisk (`mkinitcpio -P`) with the `encrypt`, `lvm2`, and `resume` hooks explicitly ordered so the system knows how to unlock the drive and wake from hibernation.

### Phase 6: Networking, Services, and GUI
* **Networking:** Sets up a fallback DHCP configuration using `systemd-networkd` for wired interfaces. 
* **Services:** Enables core daemons to start on boot: `sshd`, `fstrim.timer`, `systemd-timesyncd`, `bluetooth`, `power-profiles-daemon`, and `avahi-daemon`. Modifies `nsswitch.conf` to enable local network discovery (`.local` domains).
* **GUI:** If GNOME or KDE is selected, it installs the required meta-packages, enables their display managers (`gdm` or `sddm`), and switches network management from `systemd-networkd` to `NetworkManager` to prevent conflicts.

### Phase 7: Bootloader Installation
Installs the user's chosen bootloader (systemd-boot or EFISTUB directly into NVRAM). It dynamically calculates the raw LUKS UUID and configures the kernel parameters. These parameters tell the kernel to unlock the drive, allow SSD discard (TRIM), and define the LVM swap space as the hibernation resume target. It also injects the CPU microcode initramfs image if one was detected in Phase 2.

### Phase 8: Finalization
Outputs a success message and provides the final commands the user needs to manually run to safely unmount the partitions and reboot into the new operating system.

---

## Post-Installation Recommendations

Because graphics driver requirements vary wildly depending on your exact hardware, GPU drivers (Mesa, NVIDIA, etc.) are **not** automatically installed by this script. 

After your first reboot, log into your new system and manually install the appropriate drivers for your hardware (e.g., `mesa`, `vulkan-radeon`, `nvidia`) to ensure your Desktop Environment performs optimally.
```
