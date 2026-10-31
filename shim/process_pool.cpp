// One native acceptor passes sockets to independently spawned runtimes. Only
// connection setup crosses IPC; HTTP/WebSocket traffic stays in the worker.
#include "libusockets.h"
extern "C" {
#include "internal/internal.h"
}
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <string>
#include <thread>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>
#ifdef __APPLE__
#include <crt_externs.h>
#else
extern char **environ;
#endif

namespace {
constexpr const char *channel_env = "BKR_HTTP_DISPATCH_FD";
struct Message {
    char type; // L: listener request, B: bound port, A: accepted fd, S: stopped
    unsigned char ip_length;
    unsigned short port;
    char host[256]; // host for L, raw peer IP for A
};
using Adopt = void (*)(void *, int, const char *, int);
struct Receiver {
    void *app;
    Adopt adopt;
    us_loop_t *loop;
    us_poll_t *poll;
    int fd;
};
bool worker_mode = false;
int worker_fd = -1;
std::thread::id worker_thread;
pid_t worker_supervisor = -1;
Receiver *receiver = nullptr; // only one HTTP listener per worker process
volatile sig_atomic_t interrupted = 0;
void on_signal(int signal) { interrupted = signal; }

bool fd_flags(int fd, bool nonblock) {
    return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 &&
        (!nonblock || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0);
}
ssize_t send_message(int channel, const Message &message, int descriptor = -1) {
    iovec io{const_cast<Message *>(&message), sizeof(message)};
    alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))]{};
    msghdr msg{};
    msg.msg_iov = &io; msg.msg_iovlen = 1;
    if (descriptor >= 0) {
        msg.msg_control = control; msg.msg_controllen = sizeof(control);
        cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        std::memcpy(CMSG_DATA(c), &descriptor, sizeof(descriptor));
    }
    ssize_t sent;
    do { sent = sendmsg(channel, &msg, 0); } while (sent < 0 && errno == EINTR);
    return sent;
}
// Always close extra/truncated ancillary descriptors, including malformed
// messages. The sender owns its copy until sendmsg succeeds.
ssize_t receive_message(int channel, Message &message, int &descriptor) {
    descriptor = -1;
    iovec io{&message, sizeof(message)};
    alignas(cmsghdr) char control[CMSG_SPACE(8 * sizeof(int))]{};
    msghdr msg{};
    msg.msg_iov = &io; msg.msg_iovlen = 1;
    msg.msg_control = control; msg.msg_controllen = sizeof(control);
    ssize_t count;
    do { count = recvmsg(channel, &msg, 0); } while (count < 0 && errno == EINTR);
    if (count < 0) return count;
    unsigned delivered = 0;
    for (cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS || c->cmsg_len < CMSG_LEN(0)) continue;
        size_t n = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t i = 0; i < n; i++) {
            int fd;
            std::memcpy(&fd, (char *)CMSG_DATA(c) + i * sizeof(int), sizeof(fd));
            if (++delivered == 1) descriptor = fd;
            else close(fd);
        }
    }
    if (count != sizeof(message) || (msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) || delivered > 1) {
        if (descriptor >= 0) close(descriptor);
        descriptor = -1;
        errno = EPROTO;
        return -1;
    }
    return count;
}
void read_sockets(us_internal_callback_t *callback) {
    auto *r = *(Receiver **)(callback + 1);
    // Bound each batch so an accept storm cannot starve existing connections.
    for (unsigned i = 0; i < 64; i++) {
        Message message{};
        int fd;
        if (receive_message(r->fd, message, fd) < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            std::fprintf(stderr, "error: HTTP process channel failed: %s\n", std::strerror(errno));
            _exit(1);
        }
        if (message.type != 'A' || fd < 0 || (message.ip_length != 4 && message.ip_length != 16)) {
            if (fd >= 0) close(fd);
            std::fprintf(stderr, "error: invalid HTTP process handoff\n");
            _exit(1);
        }
        if (!fd_flags(fd, true)) { close(fd); continue; }
        r->adopt(r->app, fd, message.host, message.ip_length);
    }
}
struct Worker { pid_t pid = -1; int channel = -1; bool ready = false; bool active = false; };
char **environment() {
#ifdef __APPLE__
    return *_NSGetEnviron();
#else
    return environ;
#endif
}
void terminate_workers(std::vector<Worker> &workers) {
    for (auto &w : workers) {
        if (w.channel >= 0) { close(w.channel); w.channel = -1; }
        if (w.pid > 0) kill(w.pid, SIGTERM);
    }
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    for (;;) {
        bool alive = false;
        for (auto &w : workers) if (w.pid > 0) {
            int status;
            pid_t result = waitpid(w.pid, &status, WNOHANG);
            if (result == w.pid || (result < 0 && errno == ECHILD)) w.pid = -1;
            else alive = true;
        }
        if (!alive) return;
        if (std::chrono::steady_clock::now() >= deadline) break;
        poll(nullptr, 0, 10);
    }
    for (auto &w : workers) if (w.pid > 0) {
        kill(w.pid, SIGKILL);
        while (waitpid(w.pid, nullptr, 0) < 0 && errno == EINTR) {}
        w.pid = -1;
    }
}
}

extern "C" {
// -1 means continue booting this runtime; >=0 is the supervisor's exit code.
int bkr_process_supervise(char **argv, int count) {
    if (const char *inherited = std::getenv(channel_env)) {
        char *end;
        long fd = std::strtol(inherited, &end, 10);
        int type = 0; socklen_t size = sizeof(type);
        if (*inherited == 0 || *end || fd < 3 || fd > 0x7fffffff ||
            getsockopt((int)fd, SOL_SOCKET, SO_TYPE, &type, &size) || type != SOCK_DGRAM) {
            std::fprintf(stderr, "error: invalid HTTP process channel\n");
            return 1;
        }
        worker_mode = true; worker_fd = (int)fd;
        worker_thread = std::this_thread::get_id(); worker_supervisor = getppid();
        unsetenv(channel_env);
        if (!fd_flags(worker_fd, false)) return 1;
        // Keep parent-death detection independent of the VM/event loop, so a
        // worker running synchronous JS cannot become an orphan CPU consumer.
        try {
            std::thread([parent = worker_supervisor]() {
                for (;;) {
                    usleep(250000);
                    if (getppid() != parent) _exit(1);
                }
            }).detach();
        } catch (const std::exception &error) {
            std::fprintf(stderr, "error: HTTP process liveness monitor: %s\n", error.what());
            return 1;
        }
        return -1;
    }
    if (!count) return -1;
    std::vector<Worker> workers;
    int listener = -1, pending = -1, result = 1;
    Message accepted{};
    struct sigaction action{}, old_int{}, old_term{};
    action.sa_handler = on_signal; sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, &old_int); sigaction(SIGTERM, &action, &old_term);
    interrupted = 0;
    auto cleanup = [&]() {
        if (pending >= 0) close(pending);
        if (listener >= 0) close(listener);
        terminate_workers(workers);
        sigaction(SIGINT, &old_int, nullptr); sigaction(SIGTERM, &old_term, nullptr);
        return interrupted ? 128 + (int)interrupted : result;
    };
    std::vector<char *> env;
    for (char **entry = environment(); *entry; entry++) env.push_back(*entry);
    std::string setting = std::string(channel_env) + "=3";
    env.push_back(setting.data()); env.push_back(nullptr);
    for (int i = 0; i < count && !interrupted; i++) {
        int pair[2];
        if (socketpair(AF_UNIX, SOCK_DGRAM, 0, pair)) { std::perror("HTTP process socketpair"); return cleanup(); }
        if (!fd_flags(pair[0], true) || !fd_flags(pair[1], false)) {
            close(pair[0]); close(pair[1]); return cleanup();
        }
#ifdef SO_NOSIGPIPE
        int one = 1;
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        posix_spawn_file_actions_t actions;
        int error = posix_spawn_file_actions_init(&actions);
        if (error) { close(pair[0]); close(pair[1]); return cleanup(); }
        // Other channels carry CLOEXEC. Close this parent end before dup2,
        // since it can be descriptor 3 in the first worker.
        error = posix_spawn_file_actions_addclose(&actions, pair[0]);
        if (!error) error = posix_spawn_file_actions_adddup2(&actions, pair[1], 3);
        pid_t pid;
        if (!error) error = posix_spawnp(&pid, argv[0], &actions, nullptr, argv, env.data());
        posix_spawn_file_actions_destroy(&actions);
        close(pair[1]);
        if (error) { close(pair[0]); std::fprintf(stderr, "error: spawn HTTP process: %s\n", std::strerror(error)); return cleanup(); }
        workers.push_back({pid, pair[0], false, false});
    }
    unsigned ready = 0;
    size_t next = 0;
    bool started = false;
    std::string host;
    unsigned short requested_port = 0, bound_port = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (!interrupted) {
        unsigned alive = 0, active = 0;
        for (auto &w : workers) {
            if (w.pid <= 0) continue;
            int status;
            pid_t ended = waitpid(w.pid, &status, WNOHANG);
            if (ended == w.pid) {
                w.pid = -1; w.active = false;
                if (w.channel >= 0) { close(w.channel); w.channel = -1; }
                if (!started || !WIFEXITED(status) || WEXITSTATUS(status)) {
                    std::fprintf(stderr, "error: HTTP worker exited unexpectedly\n");
                    return cleanup();
                }
                continue;
            }
            alive++; active += w.active;
        }
        if (!alive) { result = started ? 0 : 1; return cleanup(); }
        if (!started && std::chrono::steady_clock::now() >= deadline) {
            std::fprintf(stderr, "error: HTTP processes did not listen within 30 seconds\n"); return cleanup();
        }
        if (started && !active) {
            if (listener >= 0) { close(listener); listener = -1; }
            if (pending >= 0) { close(pending); pending = -1; }
        }
        // Retain at most one unsent socket. If a worker's IPC queue fills,
        // try another worker; if all fill, pause accept until one can receive.
        auto handoff = [&]() {
            for (size_t attempt = 0; attempt < workers.size(); attempt++) {
                auto &w = workers[next++ % workers.size()];
                if (!w.active) continue;
                if (send_message(w.channel, accepted, pending) == sizeof(Message)) {
                    close(pending); pending = -1; return true;
                }
                if (errno != EAGAIN && errno != EWOULDBLOCK && errno != ENOBUFS) {
                    std::fprintf(stderr, "error: HTTP socket handoff: %s\n", std::strerror(errno));
                    w.active = false;
                }
            }
            return false;
        };
        if (pending >= 0) handoff();
        std::vector<pollfd> polls;
        polls.push_back({listener, (short)(started && pending < 0 ? POLLIN : 0), 0});
        for (auto &w : workers) polls.push_back({w.channel, (short)(POLLIN | (pending >= 0 && w.active ? POLLOUT : 0)), 0});
        int polled = poll(polls.data(), polls.size(), 100);
        if (polled < 0) { if (errno == EINTR) continue; std::perror("HTTP process poll"); return cleanup(); }
        for (size_t i = 0; i < workers.size(); i++) if (polls[i + 1].revents & POLLIN) {
            auto &w = workers[i];
            Message message{}; int extra;
            ssize_t n = receive_message(w.channel, message, extra);
            if (extra >= 0) close(extra);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
                std::fprintf(stderr, "error: HTTP process control channel: %s\n", std::strerror(errno));
                return cleanup();
            }
            if (message.type == 'S') {
                w.active = false;
                close(w.channel); w.channel = -1;
                continue;
            }
            if (message.type != 'L' || w.ready || !std::memchr(message.host, 0, sizeof(message.host))) return cleanup();
            if (!ready) {
                host = message.host; requested_port = message.port;
                listener = bsd_create_listen_socket(host.c_str(), requested_port, LIBUS_LISTEN_EXCLUSIVE_PORT);
                if (listener < 0) { std::fprintf(stderr, "error: HTTP process listener %s:%u: %s\n", host.c_str(), requested_port, std::strerror(errno)); return cleanup(); }
                if (!fd_flags(listener, true)) return cleanup();
                bsd_addr_t address{};
                if (bsd_local_addr(listener, &address)) return cleanup();
                bound_port = bsd_addr_get_port(&address);
            } else if (host != message.host || requested_port != message.port) {
                std::fprintf(stderr, "error: HTTP process listener configurations differ\n"); return cleanup();
            }
            Message reply{}; reply.type = 'B'; reply.port = bound_port;
            if (send_message(w.channel, reply) != sizeof(reply)) return cleanup();
            w.ready = w.active = true; ready++;
            if (ready == (unsigned)count) {
                started = true;
                std::fprintf(stdout, "HTTP processes ready: %u (port %u)\n", ready, bound_port); std::fflush(stdout);
            }
        }
        if (started && pending < 0 && listener >= 0 && (polls[0].revents & POLLIN)) {
            for (unsigned batch = 0; batch < 64; batch++) {
                bsd_addr_t address{};
                pending = bsd_accept_socket(listener, &address);
                if (pending < 0) {
                    if (errno == EINTR || errno == ECONNABORTED) continue;
                    if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                    std::perror("HTTP process accept"); return cleanup();
                }
                if (!fd_flags(pending, true)) { close(pending); pending = -1; continue; }
                accepted = {}; accepted.type = 'A';
                accepted.ip_length = bsd_addr_get_ip_length(&address);
                std::memcpy(accepted.host, bsd_addr_get_ip(&address), accepted.ip_length);
                if (!handoff()) break;
            }
        }
    }
    return cleanup();
}

// -2 means ordinary in-process listening, -1 means a worker setup error.
int bkr_process_listen(void *app, const char *host, int port, void *loop, Adopt adopt) {
    if (!worker_mode) return -2;
    if (std::this_thread::get_id() != worker_thread || receiver || worker_fd < 0 || std::strlen(host) >= sizeof(Message::host)) return -1;
    Message request{}; request.type = 'L'; request.port = (unsigned short)port;
    std::strcpy(request.host, host);
    if (send_message(worker_fd, request) != sizeof(request)) return -1;
    pollfd wait{worker_fd, POLLIN, 0};
    int ready = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (std::chrono::steady_clock::now() < deadline && getppid() == worker_supervisor) {
        ready = poll(&wait, 1, 100);
        if (ready > 0 || (ready < 0 && errno != EINTR)) break;
    }
    if (ready <= 0) return -1;
    Message reply{}; int extra;
    ssize_t n = receive_message(worker_fd, reply, extra);
    if (extra >= 0) close(extra);
    if (n != sizeof(reply) || reply.type != 'B' || !fd_flags(worker_fd, true)) return -1;
    auto *r = new Receiver{app, adopt, (us_loop_t *)loop, nullptr, worker_fd};
    r->poll = us_create_poll(r->loop, 0, sizeof(us_internal_callback_t) - sizeof(us_poll_t) + sizeof(Receiver *));
    if (!r->poll) { delete r; return -1; }
    auto *callback = (us_internal_callback_t *)r->poll;
    callback->loop = r->loop; callback->cb_expects_the_loop = 0; callback->leave_poll_ready = 1; callback->cb = read_sockets;
    *(Receiver **)(callback + 1) = r;
    us_poll_init(r->poll, worker_fd, POLL_TYPE_CALLBACK);
    us_poll_start(r->poll, r->loop, LIBUS_SOCKET_READABLE);
    receiver = r;
    return reply.port;
}
void bkr_process_stop(void *app) {
    if (!worker_mode || std::this_thread::get_id() != worker_thread) return;
    auto *r = receiver;
    if (!r || r->app != app) return;
    Message message{}; message.type = 'S';
    (void)send_message(r->fd, message);
    us_poll_stop(r->poll, r->loop); us_poll_free(r->poll, r->loop);
    close(r->fd);
    worker_fd = -1; receiver = nullptr;
    delete r;
}
}
