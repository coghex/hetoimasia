# Foundation

Buildable package: `hetoimasia-foundation`.

Owns small independent services. Currently provides an abstract `Logger` with
validated component names, pure filter configuration, immutable scoped context,
injectable clock and thread metadata, and a borrowed-handle sink. Logging is
synchronous; callers own sink lifetime, exception handling, and concurrency.
See [docs/logging.md](../../docs/logging.md) for the logging contract.

Depends on `base`, `text`, `containers`, and `time`. It must not import runtime,
rendering, scripting, application, or game modules. Add a helper here only when
it has an independent purpose; this is not a miscellaneous bucket.
