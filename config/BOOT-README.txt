MSM8916 postmarketOS multi-board image
======================================

The default device tree is msm8916-thwc-ufi003.dtb.

To select another board, edit /boot/extlinux/extlinux.conf in the installed
system (or /extlinux/extlinux.conf when this boot image is mounted on a host)
and change the single "fdt" line to:

    fdt /dtbs/qcom/<dtb-file>

The complete board-to-DTB mapping is stored in /boards.conf. Reboot after
changing the file. Choosing an incompatible DTB can prevent the device from
booting; keep EDL backups and recovery tools available.
