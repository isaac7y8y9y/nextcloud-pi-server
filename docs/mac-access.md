# Local client access

Use the public hostname defined in the local deployment environment. Documentation
examples must use reserved values, for example:

```text
192.0.2.10 nextcloud.example.invalid
```

If the deployment uses Caddy’s internal certificate authority, install its root
certificate through a deliberate local trust process. Never add certificate or
private-key material to this repository.
