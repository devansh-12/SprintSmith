# Production Deployment

## Backend deployment

- Frontend: Cloudflare Workers deployment from `frontend/`.
- Backend: Google Compute Engine VM `sprintsmith-backend` in `us-central1-a`.
- Database: PostgreSQL/pgvector in the private Docker Compose network on the VM.
- Registry: Google Artifact Registry repository `devpilot-repo` in `us-central1`.
- DNS/TLS: Cloudflare DNS and proxy.

Cloudflare cannot host the Dockerized PostgreSQL, worker, and AI-engine stack directly. The backend VM is required. Free-tier availability, billing verification, storage, and resource limits can change, so confirm them in the provider account before production use.

## Current deployed state

- GCP project: `major-project-512815`
- VM: `sprintsmith-backend`, zone `us-central1-a`
- Reserved external IP: `34.9.97.6`
- API: `https://sprintsmith-api.rajmathuria.me`
- Frontend hostname: `app.rajmathuria.me`
- Existing `api.rajmathuria.me` and `portfolio.rajmathuria.me` are separate
  hostnames and must not be changed for this deployment.
- The Compose services are `backend-core`, `ai-engine`, `db`, and `caddy`.
  The backend binds to loopback port `8002`; only Caddy's ports 80/443 are
  public. The AI engine and database are private.

The backend and AI engine have been deployed. The API's `/health`, `/health/db`,
`/health/ai`, and `/docs` have returned HTTP 200 on the VM, and the public API
health endpoint has been verified over HTTPS. Provider keys are stored in the
VM's `/opt/sprintsmith/.env`; never print or commit that file.

## One-time backend VM setup

```bash
gcloud compute instances describe sprintsmith-backend \
  --project major-project-512815 \
  --zone us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

The VM already has Docker Compose and `/opt/sprintsmith/.env`. The VM does
**not** need a Git checkout. GitHub Actions uses Workload Identity Federation
to authenticate to GCP without a service-account key, runs Cloud Build, and
updates the containers over OS Login. No `BACKEND_HOST`, SSH private key, or
GHCR pull token is needed.

For non-interactive deployments, the OS Login user used by GitHub Actions must
own `/opt/sprintsmith` and be able to run Docker without `sudo`. On the VM,
run this one-time setup as an administrator, replacing the placeholder with
the OS Login username used by the deployment:

```bash
DEPLOY_USER=your_os_login_username
sudo usermod -aG docker "$DEPLOY_USER"
sudo chown -R "$DEPLOY_USER" /opt/sprintsmith
sudo chmod 600 /opt/sprintsmith/.env
```

Find the OS Login username with
`gcloud compute ssh sprintsmith-backend --zone=us-central1-a --command='id -un'`.
Reconnect after adding the user to the Docker group so the new group membership
takes effect. Verify `docker info` and that the user can write
`/opt/sprintsmith/.env` before retrying deployment. Docker group membership is
effectively root access, so grant it only to a trusted deployment account.

## Verify a GCE deployment

Find the VM's current external IP in Google Cloud Console under **Compute
Engine > VM instances**, or run:

```bash
gcloud compute instances describe sprintsmith-backend \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

Check deployment state and the backend from the VM:

```bash
gcloud compute ssh sprintsmith-backend --zone=us-central1-a \
  --command='cd /opt/sprintsmith && docker compose --env-file .env -f infra/deploy/compose.production.yaml ps'

gcloud compute ssh sprintsmith-backend --zone=us-central1-a \
  --command='curl --fail http://localhost:8002/health'
```

The production Compose stack binds the backend gateway to loopback on port
`8002` for VM-local health checks. Caddy serves HTTPS at
`https://sprintsmith-api.rajmathuria.me`; the AI engine and database remain
private to the Compose network. The separate platform API on port `8000` is
not part of this production stack. GCP ingress should allow only ports `80`
and `443` for the VM's `sprintsmith-backend` network tag (plus the separately
managed SSH rule).

## GCP-native manual build and deploy

From a local checkout, with `gcloud` authenticated to the target project,
deploy the current commit with:

```bash
gcloud config set project major-project-512815
bash infra/deploy/deploy-gcp.sh
```

The script submits the backend and AI-engine Docker builds to Cloud Build,
pushes commit-tagged images to Artifact Registry, copies the Compose, Caddy,
and database initialization files to the VM, updates only the image tags in
the VM `.env`, then restarts the stack and checks health. It uses
`sprintsmith-api.rajmathuria.me` as the API host. The VM service account must have
Artifact Registry Reader access and an access scope that allows Artifact
Registry authentication.

If a build succeeds but the VM rollout needs to be retried, reuse the published
tag without rebuilding:

```bash
SKIP_BUILD=true GCP_IMAGE_TAG=<published-image-tag> bash infra/deploy/deploy-gcp.sh
```

The VM's reserved external IP is `34.9.97.6`. Keep any existing
`api.rajmathuria.me` DNS record unchanged. In Cloudflare DNS, create a separate
`sprintsmith-api` A record pointing to `34.9.97.6`; remove any stale manually
configured AAAA record for `sprintsmith-api`. Initially set the record to
**DNS only** so Caddy can obtain its origin HTTPS certificate. After
`https://sprintsmith-api.rajmathuria.me/health` works, optionally enable the
Cloudflare proxy and set SSL/TLS encryption to **Full (strict)**. Caddy
automatically retries certificate issuance; ports 80/443 must be open.
The deployment command checks the public API hostname and reports the DNS/TLS
prerequisite if local health succeeds but the public route does not.

## DNS

Keep existing `api.rajmathuria.me` and `portfolio.rajmathuria.me` unchanged.
Add separate SprintSmith hostnames:

- `sprintsmith-api.rajmathuria.me`: A record to the backend VM (`34.9.97.6`)
- `app.rajmathuria.me`: Cloudflare Worker custom domain

Set `CORS_ORIGINS=https://app.rajmathuria.me` in the VM `.env`. The GitHub
Actions frontend workflow builds with
`VITE_API_URL=https://sprintsmith-api.rajmathuria.me`.

## Deploy the frontend manually

The repo's `frontend/wrangler.jsonc` config attaches
`app.rajmathuria.me` as a Worker custom domain. From `frontend/`, confirm
Wrangler is logged into the Cloudflare account that owns the active
`rajmathuria.me` zone, then build and deploy:

```bash
npx wrangler whoami
npm ci
VITE_API_URL=https://sprintsmith-api.rajmathuria.me npm run build
npx wrangler login # only if whoami shows the wrong account or no login
npx wrangler deploy
```

Cloudflare creates/updates the Worker's custom-domain DNS and certificate.
Do not add a manual A record for `app`, and leave the existing
`api.rajmathuria.me` record untouched. Verify the API at
`https://sprintsmith-api.rajmathuria.me/health` and the frontend at
`https://app.rajmathuria.me`.

## GitHub Actions pipelines

All five workflows start on every branch push:

1. `CI`: root lint and unit tests.
2. `Full Stack Platform`: both Compose profiles, stack startup, and smoke test.
3. `DevPilot Backend Core`: backend unit, repository, migration, and PostgreSQL integration tests.
4. `DevPilot AI Engine`: offline AI-engine tests.
5. `Production Deployment`: the workflow starts on each branch push; production
   deployment jobs run only for `main`.

The CI and full-stack workflows intentionally have separate responsibilities:
CI runs the root lint and unit tests; Full Stack validates Compose, starts the
stack, and smoke-tests the API. Backend-core and AI-engine tests are separate
pipelines. There is one production deploy workflow; the old GHCR deploy path
has been removed to avoid deploying the same backend twice.

The production workflow deploys backend and AI-engine images through Cloud
Build and Artifact Registry using the repository-restricted GCP Workload
Identity Federation provider. It does not use GHCR or long-lived GCP keys.
Backend deployment runs automatically after a push to `main`. The Cloudflare
frontend job runs after a successful backend deployment only when the
repository Actions variable `DEPLOY_FRONTEND` is exactly `true`.

### Configure GitHub for frontend deployment

The GCP Workload Identity pool/provider and deployment service account are
already configured for `CodeCraftsmanRaj/SprintSmith` on `main`; the workflow
uses the provider and account directly. No GCP JSON key or additional GitHub
GCP secret is required. The deploy service account has build permissions and
bucket-scoped `roles/storage.legacyBucketWriter` and
`roles/storage.objectViewer` access to the Cloud Build staging bucket
`gs://major-project-512815_cloudbuild`. The writer role permits source upload;
the viewer role permits reading staged source objects.

In the repository's **Settings > Secrets and variables > Actions**, add the
following secrets (repository-level or `production` environment-level):

- `CLOUDFLARE_API_TOKEN`: token with permission to deploy the Worker.
- `CLOUDFLARE_ACCOUNT_ID`: the Cloudflare account identifier.

Then add the repository Actions variable:

- Name: `DEPLOY_FRONTEND`
- Value: `true`

The frontend job builds with `VITE_API_URL=https://sprintsmith-api.rajmathuria.me`
and deploys the Worker named `sprintsmith-frontend`. The Wrangler config
attaches `app.rajmathuria.me` as a custom domain and Cloudflare creates the DNS
record and certificate. The Cloudflare account used by Wrangler must own the
active `rajmathuria.me` zone. Do not create a manual A record for the Worker
hostname. Keep existing `api.rajmathuria.me` unchanged.

All pushes, including collaborator pushes to feature branches, run the five
workflow checks. Production deployment is intentionally restricted to
`main`: merge or push reviewed changes to `main` to update the live backend
and, when enabled, frontend. Feature-branch pushes do not replace production.

### Push and monitor a deployment

Commit and push the changes to the `main` branch to run all five workflows and
deploy the backend:

```bash
git status --short
git add .gcloudignore .github/workflows README.md docs infra/deploy infra/db/init.sql
git commit -m "Configure GCP deployment pipeline"
git push origin main
```

Check **GitHub > CodeCraftsmanRaj/SprintSmith > Actions**. Confirm that the
five workflow runs started for the push. In `Production Deployment`, wait for
`Build and deploy backend to GCP` to finish; when `DEPLOY_FRONTEND=true`, the
Cloudflare Worker deployment follows that job.

If a deployment attempt failed before Cloud Build started because the GitHub
deploy identity could not access the staging bucket, the bucket-scoped
permission is configured. Rerun **Production Deployment** on `main` from
**Actions > Production Deployment > Run workflow**; no source changes are
needed for that IAM fix.

Verify the live endpoints:

```bash
curl --fail https://sprintsmith-api.rajmathuria.me/health
curl --fail https://sprintsmith-api.rajmathuria.me/health/db
curl --fail https://sprintsmith-api.rajmathuria.me/health/ai
```

Open `https://sprintsmith-api.rajmathuria.me/docs` and, after configuring the
Worker custom domain, `https://app.rajmathuria.me`.

If frontend deployment is not ready yet, leave `DEPLOY_FRONTEND` unset or set
it to `false`; backend deployment still runs on `main`. To manually retry a
failed deployment, use **Actions > Production Deployment > Run workflow** on
`main`. Local build/deploy remains available with
`bash infra/deploy/deploy-gcp.sh`.

## Constraints

- No cloud credentials or service-account keys are stored in this repository.
- The AI-engine image is large and CPU-heavy because it includes Docling and document models.
- Free hosting is quota-based and may require payment verification.
- Configure backups, monitoring retention, and model API limits before real user data.
