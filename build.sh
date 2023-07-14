#!/bin/bash

set -e

kernel_source_dir=$PWD/linux
kernel_source_url='https://github.com/chrultrabook/linux'
kernel_config_dir=$PWD/config
build_dir=$PWD/build

# each variant has a different config, branch, arch, etc
variants=('stoney' 'avs' 'mt8173')

function build_kernel {
    variant=$1
    case $variant in
        stoney)
      stoney_ver=6.4.6
	    arch=x86_64

	    # Install amdgpu firmware
	    firmware_dir=${build_dir}/${variant}/stoney_firmware
	    mkdir -p ${firmware_dir}/amdgpu
	    cp -r /lib/firmware/amdgpu/stoney* ${firmware_dir}/amdgpu
	    # doesn't matter if decompression fails
	    xz -d ${firmware_dir}/amdgpu/stoney* &> /dev/null || true
	    zstd -d ${firmware_dir}/amdgpu/stoney* &> /dev/null || true
	    ;;
	avs)
	    branch=avs
	    arch=x86_64
	    ;;
	mt8173)
	    branch=linux-mt8173
	    arch=arm64
	    ;;
    esac

    output_dir=${build_dir}/${variant}
    module_dir=${output_dir}/modules
    header_dir=${output_dir}/headers
    case $arch in
        arm*) dtbs_dir=${output_dir}/dtbs ;;
    esac

    echo "Building $variant kernel"

    if [[ $variant == 'stoney' ]]; then
        if [[ -d $kernel_source_dir ]]; then
            rm -rf $kernel_source_dir
        fi
        curl -LO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${stoney_ver}.tar.xz
        tar xf linux-${stoney_ver}.tar.xz
        rm linux-${stoney_ver}.tar.xz
        mv linux-${stoney_ver} $kernel_source_dir
        cd $kernel_source_dir
        patch -p1 < ../patches/stoney/*
    else
        if [[ ! -d ${kernel_source_dir}/.git ]]; then
            rm -rf $kernel_source_dir
        fi
        if [[ ! -d $kernel_source_dir ]]; then
            git clone $kernel_source_url $kernel_source_dir
        fi
        cd $kernel_source_dir
        git switch $branch
    fi
    
    # make sure source is clean from any previous builds
    make clean

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
