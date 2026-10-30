// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * kvmcheck - probe /dev/kvm on an Android (aarch64) host.
 *
 * Tiny, dependency-free native tool to tell you, on the phone, whether the
 * running kernel actually gives you working KVM: whether /dev/kvm exists, is
 * openable, reports a sane API version, and what the important ARM64
 * capabilities and the guest IPA (physical address) limit are.
 *
 * Build (Android NDK, bionic, static):
 *   aarch64-linux-android24-clang -O2 -static -o kvmcheck-arm64 kvmcheck.c
 *
 * Run on device (needs read/write on /dev/kvm, i.e. root or the right group):
 *   ./kvmcheck-arm64
 *
 * Exit status: 0 if KVM looks usable, non-zero otherwise.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/kvm.h>

static int check_ext(int fd, const char *name, int cap) {
    int r = ioctl(fd, KVM_CHECK_EXTENSION, cap);
    if (r < 0) {
        printf("  %-28s error (%s)\n", name, strerror(errno));
        return -1;
    }
    printf("  %-28s %d\n", name, r);
    return r;
}

int main(void) {
    struct stat st;
    printf("kvmcheck - KVM probe for Android aarch64\n");
    printf("========================================\n");

    if (stat("/dev/kvm", &st) != 0) {
        printf("[FAIL] /dev/kvm does not exist: %s\n", strerror(errno));
        printf("       Your kernel was not built with CONFIG_KVM=y, or the\n");
        printf("       device node was not created. Samsung stock kernels ship\n");
        printf("       KVM disabled; you need a custom kernel.\n");
        return 2;
    }
    printf("[ ok ] /dev/kvm exists (mode %o, uid %d, gid %d)\n",
           st.st_mode & 07777, st.st_uid, st.st_gid);

    int fd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        printf("[FAIL] cannot open /dev/kvm: %s\n", strerror(errno));
        printf("       Fix permissions (chmod 666 /dev/kvm) or run as root.\n");
        return 3;
    }
    printf("[ ok ] opened /dev/kvm read-write\n");

    int api = ioctl(fd, KVM_GET_API_VERSION, 0);
    if (api < 0) {
        printf("[FAIL] KVM_GET_API_VERSION: %s\n", strerror(errno));
        close(fd);
        return 4;
    }
    printf("[ ok ] KVM API version: %d%s\n", api,
           api == 12 ? " (stable)" : " (unexpected; expected 12)");

    printf("\nCapabilities:\n");
    check_ext(fd, "KVM_CAP_ARM_VM_IPA_SIZE", KVM_CAP_ARM_VM_IPA_SIZE);
    check_ext(fd, "KVM_CAP_NR_VCPUS", KVM_CAP_NR_VCPUS);
    check_ext(fd, "KVM_CAP_MAX_VCPUS", KVM_CAP_MAX_VCPUS);
    check_ext(fd, "KVM_CAP_ONE_REG", KVM_CAP_ONE_REG);
    check_ext(fd, "KVM_CAP_ARM_PSCI_0_2", KVM_CAP_ARM_PSCI_0_2);
    check_ext(fd, "KVM_CAP_MP_STATE", KVM_CAP_MP_STATE);
#ifdef KVM_CAP_ARM_EL1_32BIT
    check_ext(fd, "KVM_CAP_ARM_EL1_32BIT", KVM_CAP_ARM_EL1_32BIT);
#endif

    /* Try to actually create a VM: the real test of whether EL2/HVC works. */
    printf("\nVM creation test:\n");
    int vm = ioctl(fd, KVM_CREATE_VM, 0);
    if (vm < 0) {
        printf("[FAIL] KVM_CREATE_VM: %s\n", strerror(errno));
        printf("       KVM is present but cannot create a VM. On the\n");
        printf("       Snapdragon 8+ Gen 1 this usually means the kernel is\n");
        printf("       not booted at EL2 / the Gunyah hypervisor owns EL2, so\n");
        printf("       KVM has no hypervisor mode to use.\n");
        close(fd);
        return 5;
    }
    printf("[ ok ] KVM_CREATE_VM succeeded (fd %d)\n", vm);
    int ipa = ioctl(fd, KVM_CHECK_EXTENSION, KVM_CAP_ARM_VM_IPA_SIZE);
    if (ipa > 0)
        printf("       guest physical address space: up to %d-bit\n", ipa);
    close(vm);
    close(fd);

    printf("\n[PASS] KVM looks usable. You can run qemu with -enable-kvm -cpu host.\n");
    return 0;
}
