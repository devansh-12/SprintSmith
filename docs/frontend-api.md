# Frontend API Contract

The frontend should use the integrated backend gateway at
`http://localhost:8002` during local development. Start it with:

```bash
docker compose --profile core up -d --build
```

In production this should be
`https://sprintsmith-api.rajmathuria.me`. The AI engine at port `8001` is an
internal service and should not be called directly by the browser.

All protected routes use `Authorization: Bearer <access_token>`.

## Backend gateway endpoints

### Health and metadata

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Backend liveness |
| GET | `/health/db` | Database health |
| GET | `/health/ai` | AI engine connectivity |
| GET | `/api/v1/artifact-types` | Supported generated artifact types |

### Authentication

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/api/v1/auth/register` | Register a member account |
| POST | `/api/v1/auth/login` | Obtain a bearer token |
| GET | `/api/v1/auth/me` | Get the current user |

### Projects and access

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/v1/projects` | List accessible projects |
| POST | `/api/v1/projects` | Create a project |
| GET | `/api/v1/projects/{project_id}` | Get a project |
| PATCH | `/api/v1/projects/{project_id}` | Update a project |
| DELETE | `/api/v1/projects/{project_id}` | Delete a project |
| POST | `/api/v1/projects/{project_id}/members?email=&role=` | Add a project member |

### Requirements and ingestion

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/api/v1/projects/{project_id}/requirements` | Upload a requirement document; returns `202` and an ingestion job |
| GET | `/api/v1/projects/{project_id}/requirements` | List project requirements |
| GET | `/api/v1/requirements/{requirement_id}` | Get one requirement |
| GET | `/api/v1/ingest-jobs/{job_id}` | Poll ingestion status until `done` or `failed` |

### Generation and retrieval

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/api/v1/projects/{project_id}/generate` | Generate a structured SDLC artifact |
| POST | `/api/v1/projects/{project_id}/generate/stream` | Stream generation progress as SSE |
| POST | `/api/v1/projects/{project_id}/compare` | Compare default and fallback models |
| GET | `/api/v1/projects/{project_id}/history` | List generation history and telemetry |
| GET | `/api/v1/projects/{project_id}/traceability` | React Flow-compatible traceability graph |

### Artifacts and evaluation

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/v1/projects/{project_id}/artifacts` | List project artifacts |
| GET | `/api/v1/artifacts/{artifact_id}` | Get an artifact |
| PATCH | `/api/v1/artifacts/{artifact_id}` | Update an artifact |
| GET | `/api/v1/artifacts/{artifact_id}/export?format=json\|markdown\|csv\|yaml` | Export an artifact |
| POST | `/api/v1/artifacts/{artifact_id}/evaluations` | Submit artifact evaluation |
| GET | `/api/v1/artifacts/{artifact_id}/evaluations` | List artifact evaluations |

### Administration

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/v1/audit-logs` | List audit records; admin only |
| POST | `/api/v1/evaluate/batch?retrieval_mode=vector\|hybrid` | Run evaluation batch; admin only |

## AI engine internal endpoints

The gateway proxies the browser-safe workflows. These routes are listed for
backend/platform integration and should remain private:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | AI engine health |
| GET | `/artifact-types` | Engine artifact types |
| POST | `/ingest` | Start asynchronous ingestion |
| GET | `/ingest/{job_id}` | Poll engine ingestion |
| POST | `/generate` | Generate an artifact |
| POST | `/generate/stream` | Stream generation node events |
| POST | `/generate/compare` | Compare configured models |
| POST | `/evaluate/batch` | Run offline retrieval evaluation |

## Frontend integration sequence

1. Register or log in and store the returned access token securely.
2. Create/select a project.
3. Upload a requirement and poll the returned ingestion job.
4. Generate an artifact after ingestion completes.
5. Render `output`, `eval_score`, `retry_count`, `model_used`, `usage`, and `latency_ms`.
6. Use the export, history, evaluation, and traceability endpoints for the project workspace.

Do not send model keys, database URLs, JWT signing secrets, or direct AI-engine
requests from the browser.