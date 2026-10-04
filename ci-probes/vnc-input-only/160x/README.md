# Isolated VNC input native compilation

This branch compiles a complete snapshot of the reviewed native-CG VNC input draft, rather than the older default-branch or local Git HEAD source.

The workflow invokes only the libmachook target and portable header fixtures. It has no device, deployment, package, release, or production mutation step. Artifacts are compile evidence and require separate CodeDirectory, final identity, live trustcache, and real input/display validation before deployment.

Source-manifest.json binds the normalized F20 baseline, reviewed cumulative patch, final source files, and exact load-command-only VNC metadata fixture. The tiny fixture is not executable and does not replace runtime code identity validation.
