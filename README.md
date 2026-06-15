# dbt — Bitcoin Cash transformations

A dbt-core project that turns the public Bitcoin Cash blockchain dataset into a
staging table and a per-address balance data mart, with CI that runs dbt on
every pull request.

## Models

| Model | Materialization | Description |
|-------|-----------------|-------------|
| [`staging_model`](bitcoin_cash/models/staging/staging_model.sql) | table (`staging` dataset) | The **last three months** of `bigquery-public-data.crypto_bitcoin_cash.transactions`. Filtered on the monthly partition column for cheap partition pruning, then trimmed to an exact 3-month window. |
| [`mart_model`](bitcoin_cash/models/mart/mart_model.sql) | table (`mart` dataset) | **Current balance per address** = sum(outputs received) − sum(inputs spent). Any address that ever appeared in a coinbase transaction is excluded. |

Sources are declared in [`sources.yml`](bitcoin_cash/models/sources.yml); column
descriptions and tests live in [`schema.yml`](bitcoin_cash/models/schema.yml).

## Prerequisites

Install on your laptop:

- **uv** (Python package/venv manager) — <https://docs.astral.sh/uv/getting-started/installation/>.
  `uv` provisions the pinned Python (3.12.9, see [`.python-version`](.python-version))
  and installs the locked dbt dependencies — you don't need a separate Python install.
- **Google Cloud SDK** (`gcloud`) — <https://cloud.google.com/sdk/docs/install>,
  used to obtain Application Default Credentials for local runs.

## Install

```bash
cd dbt_repo
uv sync          # reads pyproject.toml + uv.lock, installs dbt-core & dbt-bigquery
```

## Authenticate (local)

The `dev` target uses OAuth / Application Default Credentials:

```bash
gcloud auth application-default login
```

## Configure

The profile ([`profiles.yml`](profiles.yml)) is committed and fully driven by
env vars (no secrets). For local `dev` runs set:

```bash
export DBT_BIGQUERY_PROJECT="blockchain-cash-analysis"   # your GCP project
export DBT_BIGQUERY_DATASET="staging"                    # default dataset
```

(The `ci` target reads `GCP_PROJECT_ID` / `BQ_LOCATION`, which CI injects
automatically.)

## Run

```bash
uv run dbt deps      # install dbt package dependencies (no-op if none)
uv run dbt debug     # verify the connection
uv run dbt run       # build staging_model then mart_model
uv run dbt test      # run the schema.yml tests
```

To target the CI profile explicitly: append `--target ci`.

## Continuous Integration

[`.github/workflows/dbt_ci.yml`](.github/workflows/dbt_ci.yml) runs on every pull
request to `main`. It:

1. Checks out the repo and installs dependencies with `uv sync`.
2. Authenticates to Google Cloud **keylessly** via Workload Identity Federation,
   assuming the `dbt-runner` service account provisioned by Terraform (the
   `GCP_WORKLOAD_IDENTITY_PROVIDER` / `GCP_SERVICE_ACCOUNT` secrets and
   `GCP_PROJECT_ID` / `BQ_LOCATION` variables are all set by Terraform).
3. Runs `dbt deps`, `dbt debug`, and `dbt run`.

## Design choices

- **Last 3 months only** — keeps every query partition-pruned and inside the
  BigQuery free tier.
- **Coinbase exclusion via a `NOT IN` with a `NULL` guard** — addresses can be
  `NULL` in unnested outputs, and an unguarded `NOT IN` against a set containing
  `NULL` returns no rows; the `where address is not null` subquery filter avoids
  that trap.
- **Committed, env-var-only `profiles.yml`** — works identically for local dev
  and CI with zero secrets in version control.
