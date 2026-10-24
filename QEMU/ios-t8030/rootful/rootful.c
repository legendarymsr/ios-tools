/*
 * rootful: an ephemeral "rootful" overlay for HackiOS (ios-tools), run by hackios.sh
 *          when built with HACKIOS_ROOTFUL=1.
 *
 * HackiOS's root filesystem is a read-only APFS RAM disk; the only writable filesystem is the memory
 * filesystem on /private/var, which is why the jailbreak is rootless (everything under /var/jb). This
 * mounts a writable memory filesystem (ramfs) as a UNION over each system directory given on the
 * command line: a file created there lands in memory (the ramfs on top), while reads of what is
 * already there fall through to the read-only root below (MNT_UNION). So /Applications, /Library and
 * the like become writable -- you can drop a new .app or daemon in beside Apple's, rootfully.
 *
 * It is ephemeral: the overlay is memory, emptied on a cold boot like the rest of /private/var (a
 * snapshot keeps it). It cannot change the read-only system files that are already there, only add
 * alongside them -- the kernel's APFS is a reader (see xnu .../apfs_write.c), so there is no way to
 * rewrite the real files; this is the closest a read-only-root port can come to a rootful jailbreak.
 *
 * Run as root from the boot job list (rc.jobs).  usage: rootful DIR [DIR ...]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

#ifndef MNT_UNION
#define MNT_UNION 0x00000020    /* what is not in the mounted fs is found in the one below it */
#endif

/* create a file under dir, write to it, then remove it: proves the overlay is writable */
static int
writable(const char *dir)
{
	char path[1024];
	int fd;

	snprintf(path, sizeof(path), "%s/.rootful-writable", dir);
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		return 0;
	}
	if (write(fd, "ok\n", 3) != 3) {
		close(fd);
		unlink(path);
		return 0;
	}
	close(fd);
	unlink(path);
	return 1;
}

int
main(int argc, char **argv)
{
	int rc = 0;

	if (argc < 2) {
		fprintf(stderr, "usage: %s DIR [DIR ...]\n", argv[0]);
		return 2;
	}
	for (int i = 1; i < argc; i++) {
		if (mount("ramfs", argv[i], MNT_UNION, NULL) != 0) {
			printf("rootful: %s: mount: %s\n", argv[i], strerror(errno));
			rc = 1;
			continue;
		}
		if (writable(argv[i])) {
			printf("rootful: writable overlay on %s (verified: created a file)\n", argv[i]);
		} else {
			printf("rootful: overlay on %s mounted but NOT writable: %s\n", argv[i], strerror(errno));
			rc = 1;
		}
	}
	return rc;
}
