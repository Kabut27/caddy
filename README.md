# caddy

Automatic HTTPS reverse proxy for 3x-ui / Xray, powered by Caddy.

```bash
curl -fsSL https://raw.githubusercontent.com/Kabut27/caddy/main/caddy.sh -o caddy.sh
sudo bash caddy.sh
```

- Caddy gets and renews the TLS certificate by itself
- Routes `/1`–`/4` (or any path) to Xray inbounds on `127.0.0.1`
- Optional camouflage website for normal browsers
- Re-run anytime to add or remove locations
- Validates every change and rolls back on failure

**Requirements:** Debian/Ubuntu, root, domain pointing to the server, ports 80/443 open.
