// WSL 1 gets the priority-inheriting futex wrong, which libdispatch's locks are built on.
// It answers FUTEX_UNLOCK_PI with 1 where Linux answers 0, and libdispatch takes that for
// a broken lock and stops at a trap, which WSL 1 does not step past. And handing the lock
// to 1 of several waiters, it drops the bit that says others still wait: the next unlock
// then wakes nobody, and they sleep for ever.
//
// So kmap brings its own syscall(): libdispatch is linked into the binary and calls it by
// name, and a definition in the binary is the one it binds to. On WSL 1 the 3 PI lock
// operations are done here, as a plain lock with a waiters bit over FUTEX_WAIT and
// FUTEX_WAKE, which WSL 1 gets right. Everything else, and everything on Linux itself,
// goes to the kernel; a futex operation that answers 0 or -1 and came back above 0 is
// given 0, which no Linux kernel ever sends.

#if defined(__linux__) && (defined(__aarch64__) || defined(__x86_64__))

#include <errno.h>
#include <fcntl.h>
#include <linux/futex.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static long kmap_raw_syscall(long number, long a0, long a1, long a2, long a3, long a4, long a5) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = number;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    register long x4 __asm__("x4") = a4;
    register long x5 __asm__("x5") = a5;
    __asm__ volatile("svc #0"
                     : "+r"(x0)
                     : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                     : "memory", "cc");
    return x0;
#else
    register long r10 __asm__("r10") = a3;
    register long r8 __asm__("r8") = a4;
    register long r9 __asm__("r9") = a5;
    long result;
    __asm__ volatile("syscall"
                     : "=a"(result)
                     : "a"(number), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8), "r"(r9)
                     : "rcx", "r11", "memory", "cc");
    return result;
#endif
}

// Whether a futex operation answers only 0 or -1.
static int kmap_futex_answers_zero(long op) {
    switch (op & FUTEX_CMD_MASK) {
    case FUTEX_WAIT:
    case FUTEX_LOCK_PI:
    case FUTEX_UNLOCK_PI:
    case FUTEX_TRYLOCK_PI:
    case FUTEX_WAIT_BITSET:
    case FUTEX_WAIT_REQUEUE_PI:
        return 1;
    default:
        return 0;
    }
}

// Whether this is WSL 1, which names its kernel "4.4.0-<build>-Microsoft"; WSL 2 says
// "microsoft-standard-WSL2", in lower case. Asked once.
static int kmap_on_wsl1(void) {
    static _Atomic int known = -1;
    int answer = atomic_load_explicit(&known, memory_order_acquire);
    if (answer >= 0) return answer;
    answer = 0;
    int fd = open("/proc/sys/kernel/osrelease", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        char release[128] = {0};
        ssize_t got = read(fd, release, sizeof release - 1);
        close(fd);
        if (got > 0 && strstr(release, "-Microsoft") != NULL) answer = 1;
    }
    atomic_store_explicit(&known, answer, memory_order_release);
    return answer;
}

static long kmap_futex(_Atomic uint32_t *word, long op, uint32_t value) {
    return kmap_raw_syscall(SYS_futex, (long)word, op, (long)value, 0, 0, 0);
}

// The PI lock operations over a plain futex. The word holds the owner's thread id and
// FUTEX_WAITERS, as the kernel's own: libdispatch reads the owner from it. A lock taken
// after waiting keeps the waiters bit, so its unlock comes here and wakes the next.
static long kmap_pi_lock(_Atomic uint32_t *word, long private_flag, int trying) {
    uint32_t me = (uint32_t)kmap_raw_syscall(SYS_gettid, 0, 0, 0, 0, 0, 0);
    for (;;) {
        uint32_t seen = atomic_load_explicit(word, memory_order_relaxed);
        if ((seen & FUTEX_TID_MASK) == 0) {
            uint32_t taken = me | (trying ? (seen & FUTEX_WAITERS) : FUTEX_WAITERS);
            if (atomic_compare_exchange_weak_explicit(word, &seen, taken, memory_order_acquire, memory_order_relaxed))
                return 0;
            continue;
        }
        if ((seen & FUTEX_TID_MASK) == me) return -EDEADLK;
        if (trying) return -EAGAIN;
        if (!(seen & FUTEX_WAITERS)) {
            uint32_t marked = seen | FUTEX_WAITERS;
            if (!atomic_compare_exchange_weak_explicit(word, &seen, marked, memory_order_relaxed, memory_order_relaxed))
                continue;
            seen = marked;
        }
        // Returns when woken, or at once where the word has already changed.
        kmap_futex(word, FUTEX_WAIT | private_flag, seen);
    }
}

static long kmap_pi_unlock(_Atomic uint32_t *word, long private_flag) {
    uint32_t me = (uint32_t)kmap_raw_syscall(SYS_gettid, 0, 0, 0, 0, 0, 0);
    if ((atomic_load_explicit(word, memory_order_relaxed) & FUTEX_TID_MASK) != me) return -EPERM;
    atomic_store_explicit(word, 0, memory_order_release);
    kmap_futex(word, FUTEX_WAKE | private_flag, 1);
    return 0;
}

long syscall(long number, ...) {
    // As glibc's own: 6 arguments are read, whatever the call takes.
    va_list arguments;
    va_start(arguments, number);
    long a[6];
    for (int i = 0; i < 6; i++) a[i] = va_arg(arguments, long);
    va_end(arguments);

    long result;
    long command = a[1] & FUTEX_CMD_MASK;
    if (number == SYS_futex && (command == FUTEX_LOCK_PI || command == FUTEX_UNLOCK_PI || command == FUTEX_TRYLOCK_PI)
        && kmap_on_wsl1()) {
        _Atomic uint32_t *word = (_Atomic uint32_t *)a[0];
        long private_flag = a[1] & FUTEX_PRIVATE_FLAG;
        result = command == FUTEX_UNLOCK_PI ? kmap_pi_unlock(word, private_flag)
                                            : kmap_pi_lock(word, private_flag, command == FUTEX_TRYLOCK_PI);
    } else {
        result = kmap_raw_syscall(number, a[0], a[1], a[2], a[3], a[4], a[5]);
    }
    if ((unsigned long)result > (unsigned long)-4096) {
        errno = (int)-result;
        return -1;
    }
    if (number == SYS_futex && result > 0 && kmap_futex_answers_zero(a[1])) return 0;
    return result;
}

#endif
