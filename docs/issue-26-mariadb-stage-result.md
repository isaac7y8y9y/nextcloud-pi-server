# Issue 26: first live MariaDB stage

On October 15, 2026, the clean MariaDB stage in the
[upgrade plan](issue-26-upgrade-plan.md) and
[cutover design](issue-26-mariadb-cutover-design.md) completed. The tracked
Compose template and image lock now describe the proven database baseline.

| Component | Before | After |
| --- | --- | --- |
| MariaDB | 11.8.6 | 11.4.13, application SQL imported into a clean directory |
| Nextcloud / PHP | 30.0.17 / 8.3.28 | Unchanged images |
| Caddy | 2.10.2 | Unchanged image |

The ARM64 containerd image is locked to index
`sha256:1292844148b311e4ed4300022a996d39083f415a963e970cf47cad1b3b18e3a6`.
Its selected ARM64 manifest is
`sha256:0130d92c05fbf2d82adc2b86de742eaede65b2596c65d91786f8e03cd19e6a39`.
These identities remain distinct from the registry config digest. Exact-source
archive recovery was verified before the stage; see the
[recovery procedure](recovery.md).

The protected ingress freeze passed retained/new connection and authenticated
write denial, SSH/SMB preservation, safe synthetic upload abort, loopback HTTPS,
and two-sample zero drain. A fresh complete held backup bound to that freeze
was verified before image fetch or preparation. Both trusted IPv4 LAN routes
were tested; no scoped IPv6 route was reachable, so LAN IPv6 proof remains N/A.

Clean preparation compared full metadata for 169 tables and 1,291 columns,
plus exact counts for all 169 tables. Application login, integrity and graceful
shutdown passed before stopped-directory attestation. Database charset and
collation matched the source. The protected driver preserved the cold original
11.8 directory and promoted the verified directory to the canonical mount;
11.4 never opened the original files.

Before acceptance, MariaDB 11.4.13, READ-COMMITTED/ROW settings, disabled event
scheduler, directory identities, integrity, application access, Nextcloud 30
without a pending database upgrade, and synthetic loopback WebDAV passed.
Candidate conformance reported 68 PASS, 0 WARNING, 0 FAIL, 0 UNKNOWN and 0 DRIFT.
Separate acceptance committed the active record. Guarded release then reopened
ingress and restored jobs; synthetic LAN upload/download/delete passed on both
trusted routes. The test account and credentials were removed. Final health
passed and the original database and recovery material remain preserved.

Private artifacts, approvals, journals, inventories and detailed evidence stay
outside Git. This records one completed stage; it does not claim a production
full-runtime restore, reboot test, LAN IPv6 or Windows browser validation.
Nextcloud 30→31 is a separate stage requiring fresh recovery material and its
own held snapshot. After reopening, accepted writes must be accounted for before
any recovery; do not automatically restore the earlier held snapshot or start
11.8 on the new 11.4 directory as a rollback.
