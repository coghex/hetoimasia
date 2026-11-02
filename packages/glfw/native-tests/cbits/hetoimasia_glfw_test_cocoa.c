/* See hetoimasia_glfw_test_cocoa.h. */
#include "hetoimasia_glfw_test_cocoa.h"

#if defined(__APPLE__)
#include <objc/objc.h>
#include <objc/runtime.h>

static BOOL launch_reported_unfinished(id self, SEL command)
{
    (void) self;
    (void) command;
    return NO;
}

int hetoimasia_glfw_test_force_unfinished_launch(void)
{
    Class application = objc_getClass("NSRunningApplication");
    Method method;
    if (application == Nil)
        return 0;
    method = class_getInstanceMethod(application, sel_registerName("isFinishedLaunching"));
    if (method == NULL)
        return 0;
    method_setImplementation(method, (IMP) launch_reported_unfinished);
    return 1;
}
#else
int hetoimasia_glfw_test_force_unfinished_launch(void)
{
    return 0;
}
#endif
