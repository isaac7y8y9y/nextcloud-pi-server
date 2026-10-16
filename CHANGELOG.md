# Changelog

This changelog records major engineering phases rather than individual commits.

## 2026-10 — Nextcloud 32 checkpoint

- Accepted and reopened Nextcloud 32.0.15 / PHP 8.3.35 after a separately protected
  31→32 stage, preserving MariaDB 11.4.13 and Caddy.
- Verified exact signed app updates, retained compatible Notes, required jobs,
  integrity, synthetic file preservation, candidate conformance and LAN files.
- Rehearsed official disabled-app service registration before Mail migrations.

## 2026-10 — First live Nextcloud stage

- Promoted accepted Nextcloud 31.0.14 / PHP 8.3.30 with six exact signed custom-app
  updates, preserving the MariaDB 11.4.13 and Caddy baseline.
- Verified protected ingress/drain, held recovery, integrity, required migration
  jobs, candidate conformance and synthetic files before guarded reopening.
- Corrected approval-bound app disabling to accept matching OCC code/installed
  version output while rejecting mismatches; prevent activation CLI bytecode
  artifacts from blocking publication checks.

## 2026-10 — First live database stage

- Promoted a verified clean MariaDB 11.4.13 import while retaining Nextcloud 30
  and Caddy images, with the original database and held recovery point preserved.
- Recorded measured ingress/drain protection, inventory/integrity checks,
  candidate acceptance, guarded reopening, and synthetic file verification.

## 1.1.0 — 2026-09-16

- Added operational deployment and recovery runbooks with expanded regression
  coverage for image and runtime recovery paths.
- Introduced a least-privilege Raspberry Pi operations interface and associated
  installation, policy, and verification controls.
- Added the canonical pull-request test runner and hermetic restore-readiness
  end-to-end coverage.

## 1.0.0 — 2026-08-27

- Reframed the repository as a sanitized engineering case study.
- Added clean-clone configuration and publication-safety validation.
- Added public project licensing and concise maintenance context.

## 2026-08 — Deployment hardening and client access

- Added transactional deployment and recovery controls, active-image
  validation, storage-gated startup, and expanded regression coverage.
- Documented validated macOS and Windows wired-LAN browser access.

## 2026-07 — Sanitized configuration and recovery foundations

- Externalized deployment identity and Compose credentials from tracked files.
- Added protected rendering, preflight, backup, rollback, and recovery tooling.
- Added repository-sensitive-data scanning and full-history secret detection.

## 2026-06 — Initial architecture baseline

- Captured the Raspberry Pi Nextcloud, MariaDB, Caddy, systemd, and external
  storage architecture as repository-managed templates and documentation.
