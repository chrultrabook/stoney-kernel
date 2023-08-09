#!/bin/bash

set -e

kernel_config_dir=$PWD/config
source_dir=$PWD/source
build_dir=$PWD/build
patches_dir=$PWD/patches

kernel_version="6.4.8"
tarball_url="https://cdn.kernel.org/pub/linux/kernel/v${kernel_version:0:1}.x/linux-${kernel_version}.tar.xz"
tarball_name="$(echo $tarball_url | cut -f 8 -d '/')"

# each variant has a different config, branch, arch, patch set, etc
variants=('stoney' 'avs' 'mt8173')

function build_kernel {
    variant=$1
    case $variant in
        stoney)
	    arch=x86_64

	    # Install amdgpu firmware
	    firmware_dir=${source_dir}/${variant}/stoney_firmware
	    mkdir -p ${firmware_dir}/amdgpu
	    cp -r /lib/firmware/amdgpu/stoney* ${firmware_dir}/amdgpu
	    # doesn't matter if decompression fails
      xz_count=`ls -1 ${firmware_dir}/amdgpu/stoney*.xz 2>/dev/null | wc -l`
      zst_count=`ls -1 ${firmware_dir}/amdgpu/stoney*.zst 2>/dev/null | wc -l`
	    if [ $xz_count != 0 ]; then
        xz -d ${firmware_dir}/amdgpu/stoney*.xz &> /dev/null || true
      fi
	    if [ $zst_count != 0 ]; then
        zstd -d ${firmware_dir}/amdgpu/stoney*.zst &> /dev/null || true
      fi
	    ;;
	avs)
	    arch=x86_64
	    ;;
	mt8173)
	    tarball_url=""
	    arch=arm64
	    ;;
    esac

    kernel_source_dir=${source_dir}/${variant}/linux-${kernel_version}
    output_dir=${build_dir}/${variant}
    module_dir=${output_dir}/modules
    header_dir=${output_dir}/headers
    case $arch in
        arm*) dtbs_dir=${output_dir}/dtbs ;;
    esac

    echo "Building $variant kernel"

    curl -L $tarball_url -o ${source_dir}/${variant}/${tarball_name}
    tar xf ${source_dir}/${variant}/${tarball_name} -C ${source_dir}/${variant}/
    cd $kernel_source_dir
    patch -p1 < ${patches_dir}/${variant}/* &> /dev/null || true

    case $arch in
        arm64) cross="aarch64-linux-gnu-";;
    esac

    # install config for variant
    cp ${kernel_config_dir}/${variant}.config .config
    make CROSS_COMPILE=$cross ARCH=$arch olddefconfig

    # build kernel and modules
    make CROSS_COMPILE=$cross ARCH=$arch -j$(nproc)

    # install build files to output dir
    mkdir -p $output_dir
    case $arch in
        arm*) install_cmd="zinstall dtbs_install";;
	*) install_cmd="install";;
    esac
    make modules_install $install_cmd \
	    ARCH=$arch \
            INSTALL_MOD_PATH=$module_dir \
	    INSTALL_MOD_STRIP=1 \
	    INSTALL_PATH=$output_dir \
	    INSTALL_DTBS_PATH=$dtbs_dir
    cp .config $output_dir/config
    cp System.map $output_dir/System.map
    cp include/config/kernel.release $output_dir/kernel.release

    # install header files
    # stolen from arch's linux PKGBUILD
    mkdir -p $header_dir

    # build files
    install -Dt "$header_dir" -m644 .config Makefile Module.symvers System.map \
        vmlinux
    install -Dt "$header_dir/kernel" -m644 kernel/Makefile
    install -Dt "$header_dir/arch/x86" -m644 arch/x86/Makefile
    cp -t "$header_dir" -a scripts

    # header files
    cp -t "$header_dir" -a include
    cp -t "$header_dir/arch/x86" -a arch/x86/include
    install -Dt "$header_dir/arch/x86/kernel" -m644 arch/x86/kernel/asm-offsets.s
    install -Dt "$header_dir/drivers/md" -m644 drivers/md/*.h
    install -Dt "$header_dir/net/mac80211" -m644 net/mac80211/*.h
    install -Dt "$header_dir/drivers/media/i2c" -m644 drivers/media/i2c/msp3400-driver.h
    install -Dt "$header_dir/drivers/media/usb/dvb-usb" -m644 drivers/media/usb/dvb-usb/*.h
    install -Dt "$header_dir/drivers/media/dvb-frontends" -m644 drivers/media/dvb-frontends/*.h
    install -Dt "$header_dir/drivers/media/tuners" -m644 drivers/media/tuners/*.h
    install -Dt "$header_dir/drivers/iio/common/hid-sensors" -m644 drivers/iio/common/hid-sensors/*.h

    # kconfig files
    find . -name 'Kconfig*' -exec install -Dm644 {} "$header_dir/{}" \;

    # remove documentation
    rm -r "$header_dir/Documentation"

    # remove broken symlinks
    find -L "$header_dir" -type l -delete

    # remove loose objects
    find "$header_dir" -type f -name '*.o' -delete

    # strip build tools
    while read -rd '' file; do
        case "$(file -Sib "$file")" in
            application/x-sharedlib\;*)      # Libraries (.so)
                strip "$file" ;;
            application/x-archive\;*)        # Libraries (.a)
                strip "$file" ;;
            application/x-executable\;*)     # Binaries
                strip "$file" ;;
            application/x-pie-executable\;*) # Relocatable binaries
                strip "$file" ;;
        esac
    done < <(find "$header_dir" -type f -perm -u+x ! -name vmlinux -print0)
    strip $header_dir/vmlinux

    # compress all resulting files
    cd $output_dir; tar -caf kernel.tar.gz *; cd -
}

# if an argument is passed to the script, build that variant. otherwise build each variant
if [[ -n $1 ]]; then
    variant=$1
    build_kernel $variant
else
    for variant in ${variants[@]}; do
        build_kernel $variant
    done
fi
