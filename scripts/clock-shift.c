// Test-only clock shift for time-of-day checks: DD_FAKE_NOW (seconds since 1970) becomes "now" at the first read, and
// time keeps running from there. Interposes the realtime clock reads Foundation, CoreFoundation and SQLite use.
// Loaded with DYLD_INSERT_LIBRARIES into a check binary only; nothing else.
#include <stdlib.h>
#include <time.h>
#include <sys/time.h>
#include <stdint.h>
#include <pthread.h>

static int64_t offset_ns; static pthread_once_t once = PTHREAD_ONCE_INIT;
static void setup(void) {
    const char *s = getenv("DD_FAKE_NOW"); if (!s || !*s) return;
    char *end = NULL; double want = strtod(s, &end);
    if (end == s || *end != 0 || want < 1.0e9) return;   /* not a plain recent Unix time: leave the clock alone */
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    int64_t real = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
    offset_ns = (int64_t)(want * 1e9) - real;
}
static int fake_clock_gettime(clockid_t id, struct timespec *ts) {
    int r = clock_gettime(id, ts); pthread_once(&once, setup);
    if (r == 0 && id == CLOCK_REALTIME && offset_ns) {
        int64_t n = (int64_t)ts->tv_sec * 1000000000LL + ts->tv_nsec + offset_ns;
        ts->tv_sec = n / 1000000000LL; ts->tv_nsec = n % 1000000000LL;
    }
    return r;
}
static uint64_t fake_clock_gettime_nsec_np(clockid_t id) {
    uint64_t n = clock_gettime_nsec_np(id); pthread_once(&once, setup);
    return (id == CLOCK_REALTIME && offset_ns) ? (uint64_t)((int64_t)n + offset_ns) : n;
}
static int fake_gettimeofday(struct timeval *tv, void *tz) {
    int r = gettimeofday(tv, tz); pthread_once(&once, setup);
    if (r == 0 && tv && offset_ns) {
        int64_t us = (int64_t)tv->tv_sec * 1000000LL + tv->tv_usec + offset_ns / 1000;
        tv->tv_sec = us / 1000000LL; tv->tv_usec = (int)(us % 1000000LL);
    }
    return r;
}
static time_t fake_time(time_t *t) {
    struct timespec ts; fake_clock_gettime(CLOCK_REALTIME, &ts);
    if (t) *t = ts.tv_sec; return ts.tv_sec;
}
#define INTERPOSE(n, o) __attribute__((used)) static struct { const void *r; const void *o; } interpose_##o \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&n, (const void *)(unsigned long)&o };
INTERPOSE(fake_clock_gettime, clock_gettime)
INTERPOSE(fake_clock_gettime_nsec_np, clock_gettime_nsec_np)
INTERPOSE(fake_gettimeofday, gettimeofday)
INTERPOSE(fake_time, time)
