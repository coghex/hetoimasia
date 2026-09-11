# Foundation

Buildable package: `hetoimasia-foundation`.

Owns small independent services. Currently provides an abstract `Logger`,
severity filtering, structured entries, and a borrowed-handle sink. Logging
is synchronous; callers own sink lifetime, exception handling, and concurrency.

Depends on `base` and `text`. It must not import runtime, rendering, scripting,
application, or game modules. Add a helper here only when it has an independent
purpose; this is not a miscellaneous bucket.
