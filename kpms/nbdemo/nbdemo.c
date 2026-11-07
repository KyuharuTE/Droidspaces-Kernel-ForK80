#include <compiler.h>
#include <kpmodule.h>
#include <linux/printk.h>
#include <linux/string.h>
#include <kputils.h>

/*
 * Example KPM: the minimum a loadable module needs.
 *
 * .kpm.init and .kpm.exit are mandatory, the loader refuses a module without
 * them. Metadata comes from the KPM_* macros, which place key=value strings in
 * .kpm.info; the manager app reads that back through the info supercall.
 */

KPM_NAME("kpm-nbdemo");
KPM_VERSION("1.0.0");
KPM_LICENSE("GPL v2");
KPM_AUTHOR("Droidspaces");
KPM_DESCRIPTION("Minimal KPM example: logs on load, echoes control strings");

static long nbdemo_init(const char *args, const char *event, void *__user reserved) {
    pr_info("kpm-nbdemo: init, event=%s args=%s\n",
            event ? event : "(null)", args ? args : "(null)");
    pr_info("kpm-nbdemo: kernelpatch version %x\n", kpver);
    return 0;
}

static long nbdemo_control0(const char *args, char *__user out_msg, int outlen) {
    char echo[128] = "echo: ";
    if (args) strncat(echo, args, sizeof(echo) - 8);
    compat_copy_to_user(out_msg, echo, sizeof(echo));
    return 0;
}

static long nbdemo_exit(void *__user reserved) {
    pr_info("kpm-nbdemo: exit\n");
    return 0;
}

KPM_INIT(nbdemo_init);
KPM_CTL0(nbdemo_control0);
KPM_EXIT(nbdemo_exit);
