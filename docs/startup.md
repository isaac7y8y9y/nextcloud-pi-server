# Startup

Before starting the stack, confirm that the configured storage mount is present
and that the rendered Compose, Caddy, systemd, and fstab configuration has been
validated. The systemd unit is rendered from the local deployment environment;
the tracked version is not itself deployable.

Run preflight after a reboot or operational change. If the storage mount is
missing, stop and investigate rather than starting containers against host-local
directories.
