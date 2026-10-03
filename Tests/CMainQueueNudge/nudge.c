// Linked into the test bundle only, and active only on Linux.
//
// XCTest runs an async test as a task and parks the main thread in its run loop until
// the task reports back. A `@MainActor` test body is a job on the main dispatch queue,
// which that run loop drains when the queue's eventfd is signalled. Now and then the
// signal is lost: the job waits in the queue and the thread sleeps for good. A spare
// signal every 50 ms wakes it; on an empty queue the drain returns at once.

#include "nudge.h"

#if defined(__linux__)
#include <pthread.h>
#include <sys/eventfd.h>
#include <unistd.h>

extern int _dispatch_get_main_queue_port_4CF(void);

static void *nudge(void *unused) {
    (void)unused;
    for (;;) {
        usleep(50000);
        eventfd_write(_dispatch_get_main_queue_port_4CF(), 1);
    }
    return 0;
}

__attribute__((constructor)) static void start(void) {
    pthread_t thread;
    if (pthread_create(&thread, 0, nudge, 0) == 0) pthread_detach(thread);
}
#endif

int kmap_main_queue_nudge_linked(void) { return 1; }
