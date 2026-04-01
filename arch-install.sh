#!/bin/bash
# Fail immediately if any command exits with a non-zero status
set -e

echo "================================================="
echo "      Arch Linux Automated Installer             "
echo " LVM on LUKS | Hibernation | TRIM | Microcode    "
echo "      + Bluetooth, Avahi, NTP, Power Mgt         "
echo "================================================="
echo ""

# ---------------------------------------------------------
# Phase 1: Interactive Configuration (Ask everything upfront)
# ---------------------------------------------------------
echo "Available Disk Drives:"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
echo ""
read -p "Enter the device name to partition (e.g., sda, nvme0n1): " DISK_NAME
DEVICE="/dev/$DISK_NAME"

if [ ! -b "$DEVICE" ]; then
    echo "Error: Device $DEVICE not found."
    exit 1
fi

echo "WARNING: ALL DATA ON $DEVICE WILL BE PERMANENTLY DESTROYED!"
read -p "Are you sure you want to continue? (y/N): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    exit 1
fi

read -p "Enter a hostname for this computer: " SYSTEM_HOSTNAME

read -p "Enter your new administrative username: " ADMIN_USER
while true; do
    read -s -p "Enter the password for $ADMIN_USER: " ADMIN_PASS
    echo ""
    read -s -p "Confirm the password: " ADMIN_PASS_CONFIRM
    echo ""
    [ "$ADMIN_PASS" == "$ADMIN_PASS_CONFIRM" ] && break
    echo "Passwords do not match. Please try again."
done

echo ""
echo "Desktop Environment Selection:"
echo "1) GNOME"
echo "2) KDE Plasma"
echo "3) None (CLI only)"
read -p "Choice (1-3): " DE_CHOICE

echo ""
echo "Bootloader Selection:"
echo "1) systemd-boot"
echo "2) EFISTUB (efibootmgr)"
read -p "Choice (1-2): " BOOT_CHOICE

# ---------------------------------------------------------
# Phase 2: CPU Microcode & Mirrors
# ---------------------------------------------------------
echo ""
echo "Detecting CPU vendor for microcode..."
CPU_VENDOR=$(grep -m 1 'vendor_id' /proc/cpuinfo | awk '{print $3}' || true)
if [ "$CPU_VENDOR" == "AuthenticAMD" ]; then
    UCODE_PKG="amd-ucode"
    UCODE_IMG="amd-ucode.img"
    echo "AMD CPU detected."
elif [ "$CPU_VENDOR" == "GenuineIntel" ]; then
    UCODE_PKG="intel-ucode"
    UCODE_IMG="intel-ucode.img"
    echo "Intel CPU detected."
else
    UCODE_PKG=""
    UCODE_IMG=""
    echo "Generic/Unknown CPU detected. Skipping microcode."
fi

echo "Optimizing pacman mirrors (this may take a moment)..."
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# ---------------------------------------------------------
# Phase 3: Partitioning, LUKS, and LVM
# ---------------------------------------------------------
echo "Partitioning $DEVICE..."
sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk $DEVICE
  g       # Create GPT partition table
  n       # New partition 1 (Boot)
  1       # Partition number 1
          # Default first sector
  +2G     # 2GB size
  t       # Change type
  1       # EFI System
  n       # New partition 2 (LUKS Container)
  2       # Partition number 2
          # Default first sector
          # Default last sector (rest of drive)
  w       # Write changes and exit
EOF

partprobe $DEVICE
sleep 2

if [[ $DEVICE == *"nvme"* ]]; then
    PART_BOOT="${DEVICE}p1"
    PART_LUKS="${DEVICE}p2"
else
    PART_BOOT="${DEVICE}1"
    PART_LUKS="${DEVICE}2"
fi

echo "Formatting Boot partition..."
mkfs.vfat -F 32 $PART_BOOT

echo "Setting up LUKS encryption on $PART_LUKS..."
# Pipe the admin password into cryptsetup to fully automate it
echo -n "$ADMIN_PASS" | cryptsetup -v luksFormat $PART_LUKS -
echo -n "$ADMIN_PASS" | cryptsetup open $PART_LUKS cryptlvm -

echo "Initializing LVM..."
pvcreate /dev/mapper/cryptlvm
vgcreate archvg /dev/mapper/cryptlvm
lvcreate -L 32G archvg -n swap
lvcreate -L 250G archvg -n root
lvcreate -l 100%FREE archvg -n home

echo "Formatting LVM partitions..."
mkswap /dev/archvg/swap
swapon /dev/archvg/swap
mkfs.ext4 /dev/archvg/root
mkfs.ext4 /dev/archvg/home

echo "Mounting filesystems..."
mount /dev/archvg/root /mnt
mount --mkdir /dev/archvg/home /mnt/home
mount --mkdir $PART_BOOT /mnt/boot

# ---------------------------------------------------------
# Phase 4: Base System Installation
# ---------------------------------------------------------
echo "Installing base system via pacstrap..."
# Added avahi, nss-mdns, bluez, bluez-utils, power-profiles-daemon
pacstrap -K /mnt base base-devel linux linux-firmware lvm2 networkmanager nano sudo openssh avahi nss-mdns bluez bluez-utils power-profiles-daemon $UCODE_PKG

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ---------------------------------------------------------
# Phase 5: System Configuration (Chroot)
# ---------------------------------------------------------
echo "Configuring Timezone and Locales..."
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
arch-chroot /mnt hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
sed -i 's/^#de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "KEYMAP=de-latin1" > /mnt/etc/vconsole.conf

echo "Setting Hostname..."
echo "$SYSTEM_HOSTNAME" > /mnt/etc/hostname
cat <<EOF > /mnt/etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${SYSTEM_HOSTNAME}.localdomain ${SYSTEM_HOSTNAME}
EOF

echo "Configuring User and Passwords..."
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$ADMIN_USER"
echo "$ADMIN_USER:$ADMIN_PASS" | arch-chroot /mnt chpasswd
echo "root:$ADMIN_PASS" | arch-chroot /mnt chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers

echo "Configuring mkinitcpio..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 resume filesystems fsck)/' /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -P

# ---------------------------------------------------------
# Phase 6: Networking, Services, and GUI
# ---------------------------------------------------------
echo "Configuring Wired Networking..."
WIRED_IFACES=$(arch-chroot /mnt bash -c "ls /sys/class/net | grep -E '^en|^eth' || true")
if [ -z "$WIRED_IFACES" ]; then
    MATCH_NAME="en* eth*"
else
    MATCH_NAME=$(echo "$WIRED_IFACES" | tr '\n' ' ' | sed 's/ $//')
fi
arch-chroot /mnt mkdir -p /etc/systemd/network
cat <<EOF > /mnt/etc/systemd/network/20-wired.network
[Match]
Name=$MATCH_NAME
[Network]
DHCP=yes
EOF

echo "Enabling core daemons (SSH, TRIM, NTP, Bluetooth, Power Management, Avahi)..."
arch-chroot /mnt systemctl enable systemd-resolved sshd fstrim.timer systemd-timesyncd bluetooth power-profiles-daemon avahi-daemon

# Inject mdns_minimal into nsswitch.conf so local network discovery works
sed -i 's/resolve/mdns_minimal [NOTFOUND=return] resolve/' /mnt/etc/nsswitch.conf

echo "Installing Desktop Environment..."
if [ "$DE_CHOICE" == "1" ]; then
    arch-chroot /mnt pacman -S --noconfirm gnome gnome-tweaks gdm
    arch-chroot /mnt systemctl enable gdm NetworkManager
elif [ "$DE_CHOICE" == "2" ]; then
    arch-chroot /mnt pacman -S --noconfirm plasma-meta kde-applications-meta sddm
    arch-chroot /mnt systemctl enable sddm NetworkManager
else
    arch-chroot /mnt systemctl enable systemd-networkd
fi

# ---------------------------------------------------------
# Phase 7: Bootloader Installation
# ---------------------------------------------------------
echo "Configuring Bootloader..."
LUKS_UUID=$(blkid -s UUID -o value $PART_LUKS)

if [ "$BOOT_CHOICE" == "1" ]; then
    arch-chroot /mnt bootctl install
    cat <<EOF > /mnt/boot/loader/loader.conf
default arch.conf
timeout 4
console-mode max
editor no
EOF
    
    UCODE_ENTRY=""
    if [ -n "$UCODE_IMG" ]; then
        UCODE_ENTRY="initrd  /${UCODE_IMG}"
    fi

    cat <<EOF > /mnt/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
${UCODE_ENTRY}
initrd  /initramfs-linux.img
options cryptdevice=UUID=${LUKS_UUID}:cryptlvm:allow-discards root=/dev/archvg/root resume=/dev/archvg/swap rw
EOF

elif [ "$BOOT_CHOICE" == "2" ]; then
    arch-chroot /mnt pacman -S --noconfirm efibootmgr
    EFIDISK=$DEVICE
    EFIPART=1
    
    UCODE_PARAM=""
    if [ -n "$UCODE_IMG" ]; then
        UCODE_PARAM="initrd=\\${UCODE_IMG} "
    fi

    # Ensuring no trailing spaces exist after any of these backslashes
    arch-chroot /mnt efibootmgr --create \
        --disk ${EFIDISK} \
        --part ${EFIPART} \
        --label "Arch Linux" \
        --loader /vmlinuz-linux \
        --unicode "${UCODE_PARAM}cryptdevice=UUID=${LUKS_UUID}:cryptlvm:allow-discards root=/dev/archvg/root resume=/dev/archvg/swap rw initrd=\\initramfs-linux.img" \
        --verbose
fi

# ---------------------------------------------------------
# Phase 8: Finalization
# ---------------------------------------------------------
echo ""
echo "================================================="
echo "             INSTALLATION COMPLETE!              "
echo "================================================="
echo "You can now safely reboot your system."
echo "Command: umount -R /mnt && reboot"
