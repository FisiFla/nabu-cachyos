FROM scratch
ADD ArchLinuxARM-aarch64-latest.tar.gz /

RUN pacman-key --init && pacman-key --populate archlinuxarm

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
    base-devel bc bison flex dtc grub dosfstools btrfs-progs \
    mtools arch-install-scripts mkinitcpio git wget zstd parted \
    cpio android-tools

# Create non-root user for makepkg
RUN useradd -m builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR /build
