# Local client access

This guide documents browser-based Nextcloud access from macOS and Windows 11
clients on the wired home LAN.

The intended workflow is manual upload and download through the Nextcloud web
interface. Automatic desktop synchronization and centralized LAN DNS are outside
the scope of this setup.

## Client addressing

The Raspberry Pi administration hostname and the Nextcloud HTTPS service
hostname have different purposes.

Use the Pi administration identity for SSH and administration. Use the
Nextcloud service hostname when accessing Nextcloud from a client.

The Pi Ethernet address should be stable, such as through a router DHCP
reservation.

Documentation examples use reserved values:

```text
192.0.2.10 nextcloud.example.invalid
```

Do not commit real deployment hostnames, IP addresses, MAC addresses,
usernames, or other private deployment identifiers.

## Hostname mapping

This deployment uses per-client hosts-file mappings rather than centralized LAN
DNS.

### macOS

Add the Nextcloud service hostname and reserved Pi Ethernet address to
`/etc/hosts`.

Example:

```text
192.0.2.10 nextcloud.example.invalid
```

Normal macOS hostname resolution should then map the service hostname to the Pi
Ethernet address.

A direct DNS lookup may still return `NXDOMAIN`; that is expected when the
hostname exists only in the local hosts file.

### Windows 11

Open PowerShell as Administrator and edit the Windows hosts file:

```powershell
notepad.exe "$env:SystemRoot\System32\drivers\etc\hosts"
```

Add one mapping:

```text
192.0.2.10 nextcloud.example.invalid
```

Flush cached name-resolution state:

```powershell
ipconfig /flushdns
```

Verify HTTPS connectivity using the service hostname:

```powershell
$NextcloudHost = "nextcloud.example.invalid"
Test-NetConnection -ComputerName $NextcloudHost -Port 443
```

The resolved address should be the reserved Pi Ethernet address and
`TcpTestSucceeded` should be `True`.

## Caddy internal CA

If the deployment uses Caddy's internal certificate authority, clients must
trust the Caddy public root certificate.

Only the public root certificate may be transferred to a client. Never transfer
or commit the CA private key, server private keys, runtime TLS state, or
certificate contents.

Before installing trust, verify that the transferred public root matches the
copy read directly from the Pi.

For example, compute the public-root file SHA-256 on the Pi and on the client
and confirm the values match exactly.

The source `root.crt` file is temporary. After certificate trust is installed
and HTTPS access succeeds without a warning, the temporary certificate file may
be deleted.

## macOS certificate trust

After verifying the Caddy public root, install it into the current user's login
keychain with SSL trust:

```bash
security add-trusted-cert \
  -r trustRoot \
  -p ssl \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "<path-to-temporary-verified-root.crt>"
```

Quit and reopen the browser after installing trust.

Open the configured Nextcloud HTTPS service hostname and verify that the site
loads normally with no certificate warning and without using a certificate
bypass.

After trust is confirmed, delete the temporary public-root file. Keep the
installed keychain trust entry and the required hosts-file mapping.

## Windows certificate trust

Point PowerShell at the privately transferred and verified public root:

```powershell
$RootPath = "<path-to-temporary-verified-root.crt>"
```

Verify its SHA-256 before installing it:

```powershell
certutil -hashfile $RootPath SHA256
```

Capture the certificate thumbprint for private rollback records:

```powershell
$RootCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    (Resolve-Path $RootPath)
)
$RootThumbprint = $RootCert.Thumbprint
```

Install the certificate into the current-user Root store:

```powershell
certutil -user -addstore -f Root $RootPath
```

Verify that the expected certificate is installed:

```powershell
Get-ChildItem Cert:\CurrentUser\Root |
  Where-Object Thumbprint -eq $RootThumbprint |
  Format-List Subject, Thumbprint, NotAfter
```

Do not install machine-wide trust unless a separate validated requirement
requires it.

After trust and browser validation succeed, the transferred `root.crt` file may
be deleted. The installed trust entry does not depend on the original file
remaining on disk.

## Windows HTTPS validation

Windows curl using Schannel may report:

```text
CRYPT_E_NO_REVOCATION_CHECK
```

for the private Caddy CA because revocation information is not available.

Use Schannel's best-effort revocation mode while retaining normal certificate
and hostname validation:

```powershell
$NextcloudHost = "nextcloud.example.invalid"

curl.exe -sS --ssl-revoke-best-effort -I "https://$NextcloudHost/" |
  Select-String "HTTP/|Location:|Via:"
```

A normal Nextcloud response may be an HTTP redirect to the login page.

Do not use `-k`, `--insecure`, `--ssl-no-revoke`, or a browser
certificate-warning bypass as an acceptance test.

Open the same service hostname in the intended Windows browser and verify that
it loads through HTTPS without a certificate warning.

## Manual storage workflow

This deployment intentionally uses manual browser-based storage management.

To upload data:

1. Open the Nextcloud HTTPS service hostname.
2. Log in normally.
3. Upload the desired files through the Files interface.

To download data:

1. Open the Files interface.
2. Select the desired files.
3. Download them to the client as needed.

Automatic Nextcloud desktop synchronization is not required.

The validated client workflow includes manual transfer in both directions:
files uploaded from Windows can be downloaded on macOS, and files uploaded from
macOS can be downloaded on Windows.

## Cleanup

After client trust and browser access are verified:

- delete temporary transferred copies of `root.crt`;
- delete removable-media copies used only for certificate transfer;
- delete temporary upload/download test files;
- keep the required hosts-file mappings;
- keep the installed client trust entries.

Do not keep certificate-transfer artifacts in the repository.

## Rollback

To remove Windows client access:

1. Remove only the Nextcloud mapping added to the Windows hosts file.
2. Run:

   ```powershell
   ipconfig /flushdns
   ```

3. Remove the Caddy root from the Windows current-user Root store using the
   privately recorded certificate thumbprint.

To remove macOS client access:

1. Remove only the Nextcloud mapping added to `/etc/hosts`.
2. Set the exact certificate hash from the private rollback record and the
   login-keychain path:

   ```bash
   MAC_ROOT_CERT_SHA256="<privately-recorded-certificate-SHA-256>"
   LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
   ```

3. Remove that certificate and its user trust settings from the login
   keychain:

   ```bash
   security delete-certificate \
     -t \
     -Z "$MAC_ROOT_CERT_SHA256" \
     "$LOGIN_KEYCHAIN"
   ```

4. Verify that the exact certificate is absent:

   ```bash
   KEYCHAIN_CERTIFICATES="$(
     security find-certificate -a -Z "$LOGIN_KEYCHAIN"
   )" || {
     echo "Unable to inspect the login keychain" >&2
     exit 1
   }

   if grep -Fiq "$MAC_ROOT_CERT_SHA256" <<<"$KEYCHAIN_CERTIFICATES"; then
     echo "Caddy root certificate is still present" >&2
     exit 1
   else
     echo "Caddy root certificate was removed"
   fi

   unset KEYCHAIN_CERTIFICATES
   ```

Do not change Caddy, Nextcloud, Pi networking, or the Pi Wi-Fi interface merely
to roll back a client enrollment.
