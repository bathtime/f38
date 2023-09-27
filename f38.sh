#!/bin/bash

# This script will hopefully create a bootable OS with a minimal Fedora install. You should be able to install in virtualbox, on a computer, or on a USB stick. The latter two have been tested and are working on my machine.
#
# DO NOT RUN ON BAREMETAL IF YOU DON'T KNOW WHAT YOU'RE DOING!!!
# DO NOT RUN THIS AS A SCRIPT (run by pasting line by line to manually to assess errors)
#
# Credit goes to (with several changes and additions made by myself):
# https://www.youtube.com/watch?v=uqsVb3lvtBg&ab_channel=Stephen%27sTechTalks 
#


# exit and report the failure if any command fails
exit_trap () {                                         # ---- (1)
  local lc="$BASH_COMMAND" rc=$?
  echo "Command [$lc] exited with code [$rc]"
}

trap exit_trap EXIT                                    # ---- (2)

set -e 
umount -n -R -l /mnt


###  Find disks to install to and give user a choice  ###

echo -e "\nDrives found:\n"

disks=$(fdisk -l | awk -F' |:' '/Disk \/dev\// { print $2 }')

for i in $disks; do
        size=$(fdisk -l | grep $i | awk -F' |:' '/Disk \/dev\// { print $4 }')
        printf "%s\t\t%sG\n" $i $size
done

disks+=$(echo -e "\nquit")

echo -e "\nEnter number of drive to install to:\n"

select choice in $disks
do
   case $choice in
        quit) echo -e "\nQuitting!"; exit; ;;
        '')   echo -e "\nInvalid option!\n"; ;;
        *)    disk=$choice; echo; break; ;;
    esac
done

read -e -p "Enter the user name you'd like to create (blank will revert to 'user'): " user

if [[ "$user" == "" ]]; then
   user=user
fi


#user=user


echo -e "\nSetup config:\n\ndisk: $disk\nuser: $user\n"
read -e -p "This drive will be completely written over! Would you like to proceed (y or n)? " proceed

if [[ "$proceed" != [Yy]* ]]; then
   echo -e "\nExiting."
   exit
fi

echo -e "\nInstalling to $disk..."

# Selinux can cause some problems with the install so deactivate for now
setenforce 0

sgdisk --zap-all $disk

sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | gdisk $disk
d     # Delete partition
1     # Partition 1
d     # Delete partition
2     # Partition 2
d     # Delete partition
3     # Partition 3
d     # Delete partition
4     # Partition 4
n     # Add a new partition
      # Partition number (Accept default: 1)
      # First sector (Accept default: varies)
+600M # Last sector (Accept default: varies)
ef00  # Type of partition (EFI system partition)
n     # Add a new partition
      # Partition number (Accept default: 2)
      # Accept first sector
+1G   # Have last sector be 1Gig
      # Accept default GUID (Linux filesystem)
n     # Add a new partition
      # Partition number (Accept default: 3)
      # First sector (Accept default: varies)
+8G   # Have last sector be 8Gig
8200  # Type of partition (swap)
n     # Add a new partition
      # Partition number (Accept default: 4)
      # Accept first sector
      # Accept last sector (Default: remaining space)
      # Type of parition (Linux Filesystem)
c     # Name partition
1     # Partition 1
SYS   # Call it 'SYS' for EFI system partition
c     # Name partition
2     # Partition 2
BOOT  # Call it 'BOOT'
c     # Name Partition
3     # Partition 3
SWAP  # Call it 'SWAP'
c     # Name parition
4     # Partition 4
ROOT  # Call it 'ROOT'
p     # Print the table
w     # Write the changes
y     # Confirm 'yes'
EOF


clear
lsblk

# Add a 'p' to the end of disks starting with 'nvme'. Example, nvme0n1 = nvme0n1p (NOT TESTED YET!!!)
disk=$(echo $disk | sed -e 's/nvme.*/&p/')

mkfs.fat -F 32 -n SYS $disk'1'
mkfs.ext4 -F -L BOOT $disk'2'
mkswap $disk'3' -L swap
mkfs.btrfs -f -L ROOT $disk'4'

mkdir -p /mnt
mount $disk'4' /mnt

cd /mnt

btrfs subvolume create @
btrfs subvolume create @cache
btrfs subvolume create @log
btrfs subvolume create @vartmp
btrfs subvolume create @snapshots

cd
umount /mnt

mount -o compress=zstd,noatime,subvol=@ $disk'4' /mnt

mkdir -p /mnt/{boot,var/{log,cache,tmp},tmp,.snapshots}

mount -o compress=zstd,noatime,subvol=@log $disk'4' /mnt/var/log
mount -o compress=zstd,noatime,subvol=@cache $disk'4' /mnt/var/cache
mount -o compress=zstd,noatime,subvol=@vartmp $disk'4' /mnt/var/tmp
mount -o compress=zstd,noatime,subvol=@snapshots $disk'4' /mnt/.snapshots

chattr +C /mnt/var/log /mnt/var/cache /mnt/var/tmp

mount $disk'2' /mnt/boot
mkdir -p /mnt/boot/efi

mount $disk'1' /mnt/boot/efi

lsblk


udevadm trigger
mkdir -p /mnt/{proc,sys,dev/pts}
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -B /dev /mnt/dev
mount -t devpts pts /mnt/dev/pts



###  Find Release  ###

source /etc/os-release
export VERSION_ID="$VERSION_ID"
env | grep -i version



###  Make dnf faster  ###

DNF_VAR_fastestmirror=1
DNV_VAR_maxparallel_downloads=10



###  Install core system  ###

dnf --installroot=/mnt --releasever=$VERSION_ID groupinstall -y core

mv /mnt/etc/resolv.conf /mnt/etc/resolv.conf.org
cp -L /etc/resolv.conf /mnt/etc



###  Generate /etc/fstab  ###

dnf install -y arch-install-scripts
genfstab -U /mnt >> /mnt/etc/fstab

# Using subvolids in fstab will result in error message when creating snapshots
sed -i 's/subvolid=.*,//' /mnt/etc/fstab

# Not needed
sed -i '/zram0/d' /mnt/etc/fstab

sed -i 's/zstd:3/zstd:1/' /mnt/etc/fstab

cat /mnt/etc/fstab

# Needed to pass the variable to chroot
echo $disk > /mnt/disk
echo $user > /mnt/username



###  chroot  ###

chroot /mnt /bin/bash
export PS1="(chroot) $PS1"     # So we know when we are in chroot

#sleep 1

disk=$(cat /disk)
user=$(cat /username)

mount -a

# The below command gives me an error. Setup still works though.
mount -t efivarfs efivarfs /sys/firmware/efi/efivars

fixfiles -F onboot



###  Install essential applications  ###

dnf install -y glibc-langpack-en btrfs-progs efi-filesystem efibootmgr fwupd grub2-common grub2-efi-ia32 grub2-efi-x64 grub2-pc grub2-pc-modules grub2-tools grub2-tools-efi grub2-tools-extra grub2-tools-minimal grubby kernel mokutil shim-ia32 shim-x64 util-linux-user

# Barebones to get wireless iwd running?
dnf install -y iw iwl* iwd


# Extra wireless applications that might be helpful
#dnf install wpa_supplicant net-tools iw NetworkManager-config-connectivity-fedora iwl*



###  Install extra applications ###

dnf install -y vim htop lz4 dhcpcd mksh htop tar

dnf install -y plasma-mobile dolphin kate btrfs-assistant ark pip --exclude=PackageKit

dnf remove -y PackageKit plymouth firewalld 



###  Grub  ###
 
rm -rf /boot/efi/EFI/fedora/grub.cfg
rm -rf /boot/grub2/grub.cfg
 
dnf reinstall -y shim-* grub2-efi-* grub2-common
 
ls /boot/efi/EFI/fedora
ls /boot/loader/entries
 
# Create a silent booting system
cat > /etc/default/grub << EOF
GRUB_TIMEOUT=0
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="quiet nmi_watchdog=0 loglevel=3 systemd.show_status=auto rd.udev.log_level=3"
GRUB_DISABLE_RECOVERY="true"
#GRUB_ENABLE_BLSCFG=true
GRUB_HIDDEN_TIMEOUT=2
GRUB_RECORDFAIL_TIMEOUT=1
GRUB_TIMEOUT=0
 
# Update grub with:
# grub2-mkconfig -o /etc/grub2.cfg
EOF
 
efibootmgr
efibootmgr -c -d $disk -p 1 -L "Fedora (Custom)" -l \\EFI\\FEDORA\\SHIMX64.EFI
 
UUID_SWAP=$(blkid | grep $disk'3' | grep -o -P '(?<=UUID=\").*(?=\" TYPE)')
grubby --update-kernel=ALL --args="resume=UUID=$UUID_SWAP"

grub2-mkconfig -o /boot/grub2/grub.cfg



###  Create user  ###

#useradd -m $user
#usermod -aG wheel $user
useradd -mG $user -p '123456'








ls -la /home/$user
#chown -R user:user /home/user








mkdir -p /home/user/.local/bin








#  Default root password is '123456'
echo 123456 | passwd root --stdin



###  Silent boot  ###

mkdir -p /etc/sysctl.d
echo 'kernel.printk = 3 3 3 3' > /etc/sysctl.d/20-quiet-printk.conf
echo 'kernel.nmi_watchdog=0' > /etc/sysctl.d/99-nowatchdog.conf
sudo sysctl -p



###  Last touches  ###

# Use to check current locale:
#locale -a

LANG=en_US.UTF-8
echo $LANG > /etc/locale.conf

KEYMAP=us
touch /etc/vconsole.conf
sed -i "s/KEYMAP=.*/KEYMAP=$KEYMAP/" /etc/vconsole.conf

TIMEZONE=America/Toronto
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime


# An alternative to the above
#systemd-firstboot --prompt



###  iwd  ###

mkdir /etc/iwd
touch /etc/iwd/main.conf
cat > /etc/iwd/main.conf << EOF

[General]
EnableNetworkConfiguration=true
EOF

echo "Enabling iwd service..."
systemctl enable iwd.service



###  Shell  ###

chsh -s /bin/mksh
echo 123456 | sudo -u user chsh -s /bin/mksh



###  Autologin  ####

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
Type=simple
ExecStart=
ExecStart=-/sbin/agetty --skip-login --nonewline --noissue --autologin $user --noclear %I 38400 linux
EOF

cat >> /root/.mkshrc << EOF
HISTFILE=/root/.mksh_history
HISTSIZE=5000
export VISUAL="emacs"
export EDITOR="/usr/bin/vi"
set -o emacs
EOF



###  visudo  ***

mkdir -p /etc/sudoers.d
echo "user ALL=(ALL)  NOPASSWD: /usr/bin/btrfs-assistant" > /etc/sudoers.d/nopasswd

echo "Defaults editor=/usr/bin/vi" > /etc/sudoers.d/editor

# If needed
#echo "#includedir /etc/sudoers.d" | sudo EDITOR="tee -a" visudo    # if needed



###  user stuff  ###
 
 
su $user





mkdir -p ~/.local/bin






touch ~/.hushlogin


 
# HACK: to unlock session

echo '#!/bin/sh
 
while :; do
   loginctl unlock-session 1 &> /dev/null
   loginctl unlock-session 2 &> /dev/null
   loginctl unlock-session 3 &> /dev/null
   loginctl unlock-session 4 &> /dev/null
   loginctl unlock-session 5 &> /dev/null
   loginctl unlock-session 6 &> /dev/null
   sleep 5
done' > ~/.local/bin/lock.sh
chmod +x ~/.local/bin/lock.sh
 


###  Setup iwd script  ###
 
echo '#!/bin/bash
 
echo "This script should only need to be run once."
 
for dev in $(ls /sys/class/net); do
   if [[ -d "/sys/class/net/$dev/wireless" ]]; then
      wlan=$dev
      iwctl --passphrase 13FDC4A93E3C station $wlan connect BELL364

      if [ "$?" -eq 0 ]; then 
          echo "Connection successful!"
          exit
      else
          echo -e "Wireless device ($wlan) found.\nEnter your wireless network name:"
          read network
          iwctl station $wlan connect $network
      fi
   fi
done' > ~/.local/bin/setup-iwd.sh
chmod +x ~/.local/bin/setup-iwd.sh
 
 
 
cat > ~/.profile << EOF
# If running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi
 
PATH="$HOME/.local/bin:$PATH"
 
export EDITOR=/usr/bin/vi
export ENV="/home/$USER/.mkshrc"
export QT_QPA_PLATFORM=wayland
export QT_IM_MODULE=Maliit
export MOZ_ENABLE_WAYLAND=1
export XDG_RUNTIME_DIR=/tmp/runtime-user
export XDG_RUNTIME_DIR=/run/$USER/1000
export RUNLEVEL=3
export QT_LOGGING_RULES='*=false'

EOF


# Auto run in tty 1
 
echo -e '
if [[ ! ${DISPLAY} && ${XDG_VTNR} == 1 ]]; then
    startplasmamobile
fi' >> ~/.profile
 


cat > ~/.mkshrc << EOF
HISTFILE=/home/$USER/.mksh_history
HISTSIZE=5000
export VISUAL="emacs"
export EDITOR="/usr/bin/vi"
set -o emacs
EOF



###  Automaximize windows and remove title bar in KDE  ###

mkdir ~/.config
echo '[$Version]
update_info=kwinrules.upd:replace-placement-string-to-enum,kwinrules.upd:use-virtual-desktop-ids

[1]
Description=Windows
maximizehoriz=true
maximizehorizrule=3
maximizevert=true
maximizevertrule=3
noborder=true
noborderrule=3
types=1

[General]
count=1
rules=1' > ~/.config/kwinrulesrc



###  Setup konsole profiles  ###

mkdir -p ~/.local/share/konsole
cat > ~/.local/share/konsole/epy.profile << EOF
[Appearance]
ColorScheme=WhiteOnBlack
Font=Noto Sans Mono,24,-1,5,50,0,0,0,0,0
 
[General]
Name=epy
Parent=FALLBACK/
 
[Scrolling]
ScrollBarPosition=2
EOF
 
cat > ~/.local/share/konsole/user.profile << EOF
[Appearance]
ColorScheme=WhiteOnBlack
Font=Noto Sans Mono,14,-1,5,50,0,0,0,0,0
 
[General]
Name=user
Parent=FALLBACK/
EOF

mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/btrfs-assistant.desktop << EOF
[Desktop Entry]
Name=Btrfs Assistant
Comment=Change system settings
Exec=sudo /usr/bin/btrfs-assistant
Terminal=false
Type=Application
Icon=btrfs-assistant
Categories=System
NoDisplay=false
EOF
 
###  Epy reader  ###

mkdir -p ~/.config

pip3 install epy-reader

cat > ~/.local/share/applications/epy.desktop << EOF
[Desktop Entry]
Categories=System
Comment=Read ebooks
Exec=konsole --profile epy -e 'epy %u'
Icon=audiobook
Name=Epy
NoDisplay=false
Path=
StartupNotify=true
Terminal=false
TerminalOptions=
Type=Application
X-KDE-SubstituteUID=false
X-KDE-Username=
EOF
 
sed -i 's/    "MouseSupport": false,/    "MouseSupport": true,/g' ~/.config/epy/configuration.json


cat > ~/.local/share/applications/btrfsi-assistant.desktop << EOF
[Desktop Entry]
Name=Btrfs Assistant
Comment=Change system settings
Exec=sudo /usr/bin/btrfs-assistant
Terminal=false
Type=Application
Icon=btrfs-assistant
Categories=System
NoDisplay=false
EOF


###  flatpaks script (will not work in chroot)  ###
 
cat > ~/.local/bin/flatpack-install.sh << EOF
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install flathub org.mozilla.firefox
flatpak install flathub rocks.koreader.KOReader
 
# If you run into issues this might help
#flatpak uninstall --unused
EOF
chmod +x ~/.local/bin/flatpack-install.sh
 


###  snapper  ###
 
echo '# FIXME: snapper root config needs to be deleted and recreated. Not sure why
umount /.snapshots
rm -rf /.snapshots
snapper create-config /
 
if [[ $(snapper list | awk "/Setup complete/") == "" ]]; then
   snapper -c root create --description "Setup complete"
fi
  
# Automate snapper and btrfs services  ###
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer
systemctl enable snapper-boot.timer
 
systemctl enable btrfs-balance.timer
systemctl enable btrfs-scrub.timer
systemctl enable btrfs-trim.timer
 
# Have snapper take a snapshot every 20 mins (default is every 1hr)
mkdir -p /etc/systemd/system/snapper-timeline.timer.d/
cat > /etc/systemd/system/snapper-timeline.timer.d/frequency.conf << EOF
[Timer]
OnCalendar=
OnCalendar=*:0/20
EOF

echo "To edit snapper config, run: vi /etc/snapper/configs/root"
' > ~/.local/bin/snapper.sh
chmod +x ~/.local/bin/snapper.sh

 
###  Create a post install script ###
 
echo '#/bin/bash
 
# Automatic date and time sync
sudo timedatectl set-ntp yes

systemctl disable avahi-daemon.service bluetooth.service firewalld ModemManager.service NetworkManager.service

dnf remove firewalld plymouth
chattr +C /home/user/.cache

' > ~/.local/bin/post-install.shchmod +x ~/.local/bin/post-install.sh



###  Tweak kernel  ###
 
cat > ~/.local/bin/post-install.sh << EOF
sudo mkdir -p /etc/dracut.conf.d
sudo echo 'add_dracutmodules+=" resume "' >> /etc/dracut.conf.d/99-resume.conf
sudo echo 'hostonly="yes"' >> /etc/dracut.conf.d/99-hostonly.conf
sudo echo 'compress="lz4"' >> /etc/dracut.conf.d/99-compress.conf
sudo dracut -f
EOF
chmod +x ~/.local/bin/post-install.sh

 
###  Create chroot script incase you need it later  ###
 
echo '#!/bin/bash

fdisk -l

echo

read -e -p "Enter disk to chroot into: " disk 
disk=$(echo $disk | sed -e "s/nvme.*/&p/")
echo "Disk: $disk"

cd /
umount /mnt

mount -o compress=zstd,noatime,subvol=@ $disk"4" /mnt
 
#mkdir -p /mnt/{boot,var/{log,cache,tmp},tmp,home/user/.cache,.snapshots}
 
mount -o compress=zstd,noatime,subvol=@log $disk"4" /mnt/var/log
mount -o compress=zstd,noatime,subvol=@cache $disk"4" /mnt/var/cache
mount -o compress=zstd,noatime,subvol=@vartmp $disk"4" /mnt/var/tmp
mount -o compress=zstd,noatime,subvol=@tmp $disk"4" /mnt/tmp
mount -o compress=zstd,noatime,subvol=@homecache $disk"4" /mnt/home/user/.cache
mount -o compress=zstd,noatime,subvol=@snapshots $disk"4" /mnt/.snapshots
 
chattr +C /mnt/var/log /mnt/var/cache /mnt/var/tmp /mnt/tmp /mnt/home/user/.cache
 
chown -R user:user /mnt/home/user
 
mount $disk"2" /mnt/boot
#mkdir -p /mnt/boot/efi
 
mount $disk"1" /mnt/boot/efi
 
udevadm trigger
#mkdir -p /mnt/{proc,sys,dev/pts}
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -B /dev /mnt/dev
mount -t devpts pts /mnt/dev/pts
 
 
###  Find Release  ###
 
source /etc/os-release
export VERSION_ID="$VERSION_ID"
 
env | grep -i version
  
mv /mnt/etc/resolv.conf /mnt/etc/resolv.conf.org
cp -L /etc/resolv.conf /mnt/etc
  
 
chroot /mnt /bin/bash
export PS1="(chroot) $PS1"     # So we know when we are in chroot
 
 
mount -a
mount -t efivarfs efivarfs /sys/firmware/efi/efivars
 
 
 
###  DO STUFF!!!  ###
 
echo "You are now in chroot. Type exit to return to regular shell."
 
bash
 
echo "You have exited from chroot and are now in a regular shell."
 
 
umount -n -R /mnt
' > ~/.local/bin/chroot.sh
chmod +x ~/.local/bin/chroot.sh 
 
 
exit # exit chroot user
exit # exit chroot root
 
umount -n -R /mnt

sync
 
echo "Reboot to test system!"
