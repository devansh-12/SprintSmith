# One-time GCP setup for backend deployments

This configures the permissions and resources used by
[`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml). Run the
commands as a project owner or another administrator authorized to change IAM
in `major-project-512815`. They are not run by GitHub Actions.

## Project resources and IAM

The deployment uses:

- Cloud Build in `us-central1` to build both backend images.
- Artifact Registry repository `sprintsmith-repo` in `us-central1`.
- The existing GitHub deployment service account:
  `sprintsmith-github-deploy@major-project-512815.iam.gserviceaccount.com`.
- The existing `sprintsmith-backend` Compute Engine VM and its attached service
  account.

Run this once in Cloud Shell or from an authenticated machine. It enables the
required APIs, grants the deployment and build identities the roles needed for
this pipeline, creates the staging bucket and Artifact Registry repository if
needed, and grants the VM identity read access to images:

```bash
set -euo pipefail

PROJECT_ID=major-project-512815
REGION=us-central1
DEPLOY_SA="sprintsmith-github-deploy@${PROJECT_ID}.iam.gserviceaccount.com"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
BUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
BUCKET="gs://${PROJECT_ID}_cloudbuild"

gcloud services enable \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  serviceusage.googleapis.com \
  --project "$PROJECT_ID"

gcloud iam service-accounts describe "$DEPLOY_SA" --project "$PROJECT_ID" >/dev/null || \
  gcloud iam service-accounts create sprintsmith-github-deploy \
    --display-name="SprintSmith GitHub deployment" \
    --project "$PROJECT_ID"

for role in \
  roles/cloudbuild.builds.editor \
  roles/serviceusage.serviceUsageConsumer \
  roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEPLOY_SA}" \
    --role="$role" \
    --condition=None \
    --quiet >/dev/null
done

gcloud storage buckets describe "$BUCKET" --project "$PROJECT_ID" >/dev/null 2>&1 || \
  gcloud storage buckets create "$BUCKET" \
    --project "$PROJECT_ID" \
    --location "$REGION" \
    --uniform-bucket-level-access

for sa in "$DEPLOY_SA" "$BUILD_SA" "$COMPUTE_SA"; do
  for role in roles/storage.legacyBucketReader roles/storage.objectAdmin; do
    gcloud storage buckets add-iam-policy-binding "$BUCKET" \
      --member="serviceAccount:${sa}" \
      --role="$role" \
      --project "$PROJECT_ID" >/dev/null
  done
done

gcloud artifacts repositories describe sprintsmith-repo \
  --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1 || \
  gcloud artifacts repositories create sprintsmith-repo \
    --repository-format=docker \
    --location "$REGION" \
    --description="SprintSmith images" \
    --project "$PROJECT_ID"

for sa in "$BUILD_SA" "$COMPUTE_SA"; do
  gcloud artifacts repositories add-iam-policy-binding sprintsmith-repo \
    --location "$REGION" \
    --member="serviceAccount:${sa}" \
    --role="roles/artifactregistry.writer" \
    --project "$PROJECT_ID" >/dev/null
done

VM_SA="$(gcloud compute instances describe sprintsmith-backend \
  --zone us-central1-a \
  --project "$PROJECT_ID" \
  --format='value(serviceAccounts[0].email)')"
gcloud artifacts repositories add-iam-policy-binding sprintsmith-repo \
  --location "$REGION" \
  --member="serviceAccount:${VM_SA}" \
  --role="roles/artifactregistry.reader" \
  --project "$PROJECT_ID" >/dev/null
```

The deployment service account has:

- `roles/cloudbuild.builds.editor`
- `roles/serviceusage.serviceUsageConsumer`
- `roles/iam.serviceAccountUser`
- `roles/storage.legacyBucketReader` and `roles/storage.objectAdmin` on the Cloud Build staging bucket

The Cloud Build execution service account has the same two bucket roles and
`roles/artifactregistry.writer` on the repository. The VM's attached service
account has `roles/artifactregistry.reader` on the repository.

Create `sprintsmith-repo` as a Docker-format Artifact Registry repository in
`us-central1` if it does not already exist. The script grants permissions to
the legacy Cloud Build and Compute Engine default service accounts; if the
project uses a different Cloud Build execution service account, grant that
identity the same bucket and repository roles.

## GitHub OIDC

Configure Workload Identity Federation for this repository and grant its
GitHub identity permission to impersonate the deployment service account.
Set the repository Actions variable `GCP_WORKLOAD_IDENTITY_PROVIDER` to the
full provider resource name, for example:

```text
projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID/providers/PROVIDER_ID
```

The workflow uses GitHub's OIDC token and does not require a service-account
JSON key. Restrict the provider condition to this repository and the intended
branch/environment.

## VM prerequisites

The backend rollout still connects to the VM over SSH. Configure the
`BACKEND_HOST`, `BACKEND_USER`, and `BACKEND_SSH_KEY` GitHub secrets as
described in [the deployment guide](./deployment.md).

Attach a service account with Artifact Registry read access to
`sprintsmith-backend`, enable the `cloud-platform` OAuth scope for that VM, and
install Docker Compose and the Google Cloud CLI on the VM. The workflow runs
`gcloud auth configure-docker us-central1-docker.pkg.dev` on the VM before
pulling the images.

## Verification

After setup, this should show the deployment account's project roles:

```bash
gcloud projects get-iam-policy major-project-512815 \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:sprintsmith-github-deploy@major-project-512815.iam.gserviceaccount.com" \
  --format="table(bindings.role)"
```

Then set the repository Actions variable `BACKEND_DEPLOY_ENABLED` to `true`
and run **Actions > Production Deployment > Run workflow**.
