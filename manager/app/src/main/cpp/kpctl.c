/*
 * kpctl - KernelPatch SuperCall command line client.
 *
 * Pulled in because an ordinary Android app cannot be relied on to issue the
 * supercall itself: app seccomp filters restrict which syscall numbers reach the
 * kernel, and syscall 45 is one of the ones they clamp down on. Running as root
 * through `su` sidesteps the app's seccomp profile entirely, which is also where
 * root access is already required for Droidspaces.
 *
 * Everything here is one multiplexed syscall:
 *
 *   syscall(45, superkey, encoded_cmd, a1, a2, a3, a4)
 *
 * encoded_cmd = (kp_version << 32) | (0x1158 << 16) | cmd
 *
 * Output is line oriented and machine parsed by the app, so keep it stable:
 *
 *   OK <payload>        command succeeded, payload may be empty
 *   ERR <code> <msg>    command failed
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

#define __NR_supercall 45

#define SUPERCALL_MAGIC 0x1158
#define SUPERCALL_HELLO_MAGIC 0x11581158

#define SUPERCALL_HELLO 0x1000
#define SUPERCALL_KERNELPATCH_VER 0x1008
#define SUPERCALL_KERNEL_VER 0x1009
#define SUPERCALL_KPM_LOAD 0x1020
#define SUPERCALL_KPM_UNLOAD 0x1021
#define SUPERCALL_KPM_CONTROL 0x1022
#define SUPERCALL_KPM_NUMS 0x1030
#define SUPERCALL_KPM_LIST 0x1031
#define SUPERCALL_KPM_INFO 0x1032

#define KPM_LOAD_RESULT_MAGIC 0x4b504d52
#define KPM_LOAD_RESULT_MSG 160

struct kpm_load_result {
    unsigned int magic;
    unsigned int size;
    int code;
    char message[KPM_LOAD_RESULT_MSG];
};

/* 0.13.9. The kernel answers SUPERCALL_KERNELPATCH_VER, and the app refreshes
 * this on every connect, so a stale constant only matters before the first
 * hello. */
static unsigned int g_kp_version = 0x000d09;

static long encode_cmd(unsigned int cmd) {
    return ((long)g_kp_version << 32) | ((long)SUPERCALL_MAGIC << 16) | (cmd & 0xFFFF);
}

static long supercall(const char *key, unsigned int cmd, long a1, long a2, long a3, long a4) {
    return syscall((long)__NR_supercall, key, encode_cmd(cmd), a1, a2, a3, a4);
}

static void usage(const char *argv0) {
    fprintf(stderr,
            "usage: %s <superkey> <command> [args]\n"
            "\n"
            "commands:\n"
            "  hello                          verify the superkey against the kernel\n"
            "  version                        print KernelPatch and kernel versions\n"
            "  list                           list loaded KPMs, one per line\n"
            "  nums                           count loaded KPMs\n"
            "  info <name>                    metadata for one KPM\n"
            "  load <path> [args]             load a .kpm file\n"
            "  unload <name>                  unload a KPM by name\n"
            "  control <name> <ctlargs>       send a control string to a KPM\n",
            argv0);
}

/* Kernel version arrives packed as major<<16|minor<<8|patch. */
static void print_kver(const char *label, long v) {
    printf("OK %s %ld.%ld.%ld\n", label, (v >> 16) & 0xFFFF, (v >> 8) & 0xFF, v & 0xFF);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        usage(argv[0]);
        return 2;
    }

    char key_input[66];
    const char *key = argv[1];
    if (strcmp(key, "--key-stdin") == 0) {
        if (!fgets(key_input, sizeof(key_input), stdin)) {
            fprintf(stderr, "cannot read superkey from stdin\n");
            return 2;
        }
        key_input[strcspn(key_input, "\r\n")] = '\0';
        if (!key_input[0] || strlen(key_input) > 64) {
            fprintf(stderr, "invalid superkey length\n");
            return 2;
        }
        key = key_input;
    }
    const char *cmd = argv[2];
    long r;

    if (strcmp(cmd, "hello") == 0) {
        r = supercall(key, SUPERCALL_HELLO, 0, 0, 0, 0);
        if (r == (long)SUPERCALL_HELLO_MAGIC) {
            /* Refresh the version so later calls encode it correctly. */
            long v = supercall(key, SUPERCALL_KERNELPATCH_VER, 0, 0, 0, 0);
            if (v > 0) g_kp_version = (unsigned int)v;
            printf("OK hello kp=%u\n", g_kp_version);
            return 0;
        }
        printf("ERR %ld %s\n", r, strerror(errno));
        return 1;
    }

    if (strcmp(cmd, "version") == 0) {
        long kp = supercall(key, SUPERCALL_KERNELPATCH_VER, 0, 0, 0, 0);
        long k = supercall(key, SUPERCALL_KERNEL_VER, 0, 0, 0, 0);
        if (kp > 0) g_kp_version = (unsigned int)kp;
        if (kp < 0 || k < 0) {
            printf("ERR %ld %s\n", kp < 0 ? kp : k, strerror(errno));
            return 1;
        }
        print_kver("kp_version", kp);
        print_kver("kernel_version", k);
        return 0;
    }

    if (strcmp(cmd, "list") == 0) {
        char buf[16384];
        memset(buf, 0, sizeof(buf));
        r = supercall(key, SUPERCALL_KPM_LIST, (long)buf, (long)sizeof(buf) - 1, 0, 0);
        if (r < 0) {
            printf("ERR %ld %s\n", r, strerror(errno));
            return 1;
        }
        buf[sizeof(buf) - 1] = '\0';
        printf("OK list\n%s\n", buf);
        return 0;
    }

    if (strcmp(cmd, "nums") == 0) {
        r = supercall(key, SUPERCALL_KPM_NUMS, 0, 0, 0, 0);
        if (r < 0) {
            printf("ERR %ld %s\n", r, strerror(errno));
            return 1;
        }
        printf("OK nums %ld\n", r);
        return 0;
    }

    if (strcmp(cmd, "info") == 0) {
        if (argc < 4) { usage(argv[0]); return 2; }
        char buf[8192];
        memset(buf, 0, sizeof(buf));
        r = supercall(key, SUPERCALL_KPM_INFO, (long)argv[3], (long)buf,
                      (long)sizeof(buf) - 1, 0);
        if (r < 0) {
            printf("ERR %ld %s\n", r, strerror(errno));
            return 1;
        }
        buf[sizeof(buf) - 1] = '\0';
        printf("OK info\n%s\n", buf);
        return 0;
    }

    if (strcmp(cmd, "load") == 0) {
        if (argc < 4) { usage(argv[0]); return 2; }
        const char *path = argv[3];
        const char *args = (argc >= 5) ? argv[4] : "";
        struct kpm_load_result res;
        memset(&res, 0, sizeof(res));
        r = supercall(key, SUPERCALL_KPM_LOAD, (long)path, (long)args, (long)&res, 0);
        if (r == 0) {
            printf("OK load\n");
            return 0;
        }
        if (res.magic == KPM_LOAD_RESULT_MAGIC) {
            printf("ERR %d %s\n", res.code, res.message);
        } else {
            printf("ERR %ld %s\n", r, strerror(errno));
        }
        return 1;
    }

    if (strcmp(cmd, "unload") == 0) {
        if (argc < 4) { usage(argv[0]); return 2; }
        r = supercall(key, SUPERCALL_KPM_UNLOAD, (long)argv[3], 0, 0, 0);
        if (r == 0) {
            printf("OK unload\n");
            return 0;
        }
        printf("ERR %ld %s\n", r, strerror(errno));
        return 1;
    }

    if (strcmp(cmd, "control") == 0) {
        if (argc < 5) { usage(argv[0]); return 2; }
        char buf[8192];
        memset(buf, 0, sizeof(buf));
        r = supercall(key, SUPERCALL_KPM_CONTROL, (long)argv[3], (long)argv[4],
                      (long)buf, (long)sizeof(buf) - 1);
        if (r < 0) {
            printf("ERR %ld %s\n", r, strerror(errno));
            return 1;
        }
        buf[sizeof(buf) - 1] = '\0';
        printf("OK control\n%s\n", buf);
        return 0;
    }

    fprintf(stderr, "unknown command: %s\n", cmd);
    usage(argv[0]);
    return 2;
}
