// Root helper: spawned by the app as root via TrollStore's persona trick. Prints its uid and
// proves it by reading /etc/master.passwd (root-only, mode 600).
#include <stdio.h>
#include <unistd.h>
int main(void) {
    FILE *f = fopen("/etc/master.passwd", "r");
    printf("uid=%d%s\n", getuid(), f ? ", read /etc/master.passwd" : "");
    return 0;
}
