# Tailscale

Tailscale is the only network path to the bot. SilverBullet and the web terminal bind to `127.0.0.1`, and `tailscale serve` publishes each one on the tailnet under its own HTTPS hostname. There is no reverse proxy, no port forward, and no certificate to manage.

## Join

Install Tailscale from the official repository, then join the box with a **tag**:

```bash
sudo tailscale up --advertise-tags=tag:<your-tag>
tailscale status
```

That's the standard form. An auth key that carries the tag works too. The source box carries three tags (one for lab machines, one for containers, one that lets it use Tailscale SSH into the lab), and its device record shows `keyExpiryDisabled: true`.

Tag the box for two reasons that were both learned on the source system:

- **Tailscale Services need a tagged host.** The source system's record from the day it set this up reads: "Device tagged … for Tailscale Services (required tag-based identity)".
- **Tagged nodes are exempt from key expiry.** On the source box, `tailscale status --json | jq .Self.KeyExpiry` is `null` and `.Self.Tags` lists its tags. An untagged server's key expires, and the box drops off the tailnet until someone re-authenticates it.

The tag has to exist in your tailnet policy file (`tagOwners`) before a node can advertise it. Pick one tag for lab machines and keep using it. Renaming tags later means touching every node.

## Publish with tailscale serve

Each service gets a name of the form `svc:<name>`, and Tailscale gives it a MagicDNS hostname `<name>.${TAILNET}.ts.net` with its own virtual IP. These are the two commands the source system ran, with its names replaced:

```bash
sudo tailscale serve --service=svc:${BOT_NAME}-notes --https=443 http://127.0.0.1:${SB_PORT}
sudo tailscale serve --service=svc:${BOT_NAME}-shell --https=443 http://127.0.0.1:${TERM_PORT}
```

Check:

```bash
tailscale serve status
```

On the source system (Tailscale 1.102) that prints:

```
https://${BOT_NAME}-notes.${TAILNET}.ts.net (tailnet only) (svc:${BOT_NAME}-notes)
|-- / proxy http://127.0.0.1:${SB_PORT}

https://${BOT_NAME}-shell.${TAILNET}.ts.net (tailnet only) (svc:${BOT_NAME}-shell)
|-- / proxy http://127.0.0.1:${TERM_PORT}
```

"tailnet only" is what you want. Funnel, which exposes a service to the internet, is a separate command and is not used here.

Running `serve --service` on the host is only half of it. The other half is in the admin console:

1. **Define the service** (admin console → Services): name `svc:${BOT_NAME}-notes`, port `tcp:443`, and one or more **service tags**. A service has its own tags, separate from the host's, and the grants in your policy match on those tags. On the source tailnet the notes service is tagged as management/container and the shell service as lab.
2. **Approve the host.** When the box first advertises the service, it appears as a pending host on that service. Approve it. The source tailnet has no `autoApprovers` entry for services, so both hosts show `approvalLevel: approved:manual` and `configured: ready`. If you'd rather not click, an `autoApprovers.services` entry in the policy can approve tagged hosts automatically (check Tailscale's docs for the current syntax).
3. **Check it:** the service page should list the box as a ready host, and `https://${BOT_NAME}-notes.${TAILNET}.ts.net` should load from another tailnet device.

### Why two hostnames and not two paths

The first attempt put both apps behind one hostname on different paths. It failed: two apps with their own logins on one hostname share cookies and break each other's redirects, and SilverBullet does not like living under a sub-path. One hostname per service, both on port 443, has had no trouble since.

If you don't want Services, plain `tailscale serve --bg --https=443 http://127.0.0.1:${SB_PORT}` publishes one app on the node's own hostname, and a second app can go on another port such as `--https=8443`. That is the layout the source system used before Services.

### The serve config is state. Treat it that way

- It lives in tailscaled on the host, not in any container. Recreating the SilverBullet container does not touch it.
- `tailscale up --reset` wipes it. On the source system a fleet-wide tagging run did exactly that and both services disappeared without an error. After any `tailscale up` with new flags, run `tailscale serve status` and re-add what is missing.
- Keep the two `serve` commands in your notes. `collaboration.md` in the vault lists the URLs so the bot can tell when one is gone.

## Access policy

This mirrors the source tailnet's policy, with its tags replaced by placeholders. It uses `grants` only (no `acls` section) and has **no `svc:` entries**. Access to each service follows the service's own tags from step 1 above.

```jsonc
{
  "tagOwners": {
    "tag:<lab-tag>":   ["autogroup:admin"],   // the bot box and other lab machines
    "tag:<svc-tag>":   ["autogroup:admin"],   // put this on the two services
    "tag:<ssh-tag>":   ["autogroup:admin"],   // optional: lets the bot SSH into the lab
  },
  "grants": [
    // you (owner/admins) reach everything, including both services on tcp:443
    { "src": ["autogroup:owner", "autogroup:admin"], "dst": ["*"], "ip": ["*"] },
    // lab machines may talk to each other; drop this if the bot box should stay isolated
    { "src": ["tag:<lab-tag>"], "dst": ["tag:<lab-tag>"], "ip": ["*"] },
  ],
  // optional: Tailscale SSH from the bot box into lab machines
  "ssh": [
    { "src": ["tag:<ssh-tag>"], "dst": ["tag:<lab-tag>"],
      "users": ["root", "autogroup:nonroot"], "action": "accept" },
  ],
}
```

If you share the tailnet with other people, replace the first grant with one that names only you as `src` and the service tag as `dst` on `tcp:443`. The broad admin grant is what the source system runs because its tailnet has a single human.

Both apps keep their own logins on top of this. The tailnet decides who can connect; the app decides who can read and write.

## Gotchas

### `tailscale status` does not show an expired key

A peer whose node key has expired still appears in `tailscale status` as a normal online row, with no `offline` marker. It looks healthy and is unreachable. `tailscale ping <host>` names the problem ("peer's node key has expired"), and so does probing a real service port.

Related: expiry stays invisible until something forces the node to re-register, such as a `tailscaled` restart or a `tailscale up` with changed preferences. So "fixing" the tag on a node whose key has already expired is the thing that logs it out. If that node is only reachable over Tailscale, you have locked yourself out. Audit without triggering anything by reading `tailscale status --json` on each host: `.Self.KeyExpiry` and `.Self.Tags`.

### MagicDNS disappears when resolv.conf is overwritten

Symptom: every `*.ts.net` name fails to resolve on the box while the tailnet data path is fine.

Diagnose:

```bash
getent hosts <peer>.${TAILNET}.ts.net     # fails
getent hosts github.com                    # works
tailscale ping <peer>                      # pong
tailscale status --json | jq .Health       # mentions resolv.conf being overwritten
```

Cause on the source system: `/etc/resolv.conf` had been rewritten with only the LAN resolvers, which dropped Tailscale's MagicDNS resolver, `100.100.100.100` (a fixed address that is the same on every tailnet). Nothing else on that box managed the file. `tailscale set --accept-dns=true` did not reclaim it. What worked was backing up the file and putting `nameserver 100.100.100.100` back as the first line, with the LAN resolver after it as a fallback.

Today the same file on the source box starts with "generated by tailscale … DO NOT EDIT", so Tailscale owns it again. If yours stops saying that, this is the first thing to look at.

A side effect worth knowing: any check that treats "the request failed" the same as "nothing new" will report a quiet day during a DNS outage. The `sb-mentions` gate talks to `127.0.0.1` and is not affected, but keep it in mind for anything you add that calls a tailnet name.

### `ping` in unprivileged containers

In an unprivileged LXC, `ping` can fail with "Operation not permitted". The source box fixed it with the sysctl `net.ipv4.ping_group_range = 0 65535`. Where that is not set, test reachability with `tailscale ping` or a TCP probe (`timeout 3 bash -c '</dev/tcp/<host>/<port>'`).

### Old browser state survives a move

After moving a service to a different backend behind the same tailnet hostname, one browser kept failing to load script chunks while another worked. The server was returning identical bytes either way. A service worker cached at that origin was the cause, and clearing that site's data fixed it. Check this before debugging the proxy.
