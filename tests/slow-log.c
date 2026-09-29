// preloaded into the check in tests/check.nix: each fflush of the check's log,
// which Asterisk's logger thread does after each line, waits 3 s first
#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int fflush(FILE *stream)
{
	static int (*flush)(FILE *);
	static const char suffix[] = "/log/check";
	char link[64], path[PATH_MAX];
	ssize_t length;

	if (!flush) {
		flush = (int (*)(FILE *))dlsym(RTLD_NEXT, "fflush");
	}
	if (stream) {
		snprintf(link, sizeof(link), "/proc/self/fd/%d", fileno(stream));
		length = readlink(link, path, sizeof(path) - 1);
		if (length >= (ssize_t)strlen(suffix)) {
			path[length] = '\0';
			if (!strcmp(path + length - strlen(suffix), suffix)) {
				sleep(3);
			}
		}
	}
	return flush(stream);
}
