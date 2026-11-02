# Issue #586: the macOS glfwInit hang, diagnosis and batches

Evidence for [#586](https://github.com/coghex/hetoimasia/issues/586) and [PR #591](https://github.com/coghex/hetoimasia/pull/591), kept here rather than as issue comments because a comment from the owner's login counts as part of the issue's specification. The two sections below are the full text of the two issue comments the solver first posted (diagnosis 6566417079, batches 6569825457), unchanged.

---

# Part 1: diagnosis (issue comment 6566417079)

### Diagnosis (solver, before any prevention)

**Cause (established, with limits below).** GLFW 3.4 `_glfwInitCocoa` (`src/cocoa_init.m:633`) calls `[NSApp run]` whenever `-[NSRunningApplication isFinishedLaunching]` is false. `[NSApp run]` only returns because `applicationDidFinishLaunching:` (`:439`) calls `[NSApp stop:nil]`, and `NSApplication` sends that notification **once per process**. So on a *re-initialisation* (a `glfwInit` after an earlier session in the same process has already finished launching) a **transiently false** `isFinishedLaunching` read sends GLFW into a `[NSApp run]` that can never be stopped. The flag is LaunchServices' view of the process, not NSApplication's, and it is read once, at that instant.

**Evidence** (scratch C/ObjC probe, the pinned `~/.cache/hetoimasia/native/glfw` static GLFW 3.4, same two init hints the product sets; machine: the owner's Mac, macOS 26.7.1 (Darwin 25.6.0) arm64; no windows are created, only `glfwInit`/`glfwTerminate` loops):

1. *The mechanism is deterministic.* `glfwInit(); glfwTerminate();` then a bare `[NSApp run]`: before the first init `isFinishedLaunching=false`, after it `true` (stable over 1 s of polling, and after terminate); the second `[NSApp run]` blocks (watcher at 8 s: `isFinishedLaunching=true`, `NSApp.isRunning=1`). Nothing ever calls `stop:` again.
2. *The flag is stable in a quiet process.* 3000 init/terminate cycles: the flag was true before **all 2999** re-initialisations; worst `glfwInit` 0.061 s (the first), typical 0.4 ms.
3. *It goes transiently false under LaunchServices churn.* The same loop while three other processes repeatedly launch and exit a GLFW app (what the harness's windowed product children do): run A, 649 cycles: the flag read false before 4 re-initialisations (iterations 300, 359, 446, 550) and **`glfwInit` of iteration 649 never returned**; run B, 231 cycles: 3 false reads, then **`glfwInit` of iteration 231 never returned**. The false reads that returned were reads of mine that sat microseconds before GLFW's own read; by the time the watcher looked at a hung process the flag was true again, as the transient predicts.
4. *The hung stack is the issue's.* `sample` of the hung probe (excerpt below): `glfwInit` → `_glfwInitCocoa` → `-[NSApplication run]` → `nextEventMatchingMask:untilDate:inMode:dequeue:` → `mach_msg2_trap`, only other threads idle.

**What this does not establish.** (i) The flag was never read false *inside* `run-native-tests`: `run.sh` strips `DYLD_INSERT_LIBRARIES`, so the real harness could not be instrumented without changing it; that its windowed product children are the churn is inferred from the match of stack, in-process re-initialisation (`the command's production composition` examples run complete sessions on the main thread; the single-`glfwInit` runs and `glfw-native-tests` did not hang), and the churn reproduction. (ii) Why LaunchServices answers false at those instants is not established (it is a private service of the OS). (iii) The rates above (about 1 hang in 230 to 650 re-initialisations under artificial churn) are not the harness's per-run rate and are not claimed to be.

**Consequence for the fix.** A watchdog timeout proves only that Cocoa initialisation exceeded its bound; it is not itself proof of this cause. The prevention has to stop `[NSApp run]` being entered (or make it return) when the application already finished launching in this process, before `glfwInit`, without touching GLFW.

<details><summary>hung-process sample excerpt</summary>

```
Idle exit:                  untracked
----

Call graph:
    2411 Thread_706865576   DispatchQueue_1: com.apple.main-thread  (serial)
    + 2411 start  (in dyld) + 6992  [0x1809bc4e4]
    +   2411 main  (in reinit) + 420  [0x10460902c]
    +     2411 glfwInit  (in reinit) + 180  [0x10460abc0]
    +       2411 _glfwInitCocoa  (in reinit) + 1112  [0x104615694]
    +         2411 -[NSApplication run]  (in AppKit) + 368  [0x18527213c]
    +           2411 -[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]  (in AppKit) + 72  [0x185e14678]
    +             2411 -[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]  (in AppKit) + 688  [0x185e1496c]
    +               2411 _DPSNextEvent  (in AppKit) + 576  [0x18527f084]
    +                 2411 _DPSBlockUntilNextEventMatchingListInMode  (in AppKit) + 228  [0x18592b3d0]
    +                   2411 _BlockUntilNextEventMatchingListInMode  (in HIToolbox) + 48  [0x18ddc414c]
    +                     2411 ReceiveNextEventCommon  (in HIToolbox) + 488  [0x18dc3a8bc]
    +                       2411 RunCurrentEventLoopInMode  (in HIToolbox) + 320  [0x18dc37560]
    +                         2411 _CFRunLoopRunSpecificWithOptions  (in CoreFoundation) + 532  [0x180f16508]
    +                           2411 __CFRunLoopRun  (in CoreFoundation) + 1188  [0x180e43a44]
    +                             2411 __CFRunLoopServiceMachPort  (in CoreFoundation) + 160  [0x180e45158]
    +                               2411 mach_msg  (in libsystem_kernel.dylib) + 24  [0x180d43fc0]
    +                                 2411 mach_msg_overwrite  (in libsystem_kernel.dylib) + 480  [0x180d4c9c0]
    +                                   2411 mach_msg2_internal  (in libsystem_kernel.dylib) + 76  [0x180d565a4]
    +                                     2411 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x180d43c34]
    2411 Thread_706865655
    + 2411 thread_start  (in libsystem_pthread.dylib) + 8  [0x180d82c1c]
    +   2411 _pthread_start  (in libsystem_pthread.dylib) + 136  [0x180d87c58]
    +     2411 watcher  (in reinit) + 316  [0x10460944c]
    +       2411 sleep  (in libsystem_c.dylib) + 52  [0x180c2be24]
    +         2411 nanosleep  (in libsystem_c.dylib) + 220  [0x180c22cc0]
    +           2411 __semwait_signal  (in libsystem_kernel.dylib) + 8  [0x180d47308]
    2411 Thread_706865713: com.apple.NSEventThread
      2411 thread_start  (in libsystem_pthread.dylib) + 8  [0x180d82c1c]
        2411 _pthread_start  (in libsystem_pthread.dylib) + 136  [0x180d87c58]
          2411 _NSEventThread  (in AppKit) + 184  [0x1853a0cac]
            2411 _CFRunLoopRunSpecificWithOptions  (in CoreFoundation) + 532  [0x180f16508]
              2411 __CFRunLoopRun  (in CoreFoundation) + 1188  [0x180e43a44]
                2411 __CFRunLoopServiceMachPort  (in CoreFoundation) + 160  [0x180e45158]
                  2411 mach_msg  (in libsystem_kernel.dylib) + 24  [0x180d43fc0]
                    2411 mach_msg_overwrite  (in libsystem_kernel.dylib) + 480  [0x180d4c9c0]
                      2411 mach_msg2_internal  (in libsystem_kernel.dylib) + 76  [0x180d565a4]
                        2411 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x180d43c34]

Total number in stack (recursive counted multiple, when >=5):

Sort by top of stack, same collapsed (when >= 5):
        mach_msg2_trap  (in libsystem_kernel.dylib)        4822
```
</details>

<details><summary>probe source (scratch, not committed)</summary>

```objc
// Diagnostic instrument for #586 (scratch; not part of the repository).
// Mode "loop N": N x (glfwInit; glfwTerminate) with the same init hints the
// product sets (Cocoa platform, chdir-resources off), recording the
// LaunchServices launch flag before each init and the duration of each init.
// A watcher thread reports the state if one init exceeds the bound.
// Mode "rerun": glfwInit; glfwTerminate; then a bare [NSApp run] under a
// watcher, to show what a second run does after launch already finished.
#import <Cocoa/Cocoa.h>
#include <GLFW/glfw3.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

static volatile int g_phase = 0;      // 0 idle, 1 in glfwInit, 2 in bare run
static volatile int g_iter = 0;
static volatile double g_start = 0;
static double g_bound = 8.0;

static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static const char* finished(void) {
    return [[NSRunningApplication currentApplication] isFinishedLaunching] ? "true" : "false";
}

static void* watcher(void* arg) {
    (void)arg;
    for (;;) {
        usleep(100000);
        if (g_phase && now() - g_start > g_bound) {
            printf("HANG iter=%d phase=%d after=%.1fs; from watcher thread: "
                   "isFinishedLaunching=%s NSApp.isRunning=%d\n",
                   g_iter, g_phase, now() - g_start, finished(),
                   (int)[NSApp isRunning]);
            fflush(stdout);
            if (getenv("HANG_HOLD")) sleep(atoi(getenv("HANG_HOLD")));
            _exit(3);
        }
    }
    return NULL;
}

int main(int argc, char** argv) {
    int n = argc > 2 ? atoi(argv[2]) : 20;
    int rerun = argc > 1 && !strcmp(argv[1], "rerun");
    pthread_t th;
    pthread_create(&th, NULL, watcher, NULL);
    glfwInitHint(GLFW_PLATFORM, GLFW_PLATFORM_COCOA);
    glfwInitHint(GLFW_COCOA_CHDIR_RESOURCES, GLFW_FALSE);
    if (rerun) {
        printf("before first init: finished=%s\n", finished());
        g_start = now(); g_phase = 1; g_iter = 1;
        if (!glfwInit()) return 2;
        g_phase = 0;
        printf("after first init: finished=%s\n", finished());
        for (int i = 0; i < 5; i++) { printf("  poll %d finished=%s\n", i, finished()); usleep(200000); }
        glfwTerminate();
        printf("after terminate: finished=%s\n", finished());
        printf("bare [NSApp run] with an AppDelegate not notified...\n"); fflush(stdout);
        g_start = now(); g_phase = 2; g_iter = 2;
        [NSApp run];
        g_phase = 0;
        printf("bare run returned\n");
        return 0;
    }
    int falseBefore = 0;
    double worst = 0;
    for (int i = 1; i <= n; i++) {
        const char* f = finished();
        if (i > 1 && f[0] == 'f') falseBefore++;
        g_iter = i; g_start = now(); g_phase = 1;
        if (!glfwInit()) { printf("glfwInit failed at %d\n", i); return 2; }
        double d = now() - g_start; g_phase = 0;
        if (d > worst) worst = d;
        printf("iter %d before=%s init=%.4fs\n", i, f, d);
        fflush(stdout);
        glfwTerminate();
    }
    printf("DONE n=%d reinit-with-false-flag=%d worst=%.4fs\n", n, falseBefore, worst);
    return 0;
}
```
</details>

---

# Part 2: before and after batches (issue comment 6569825457)

### Before and after batches (solver, PR #591)

Same machine (Apple M3 Max, macOS 26.7.1), same probe (`hetoimasia:run-native-repeat-probe`, `run-native-repeat/`), one complete `run-native-tests` profile at a time, 45 s bound per run.

#### Unfixed head 868b78e5 (source digest bfea44470fded54aa0c029bdb924aaba61f3394c72351337241a3fefe87842dd), until the first hang

```
# Repeated complete run-native-tests profile (#586)

- revision: 868b78e55765bb1d2d91ad8c29f23c7c364dde52
- checkout: /Users/vincentcoghlan/worktrees/coghex/hetoimasia/issue-586-unfixed
- output: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/d4a7e2dc-6bf7-4d05-beee-8da8be50bdd9/scratchpad/batch-before
- mode: until the first hang (unfixed revision)
- N: 150 planned, 6 attempted
- confidence: N = 150 independent runs at an unchanged 5% per-run failure probability would have shown at least one failure with probability 99.95% (1 - 0.95^N); this is detection power, not proof that the program cannot hang
- passed: 5, hung: 1, failed: 0
- a run the initialization deadline ended counts as a hang, not a pass

### Hangs
- run 6: no end within 45 seconds; samples: ["77786: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/d4a7e2dc-6bf7-4d05-beee-8da8be50bdd9/scratchpad/batch-before/run-006.77786.sample.txt"]; everything it started stopped: True
```

Sample of the hung run-native-tests (main thread):

```
    3219 Thread_708185518   DispatchQueue_1: com.apple.main-thread  (serial)
    +         3219 glfwInit  (in run-native-tests) + 180  [0x1049d1480]
    +           3219 _glfwInitCocoa  (in run-native-tests) + 1112  [0x1049d8f48]
    +             3219 -[NSApplication run]  (in AppKit) + 368  [0x18527213c]
    +               3219 -[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]  (in AppKit) + 72  [0x185e14678]
    +                                         3219 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x180d43c34]
    +                   3219 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x180d43c34]
```

The hung run's output ends in the `Lua native milestone` group, as the issue describes; the probe stopped the process by PID after the sample and confirmed nothing it started was left.

#### Fixed head 1b504dc4 (source digest 55a098616a5d8575f185f34832ff29391c62b415e7e185c900ce655af5b9cbd2), N = 59 chosen before the run

```
# Repeated complete run-native-tests profile (#586)

- revision: 1b504dc4a8cbc989af165d4f846460b40ef6e390
- checkout: /Users/vincentcoghlan/worktrees/coghex/hetoimasia/issue-586-glfwinit-bounded
- output: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/d4a7e2dc-6bf7-4d05-beee-8da8be50bdd9/scratchpad/batch-after
- mode: N consecutive runs (fixed revision)
- N: 59 planned, 59 attempted
- confidence: N = 59 independent runs at an unchanged 5% per-run failure probability would have shown at least one failure with probability 95.15% (1 - 0.95^N); this is detection power, not proof that the program cannot hang
- passed: 58, hung: 0, failed: 1
- a run the initialization deadline ended counts as a hang, not a pass

### Hangs
```

**58 passed, 0 hung, 1 failed.** The failure (run 27) is a different example, `Lua native milestone answers an INJECTED clean refusal of one window's standing…` (`run-native-test/Test/Run/Native/Milestone.hs:545`): it expected the instance failure text to contain `window_error` and got the injected Lua error as a boundary fault (`ErrorFault (BoundaryFailed … injected clean refusal …)`), after the windows existed. It is not a `glfwInit` event and is recorded, not rerun away. 53 examples passed in that run.
