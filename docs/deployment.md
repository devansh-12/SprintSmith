# Production Deployment

## Backend deployment

- Frontend: Cloudflare Workers deployment from `frontend/`.
- Backend: a Docker-capable VM (for example, Google Compute Engine).
- Database: PostgreSQL/pgvector on the same VM initially.
- Builds and registry: Google Cloud Build and Artifact Registry.
- DNS/TLS: Cloudflare DNS and proxy.

Cloudflare cannot host the Dockerized PostgreSQL, worker, and AI-engine stack directly. The backend VM is required. Free-tier availability, billing verification, storage, and resource limits can change, so confirm them in the provider account before production use.

## One-time backend VM setup

Create a Linux VM with an attached service account, install Docker Compose and
the Google Cloud CLI, open only SSH and HTTPS, then run:

```bash
sudo mkdir -p /opt/sprintsmith/infra/deploy
sudo chown -R "$USER":"$USER" /opt/sprintsmith
```

Copy `infra/deploy/.env.production.example` to `/opt/sprintsmith/.env` and replace every placeholder. Never commit that file.

Grant the VM's attached service account `roles/artifactregistry.reader` on the
`sprintsmith-repo` repository, and ensure the VM has the `cloud-platform` OAuth
scope. The deployment configures Docker's Artifact Registry credential helper
on the VM before pulling images.

The workflow builds and publishes commit-tagged images with Cloud Build, then
deploys the backend to the VM over SSH. Configure the repository Actions
variable `GCP_WORKLOAD_IDENTITY_PROVIDER` with the full Workload Identity
Provider resource name for the GitHub identity pool. The workflow authenticates
as `sprintsmith-github-deploy@major-project-512815.iam.gserviceaccount.com`
using GitHub OIDC; no service-account key is stored in GitHub.

Configure these GitHub repository secrets (or `production` environment secrets
if that environment is configured for both publishing and deployment):

- `BACKEND_HOST`: VM public hostname or IP
- `BACKEND_USER`: SSH deployment user
- `BACKEND_SSH_KEY`: private SSH key

Set the repository Actions variable `BACKEND_DEPLOY_ENABLED` to `true` only after `BACKEND_HOST`,
`BACKEND_USER`, and `BACKEND_SSH_KEY` are configured and the VM is prepared.
The frontend job is skipped unless the repository Actions variable
`DEPLOY_FRONTEND` is exactly `true`.

The one-time project IAM and API setup is described in
[docs/gcp-setup-for-owner.md](./gcp-setup-for-owner.md). It must be completed
by someone with permission to administer IAM in `major-project-512815`.

## DNS

Keep `portfolio.rajmathuria.me` unchanged. Add separate records:

- `api.rajmathuria.me`: proxied record to the backend VM
- `app.rajmathuria.me`: Cloudflare Worker hostname, or use the generated `workers.dev` hostname first

Add the API hostname to `CORS_ORIGINS` in the VM `.env`. The frontend receives the same value as `VITE_API_URL` through `PUBLIC_API_URL`.

## Deployment pipeline

Every push to `main` runs `.github/workflows/deploy.yml`. Backend image publishing and VM deployment happen when the repository Actions variable `BACKEND_DEPLOY_ENABLED` is exactly `true`; the frontend job is skipped unless `DEPLOY_FRONTEND` is exactly `true`.

1. Submit `infra/gcp/cloudbuild.yaml` to Cloud Build to build and publish backend-core and AI-engine images to Artifact Registry.
2. SSH to the VM, pull immutable commit-tagged images, run migrations, and restart the backend stack.
3. Check `/health` on the deployed backend.
4. The frontend deploy job is skipped unless `DEPLOY_FRONTEND` is set to `true`.

The workflow is also available through **Actions > Production Deployment > Run workflow**. The first deployment should be approved through the GitHub `production` environment.

## Constraints

- No cloud credentials are stored in this repository.
- The AI-engine image is large and CPU-heavy because it includes Docling and document models.
- Free hosting is quota-based and may require payment verification.
- Configure backups, monitoring retention, and model API limits before real user data.
