# Portainer (optional Docker UI)

A browser interface for the Docker containers you're already running (SilverBullet, plus anything else you add later). It runs as a container itself, lets you tail logs, exec into a shell, restart, inspect networks, all the things you'd otherwise use `docker compose logs`, `docker exec`, `docker ps` for from a terminal.

Optional. Skip if you're comfortable with the Docker CLI; add it the first time you wish you could just click "View Logs" on a container from your phone.

## What you're trading

**For:** point-and-click container management, real-time log tails in a browser, container restart/exec without SSH, a quick "is everything running?" dashboard.

**Against:** another running container; another web UI to keep logged into; a service with effectively `root`-via-`docker.sock` privileges on your box — anyone who reaches the Portainer UI can launch any container as any user.

Mitigations:
- Bind Portainer's port to `127.0.0.1` only — never expose it on `0.0.0.0` directly.
- Reach it via Tailscale, never via a port mapped on a public interface.
- Use a strong admin password and don't share it.

## Install via the same docker-compose.yml as SilverBullet

You already have a `docker-compose.yml` in your vault from [silverbullet-setup.md](silverbullet-setup.md). Add a `portainer` service to it:

```yaml
# <VAULT>/docker-compose.yml (additions only — keep the existing silverbullet block)
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "127.0.0.1:9000:9000"          # localhost only; Tailscale fronts it
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:
  portainer_data:
```

Bring it up:

```bash
cd <VAULT>
docker compose up -d portainer
docker compose ps portainer        # should show 'running'
```

## Step through first-run setup

Portainer's first-run includes a **timed security gate**: if no admin user is created within ~5 minutes of container startup, the UI refuses to let you set one until you restart the container. Do this part promptly.

1. Hit `http://localhost:9000` from the box (or through Tailscale — see below). The first-run screen asks you to create an admin user.
2. Pick a username (`admin` is fine) and a strong password — 12+ chars, generate one with `openssl rand -base64 24` if you don't have a password manager open.
3. On the next screen, pick "Get Started" / "Local environment" — Portainer auto-detects the local Docker socket and connects to it.
4. You should land on a dashboard showing your running containers (silverbullet, portainer, plus claude-code-related ones if any).

If you missed the 5-minute window, you'll see "Initial setup has timed out — restart the container to continue." Fix:

```bash
docker compose restart portainer
# then immediately hit localhost:9000 again
```

## Expose via Tailscale

SilverBullet is already on `https://<host>.<tailnet>.ts.net` (port 443). Pick a different port for Portainer — 8443 is a common choice for "second HTTPS service":

```bash
sudo tailscale serve --bg --https=8443 http://127.0.0.1:9000
sudo tailscale serve status     # verify both services listed
```

You can now reach Portainer at `https://<host>.<tailnet>.ts.net:8443` from any Tailscale-connected device.

If you'd rather path-prefix on a single 443 endpoint instead of using two ports, see Tailscale's docs on `--set-path` — works but requires care because Portainer's UI uses absolute paths internally and can break under a path prefix without a reverse-proxy rewrite. Two ports is friendlier.

## Day-to-day uses

The most-useful Portainer flows once it's set up:

- **Tail SilverBullet logs from your phone** — Containers → silverbullet → Logs → auto-refresh on.
- **Restart a container without SSH** — Containers → click container → Restart. Handy if SilverBullet hangs on a malformed page and you don't want to wait to get to a laptop.
- **Quick `exec` into a running container** — Containers → Console. Useful for poking at SilverBullet's `/space` directory or the bot's tmux session from a browser when the [web-shell](web-shell.md) isn't an option.
- **See disk usage per container/volume** — Dashboard → Volumes. Catches the "why is my disk filling up" question before it becomes the answer.

## What I'm not doing here

- **Portainer Business Edition.** The free CE covers everything described above. BE adds RBAC, support, and a few enterprise features you don't need for a one-person bot.
- **Wiring up Claude as a Portainer user.** The bot doesn't need a UI — it can use `docker` CLI directly when it needs to manage containers, which is rare. Portainer is purely for *you* (the human) to inspect state.
- **HTTPS inside the container.** Portainer can self-sign and serve `9443`, but Tailscale terminates TLS for us already, so plain HTTP on `9000` (bound to `127.0.0.1`) is fine and one less moving part.

## When to skip Portainer

If you're comfortable with:

```bash
docker compose logs -f silverbullet     # tail logs
docker compose restart silverbullet     # restart
docker compose exec silverbullet sh     # shell in
docker compose ps                       # list
docker system df                        # disk usage
```

…then you don't need Portainer. It's a nice-to-have, not a requirement. The [web-shell](web-shell.md) covers most "I want browser access to my box from my phone" needs without the docker-socket-exposure tradeoff.
