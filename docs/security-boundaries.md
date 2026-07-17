# Security Boundaries

This repository must contain documentation and sanitized configuration only.

Never commit:

- `.env`
- Nextcloud `config.php`
- Nextcloud secret values
- Nextcloud password salt
- Uploaded user files
- Nextcloud data-directory contents
- MariaDB database files
- Database dumps
- Caddy private keys
- Caddy `/data` runtime volume contents
- Caddy `/config` runtime volume contents
- Certificates unless intentionally reviewed and approved
- Session cookies
- Backup archives
- Raw secrets or credentials
- Unreviewed live configuration
- Raw discovery reports unless sanitized and intentionally included

The sanitized Compose file reads database settings from environment variables. The live `.env` file must be created only on the deployment target or handled through another secret-management process.

For this deployment, the expected live path is:

```text
/srv/example/nextcloud-docker/.env
```

Create it from `compose/.env.example`. Keep the real file untracked.
