#!/usr/bin/env bash

DISK='/dev/sda'
FQDN='vagrant-arch.vagrantup.com'
KEYMAP='us'
LANGUAGE='en_US.UTF-8'
PASSWORD=$(/usr/bin/openssl passwd -crypt 'vagrant')
TIMEZONE='UTC'

CONFIG_SCRIPT='/usr/local/bin/arch-config.sh'
ROOT_PARTITION="${DISK}1"
TARGET_DIR='/var/log'

echo "==> clearing partition table on ${DISK}"
/usr/bin/sgdisk --zap ${DISK}

echo "==> destroying magic strings and signatures on ${DISK}"
/usr/bin/dd if=/dev/zero of=${DISK} bs=512 count=2048
/usr/bin/wipefs --all ${DISK}

echo "==> creating /root partition on ${DISK}"
/usr/bin/sgdisk --new=1:0:0 ${DISK}

echo "==> setting ${DISK} bootable"
/usr/bin/sgdisk ${DISK} --attributes=1:set:2

echo '==> creating /root filesystem (ext4)'
/usr/bin/mkfs.ext4 -F -m 0 -q -L root ${ROOT_PARTITION}

echo "==> mounting ${ROOT_PARTITION} to ${TARGET_DIR}"
/usr/bin/mount -o noatime,errors=remount-ro ${ROOT_PARTITION} ${TARGET_DIR}

echo '==> bootstrapping the base installation'
/usr/bin/pacstrap ${TARGET_DIR} base base-devel
echo '==> updating the base installation'
/usr/bin/arch-chroot ${TARGET_DIR} pacman -Syu --noconfirm
echo '==> installing basics'
/usr/bin/arch-chroot ${TARGET_DIR} pacman -S --noconfirm linux-headers gptfdisk openssh syslinux wget git expac jshon ruby mlocate virtualbox-guest-utils virtualbox-guest-dkms
/usr/bin/arch-chroot ${TARGET_DIR} syslinux-install_update -i -a -m
/usr/bin/sed -i 's/sda3/sda1/' "${TARGET_DIR}/boot/syslinux/syslinux.cfg"
/usr/bin/sed -i 's/TIMEOUT 50/TIMEOUT 10/' "${TARGET_DIR}/boot/syslinux/syslinux.cfg"

echo '==> generating the filesystem table'
/usr/bin/genfstab -p ${TARGET_DIR} >> "${TARGET_DIR}/etc/fstab"

echo '==> generating the system configuration script'
/usr/bin/install --mode=0755 /dev/null "${TARGET_DIR}${CONFIG_SCRIPT}"

cat <<-EOF > "${TARGET_DIR}${CONFIG_SCRIPT}"
	echo '${FQDN}' > /etc/hostname
	/usr/bin/ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
	echo 'KEYMAP=${KEYMAP}' > /etc/vconsole.conf
	/usr/bin/sed -i 's/#${LANGUAGE}/${LANGUAGE}/' /etc/locale.gen
	
	/usr/bin/locale-gen
	/usr/bin/mkinitcpio -A vboxguest -p linux
	/usr/bin/usermod --password ${PASSWORD} root
	# https://wiki.archlinux.org/index.php/Network_Configuration#Device_names
	/usr/bin/ln -s /dev/null /etc/udev/rules.d/80-net-name-slot.rules
	/usr/bin/ln -s '/usr/lib/systemd/system/dhcpcd@.service' '/etc/systemd/system/multi-user.target.wants/dhcpcd@eth0.service'
	/usr/bin/sed -i 's/#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
	/usr/bin/systemctl enable sshd.service
		
	echo "======================>   Setting up network....................................."	
	# enable dhcpcd
	/usr/bin/systemctl enable dhcpcd

	echo "==================> Installing VirtualBox Guest Additions"	
	echo -e 'vboxguest\nvboxsf\nvboxvideo' > /etc/modules-load.d/virtualbox.conf
	/usr/bin/systemctl enable dkms
	/usr/bin/systemctl enable vboxservice
	
	echo "======================>   Setting up vagrant user....................................."			
	# Vagrant-specific configuration
	/usr/bin/groupadd vagrant
	/usr/bin/useradd --password ${PASSWORD} --comment 'Vagrant User' --create-home --gid users --groups vagrant,vboxsf vagrant
	echo 'Defaults env_keep += "SSH_AUTH_SOCK"' > /etc/sudoers.d/10_vagrant
	echo 'vagrant ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/10_vagrant
	/usr/bin/chmod 0440 /etc/sudoers.d/10_vagrant
	/usr/bin/install --directory --owner=vagrant --group=users --mode=0700 /home/vagrant/.ssh
	/usr/bin/curl --output /home/vagrant/.ssh/authorized_keys https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub
	/usr/bin/chown vagrant:users /home/vagrant/.ssh/authorized_keys
	/usr/bin/chmod 0600 /home/vagrant/.ssh/authorized_keys

	echo "==================> Installing packer and puppet"
	echo "==================> Downloading and building packer"
	echo ${PASSWORD} | su -c "/usr/bin/mkdir /home/vagrant/packer" vagrant 
	echo ${PASSWORD} | su -c "/usr/bin/curl --output /home/vagrant/packer/PKGBUILD https://aur.archlinux.org/packages/pa/packer/PKGBUILD" vagrant 
	cd /home/vagrant/packer && echo ${PASSWORD} | su -c /usr/bin/makepkg vagrant
	echo "==================> Installing packer"
	/usr/bin/pacman -U /home/vagrant/packer/packer-*.pkg.tar.xz --noconfirm	
	echo "==================> Installing puppet"
	/usr/bin/packer -S puppet --noconfirm
	#A bug with the hiera dep makes this neccessary
	/usr/bin/packer -S puppet --noconfirm
	echo "==================> Installing vboxguest-hook"
	/usr/bin/packer -S vboxguest-hook --noconfirm
	echo "==================> Packer and vboxguest-hook installed"
	
	# workaround for shutdown race condition: http://comments.gmane.org/gmane.linux.arch.general/48739
	/usr/bin/curl --output /etc/systemd/system/poweroff.timer https://raw.github.com/nisbus/packer-arch/master/poweroff.timer

	echo "======================>   Cleaning up....................................."			
	# clean up
	/usr/bin/pacman -Rcns --noconfirm gptfdisk
	
	#This is considered bad practice
	#/usr/bin/pacman -Scc --noconfirm
	
	/usr/bin/sleep 5
EOF

echo '==> entering chroot and configuring system'
/usr/bin/arch-chroot ${TARGET_DIR} ${CONFIG_SCRIPT} 2>&1 | tee -a /var/log/install.log
#rm "${TARGET_DIR}${CONFIG_SCRIPT}"

echo '==> installation complete!...........................................'
/usr/bin/sleep 3
/usr/bin/umount ${TARGET_DIR}
/usr/bin/systemctl reboot -f