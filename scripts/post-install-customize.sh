#!/usr/bin/env bash
set -euo pipefail

# Post-install customization applied to the pmbootstrap rootfs chroot before
# exporting the split image. Shared between .github/workflows/build.yml and
# scripts/build-local.sh so the CI image and a locally-built image have the
# same behavior.
#
# Run as a user with sudo rights. $ROOTFS is the chroot path created by
# pmbootstrap install (e.g. $PMB_WORK/chroot_rootfs_zhihe-generic); every file
# inside is root-owned, so all writes go through sudo.
#
# What this does:
#   1. Replace apk repositories with TUNA mirrors (Alpine edge + pmOS master)
#   2. Install setup_usb_gadget.sh: composite NCM+RNDIS gadget via configfs
#   3. Install a systemd unit + udev rule to bring the gadget up at boot
#   4. Enable IPv4/IPv6 forwarding
#   5. Flip the chroot-side extlinux.conf default DTB to UFI003
#
# Networking deps (dnsmasq, iptables, iproute2) must already be installed via
# pmbootstrap's extra_packages; calling apk here would desync the chroot state.

rootfs=${1:?Usage: post-install-customize.sh <rootfs-dir>}
test -d "$rootfs" || { echo "rootfs chroot missing: $rootfs" >&2; exit 1; }

# 1) TUNA mirrors. postmarketOS edge moved to systemd, so the master channel
#    is what tracks the rolling binary packages matching the pinned pmaports.
sudo tee "$rootfs/etc/apk/repositories" > /dev/null <<'REPOS'
https://mirrors.tuna.tsinghua.edu.cn/alpine/edge/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/edge/community
https://mirrors.tuna.tsinghua.edu.cn/postmarketOS/master
REPOS

# 2) Gadget setup script. Pattern from kinsamanka/OpenStick-Builder
#    setup_ncm_gadget.sh, extended to expose both ncm.1 and rndis.0 so the
#    host picks whichever the OS prefers (Win/macOS -> RNDIS, Linux -> NCM).
sudo install -d "$rootfs/usr/local/bin"
sudo tee "$rootfs/usr/local/bin/setup_usb_gadget.sh" > /dev/null <<'GADGET'
#!/bin/sh -e
CONFIGFS=/sys/kernel/config/usb_gadget
NAME=openstick
DIR=$CONFIGFS/$NAME
[ -d "$CONFIGFS" ] || { echo "configfs missing"; exit 0; }
[ -d "$DIR" ] && exit 0
mkdir -p "$DIR/functions/ncm.1" "$DIR/functions/rndis.0"
echo 0x0200  > "$DIR/bcdUSB"
echo 0x1d6b  > "$DIR/idVendor"   # Linux Foundation
echo 0x0104  > "$DIR/idProduct"  # Multifunction Composite Gadget
echo 0x40    > "$DIR/bMaxPacketSize0"
mkdir -p "$DIR/strings/0x409"
echo "4G LTE Dongle" > "$DIR/strings/0x409/product"
echo "Openstick"    > "$DIR/strings/0x409/manufacturer"
echo "0123456789"   > "$DIR/strings/0x409/serialnumber"
# RNDIS uses a different interface class so Windows auto-binds usbnet/rndis
echo 0xef > "$DIR/functions/rndis.0/bInterfaceClass"
mkdir -p "$DIR/configs/c.1"
echo 0x80 > "$DIR/configs/c.1/bmAttributes"
echo 250  > "$DIR/configs/c.1/MaxPower"
ln -sf "$DIR/functions/ncm.1"    "$DIR/configs/c.1"
ln -sf "$DIR/functions/rndis.0" "$DIR/configs/c.1"
# OS descriptors so Windows loads RNDIS drivers automatically
echo "MSFT100" > "$DIR/os_desc/qw_sign"
echo 0xbc     > "$DIR/os_desc/b_vendor_code"
echo 1        > "$DIR/os_desc/use"
ln -sf "$DIR/configs/c.1" "$DIR/os_desc"
echo "$(ls /sys/class/udc | head -1)" > "$DIR/UDC"
GADGET
sudo chmod +x "$rootfs/usr/local/bin/setup_usb_gadget.sh"

# 3) systemd unit + udev rule. postmarketOS edge ships systemd by default,
#    so /etc/init.d/ (OpenRC) does not exist on the rootfs -- a previous
#    OpenRC service here failed with "No such file or directory".
sudo install -d "$rootfs/etc/systemd/system"
sudo tee "$rootfs/etc/systemd/system/usb-gadget.service" > /dev/null <<'SVC'
[Unit]
Description=USB NCM+RNDIS gadget networking
After=sys-subsystem-net-devices-%i.device sys-kernel-config.mount
Wants=sys-kernel-config.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe libcomposite
ExecStart=/usr/local/bin/setup_usb_gadget.sh
# DHCPv4 + DHCPv6 via dnsmasq on the USB link. Device side: 10.0.0.1/24 +
# fc00::1/64; host gets .2/fc00::2 via DHCP.
ExecStartPost=/bin/sh -c 'for i in $$(seq 1 30); do ip link show usb0 >/dev/null 2>&1 && break; sleep 1; done; ip link set usb0 up; ip addr add 10.0.0.1/24 dev usb0 2>/dev/null || true; ip -6 addr add fc00::1/64 dev usb0 2>/dev/null || true; pkill dnsmasq 2>/dev/null || true; dnsmasq --interface=usb0 --bind-interfaces --no-resolv --dhcp-range=10.0.0.2,10.0.0.6,255.255.255.0,12h --dhcp-range=fc00::2,fc00::6,64,12h --dhcp-option=option:router,10.0.0.1 --dhcp-option=option:dns-server,10.0.0.1,223.5.5.5,2400:3200::1'
ExecStop=/bin/sh -c 'pkill dnsmasq 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
SVC

# udev: kick the gadget setup as soon as the UDC appears at boot, and mark
# gadget net interfaces as NetworkManager-managed so the host side gets an IP.
sudo install -d "$rootfs/etc/udev/rules.d"
sudo tee "$rootfs/etc/udev/rules.d/10-udc.rules" > /dev/null <<'UDEV'
ACTION=="add", SUBSYSTEM=="udc", RUN+="/sbin/modprobe libcomposite", RUN+="/usr/local/bin/setup_usb_gadget.sh"
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
UDEV

# 4) Enable the unit at boot (symlink equivalent of `systemctl enable`) and
#    turn on IPv4/IPv6 forwarding so the dongle can route for the host.
sudo ln -sf /etc/systemd/system/usb-gadget.service \
    "$rootfs/etc/systemd/system/multi-user.target.wants/usb-gadget.service"
sudo install -d "$rootfs/etc/sysctl.d"
sudo tee "$rootfs/etc/sysctl.d/99-usb-gadget-forwarding.conf" > /dev/null <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSCTL

# 5) Belt-and-suspenders: flip the chroot-side extlinux.conf to UFI003 so
#    the exported boot image and the rootfs agree on the default DTB. The
#    boot image itself is rewritten by scripts/configure-multiboard-boot.sh.
if [ -f "$rootfs/boot/extlinux/extlinux.conf" ]; then
    sudo sed -i 's#^[[:space:]]*fdt .*#\tfdt /dtbs/qcom/msm8916-thwc-ufi003.dtb#' \
        "$rootfs/boot/extlinux/extlinux.conf"
fi

echo "post-install-customize: applied CN mirrors, USB gadget, UFI003 default DTB"
