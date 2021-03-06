# Copyright 1999-2014 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: /var/cvsroot/gentoo-x86/sys-kernel/gentoo-sources/gentoo-sources-3.16.1.ebuild,v 1.1 2014/08/14 12:17:42 mpagano Exp $

EAPI="5"
# Although this is not strictly a Gentoo kernel source package, we still
# want to get all the kernel-2 eclass magic used for kernel sources.
ETYPE="sources"
K_WANT_GENPATCHES="base extras experimental"
K_GENPATCHES_VER="1"
K_DEBLOB_AVAILABLE="1"
inherit kernel-2 mount-boot
detect_version
detect_arch

KEYWORDS="~alpha ~amd64 ~arm ~arm64 ~hppa ~ia64 ~mips ~ppc ~ppc64 ~s390 ~sh ~sparc ~x86"
HOMEPAGE="https://github.com/crossdistro/gentoo-kernel"
# A couple of use flags including `symlink` inherited from the `kernel-2`
# eclass are set by default in order to provide full automation of the
# `gentoo-kernel` e build.
#
#   * kpackage – Enable package based kernel configuration automation.
#   * grub – Configure grub to boot the new kernel.
#   * symlink – Fix the `/usr/src/linux` symlink to point to the new kernel.
# 
IUSE="experimental -menuconfig +kpackage +grub +symlink"
PROPERTIES="menuconfig? ( interactive )"

DESCRIPTION="Directly installable kernel package using Gentoo sources and a bit of automation"
SLOT="0"
SRC_URI="${KERNEL_URI} ${GENPATCHES_URI} ${ARCH_URI}"

# We want to use a version of genkernel that doesn't install firmware by default.
#
# https://bugs.gentoo.org/show_bug.cgi?id=600262#c1
DEPEND="
	>=sys-kernel/genkernel-3.5.0.6
	sys-kernel/kernel-tools
	!=sys-kernel/gentoo-sources-${PV}
"

# We need to be able to find the right default genkernel configuration file
# the respective kernel architecture. While kernel no longer distinguishes
# x86 and x86_64 architectures, genkernel stil does that. As a result, it
# provides a different default configuration file for x86_64 and the
# resulting file names also include that string.
case "$ARCH" in
amd64)
	export GK_ARCH="x86_64"
	;;
ppc64)
	export GK_ARCH="$ARCH"
	;;
*)
	export GK_ARCH="$(tc-arch-kernel)"
	;;
esac
# Some variable interfere with the kernel Makefile. While they are harmless
# with kernel source packages, `gentoo-kernel` ebuild actually uses the
# kernel Makefile for all sorts of things including the actual kernel build
# process.
unset ARCH
unset LDFLAGS

src_configure() {
	mkdir -p "${T}"/cfg || die

	cat `find /etc/kconfig/rules/ -type f` > "${T}/cfg/rules.config" || die
	{ use kpackage && kpackage || true; } > "${T}/cfg/package.config" || die
	kcombine "/usr/share/genkernel/arch/$GK_ARCH/kernel-config" "${T}/cfg/rules.config" "${T}/cfg/package.config" > "${T}/cfg/.config" || die

	kconfig --check "${T}/cfg/.config" || die
	make O="${T}/cfg/" olddefconfig || die
	mv "${T}/cfg/.config" "${T}/cfg/auto.config" || die
	kconfig --check "${T}/cfg/auto.config"

	if use menuconfig; then
		ash
		cp "${T}/cfg/auto.config" "${T}/cfg/.config" || die
		make O="${T}/cfg/" menuconfig </dev/tty >/dev/tty || die
		user-config.py --trim "${T}/cfg/.config" "${T}/cfg/auto.config" "${T}/cfg/user.config" || die
	fi

	if [ -f user.config ]; then
		kcombine "${T}/cfg/auto.config" "${T}/cfg/user.config" > "${T}/cfg/.config" || die
		make O="${T}/cfg/" olddefconfig || die
		mv "${T}/cfg/.config" "${T}/cfg/final.config" || die
		kconfig --check "${T}/cfg/final.config"
	else
		cp "${T}/cfg/auto.config" "${T}/cfg/final.config" || die
	fi
}

src_compile() {
	install -d "${WORKDIR}"/out/{lib,boot}
	install -d "${T}"/{cache,twork}
	genkernel \
		--no-menuconfig \
		--no-save-config \
		--no-firmware \
		--mrproper \
		--clean \
		--kernel-config="${T}"/cfg/final.config \
		--kerneldir="${S}" \
		--kernel-outputdir="${WORKDIR}"/build \
		--makeopts="${MAKEOPTS}" \
		--cachedir="${T}"/cache \
		--tempdir="${T}"/twork \
		--logfile="${WORKDIR}"/genkernel.log \
		--bootdir="${WORKDIR}"/out/boot \
		--module-prefix="${WORKDIR}"/out \
		all || die "genkernel failed"
	# For some reason firmware gets installed anyway
	if [ -e "${WORKDIR}/out/lib/firmware" ]; then
		ewarn "Firmware (${WORKDIR}/out/lib/firmware) installed anyway, we need to delete it."
		rm -rf "${WORKDIR}/out/lib/firmware"
	fi
}

check_path() {
	local path="$1"
	local dpath="${D}/${path}"

	[ -e "${dpath}" ] || die "Missing required file in destination directory: ${path}"
}

src_install() {
	kernel-2_src_install

	# TODO: Determine whether this is needed at all.
	cd "${D}/usr/src/linux-${KV_FULL}" || die
	make mrproper || die

	# TODO: Determine whether this is needed at all.
	#
	# Reduce the installed sources only to those needed for building
	# modules, using a script from openSUSE.
	cd "${D}" || die
	perl ${FILESDIR}/group-source-files.pl -D ${T}/keep-src-files -N ${T}/nokeep-src-files \
		-L usr/src/linux-${KV_FULL}

	# TODO: Determine how much of this is needed at all.
	#
	# Copy the final config and clean up the repo.
	cd "${D}/usr/src/linux-${KV_FULL}"
	cp "${T}"/cfg/final.config .config || die
	make olddefconfig || die
	make prepare || die
	make scripts || die

	# Finally reduce the installed sources.
	cat ${T}/nokeep-src-files | grep -v '%dir' | sed -e 's#^#'"${D}"'#' | xargs rm -f

	# OK, now the source tree is configured to allow 3rd-party modules to be
	# built against it, since we want that to work since we have a binary kernel
	# built.
	cp -a "${WORKDIR}"/out/* "${D}"/ || die "couldn't copy output files into place"
	# module symlink fixup:
	rm -f "${D}"/lib/modules/*/source || die
	rm -f "${D}"/lib/modules/*/build || die
	cd "${D}"/lib/modules
	# module strip:
	find -iname *.ko -exec strip --strip-debug {} \;
	# back to the symlink fixup:
	local moddir="$(ls -d [23]*)"
	ln -s /usr/src/linux-${KV_FULL} "${D}"/lib/modules/${moddir}/source || die
	ln -s /usr/src/linux-${KV_FULL} "${D}"/lib/modules/${moddir}/build || die

	# Fixes FL-14
	cp "${WORKDIR}/build/System.map" "${D}/usr/src/linux-${KV_FULL}/" || die
	cp "${WORKDIR}/build/Module.symvers" "${D}/usr/src/linux-${KV_FULL}/" || die

	check_path "/usr/src/linux-${KV_FULL}"
	check_path "/boot/kernel-genkernel-${GK_ARCH}-${KV_FULL}"
	check_path "/boot/initramfs-genkernel-${GK_ARCH}-${KV_FULL}"
}

cond_update_grub() {
	use grub && grub-mkconfig > /boot/grub/grub.cfg
}

pkg_postinst() {
	kernel-2_pkg_postinst
	cond_update_grub
}

pkg_postrm() {
	kernel-2_pkg_postrm
	cond_update_grub
}
