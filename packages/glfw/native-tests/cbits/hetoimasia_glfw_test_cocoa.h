#ifndef HETOIMASIA_GLFW_TEST_COCOA_H
#define HETOIMASIA_GLFW_TEST_COCOA_H

/* Test-only Cocoa helper for glfw-native-tests (#586).
 *
 * It makes LaunchServices' answer to -[NSRunningApplication isFinishedLaunching]
 * NO for the rest of the process, which is what GLFW 3.4 consults before it
 * enters [NSApp run] (src/cocoa_init.m:633). In production that answer is
 * transiently NO under load; here it is NO on every call, so a re-initialization
 * that does not guard against the redundant launch wait blocks every time rather
 * than occasionally. It is compiled into this test suite alone, never into a
 * library. It changes a method of the process's own NSRunningApplication class
 * and nothing else, and it is never undone: use it only in a private child.
 *
 * Answers 1 when the answer was replaced, and 0 when this platform has no
 * Cocoa. */
int hetoimasia_glfw_test_force_unfinished_launch(void);

#endif
