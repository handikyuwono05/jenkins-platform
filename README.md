# jenkins-platform

A Jenkins controller that runs in Docker and is configured entirely as code:
authentication via **Google OAuth 2.0**, authorisation, hardening and audit
logging all live in version-controlled YAML. No setup wizard, no clicking
through Manage Jenkins, no secrets in the image or the repository.

```bash
make init          # create .env + secrets/ skeleton
make oauth-info    # the exact redirect URI to register in Google Cloud
#                  ... fill in secrets/ and .env ...
make run           # validate, build, start, wait for healthy
make smoke         # prove login works and anonymous access is denied
```

---

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Docker Engine + Compose v2 | `docker compose version` must work |
| GNU Make 4.x | macOS ships 3.81 — `brew install make`, then use `gmake` |
| `openssl` | generates the break-glass password |
| A Google Cloud project | to create the OAuth client |
| A Google Workspace domain | to restrict who may log in |

## 2. Register the OAuth client in Google Cloud

1. **Google Cloud Console → APIs & Services → OAuth consent screen.** Choose
   **Internal** if your Workspace covers every intended user — it avoids Google's
   verification review and, more importantly, makes the app unreachable by
   accounts outside your organisation. Scopes needed: `email`, `profile`, `openid`.
2. **Credentials → Create credentials → OAuth client ID → Web application.**
3. Set the **Authorised redirect URI** to exactly:

   ```
   <JENKINS_URL>securityRealm/finishLogin
   ```

   For local evaluation that is `http://localhost:8080/securityRealm/finishLogin`.
   Run `make oauth-info` and copy the value it prints — it is derived the same
   way the plugin derives it at runtime, so it cannot disagree.

   Google accepts plain `http` **only** for `localhost`. Any other host must be
   `https`, and `make check-env` enforces that.
4. Copy the **Client ID** and **Client secret** into `secrets/` (step 3).

> **Redirect URI mismatches are the single most common failure.** The plugin
> builds the URI from Jenkins' own root URL (`JENKINS_URL`), not from the
> browser's address bar. If `JENKINS_URL` and the registered URI differ by so
> much as a trailing slash, scheme or port, Google returns
> `Error 400: redirect_uri_mismatch`.

## 3. Configure locally

```bash
make init
```

Creates (and never overwrites):

- `.env` — non-sensitive settings, from `.env.example`
- `secrets/google_oauth_client_id`, `secrets/google_oauth_client_secret` — **empty**, fill these in
- `secrets/recovery_admin_password` — random 24-byte break-glass password

Then fill in the two OAuth values and edit `.env`:

```bash
printf '%s' '1234-abc.apps.googleusercontent.com' > secrets/google_oauth_client_id
printf '%s' 'GOCSPX-...'                          > secrets/google_oauth_client_secret
chmod 600 secrets/*
```

Use `printf`, not `echo` — a trailing newline in a secret file is a confusing
class of bug. (JCasC trims it, but not every consumer does.)

Required in `.env`:

| Variable | Meaning |
|---|---|
| `JENKINS_URL` | Public root URL, **with trailing slash**. The OAuth redirect URI derives from it. |
| `JENKINS_ADMIN_EMAIL` | Google account granted `Overall/Administer`. |
| `GOOGLE_ALLOWED_DOMAINS` | Comma-separated Workspace domain allowlist. **Never leave empty.** |

## 4. Build and run

```bash
make run     # = validate + build + up + wait + oauth-info
make smoke   # assertions against the running controller
```

`make validate` runs first and refuses to start on any of these:

- a required variable unset, or still holding the placeholder domain
- `JENKINS_URL` without a trailing slash, or plain `http` off localhost
- `JENKINS_ADMIN_EMAIL` in a domain absent from `GOOGLE_ALLOWED_DOMAINS`
  (**this is the lockout case**: authentication succeeds, then no one holds
  `Overall/Administer`)
- a missing or empty secret file
- the pinned base-image digest having drifted between `Dockerfile`,
  `docker-compose.yml` and `.env.example`
- a secret or `.env` having become tracked by git

It warns, without blocking, on `gmail.com` in the allowlist (that is every
consumer Google account — effectively no restriction) and on secret files that
are group- or world-readable.

## 5. Everyday commands

```bash
make help              # every target
make logs              # follow controller logs
make audit             # only audit-trail entries: who did what
make ps / restart / down
make shell             # shell inside the container
make plugins-freeze    # pin running plugin versions -> plugins.lock.txt
make base-digest       # is the pinned base image still current?
make backup            # cold, consistent archive of JENKINS_HOME
make restore ARCHIVE=backups/<file>.tar.gz CONFIRM=yes
make nuke CONFIRM=yes  # delete container, image and all Jenkins data
```

---

## How the configuration works

`casc/jenkins.yaml` is applied by the Configuration as Code plugin on **every
boot**. A change made through the web UI survives only until the next restart.
That is deliberate: configuration drift is how a reviewed, compliant controller
quietly becomes an unreviewed one. To change behaviour, change the YAML and open
a pull request.

The config lives at `/var/jenkins_conf/casc` — outside `$JENKINS_HOME` — so the
persistent volume can never shadow or mutate it.

Values are resolved two ways, and the distinction matters:

| Form | Source | Use for |
|---|---|---|
| `${UPPER_CASE}` | environment variable | non-sensitive settings |
| `${lower_case}` | file at `/run/secrets/<name>` | secrets |

Secrets are Compose file-secrets, so they never appear in the image, in
`docker inspect`, or in `/proc/1/environ`.

### Repository layout

```
Dockerfile              controller image; base pinned by tag AND digest
plugins.txt             plugin set, resolved at build time (never at boot)
docker-compose.yml      runtime: file-secrets, hardening, limits, log rotation
Makefile                build/run/validate/operate
casc/jenkins.yaml       THE configuration: OAuth realm, authorisation, audit
casc-recovery/          break-glass local admin, used only on demand
config/logging.properties  single-line stdout logging
secrets/                gitignored runtime secrets (see secrets/README.md)
.env.example            documented settings template
```

---

## Security posture

The choices below are deliberate; each names the risk it addresses.

| Area | Control | Why |
|---|---|---|
| Broken access control (A01) | `domain` allowlist on the OAuth realm | Without it **any** Google account on the internet authenticates successfully. |
| Broken access control (A01) | Explicit `globalMatrix`; anonymous absent | Authentication is not authorisation. Anonymous holds no permission, not even read. |
| Broken access control (A01) | CSRF crumb issuer declared explicitly | On by default; declared so that removing it shows up in review. |
| Cryptographic failures (A02) | Secrets as files, not env vars | Keeps them out of `docker inspect`, `/proc/1/environ` and crash dumps. |
| Cryptographic failures (A02) | `https` enforced off localhost | The OAuth code and session cookie cross the network. |
| Misconfiguration (A05) | Setup wizard disabled + JCasC reapplied each boot | Configuration is reviewable and cannot drift. |
| Misconfiguration (A05) | `slaveAgentPort: -1`, no Docker socket mount | Closes an unused listener. Mounting `/var/run/docker.sock` is equivalent to granting host root to anyone who can define a build. |
| Misconfiguration (A05) | `cap_drop: ALL`, `no-new-privileges`, non-root uid 1000, loopback-only port | Least privilege at the container boundary. |
| Vulnerable components (A06) | Base image pinned by digest; `make base-digest`; `make plugins-freeze` | A tag is mutable; a digest is not. Upgrades become reviewed commits. |
| Identification failures (A07) | `disableRememberMe: true`, legacy API tokens disabled | Long-lived credentials on a system holding deployment secrets are not worth the convenience. |
| Logging failures (A09) | audit-trail plugin → stdout; bounded json-file driver | "Who changed what" evidence for access reviews and change management, with no unbounded disk growth. |

Controller executors default to **1** so the stack is useful immediately. In
production set `JENKINS_CONTROLLER_EXECUTORS=0` and attach agents: a build
running on the controller can read `JENKINS_HOME`, including the credential
store and the secret key that encrypts it.

### Concurrency and race conditions

- **Single writer on `JENKINS_HOME`.** Jenkins assumes exclusive ownership of
  its home directory; two controllers on one volume corrupt it. The fixed
  `container_name` makes a second instance fail fast on a name clash rather than
  start and quietly interleave writes. Never `docker compose up --scale`
  this service.
- **Mutating make targets take a lock.** `build`, `up`, `backup`, `restore` and
  `nuke` acquire `.make-lock/` via `mkdir`, which is atomic on POSIX
  filesystems. A concurrent invocation exits with a clear message instead of
  racing. If a run is killed hard, remove the directory: `rmdir .make-lock`.
- **`stop_grace_period: 60s`.** Jenkins flushes state on shutdown; a default
  10-second kill is how build records and plugin state get truncated.
- **Backups are cold.** `make backup` stops the container, archives, and
  restarts. Archiving a live `JENKINS_HOME` yields a crash-consistent copy that
  may restore into a broken state.
- **`.env` is parsed, never sourced.** Sourcing would execute the file's
  contents and would mis-handle valid values containing spaces.

### Locked out? Break-glass recovery

Because JCasC reapplies configuration on every boot, hand-editing `config.xml`
cannot rescue a broken login — the next restart overwrites it. Instead:

```bash
make recovery-up     # prints the local recovery-admin password, restarts with OAuth OFF
#                    ... fix casc/jenkins.yaml or .env ...
make recovery-down   # back to Google OAuth
make recovery-rotate # rotate the break-glass password after use
```

Recovery mode is never the default (it requires pointing
`CASC_JENKINS_CONFIG` at `casc-recovery/`), runs with zero executors and no
agent port, and every entry into it is visible in the container logs.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Error 400: redirect_uri_mismatch` | Registered URI ≠ `<JENKINS_URL>securityRealm/finishLogin` | `make oauth-info`, paste that value into Google Cloud verbatim |
| `Jenkins root url should not be null` | `JENKINS_URL` not applied | Check `unclassified.location.url` resolved; `make logs` |
| Login succeeds, then "access denied" | Authenticated but not authorised | `JENKINS_ADMIN_EMAIL` must match the Google account exactly; `make check-env` catches the domain case |
| Users outside your company can log in | `GOOGLE_ALLOWED_DOMAINS` empty or a public domain | Set real Workspace domains and `make restart` |
| Container never becomes healthy | JCasC rejected the config | `make logs` — JCasC names the offending key and line |
| A UI change disappeared after restart | Working as designed | Change `casc/jenkins.yaml` instead |
| `make: *** No rule to make target` on macOS | Make 3.81 | `brew install make` and use `gmake` |

---

## Production checklist

This repository is a correct, hardened starting point sized for evaluation on a
single host. Before it carries regulated workloads:

- [ ] Terminate TLS in front of Jenkins; set `JENKINS_URL` to the `https` URL
      and leave the published port on `127.0.0.1`
- [ ] `JENKINS_CONTROLLER_EXECUTORS=0`; run builds on dedicated agents
- [ ] Move secrets to Google Secret Manager or Vault (a CSI driver on GKE, or
      JCasC's Vault secret source) — files are a laptop-grade boundary
- [ ] `make plugins-freeze` and commit pinned plugin versions; schedule
      `make base-digest` and review upgrades as commits
- [ ] Ship stdout to Cloud Logging with retention that satisfies your audit
      period, and alert on `AUDIT` entries touching credentials
- [ ] Back up `JENKINS_HOME` off-host, **encrypted** — it contains the
      credential store and the key that decrypts it — and rehearse `make restore`
- [ ] Restrict the OAuth consent screen to Internal, and review who holds
      `Overall/Administer` on a schedule
- [ ] Consider `read_only: true` on the container with a tmpfs for `/tmp`
      (verify plugin compatibility first)

## Verification status

Every JCasC key here was checked against the plugins' own source rather than
written from memory — `googleOAuth2` (`clientId`/`clientSecret`/`domain`), the
`securityRealm/finishLogin` callback path, `globalMatrix.entries` with
`user`/`group` children, `audit-trail` with its `console` logger, and JCasC's
`/run/secrets/<name>` file-secret resolution. The base image digest was resolved
from Docker Hub and matches tag `2.568.3-lts-jdk21`.

The YAML and Makefile parse, and the preflight guards were executed against
valid and invalid inputs. **The image build and Jenkins boot were not executed**,
because no Docker daemon was available in the environment where this was
authored. Run `make run && make smoke` once; if JCasC rejects a key it fails
fast at boot and names it in `make logs`.
