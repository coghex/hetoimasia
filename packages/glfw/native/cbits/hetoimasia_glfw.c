/*
 * The thread-identity shim. It holds no state, queues nothing, and calls no
 * GLFW function: it answers whether the calling OS thread is the process main
 * thread, which a Haskell ThreadId or a bound thread cannot establish.
 */
#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "hetoimasia_glfw.h"

#if defined(__APPLE__)
#include <pthread.h>

int hetoimasia_glfw_is_process_main_thread(void)
{
    return pthread_main_np() != 0;
}

#elif defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>

/* The initial thread's kernel thread id is the process id. */
int hetoimasia_glfw_is_process_main_thread(void)
{
    return (pid_t) syscall(SYS_gettid) == getpid();
}

#else

/* No supported platform: no thread is accepted as the session owner. */
int hetoimasia_glfw_is_process_main_thread(void)
{
    return 0;
}

#endif
