#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
boot_image=${1:?Usage: configure-multiboard-boot.sh <boot-image> <dtb-output-directory>}
dtb_output=${2:?Usage: configure-multiboard-boot.sh <boot-image> <dtb-output-directory>}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$dtb_output"

fail() {
	echo "ERROR: $*" >&2
	echo "Boot image root directory:" >&2
	debugfs -R 'ls -l /' "$boot_image" >&2 || true
	echo "Boot image /extlinux directory:" >&2
	debugfs -R 'ls -l /extlinux' "$boot_image" >&2 || true
	echo "Boot image /dtbs/qcom directory:" >&2
	debugfs -R 'ls -l /dtbs/qcom' "$boot_image" >&2 || true
	# Dump the actual extlinux.conf content so a mismatch is visible instead
	# of just "must contain exactly one linux directive". Also show what we
	# wrote, to tell a write failure from a read failure.
	echo "Host-side extlinux.conf (what we wrote):" >&2
	cat "$work_dir/extlinux.conf" >&2 || true
	echo "Image-side extlinux.conf (what verify read back):" >&2
	cat "$work_dir/verify-extlinux.conf" >&2 || true
	exit 1
}

debugfs_run() {
	local command=$1
	local result
	if ! result=$(debugfs -R "$command" "$boot_image" 2>&1); then
		printf '%s\n' "$result" >&2
		fail "debugfs command failed: $command"
	fi
	case "$result" in
		*'File not found'*|*'not found by ext2_lookup'*|*'No such file or directory'*|*'Ext2 directory already exists'*)
			printf '%s\n' "$result" >&2
			fail "debugfs command failed: $command"
			;;
	esac
}

debugfs_write() {
	local command=$1
	local result
	if ! result=$(debugfs -w -R "$command" "$boot_image" 2>&1); then
		printf '%s\n' "$result" >&2
		fail "debugfs write failed: $command"
	fi
	case "$result" in
		*'File not found'*|*'not found by ext2_lookup'*|*'No such file or directory'*)
			printf '%s\n' "$result" >&2
			fail "debugfs write failed: $command"
			;;
	esac
}

if [ ! -s "$boot_image" ]; then
	echo "ERROR: boot image is missing or empty: $boot_image" >&2
	exit 1
fi
if ! dumpe2fs -h "$boot_image" >"$work_dir/dumpe2fs.txt" 2>&1; then
	cat "$work_dir/dumpe2fs.txt" >&2
	echo "ERROR: boot image is not a readable ext2/3/4 filesystem: $boot_image" >&2
	exit 1
fi

read_compatible() {
	file=$1
	if command -v fdtget >/dev/null 2>&1; then
		fdtget -t s "$file" / compatible | awk '{print $1}'
	else
		"${DTC:-dtc}" -q -I dtb -O dts "$file" 2>/dev/null \
			| awk -F '"' '/^[[:space:]]*compatible =/ && !found { print $2; found = 1 }'
	fi
}

debugfs_run 'stat /vmlinuz'
debugfs_run 'stat /dtbs/qcom'

# Current edge packages may generate multiple boot entries or no extlinux.conf
# at all. The release contract is deliberately one unambiguous entry, so write
# the complete known-good pmos-example shape instead of merging a rolling
# template. The root filesystem label is stable across split-image builds.
cat > "$work_dir/extlinux.conf" <<'EOF'
linux /vmlinuz
fdt /dtbs/qcom/msm8916-thwc-ufi003.dtb
append earlycon root=LABEL=pmOS_root console=ttyMSM0,115200 no_framebuffer=true rw rootwait
EOF

if ! debugfs -R 'stat /extlinux' "$boot_image" >"$work_dir/extlinux-stat.txt" 2>&1 \
		|| grep -Eq 'File not found|not found by ext2_lookup' "$work_dir/extlinux-stat.txt"; then
	debugfs_write 'mkdir /extlinux'
fi
debugfs -w -R 'rm /extlinux/extlinux.conf' "$boot_image" >/dev/null 2>&1 || true
debugfs_write "write $work_dir/extlinux.conf /extlinux/extlinux.conf"
debugfs_write 'set_inode_field /extlinux/extlinux.conf mode 0100644'

for item in boards.conf README-BOARD-SELECTION.txt; do
	debugfs -w -R "rm /$item" "$boot_image" >/dev/null 2>&1 || true
done
debugfs_write "write $repo_root/config/boards.conf /boards.conf"
debugfs_write "write $repo_root/config/BOOT-README.txt /README-BOARD-SELECTION.txt"
debugfs_write 'set_inode_field /boards.conf mode 0100644'
debugfs_write 'set_inode_field /README-BOARD-SELECTION.txt mode 0100644'

while IFS='|' read -r board dtb _source compatible _display; do
	case "$board" in ''|'#'*) continue ;; esac
	output="$dtb_output/$dtb"
	debugfs_run "dump /dtbs/qcom/$dtb $output"
	test -s "$output" || fail "missing /dtbs/qcom/$dtb in $boot_image"
	actual=$(read_compatible "$output")
	[ "$actual" = "$compatible" ] || {
		fail "$board compatible mismatch: expected $compatible, got $actual"
	}
done < "$repo_root/config/boards.conf"

debugfs_run "dump /extlinux/extlinux.conf $work_dir/verify-extlinux.conf"
[ "$(grep -c '^[[:space:]]*linux ' "$work_dir/verify-extlinux.conf")" -eq 1 ] \
	|| fail "extlinux.conf must contain exactly one linux directive"
[ "$(grep -c '^[[:space:]]*fdt ' "$work_dir/verify-extlinux.conf")" -eq 1 ] \
	|| fail "extlinux.conf must contain exactly one fdt directive"
[ "$(grep -c '^[[:space:]]*append ' "$work_dir/verify-extlinux.conf")" -eq 1 ] \
	|| fail "extlinux.conf must contain exactly one append directive"
grep -Fq 'linux /vmlinuz' "$work_dir/verify-extlinux.conf" \
	|| fail "extlinux.conf does not select /vmlinuz"
grep -Fq 'fdt /dtbs/qcom/msm8916-thwc-ufi003.dtb' "$work_dir/verify-extlinux.conf" \
	|| fail "extlinux.conf does not select the default UFI003 DTB"
grep -Fq 'root=LABEL=pmOS_root' "$work_dir/verify-extlinux.conf" \
	|| fail "extlinux.conf does not select the split root filesystem label"
debugfs_run 'stat /boards.conf'
debugfs_run 'stat /README-BOARD-SELECTION.txt'
[ "$(find "$dtb_output" -maxdepth 1 -type f -name '*.dtb' | wc -l)" -eq 19 ] \
	|| fail "expected exactly 19 exported DTBs"

echo "Configured multi-board boot image and exported 19 DTBs"
