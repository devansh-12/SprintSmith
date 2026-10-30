# SprintSmith v2

Provider-neutral enterprise search and RAG platform. The current foundation is
Dockerized, observable, and ready for the ingestion and hybrid retrieval slices.
The first product surface is enterprise search, with contracts that can later
provide context to an agent runtime.

## Quick start

Requirements: Docker Engine with Compose, Python 3.13+, and `uv` for local
quality checks.

```bash
uv sync --extra dev
docker compose up -d --build
docker compose ps
```

For the complete application, including the integrated backend gateway and AI
engine, use the `core` profile:

```bash
make up-core
make test
make smoke
make logs
```

This starts the platform API on `8000`, AI engine on `8001`, integrated backend
gateway on `8002`, PostgreSQL on `5433`, Prometheus on `9090`, and Grafana on
`3000`. The AI engine image is intentionally large because it includes Docling
and document models. Swagger is available at
[localhost:8002/docs](http://localhost:8002/docs) for the integrated backend
and [localhost:8000/docs](http://localhost:8000/docs) for the platform API.

Check the running API:

```bash
curl http://localhost:8000/health
curl http://localhost:8000/ready
curl http://localhost:8000/metrics
curl -X POST http://localhost:8000/v1/search \
	-H 'content-type: application/json' \
	-d '{"query":"retention policy","top_k":10}'
```

Stop the local stack without deleting persisted volumes:

```bash
docker compose down
```

To remove local PostgreSQL, Prometheus, and Grafana data as well:

```bash
docker compose down -v
```

## Repository shape

- `apps/api`: HTTP boundary and API contracts
- `apps/worker`: asynchronous ingestion boundary
- `packages`: future domain, retrieval, provider, and observability libraries
- `infra/docker`: service images
- `tests`: executable contracts and integration tests
- `.github/workflows`: CI checks
- `backend-core`: integrated production backend and AI engine

The backend is intentionally split into two deployable boundaries inside this
monorepo: `apps/api` owns HTTP contracts and `apps/worker` will own asynchronous
ingestion. Shared domain, retrieval, provider, and observability packages will
be added under `packages/` as their contracts stabilize. A frontend is reserved
for later work and is not included yet.

## What is implemented

- FastAPI service with health, readiness, metrics, and initial search endpoints
- Request IDs and structured JSON request/service logs
- Prometheus request counters and latency histograms
- Separate worker container boundary
- PostgreSQL 17 with `pgvector` image, exposed locally on port `5433`
- Prometheus scraping the API on the internal Compose network
- Grafana datasource and `SprintSmith API` dashboard provisioning
- Non-root API and worker Docker images
- GitHub Actions workflow for dependency installation, Ruff, pytest, and Compose validation
- Reproducible Python dependency lockfile through `uv.lock`
- Integrated DevPilot backend gateway with auth, projects, requirements, artifacts, generation, evaluation, exports, audit, and traceability APIs
- Integrated DevPilot AI engine with async ingestion, hybrid/vector retrieval, generation, streaming, comparison, prompts, and offline evaluation

The supplied DOCX and ZIP are reference material only. They are not imported
as runtime dependencies. Do not commit extracted contents, secrets, raw
document text, or unrestricted prompts.

## Local URLs

Open these addresses in a browser while the stack is running:

| Component | URL | Purpose |
| --- | --- | --- |
| API health | [localhost:8000/health](http://localhost:8000/health) | Liveness response |
| API readiness | [localhost:8000/ready](http://localhost:8000/ready) | Readiness response |
| API metrics | [localhost:8000/metrics](http://localhost:8000/metrics) | Prometheus exposition format |
| API documentation | [localhost:8000/docs](http://localhost:8000/docs) | Interactive OpenAPI UI |
| Prometheus | [localhost:9090](http://localhost:9090) | Queries, targets, and time series |
| Prometheus targets | [localhost:9090/targets](http://localhost:9090/targets) | Confirm scrape status is `UP` |
| Grafana | [localhost:3000](http://localhost:3000) | Local dashboards, anonymous viewer access |
| Grafana dashboard | [SprintSmith API dashboard](http://localhost:3000/d/sprintsmith-api/sprintsmith-api) | Request rate, p95 latency, response status |
| Integrated backend docs | [localhost:8002/docs](http://localhost:8002/docs) | Frontend-facing DevPilot OpenAPI UI when the `core` profile is running |
| AI engine docs | [localhost:8001/docs](http://localhost:8001/docs) | Internal RAG/generation API when the `core` profile is running |

Grafana is configured for local viewing only. It has anonymous viewer access
and must not be exposed publicly without authentication and network controls.

## Logs and operational checks

Follow all application and observability logs in one terminal:

```bash
docker compose logs -f --tail=100 api worker db prometheus grafana
```

Follow only the API and worker logs:

```bash
docker compose logs -f --tail=100 api worker
```

Check container health and Prometheus targets:

```bash
docker compose ps
curl http://localhost:9090/api/v1/targets
curl http://localhost:3000/api/health
```

The expected Prometheus target jobs are `prometheus` and `sprintsmith-api`,
both with health `up`.

## Integrated backend core

The integrated `backend-core` services are connected as an opt-in
Compose profile. The default stack stays lightweight; start the complete core
stack only after installing its dependencies and providing runtime secrets:

```bash
docker compose --profile core up -d --build
curl http://localhost:8002/health
curl http://localhost:8001/health
```

The core backend uses port `8002` so it does not collide with the SprintSmith
platform API on `8000`. The AI engine uses `8001`. Both use the Compose
PostgreSQL service and the shared `core_uploads` volume. The AI image is large
because Docling and its document models are included; this is why it is not in
the default local startup path.

The frontend endpoint catalog is maintained in
[docs/frontend-api.md](docs/frontend-api.md). The interactive contract is also
available at [localhost:8002/docs](http://localhost:8002/docs) after the core
profile starts.

## Cloudflare and hosting

Local Docker is the development and integration environment, not the public
hosting target. The production shape is:

```text
frontend hosting -> Cloudflare DNS/proxy -> GCE VM (Caddy HTTPS)
                                      -> backend-core API
                                      -> private AI engine
                                      -> private PostgreSQL/pgvector
```

The GCP deployment uses `sprintsmith-api.rajmathuria.me` for the backend API
and `app.rajmathuria.me` for the frontend. Keep any existing
`api.rajmathuria.me` service and `portfolio.rajmathuria.me` unchanged. Point
the SprintSmith API hostname at the GCE VM's reserved external IP and add the
frontend hostname as a Cloudflare Worker custom domain. Cloudflare provides
DNS/proxy while Caddy on the VM terminates HTTPS and renews the origin
certificate. The database and AI engine are not exposed publicly.

Deploy from an authenticated Google Cloud CLI session with:

```bash
bash infra/deploy/deploy-gcp.sh
```

Application secrets remain in `/opt/sprintsmith/.env` on the VM and are never
uploaded with the Cloud Build source. No credentials belong in this repository.

The complete deployment runbook is in [docs/deployment.md](docs/deployment.md).
The five GitHub Actions workflows all start on every push. The production
workflow runs deployment jobs only on `main`, uses GitHub OIDC
Workload Identity Federation to build and deploy through GCP, and deploys the
frontend after the backend when `DEPLOY_FRONTEND=true`.

## Local checks

```bash
uv sync --extra dev
uv run ruff check .
uv run pytest -q
docker compose config
git diff --check
```

The GitHub Actions workflows run on every push and on pull requests. View
results at the repository's GitHub Actions page:
[github.com/CodeCraftsmanRaj/SprintSmith/actions](https://github.com/CodeCraftsmanRaj/SprintSmith/actions).

The `CI` workflow owns root unit tests and linting. The `Full Stack Platform`
workflow validates Compose, starts the platform services, and runs the API
smoke test. The backend-core and AI-engine workflows run their dedicated
suites separately.

The root workflows also run the integrated backend-core suites when their
paths change:

- `DevPilot Backend Core`: backend tests, coverage, Alembic migration, and PostgreSQL integration tests
- `DevPilot AI Engine`: keyless offline AI-engine tests with dependency/model caching

## Local services

Docker must be running for the full stack:

```bash
docker compose up --build
curl http://localhost:8000/health
curl http://localhost:8000/ready
```

## Current limitations and next slice

`POST /v1/search` currently validates the hybrid-search contract and returns an
empty result list. The following production features are intentionally next:

1. Database migrations and typed document/chunk/ingestion-job models.
2. DOCX and other document ingestion with idempotent asynchronous jobs.
3. PostgreSQL full-text retrieval plus `pgvector` semantic retrieval.
4. Reciprocal-rank fusion, citations, retrieval evaluation, and regression gates.
5. Authentication, tenant isolation, rate limits, retention, backups, and alerts.
6. Cloud deployment through GitHub OIDC after the free-tier runtime is selected.

No cloud credentials or DNS changes are required for the current local stack.
The existing `portfolio.rajmathuria.me` host is not changed by this project.

## Reference artifacts

The supplied DOCX and ZIP are authorized reference material for local
inspection, but are ignored by Git and are not imported as runtime dependencies.
Do not commit extracted contents, secrets, raw document text, or unrestricted
prompts. The current platform does not transmit their contents to an external
model provider.
