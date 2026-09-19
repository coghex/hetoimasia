/*
** The Linux confinement candidate, and the native operations that test it.
**
** This is a feasibility probe for LUA-14, not a shipped sandbox. Nothing in
** this repository links it outside the private `lua-confine-child` executable
** and the `linux-confinement-probe` test suite, and neither of those admits a
** mod source through any public path.
**
** Two halves live here because they are two halves of one question.
**
** The parent half (`hetoimasia_confine_spawn`) launches a child inside a
** candidate profile. It forks -- which is what makes the pre-exec child
** single-threaded, and therefore what makes `unshare(CLONE_NEWUSER)` legal at
** all, since that call is refused to a process with more than one thread and
** the threaded RTS always has several -- then installs the namespace, private
** root, and resource layers in that single-threaded child and execs the probe.
** Every layer that fails reports `{layer, errno}` back over a close-on-exec
** pipe, so the parent learns *which* prerequisite was missing rather than only
** that something was. A successful exec closes that pipe with nothing written,
** which is the success signal: there is no path on which the parent sees a
** started child and no report.
**
** The child half (`hetoimasia_confine_seal`) installs the layers that cannot
** survive an exec boundary or that must cover the running runtime: no-new-privs
** and the seccomp filter, the latter with SECCOMP_FILTER_FLAG_TSYNC so it
** applies to every thread the RTS has already started, and by inheritance to
** every thread it starts afterwards. The child calls it before it constructs a
** Lua VM, which is what "installed before any mod source is loaded" means here.
**
** The probes (`hetoimasia_probe_*`) are the forbidden operations attempted from
** native helper code, as P-13 requires: an absent `io` global is not evidence
** that the operating system refused anything. Each answers the `errno` it
** observed, or 0 when the operation *succeeded* -- which is how the same
** function serves as a control. A probe is only evidence about confinement when
** its control shows the same operation working where confinement is absent.
*/
#ifndef HETOIMASIA_CONFINE_H
#define HETOIMASIA_CONFINE_H

#include <stddef.h>
#include <sys/types.h>

/* The layers of the candidate profile, as a bitmask.
**
** A report names layers rather than describing them, so the parent, the child,
** and the verdict document all quote the same identities. */
#define HETOIMASIA_LAYER_NONE 0x0000
#define HETOIMASIA_LAYER_NO_NEW_PRIVS 0x0001
#define HETOIMASIA_LAYER_USER_NS 0x0002
#define HETOIMASIA_LAYER_MOUNT_NS 0x0004
#define HETOIMASIA_LAYER_NET_NS 0x0008
#define HETOIMASIA_LAYER_IPC_NS 0x0010
#define HETOIMASIA_LAYER_UTS_NS 0x0020
#define HETOIMASIA_LAYER_PRIVATE_ROOT 0x0040
#define HETOIMASIA_LAYER_RESOURCE_LIMITS 0x0080
#define HETOIMASIA_LAYER_MEMORY_LIMIT 0x0100
#define HETOIMASIA_LAYER_SECCOMP 0x0200
#define HETOIMASIA_LAYER_EXEC 0x0400

/* Where the private IPC endpoint the child inherits always lands.
**
** A fixed descriptor rather than an argument: the child has no ambient way to
** discover an inherited endpoint, and a parent that passed the number in its
** argv would be handing untrusted code a number it could have guessed anyway.
** Nothing else is inherited -- every other descriptor is closed before exec. */
#define HETOIMASIA_CONFINE_IPC_FD 3

/* Launch `program` inside the candidate profile.
**
** `root_directory` is a host path that becomes the child's private root: a
** fresh tmpfs is mounted over it, the runtime library directories are bound
** into it read-only, `program` is bound in at /probe, and /work is the child's
** private disposable working area. Nothing else is reachable from the child
** afterwards, which is what makes a host path a valid "outside the view"
** sentinel.
**
** `memory_limit_bytes` installs the whole-process address-space ceiling, or 0
** to install none. `ipc_socket` is the parent's end's peer, which becomes the
** child's HETOIMASIA_CONFINE_IPC_FD. `input` becomes its standard input and
** `output` both its standard output and its standard error; the child inherits
** these four descriptors and no others, because an inherited descriptor is an
** ambient capability and P-13 grants none.
**
** Answers the child's pid, or -1. On -1 `failed_layer` and `failed_errno`
** carry the typed refusal: which prerequisite was missing and what the kernel
** said. A refusal is terminal -- no unconfined child is ever left running, and
** the function reaps the pre-exec child itself before returning. */
pid_t hetoimasia_confine_spawn(
  const char *program,
  char *const argv[],
  char *const envp[],
  const char *root_directory,
  long memory_limit_bytes,
  int ipc_socket,
  int input,
  int output,
  int *failed_layer,
  int *failed_errno);

/* Install the in-process layers, from inside the child.
**
** `allow_executable_file_mappings` keeps the rule that denies file-backed
** PROT_EXEC mappings out of the filter. It exists so the verdict can report
** what that one rule costs and what it buys, not so a run can quietly drop it:
** the parent passes it explicitly and the suite records which way it went.
**
** Answers 0 with `*installed_layers` describing what went in, or -1 with
** `*failed_errno` set and nothing installed beyond what `*installed_layers`
** already names. */
int hetoimasia_confine_seal(
  int allow_executable_file_mappings, int *installed_layers, int *failed_errno);

/* Read one byte of `path`. Answers 0 when the read succeeded, else `errno`. */
int hetoimasia_probe_read_file(const char *path);

/* Create a socket in `domain`. Answers 0 when it was created, else `errno`.
**
** The created descriptor is closed again: this asks whether the operation is
** permitted, and holding the result open would be a second question. */
int hetoimasia_probe_open_socket(int domain);

/* Bind an abstract AF_UNIX name, keeping it bound for the process's lifetime.
**
** Abstract names are scoped to the network namespace, so a bound name is
** exactly the endpoint a peer in the same namespace could reach and a peer in
** another could not. Answers 0, else `errno`. */
int hetoimasia_probe_bind_abstract(const char *name);

/* Connect to an abstract AF_UNIX name. Answers 0 when connected, else `errno`. */
int hetoimasia_probe_connect_abstract(const char *name);

/* Execute `program` in a child of this process and wait for it.
**
** The fork is the point: a denial has to be observed where the forbidden
** operation happens, and `execve` replaces the caller on success. Answers 0
** when the program ran, else the `errno` the exec reported. */
int hetoimasia_probe_execute(const char *program);

/* Load a native module. Answers 0 when it loaded, else `errno` if one was set,
** else -1 with the loader's message copied into `message`. */
int hetoimasia_probe_load_module(const char *path, char *message, size_t length);

/* Map a file-backed page with PROT_EXEC, and the same page without it.
**
** Together these are the control and the probe for the one seccomp rule whose
** cost is worth reporting separately: `*without_exec` must be 0 for
** `*with_exec` to be evidence about PROT_EXEC rather than about the file.
** Answers 0 when both attempts were made, -1 when the fixture file could not
** be created at all. */
int hetoimasia_probe_executable_mapping(
  const char *path, int *with_exec, int *without_exec);

/* Allocate `bytes` in one native block and touch every page of it.
**
** Touching is what makes the block memory rather than address space. Answers 0
** when the allocation succeeded, else `errno`. */
int hetoimasia_probe_allocate(size_t bytes);

/* Install a handler for SIGTERM that only records it.
**
** The execution-limit experiment needs the parent's escalation to be the thing
** that ends the child, not a default action that happens to be terminal. A
** child whose only thread is inside Lua cannot act on a cooperative shutdown
** request anyway -- LUA-1 established that -- so holding the signal here makes
** the experiment exercise the path a real stuck mod would force. Answers 0, or
** -1 with `errno` set. */
int hetoimasia_confine_hold_term(void);

/* This process's address-space ceiling in bytes, or 0 when it is unlimited. */
unsigned long hetoimasia_confine_address_space_limit(void);

/* Whether this process holds CAP_SYS_ADMIN in its current user namespace. */
int hetoimasia_confine_has_sys_admin(void);

/* Whether an unprivileged user namespace can be created from this process.
**
** Asked by forking a child that tries it, so the answer costs the caller no
** namespace of its own. Answers 1, or 0 with `*observed_errno` set. */
int hetoimasia_confine_user_namespace_available(int *observed_errno);

/* The name of a layer, for a report. Never null. */
const char *hetoimasia_confine_layer_name(int layer);

#endif
