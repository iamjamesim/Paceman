/* One named macOS login item owns Paceman's source and optional APNs worker. */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t stopping = 0;
static volatile sig_atomic_t source_pid = -1;
static volatile sig_atomic_t push_pid = -1;

static void stop_children(int signal_number) {
    (void)signal_number;
    stopping = 1;
    if (source_pid > 0) kill((pid_t)source_pid, SIGTERM);
    if (push_pid > 0) kill((pid_t)push_pid, SIGTERM);
}

static pid_t start_child(const char *python, const char *root, int push) {
    pid_t pid = fork();
    if (pid != 0) return pid;
    char lib[4096], data[4096], status[4096], socket_path[4096];
    char config[4096], out[4096], err[4096];
    snprintf(lib, sizeof(lib), "%s/lib", root);
    snprintf(data, sizeof(data), "%s/data", root);
    snprintf(status, sizeof(status), "%s/status.json", root);
    snprintf(socket_path, sizeof(socket_path), "%s/hook.sock", root);
    snprintf(config, sizeof(config), "%s/private/apns.json", root);
    snprintf(out, sizeof(out), "%s/%s.log", root, push ? "push" : "source");
    snprintf(err, sizeof(err), "%s/%s-error.log", root, push ? "push" : "source");
    if (chdir(lib) != 0) _exit(127);
    int output = open(out, O_WRONLY | O_CREAT | O_APPEND, 0600);
    int error = open(err, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (output < 0 || error < 0) _exit(127);
    dup2(output, STDOUT_FILENO);
    dup2(error, STDERR_FILENO);
    close(output);
    close(error);
    if (push) {
        char *const args[] = {(char *)python, "-m", "service.push", "--config", config,
                              "--data-dir", data, NULL};
        execv(python, args);
    } else {
        char entry[4096];
        snprintf(entry, sizeof(entry), "%s/desktop/launch.py", lib);
        char *const args[] = {(char *)python, entry, "--data-dir", data, "serve",
                              "--source", "macos", "--status-file", status,
                              "--agent-socket", socket_path, "--relay-config", config, NULL};
        execv(python, args);
    }
    perror("Paceman background Python launch failed");
    _exit(127);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Paceman Background needs its Python and data paths.\n");
        return 2;
    }
    struct sigaction action = {.sa_handler = stop_children};
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);

    source_pid = start_child(argv[1], argv[2], 0);
    if (source_pid < 0) return 1;
    char config[4096], push_python[4096];
    snprintf(config, sizeof(config), "%s/private/apns.json", argv[2]);
    snprintf(push_python, sizeof(push_python), "%s/push-venv/bin/python3", argv[2]);
    if (access(config, R_OK) == 0 && access(push_python, X_OK) == 0)
        push_pid = start_child(push_python, argv[2], 1);

    while (source_pid > 0) {
        int status;
        pid_t ended = waitpid(-1, &status, 0);
        if (ended < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ended == source_pid) {
            source_pid = -1;
            if (push_pid > 0) kill((pid_t)push_pid, SIGTERM);
            break;
        }
        if (ended == push_pid) {
            push_pid = -1;
            if (!stopping) {
                sleep(10);
                if (!stopping && access(config, R_OK) == 0 && access(push_python, X_OK) == 0)
                    push_pid = start_child(push_python, argv[2], 1);
            }
        }
    }
    if (push_pid > 0) waitpid((pid_t)push_pid, NULL, 0);
    return stopping ? 0 : 1;
}
