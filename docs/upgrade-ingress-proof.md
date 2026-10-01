# Item-4 ingress and drain proof plan

This is the item-4 test protocol, with a measured checkpoint below. The
checkpoint proves the tested ingress lifecycle, not that a version upgrade or
production runtime restoration has been performed. Do not install a new bundle
or execute the live test before the item-4 failure tests and code/PR reviews
are complete and the exact downtime window and recovery path are approved.
The test temporarily changes live ingress and background jobs without upgrading
an image. Item 5 retains its separate fresh-evidence and approval gates.

## Measured checkpoint — October 1, 2026

The reviewed correction at `040979a` was installed and its bundle manifest
verified before the separate-client test. Readiness had no hard failures;
configuration/runtime/prior-image recovery material was reverified within its
freshness limit. The following observations passed on the deployed Docker
iptables path with direct routing disabled:

- Trusted IPv4 HTTPS and a synthetic authenticated WebDAV roundtrip passed
  before freezing. Two requests used the same retained TLS connection.
- Fresh host TCP 80/443, alternate IPv4 addresses, direct-container paths, and
  the retained connection could not reach the application while frozen. A
  separately attempted authenticated PUT was denied. SSH and SMB remained
  available; Pi IPv4 and IPv6 loopback HTTPS reached installed Nextcloud.
- A synthetic upload started before activation and safely aborted. Its final
  file and the denied PUT's final file were absent. The protected drain check
  passed two zero app/Caddy socket and InnoDB-transaction samples five seconds
  apart. A later loopback probe opened internal connections and correctly
  blocked the first held prerequisite check; the first retry passed after
  those connections settled, without bypassing the guard.
- The held capture completed and verified its payloads. Its `runtime-backup-v2`
  manifest bound the same freeze ID and rule hash; maintenance mode, paused
  timer, source images, and running container identities were preserved.
- Interrupting SSH during a disposable read-only protected quiescence recheck
  left the same active rule, maintenance mode, and paused timer intact. No real
  backup was interrupted.
- Approval-bound release removed the exact rule, restored the prior active
  timer, and left maintenance off. LAN synthetic upload/download/delete passed,
  release replay was denied, and the test account and retained client were
  removed/stopped. Source image and container identities remained unchanged.

LAN IPv6 HTTPS was unavailable from the tested Mac, including scoped link-local
probes, so LAN IPv6 denial is **not applicable for this checkpoint**, not passed.
Reassess it when connectivity changes. This interruption test is not a Pi reboot
or Docker restart test. No candidate image activation, production migration, or
full production-runtime restore occurred. Detailed evidence and private recovery
artifacts remain outside Git. Repeat the applicable proof and freshness checks
before each approved item-5 stage.

## Preconditions and evidence

Use a separate LAN client (the operator Mac) and the Pi's loopback. Record
sanitized pass/fail results, times, IP-family availability, rule fingerprint,
and transaction ID privately; do not publish addresses, credentials, request
payloads, or raw logs. Before any mutation:

1. Verify the reviewed privileged bundle is installed, the active-image and
   Compose baseline is unchanged, the storage mount is the expected ext4
   volume, the stack and timer are healthy, and no prior freeze/stage/active
   transaction exists. Check Docker's actual firewall backend, published
   Caddy ports, host IPv4/IPv6 addresses, direct-routing settings, and any
   externally reachable container address. An absent usable IPv6 route is
   recorded as **not applicable**, not as a passed IPv6 test.
2. Verify fresh configuration, full-runtime, and attested prior-image
   recovery artifacts. Confirm the full-runtime restore plan can be formed
   from them without mutating the Pi. Select a test transaction ID and verify
   `upgrade-freeze check` before activation.
3. On the LAN client, prove ordinary HTTPS and a small authenticated synthetic
   WebDAV upload/download over each available IP family. Open and retain an
   HTTP/1.1 keep-alive HTTPS connection on each available family; confirm it
   can make a second request before the freeze. Also record that SSH and one
   unrelated NAS port work. Never use a real user document as the test file.
4. Arrange an isolated synthetic in-flight write and a read-only database
   transaction observation. The write must be started before activation and
   finish or abort before backup capture. The draft protected
   `upgrade-freeze quiescence <id>` check samples established app/Caddy TCP
   sockets and active InnoDB transactions twice, five seconds apart, and the
   held-backup path now requires that check. It is conservative but not a
   substitute for the client-side write and firewall proof. If a repeatable
   test cannot be arranged safely, record drain as **unproved** and do not
   capture the held snapshot or claim this gate complete.

## Activation and denial matrix

Activate exactly one protected freeze. The dispatcher must pause the timer,
wait for an active background-job service to finish, enable maintenance mode,
install the bound `inet` prerouting rule, and report the active rule hash.
The reviewed bundle also installs a Docker `ExecStartPre` boot guard: if the
Pi reboots with an active freeze, it must reinstall and verify the same rule
before Docker can start Caddy; an unresolved phase or changed rule prevents
Docker startup. The timer has a `timer-held` condition and the job service has
a separate `current.tsv` condition; release removes the timer hold before
starting the timer, but keeps the job-service guard until final release.
They must not run work while the freeze is held. Reboot safety still needs
an observed disposable or approved Pi test before production reliance.
Immediately verify the timer is stopped and the rule/status hash agrees.
The first failure leaves the freeze in place; do not bypass it with manual
firewall edits.

| Probe while frozen | Required observation |
| --- | --- |
| Fresh TCP 80 and 443 from LAN, IPv4 and available IPv6 | No HTTP response or successful connection to Caddy; distinguish a transport drop from Nextcloud's maintenance response. |
| Request over each retained pre-freeze keep-alive connection | No successful HTTP response; opening a new connection is not a substitute for this check. |
| Authenticated synthetic WebDAV PUT from LAN | No application write reaches Nextcloud; later verify the attempted file is absent. |
| Pi loopback HTTPS at 127.0.0.1 and available ::1 | Expected Caddy/Nextcloud response remains reachable for local health checks. |
| SSH and unrelated NAS port from LAN | Remain reachable; this rule must not create a general network outage. |
| Caddy published-port, direct-routed container, and alternate-address paths | No bypass. Any reachable alternate path fails the test. |
| In-flight write, active DB transactions, and background job service | The write has finished or safely aborted, no application DB transaction remains, and the jobs service is inactive before snapshot. A timeout or unknown state fails closed. |

After the denial/drain proof, take only the approved held snapshot and verify
its manifest binds the same freeze ID and rule hash. To test interruption
retention, interrupt a **disposable** post-freeze step, then prove the rule,
maintenance mode, and paused timer remain in place. Do not interrupt a real
backup or leave the NAS unintentionally inaccessible.

## Release and cleanup

Do not release while a fetch, stage, active-record transaction, or recovery is
unresolved. For a test with no image stage, verify the original runtime still
passes loopback health, deliberately turn maintenance mode off with the draft
protected `upgrade-freeze maintenance-off <id>` action only after the LAN
denial proof, and use the protected single-use release. The maintenance-off
action rechecks quiescence and refuses unresolved fetch/stage/active-record
state. The draft `scripts/release-upgrade-freeze.py --plan/--apply` operator
path binds the active freeze, prior timer state, live Compose/Caddy and
container identities, and the tracked source image lock to a private,
single-use 15-minute approval. A newly accepted candidate cannot release
until its candidate lock has become the reviewed local source lock; do not
silently edit that lock during activation. The driver turns
maintenance off only if still on, checks Pi loopback health, then streams the
consumed approval to the protected dispatcher. The dispatcher independently
checks the bound freeze, configuration, active record, running containers,
source-lock provenance, and loopback HTTPS before recording the single-use
approval and removing the rule. The driver verifies the rule is absent and
the timer has its prior state. A direct `upgrade-freeze release <id>` call
without the approval is denied. This does **not** create the LAN denial proof or
authorize release without the separate measured test and reviewed approval.
If it fails after maintenance-off, keep the freeze and form a new approval
from the changed state; if release has begun, inspect the protected phase
before any recovery. Confirm the
exact rule table is absent, the timer returns to its pre-freeze state, and a
repeated release is denied. Recheck LAN browser access and synthetic
upload/download on each available family, and remove only the synthetic test
files through Nextcloud. Preserve any unexpected state and use the approved
recovery procedure rather than deleting firewall or root-owned markers by
hand.

The test passes only when every applicable row has measured evidence on the
Pi's deployed Docker/firewall path. A Linux fixture or a successful `nft`
command alone does not establish LAN denial, pre-existing-flow closure, or
database drain. If the target is shut down, unreachable, lacks the reviewed
interface, or cannot supply a safe synthetic write, the result is **blocked**,
not passed. See the [upgrade plan](issue-26-upgrade-plan.md#item-4-implement-rehearse-and-review).
