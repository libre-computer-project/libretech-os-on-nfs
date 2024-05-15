#!/bin/bash

set -ex

cd $(dirname $(readlink -f "${BASH_SOURCE[0]}"))

if [ ! -e "config.ini" ]; then
	echo "Missing config.ini" >&2
	exit 1
fi
. config.ini

host_ip=$(ip route | grep "^$LOON_IP" | grep -ioE "src\s[0-9a-f.:]+" | cut -f 2 -d " ")
if [ -z "$host_ip" ]; then
	echo "Unable to detect matching subnet on host." >&2
	if [ -z "$LOON_IP_SUBNET_MISMATCH_IGNORE" ]; then
		exit 1
	elif [ "$LOON_IP_SUBNET_MISMATCH_IGNORE" -ne 1 ]; then
		exit 1
	fi
	host_ip=$(hostname -I | cut -f 1 -d " ")
fi

apt_packages=(nfs-kernel-server tftpd-hpa mmdebstrap git build-essential device-tree-compiler)
case "$LOON_ARCH" in
	"arm64")
		apt_packages+=(gcc-aarch64-linux-gnu)
		cross_compile=aarch64-linux-gnu-
		;;
	"armhf")
		apt_packages+=(gcc-arm-linux-gnueabihf)
		cross_compile=arm-linux-gnueabihf-
		;;
	*)
		echo "Architecture $LOON_ARCH is not supported." >&2
		exit 1
		;;
esac

sudo apt -y install ${apt_packages[@]}

#NFS
if ! grep "^$LOON_DIR\s\+$LOON_IP" /etc/exports; then
	echo "$LOON_DIR $LOON_IP(rw,sync,no_root_squash,no_subtree_check)" | sudo tee -a /etc/exports
fi

#DEBIAN
if [ ! -d "$LOON_DIR" ]; then
	apt_includes=""
	if [ ! -z "$LOON_PACKAGES" ]; then
		apt_includes="--include=${LOON_PACKAGES// /,}"
	fi
	if [ -z "$LOON_APT_SERVER" ]; then
		sudo mmdebstrap --variant "$LOON_STRAP_VARIANT" --components="${LOON_COMPONENTS// /,}" $apt_includes ${apt_opt_proxy} --dpkgopt='force-unsafe-io' --arch="$LOON_ARCH" "$LOON_RELEASE" "$LOON_DIR"
	else
		sudo mmdebstrap --variant "$LOON_STRAP_VARIANT" --components="${LOON_COMPONENTS// /,}" $apt_includes --aptopt="Acquire::http { Proxy \"$LOON_APT_SERVER\"; }" --dpkgopt='force-unsafe-io' --arch="$LOON_ARCH" "$LOON_RELEASE" "$LOON_DIR"
	fi
	sudo rm "$LOON_DIR/etc/apt/apt.conf.d/99mmdebstrap"
	echo "$LOON_HOSTNAME" | sudo tee "$LOON_DIR/etc/hostname"
	echo "127.0.1.1	$LOON_HOSTNAME" | sudo tee "$LOON_DIR/etc/hosts"
	sudo ln -sfn /proc/net/pnp "$LOON_DIR/etc/resolv.conf"
	sudo mkdir "$LOON_DIR/boot/efi"
	#echo "/dev/mmcblk1p1	/boot/efi	vfat	umask=0077	0	1" | sudo tee "$LOON_DIR/etc/fstab"
	sudo git clone --single-branch --depth=1 https://github.com/libre-computer-project/libretech-wiring-tool.git "$LOON_DIR/root/libretech-wiring-tool"
	sudo make -C "$LOON_DIR/root/libretech-wiring-tool"
fi

#KERNEL
if [ ! -e "$LOON_DIR/boot/vmlinuz" ]; then
	sudo ln -sfn /dev/null "$LOON_DIR/boot/vmlinuz"
fi

if [ ! -d "$LOON_KERNEL_DIR" ]; then
	git clone --single-branch --depth=1 "$LOON_KERNEL_GIT" "$LOON_KERNEL_DIR"
fi

if [ ! -f "$LOON_KERNEL_DIR/build.sh" ]; then
	cat <<EOF > "$LOON_KERNEL_DIR/build.sh"
#!/bin/bash
cd \$(dirname \$(readlink -f "\${BASH_SOURCE[0]}"))
export ARCH=$LOON_ARCH
export CROSS_COMPILE=$cross_compile
export INSTALL_PATH=$LOON_DIR/boot
export INSTALL_MOD_PATH=$LOON_DIR
make -j \`nproc\` \$@
EOF
	chmod +x "$LOON_KERNEL_DIR/build.sh"
fi

if [ ! -f "$LOON_KERNEL_DIR/.config" ]; then
	"$LOON_KERNEL_DIR/build.sh" defconfig
	sed -i "s/\(CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=\).*/\\1n/" "$LOON_KERNEL_DIR/.config"
	sed -i "s/\(CONFIG_DEBUG_INFO_BTF=\).*/\\1n/" "$LOON_KERNEL_DIR/.config"
fi

"$LOON_KERNEL_DIR/build.sh"
sudo "$LOON_KERNEL_DIR/build.sh" install modules_install

#TFTP
sudo sed -i "s/^TFTP_DIRECTORY=.*/TFTP_DIRECTORY=\"${LOON_DIR//\//\\\/}\"/" /etc/default/tftpd-hpa

if [ -z "$(sudo grep ^root "$LOON_DIR/etc/shadow" | cut -f 2 -d :)" ]; then
	sudo chroot "$LOON_DIR" passwd
fi

sudo systemctl reload nfs-kernel-server

cat <<EOF
Create a MicroSD card with libretech-flash-tool:

  git clone https://github.com/libre-computer-project/libretech-flash-tool.git
  sudo libretech-flash-tool/lft.sh bl-flash BOARD DEVICE # eg. aml-a311d-cc-nfs mmcblk1/sda

If your board has onboard SPI NOR, move the boot switch to boot from MMC.
Run the following from u-boot prompt:

  env set serverip $host_ip
  env set bootargs "root=/dev/nfs nfsroot=\$serverip:$LOON_DIR,vers=4 rw ip=dhcp nfsrootdebug"
  env set bootcmd 'dhcp; tftpboot \\\$kernel_addr_r boot/vmlinuz; if tftpboot \\\$fdt_addr_r boot/efi/dtb/\\\$fdtfile; then bootefi \\\$kernel_addr_r \\\$fdt_addr_r; else bootefi \\\$kernel_addr_r; fi'
  env set bootdelay 0
  env save
  boot

Subsequent boots should automatically boot to NFS.
EOF
