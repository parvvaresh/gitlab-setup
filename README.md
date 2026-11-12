# GitLab CE Auto Installer (Ubuntu 22.04)

A simple one-command script to install **GitLab Community Edition** on **Ubuntu 22.04 (Jammy)**.  
Supports both **IP-based** and **domain-based** setups, with optional **HTTPS + Let’s Encrypt**.

---

##  Requirements
- Ubuntu 22.04 LTS (Jammy)
- Root or sudo privileges
- Public IP address
- (Optional) A valid domain name pointing to the server IP

---

##  Quick Start
```bash
cp .env.example .env     # fill in SERVER_IP, domain, etc.
sudo bash install_gitlab.sh
```

All settings live in **`.env`** (see `.env.example`). Anything left empty is asked interactively,
so running without a `.env` works exactly like before. Use another file with
`sudo ENV_FILE=/path/to/file bash install_gitlab.sh`.

For a fully unattended install set `ASSUME_YES=yes` in `.env`.

| Variable | Description |
|---|---|
| `SERVER_IP` | Public IP of the server |
| `USE_DOMAIN` | `yes` = real domain, `no` = IP / local hostname |
| `GITLAB_HOSTNAME` | Domain (`gitlab.example.com`) or local hostname (`gitlab.local`) |
| `USE_LETSENCRYPT`, `LE_EMAIL` | HTTPS via Let's Encrypt (domain mode only) |
| `ACCESS_VIA` | `ip` or `hostname` (non-domain mode) |
| `EXTERNAL_URL` | Optional override of the computed URL |
| `CREATE_BACKUP` | Create a backup after install (default `yes`) |
| `INSTALL_RUNNER` | Also install a GitLab Runner on this server (default `no`) |

---

##  GitLab Runner

Install and register a runner, on the GitLab server or on a separate machine:

```bash
cp .env.example .env     # set GITLAB_URL, RUNNER_TOKEN, RUNNER_EXECUTOR ...
sudo bash install_gitlab_runner.sh
```

* **Token:** create a runner in GitLab (*Admin → CI/CD → Runners → New instance runner*, or
  *Project → Settings → CI/CD → Runners*) and put the `glrt-...` token in `RUNNER_TOKEN`.
  Tags / "run untagged" for such tokens are configured in that UI.
* **On the GitLab server itself** you can leave `RUNNER_TOKEN` empty: an instance runner is
  created automatically via `gitlab-rails` (using `RUNNER_TAGS` / `RUNNER_RUN_UNTAGGED`).
  Or just set `INSTALL_RUNNER=yes` before running `install_gitlab.sh`.
* **Executor:** `docker` (default, installs `docker.io`) or `shell`.
  Set `RUNNER_DOCKER_PRIVILEGED=yes` for docker-in-docker builds.
* If GitLab is reached by a local hostname (e.g. `gitlab.local`), set
  `RUNNER_DOCKER_EXTRA_HOSTS=gitlab.local:<SERVER_IP>` so job containers can resolve it
  (done automatically when installed via `INSTALL_RUNNER=yes`).

```bash
sudo gitlab-runner list
sudo gitlab-runner verify
sudo journalctl -u gitlab-runner -f
```

---

##  Access GitLab

* Via IP:

  ```
  http://<SERVER_IP>
  ```
* Via domain:

  ```
  https://gitlab.<your-domain>
  ```

---

##  Login Credentials

View your initial root password:

```bash
sudo cat /etc/gitlab/initial_root_password
```

* **Username:** `root`
* **Password:** (value from file above)

---

##  Enable HTTPS Later

1. Point your domain to the server IP.
2. Edit:

   ```ruby
   # /etc/gitlab/gitlab.rb
   external_url "https://gitlab.yourdomain.tld"
   letsencrypt['enable'] = true
   letsencrypt['contact_emails'] = ['you@example.com']
   ```
3. Apply changes:

   ```bash
   sudo gitlab-ctl reconfigure
   ```

---

##  Useful Commands

```bash
sudo gitlab-ctl status
sudo gitlab-ctl reconfigure
sudo gitlab-ctl tail
sudo gitlab-rake gitlab:backup:create
```

> Backups are stored in `/var/opt/gitlab/backups/`.

---
```
