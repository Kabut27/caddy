# nginx-deploy

Interactive nginx setup for 3x-ui/Xray servers — no more manual config editing on every new box.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/Kabut27/caddy/main/caddy.sh -o caddy.sh
sudo bash caddy.sh
```

Answer the prompts: domain, backend ports, and any extra paths (panel, sub endpoint, etc). Certs are always read from `/root/cert/<domain>/`.

Config gets backed up before overwrite, tested with `nginx -t`, and only reloaded if the test passes.

