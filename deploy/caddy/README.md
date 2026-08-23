# Maple internal proxy

`maple.Caddyfile` is the Server-managed reverse proxy between the public preview tunnel and `maple-app:8000`.

- It listens only inside the Maple Docker network on port 8080.
- Host access is bound to `127.0.0.1:9040` by the production Compose file.
- Existing global Caddy / ports 80 and 443 are not modified.
- The temporary Cloudflare Quick Tunnel is used only for public deployment verification until a fixed domain is connected.
