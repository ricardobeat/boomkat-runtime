// uSockets exposes millisecond timers. JS timer deadlines need finer re-arms
// so a partially elapsed millisecond does not become another full one.
#include "libusockets.h"
#include "internal/internal.h"
#include <stddef.h>
#include <stdint.h>

void uws_timer_set_ns(struct us_timer_t *timer, void (*cb)(struct us_timer_t *), uint64_t ns) {
    struct us_internal_callback_t *internal = (struct us_internal_callback_t *) timer;
    internal->cb = (void (*)(struct us_internal_callback_t *)) cb;
    if (!ns) ns = 1; // zero disarms timerfd
#ifdef LIBUS_USE_EPOLL
    struct itimerspec spec = { {0, 0}, {(time_t) (ns / 1000000000), (long) (ns % 1000000000)} };
    timerfd_settime(us_poll_fd((struct us_poll_t *) timer), 0, &spec, NULL);
    us_poll_start((struct us_poll_t *) timer, internal->loop, LIBUS_SOCKET_READABLE);
#elif defined(LIBUS_USE_KQUEUE)
    struct kevent event;
    EV_SET(&event, (uintptr_t) internal, EVFILT_TIMER, EV_ADD | EV_ONESHOT,
           NOTE_NSECONDS | NOTE_CRITICAL, (int64_t) ns, internal);
    kevent(internal->loop->fd, &event, 1, NULL, 0, NULL);
#else
#error "Precise timers require the epoll or kqueue backend"
#endif
}
