# Mac Access

The Mac accesses Nextcloud through:

```text
https://cloud.example.invalid
```

The hostname is resolved locally on the Mac using an `/etc/hosts` entry that points `cloud.example.invalid` to the Raspberry Pi Ethernet address.

Example shape:

```text
192.0.2.10 cloud.example.invalid
```

Use the current Pi address for the real entry.

Caddy uses its internal certificate authority for HTTPS. macOS must trust the Caddy root certificate before browsers and clients will accept `https://cloud.example.invalid` without warnings.

The Caddy root certificate itself is excluded from Git because certificates and trust material should be handled intentionally. Caddy private key material and runtime TLS state must never be tracked.

Read-only verification examples:

```sh
curl -I https://cloud.example.invalid
curl -k -I https://cloud.example.invalid
```

The `-k` form ignores certificate trust and is useful only for separating routing problems from certificate trust problems.

Do not paste session cookies, browser headers, authenticated request output, or login tokens into documentation.

