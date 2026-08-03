#!/usr/bin/env bash
set -euo pipefail

# Build the 19-board postmarketOS image on a local x86_64 host.
#
# This mirrors .github/workflows/build.yml step for step, so a local run and a
# CI run resolve the same pinned upstreams and produce the same artifacts. The
# aarch64 rootfs is assembled under qemu-user-static emulation.
#
# Run as a normal user with sudo rights; pmbootstrap refuses to run as root.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_dir=${1:-$repo_root/artifacts}

# Upstream contract from AGENTS.md. Override only for a reviewed dependency bump.
pmbootstrap_rev=${PMBOOTSTRAP_REV:-b2bf3539cd92acce4ab187167581168e845f3e7e}
pmaports_rev=${PMAPORTS_REV:-1ce58c5ae1b7573c6471959c4ab406391eefb103}

state_dir=${MSM8916_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/msm8916-pmos}
pmbootstrap_src=$state_dir/pmbootstrap
config_file=$state_dir/pmbootstrap_v3.cfg
firmware_zip=$repo_root/temp/dragonboard410c_bootloader_emmc_android-88.zip
firmware_sha=72494b6882f60cc1704f2970543adb91370d1ec75497c4f6510fc13a4e1378ee

export PMB_WORK=${PMB_WORK:-$state_dir/pmbootstrap-work}
export PMB_APORTS=${PMB_APORTS:-$state_dir/pmaports}
export PMB_EXPORT=${PMB_EXPORT:-$state_dir/export}

# Debian keeps debugfs, losetup and mkfs.* in sbin directories that are not
# always on a normal user's PATH. pmbootstrap searches /usr/sbin explicitly
# (pmb.config.host_path); our own helper scripts need the same treatment.
PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin
export PATH

pmb() {
	python3 "$pmbootstrap_src/pmbootstrap.py" -c "$config_file" "$@"
}

# Never call "pmbootstrap log": it runs "tail -F" and never returns, which
# silently burned two full 6h CI jobs. pmbootstrap writes the real error here.
dump_log() {
	echo "" >&2
	echo "==== $1 failed: crash lines in log.txt ====" >&2
	grep -nE '^(panic|fatal error|runtime:|>>> ERROR|ERROR)' \
		"$PMB_WORK/log.txt" 2>/dev/null | tail -n 20 >&2 || true
	echo "==== $PMB_WORK/log.txt (last 500 lines) ====" >&2
	tail -n 500 "$PMB_WORK/log.txt" >&2 || true
}

require_host() {
	local arch
	local missing=()
	local tool

	arch=$(uname -m)
	if [ "$arch" != "x86_64" ]; then
		echo "This script targets an x86_64 host emulating aarch64; found $arch." >&2
		echo "On a native aarch64 host, drop the qemu requirement and build directly." >&2
		exit 1
	fi

	if [ "$(id -u)" -eq 0 ]; then
		echo "Do not run as root: pmbootstrap refuses it. Use a sudo-capable user." >&2
		exit 1
	fi

	# pmb/config/__init__.py required_programs, plus what our own scripts need.
	for tool in \
		arm-none-eabi-gcc aarch64-linux-gnu-ld chroot debugfs dtc git kpartx \
		losetup mkfs.btrfs mkfs.ext2 openssl patch ps python3 sudo tar unzip; do
		command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
	done

	if [ "${#missing[@]}" -ne 0 ]; then
		echo "Missing required commands: ${missing[*]}" >&2
		echo "See README.md for the Debian/Ubuntu package list." >&2
		exit 1
	fi

	python3 -c 'import cryptography' 2>/dev/null || {
		echo "Missing python3-cryptography (needed by qtestsign)." >&2
		exit 1
	}

	sudo -v
}

# The whole reason the hosted CI builds failed: QEMU 6.2 crashes the aarch64 Go
# binary of postmarketos-mkinitfs. Check the interpreter binfmt_misc actually
# uses, not whatever happens to be first in PATH.
require_qemu() {
	local binfmt=/proc/sys/fs/binfmt_misc/qemu-aarch64
	local interpreter=/usr/bin/qemu-aarch64-static
	local version
	local major

	if [ -r "$binfmt" ]; then
		interpreter=$(awk '/^interpreter /{ print $2 }' "$binfmt")
	else
		echo "No binfmt_misc entry yet; pmbootstrap will register $interpreter"
	fi

	if [ ! -x "$interpreter" ]; then
		echo "qemu interpreter $interpreter is missing or not executable." >&2
		echo "Install qemu-user-static and binfmt-support." >&2
		exit 1
	fi

	version=$("$interpreter" --version | head -n1)
	major=$(printf '%s\n' "$version" | sed -nE 's/^.*version ([0-9]+)\..*$/\1/p')

	if [ -z "$major" ]; then
		echo "Cannot parse a QEMU version from: $version" >&2
		exit 1
	fi

	if [ "$major" -lt 8 ]; then
		echo "$version" >&2
		echo "QEMU >= 8 is required. The 6.2 series shipped by Ubuntu 22.04 crashes" >&2
		echo "the aarch64 Go binary of postmarketos-mkinitfs under emulation." >&2
		exit 1
	fi

	echo "Using $version ($interpreter)"
}

# Stale files in the output directory would silently land in SHA256SUMS and the
# release tarball, so require a clean one rather than deleting someone's data.
prepare_output() {
	if [ -d "$output_dir" ] && [ -n "$(find "$output_dir" -mindepth 1 -print -quit)" ]; then
		echo "Output directory $output_dir is not empty; remove it first." >&2
		exit 1
	fi
	mkdir -p "$output_dir"
}

# Reset both checkouts to the pins on every run, so a reused state directory
# behaves exactly like a fresh CI runner.
sync_upstream() {
	mkdir -p "$state_dir"

	if [ ! -d "$pmbootstrap_src/.git" ]; then
		git clone https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git \
			"$pmbootstrap_src"
	fi
	# Only hit the network when the pin is not already local, so a reused state
	# directory still builds offline.
	if ! git -C "$pmbootstrap_src" cat-file -e "$pmbootstrap_rev^{commit}" 2>/dev/null; then
		git -C "$pmbootstrap_src" fetch --quiet origin
	fi
	git -C "$pmbootstrap_src" checkout --quiet --force "$pmbootstrap_rev"

	if [ ! -d "$PMB_APORTS/.git" ]; then
		git clone --filter=blob:none \
			https://gitlab.postmarketos.org/postmarketOS/pmaports.git "$PMB_APORTS"
	fi
	if ! git -C "$PMB_APORTS" cat-file -e "$pmaports_rev^{commit}" 2>/dev/null; then
		git -C "$PMB_APORTS" fetch --quiet origin
	fi
	git -C "$PMB_APORTS" checkout --quiet --force "$pmaports_rev"
	git -C "$PMB_APORTS" clean --quiet -fdx

	"$repo_root/scripts/prepare-pmaports.sh" "$PMB_APORTS"
}

write_config() {
	mkdir -p "$PMB_WORK"

	# Read the work version from the pinned source instead of hardcoding it; a
	# hardcoded value that goes stale makes migrate_work_folder() block on an
	# interactive confirm().
	PYTHONPATH="$pmbootstrap_src" python3 -c \
		'import pmb.config; print(pmb.config.work_version)' > "$PMB_WORK/version"

	# extra_packages holds only genuinely extra packages. Never list upstream
	# subpackages such as device-zhihe-generic-nonfree-firmware here:
	# get_nonfree_packages() discovers those from the APKBUILD by itself.
	# sudo_timer differs from CI on purpose, to survive a long unattended build.
	cat > "$config_file" <<-EOF
		[pmbootstrap]
		aports = $PMB_APORTS
		boot_size = 512
		build_default_device_arch = True
		build_pkgs_on_install = True
		ccache_size = 5G
		device = zhihe-generic
		extra_packages = soc-qcom-msm8916-rproc,qmi-utils,qrtr,modemmanager,iw,wpa_supplicant,wireless-regdb,dnsmasq,iptables,iproute2
		hostname = msm8916-pmos
		is_default_channel = False
		jobs = ${JOBS:-$(nproc)}
		kernel = ufi001c
		locale = C.UTF-8
		ssh_keys = False
		sudo_timer = True
		timezone = Asia/Shanghai
		ui = console
		user = user
		work = $PMB_WORK

		[providers]

		[mirrors]
	EOF

	pmb --version
	pmb status || true
}

# abuild fetches the pinned kernel tarball from github.com inside the chroot with
# busybox wget, which does not retry. A transient DNS failure on the
# codeload.github.com redirect already killed one CI run.
build_kernel() {
	local attempt

	for attempt in 1 2 3; do
		if pmb checksum linux-postmarketos-qcom-msm8916; then
			break
		fi
		if [ "$attempt" -eq 3 ]; then
			dump_log "pmbootstrap checksum"
			exit 1
		fi
		echo "Source fetch failed (attempt $attempt/3), retrying in 30s" >&2
		sleep 30
	done

	if ! pmb build --arch aarch64 --force linux-postmarketos-qcom-msm8916; then
		dump_log "pmbootstrap build"
		exit 1
	fi
}

build_image() {
	if ! pmb install --split --filesystem btrfs --password 147147; then
		dump_log "pmbootstrap install"
		exit 1
	fi
	# Apply CN mirrors + USB NCM/RNDIS gadget + UFI003 default DTB before
	# exporting, mirroring .github/workflows/build.yml. Shared script keeps
	# the two paths in sync (AGENTS.md requires it).
	bash "$repo_root/scripts/post-install-customize.sh" \
		"$PMB_WORK/chroot_rootfs_zhihe-generic"
	# Drop symlinks left by an earlier run: the state directory is reused, so a
	# stale-but-resolvable link would be collected as if it were fresh output.
	rm -rf "$PMB_EXPORT"
	pmb export "$PMB_EXPORT"
}

build_bootloaders() {
	mkdir -p "$output_dir/bootloaders"
	"$repo_root/scripts/build-bootloaders.sh" "$output_dir/bootloaders"

	# tz.mbn comes from the zip tracked in temp/, so the build needs no network
	# here and the blob stays verifiable.
	echo "$firmware_sha  $firmware_zip" | sha256sum -c -
	rm -rf "$state_dir/db410c_fw"
	unzip -o -j -d "$state_dir/db410c_fw" "$firmware_zip" 'tz.mbn'
	cp "$state_dir/db410c_fw/tz.mbn" "$output_dir/bootloaders/tz.mbn"
}

collect() {
	local path
	local rel
	local dtb_count
	local checksums

	mkdir -p "$output_dir/export"
	cp "$repo_root/config/boards.conf" "$output_dir/boards.conf"
	cp "$config_file" "$output_dir/pmbootstrap_v3.cfg"
	pmb status > "$output_dir/pmbootstrap-status.txt" || true

	while IFS= read -r path; do
		rel="${path#"$PMB_EXPORT"/}"
		mkdir -p "$output_dir/export/$(dirname "$rel")"
		cp -L "$path" "$output_dir/export/$rel"
	done < <(find "$PMB_EXPORT" -xtype f | sort)

	{
		echo "root=$(git -C "$repo_root" rev-parse HEAD)"
		echo "pmos-example=$(git -C "$repo_root/pmos-example" rev-parse HEAD)"
		echo "debian-dtbs=$(git -C "$repo_root/debian-dtbs" rev-parse HEAD)"
		echo "pmbootstrap=$pmbootstrap_rev"
		echo "pmaports=$pmaports_rev"
	} > "$output_dir/source-versions.txt"

	# Build the list outside the tree first, so find never races the file it is
	# about to describe.
	checksums=$(mktemp)
	(
		cd "$output_dir"
		find . -type f ! -name SHA256SUMS -print0 | sort -z \
			| xargs -0 sha256sum > "$checksums"
	)
	mv "$checksums" "$output_dir/SHA256SUMS"
	(
		cd "$output_dir"
		sha256sum -c SHA256SUMS >/dev/null
	)

	dtb_count=$(find "$output_dir/dtbs" -maxdepth 1 -type f -name '*.dtb' | wc -l)
	if [ "$dtb_count" -ne 19 ]; then
		echo "Expected 19 exported DTBs, found $dtb_count" >&2
		exit 1
	fi

	tar -C "$output_dir" -czf "$repo_root/postmarketos-msm8916-multiboard.tar.gz" .
	tar -tzf "$repo_root/postmarketos-msm8916-multiboard.tar.gz" \
		| grep -Fq './export/zhihe-generic-boot.img'
	tar -tzf "$repo_root/postmarketos-msm8916-multiboard.tar.gz" \
		| grep -Fq './export/zhihe-generic-root.img'
}

require_host
require_qemu
prepare_output
sync_upstream
write_config
build_kernel
build_image
build_bootloaders

mkdir -p "$output_dir/dtbs"
"$repo_root/scripts/configure-multiboard-boot.sh" \
	"$PMB_EXPORT/zhihe-generic-boot.img" "$output_dir/dtbs"

collect

echo "Built the 19-board postmarketOS image in $output_dir"
echo "Tarball: $repo_root/postmarketos-msm8916-multiboard.tar.gz"
echo "Reusable state (safe to delete): $state_dir"
