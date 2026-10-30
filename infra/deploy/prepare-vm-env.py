#!/usr/bin/env python3
import json
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import quote

env_file = Path("/opt/sprintsmith/.env")
compose_file = Path("/opt/sprintsmith/infra/deploy/compose.production.yaml")
lines = env_file.read_text().splitlines()
values = {
    line.split("=", 1)[0]: line.split("=", 1)[1]
    for line in lines
    if "=" in line and not line.lstrip().startswith("#")
}
needs_database_urls = any(
    not values.get(key, "").strip()
    or any(
        marker in values[key].lower()
        for marker in ("replace-with", "change_me", "your_")
    )
    for key in ("BACKEND_DATABASE_URL", "AI_DATABASE_URL")
)

if not needs_database_urls:
    print("Database URLs are already configured.")
    raise SystemExit(0)

compose = subprocess.run(
    [
        "docker",
        "compose",
        "--env-file",
        str(env_file),
        "-f",
        str(compose_file),
        "config",
        "--format",
        "json",
    ],
    check=True,
    capture_output=True,
    text=True,
)
database = json.loads(compose.stdout)["services"]["db"]["environment"]
user = str(database["POSTGRES_USER"])
password = str(database["POSTGRES_PASSWORD"])
name = str(database["POSTGRES_DB"])
if not all((user, password, name)) or any(
    marker in value.lower()
    for value in (user, password, name)
    for marker in ("replace-with", "change_me", "your_")
):
    raise SystemExit("Cannot derive database URLs: PostgreSQL settings are incomplete.")

url = (
    f"postgresql+psycopg://{quote(user, safe='')}:{quote(password, safe='')}"
    f"@db:5432/{quote(name, safe='')}"
)
updates = {
    "BACKEND_DATABASE_URL": url,
    "AI_DATABASE_URL": url,
}
keys = {line.split("=", 1)[0] for line in lines if "=" in line}
if not set(updates).issubset(keys):
    raise SystemExit("Cannot derive database URLs: required .env entries are missing.")

updated = [
    f"{key}='{updates[key]}'" if (key := line.split("=", 1)[0]) in updates else line
    for line in lines
]
with tempfile.NamedTemporaryFile(
    "w", encoding="utf-8", dir=env_file.parent, delete=False
) as temporary:
    temporary.write("\n".join(updated) + "\n")
    temporary_path = Path(temporary.name)
temporary_path.chmod(0o600)
temporary_path.replace(env_file)
print("Generated database URLs from the existing PostgreSQL settings.")
