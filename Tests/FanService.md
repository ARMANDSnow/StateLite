# Persistent fan authorization

FanService.c is included after FanHelper's hardware and lease implementation.
SLFanServiceCommand returns -1 for an unrelated mode, otherwise an exit status.
--install and --uninstall accept pid, uid, process start seconds and microseconds.
--serve is exclusively a launchd entry. Link the helper with Security, IOKit and
libbsm. The installer prints INSTALLED or UNINSTALLED on success; launchctl
diagnostics go to stderr. Normal control retains READY/SET/SYSTEM/PING/ACK.
--preflight is launched directly by the real bundled app without administrator
authorization. It checks the actual parent image/signature, own dynamic/static
signatures, signature-preserving copy in a private temporary directory, and
system/install directory metadata. It reports every CHECK and finally
PREFLIGHT_OK or the first failing stage. It never creates system directories,
changes system permissions, calls launchctl or opens SMC. Temporary copy files
are removed before it returns. A successful preflight does not establish that
subsequent root authorization or launchd bootstrap will succeed.

The root-owned manifest has integer protocolVersion=1, serviceVersion=1,
clientUID and hexadecimal clientCDHash/helperCDHash strings. The daemon validates
the running peer's kernel audit token, UID, dynamic signature and exact cdhash.
Both running code and staged helper signatures must have hardened runtime set,
without DYLD environment, library-validation, debugging, JIT or unsigned/executable
memory exceptions. Main-binary identity alone cannot exclude injected libraries.
Socket permissions alone do not grant control. A new ad-hoc build requires an
explicitly authorized install to replace its pin. No protocol command upgrades,
copies arbitrary files, executes commands or accepts arbitrary SMC keys.

Installation stages signed bytes inside the root-owned helper directory, checks
the copy against its own running signature, preserves existing files for rollback
and atomically places the three fixed artifacts. A global root-owned flock
prevents install/uninstall while a control lease owns the hardware. Partial
rollback retains its recovery directory and reports its exact path.
The OS-owned /private/var/run accepts Apple's root:daemon (gid 1) group-write
mode, while rejecting other-writable, non-root and symlink directories. This
exception does not apply to installed artifacts or other parents. The lock must
be a single-link root-owned private regular file and its pathname must still
identify the locked inode. Socket and lock paths remain unchanged. No system
directory permissions are modified. Identity and directory failures report
different installation stages.

launchd owns the Unix socket and starts the service on demand. RunAtLoad performs
crash-marker recovery at boot; KeepAlive/Crashed restarts an abnormally terminated
worker. An idle activation exits normally after a short accept window. No idle
heartbeat or SMC polling runs. Before entering a lease the worker creates a
root-owned dirty marker; only confirmed restoration removes it. A failed recovery
retains the marker and refuses control. Recovery failure is not an assurance that
the fans have returned to automatic control.

Run `bash Tests/test-fan-service.sh` as the ordinary user. The suite uses only a
temporary Unix socket and ad-hoc signed test executable. It verifies actual audit
token/cdhash authentication, wrong identity/UID/version/type rejection and
actual non-hardened/exception-entitled executable rejection, plus
non-root refusal. It never installs, calls launchctl or accesses SMC. These tests
do not establish live privileged installation, crash recovery, sleep behavior or
cross-reboot authorization; those require separately recorded acceptance.

API sources: Apple's installed SMAppService.h documents notarization for bundled
LaunchDaemons and the continued legacy /Library/LaunchDaemons mechanism;
launch.h documents launch_activate_socket; sys/un.h defines LOCAL_PEERTOKEN.
Apple's SecCodeCopyGuestWithAttributes accepts kSecGuestAttributeAudit to bind
validation to the actual peer process rather than a caller-supplied PID.
