#if defined(__linux__)
#define _GNU_SOURCE
#elif defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#include <fcntl.h>
#include <spawn.h>
#include <stddef.h>

// Let libc's headers supply the layout of posix_spawn_file_actions_t.
int bkr_spawn(pid_t *pid, char *const argv[], char *const envp[],
              const char *cwd, const int *child, unsigned int null_mask) {
    posix_spawn_file_actions_t actions;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc) return rc;

    if (cwd) {
#if defined(__APPLE__) && __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 260000
        rc = posix_spawn_file_actions_addchdir(&actions, cwd);
#else
        rc = posix_spawn_file_actions_addchdir_np(&actions, cwd);
#endif
    }
    for (int i = 0; i < 3 && !rc; i++) {
        if (null_mask & (1u << i))
            rc = posix_spawn_file_actions_addopen(&actions, i, "/dev/null",
                                                i == 0 ? O_RDONLY : O_WRONLY, 0);
        else if (child[i] >= 0)
            rc = posix_spawn_file_actions_adddup2(&actions, child[i], i);
    }
    if (!rc) rc = posix_spawnp(pid, argv[0], &actions, NULL, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    return rc;
}
