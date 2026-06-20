# dbt — Bitcoin Cash transformations

A dbt-core project that turns the public Bitcoin Cash blockchain dataset into a
staging table and a per-address balance data mart, with tests and CI that run on
every pull request.

> **Run Terraform first.** This project writes into the `staging` / `mart`
> BigQuery datasets and authenticates (in CI) as the `dbt-runner` service
> account — all created by [`terraform_repo/`](../terraform_repo/README.md). The
> GCP project and datasets must exist before dbt can build anything.

## Models

| Model | Materialization | Description |
|-------|-----------------|-------------|
| [`staging_model`](bitcoin_cash/models/staging/staging_model.sql) | table (`staging` dataset) | The **last three months** of `bigquery-public-data.crypto_bitcoin_cash.transactions`. Filtered on the monthly partition column for cheap partition pruning, then trimmed to an exact 3-month window. The window is anchored at **compile time** to the latest data that actually exists (the public dataset is frozen ~May 2024), so `current_date()` wouldn't return an empty window. |
| [`mart_model`](bitcoin_cash/models/mart/mart_model.sql) | table (`mart` dataset) | **Current balance per address** = sum(outputs received) − sum(inputs spent). Any address that ever appeared in a coinbase transaction is excluded. |

Sources are declared in [`sources.yml`](bitcoin_cash/models/sources.yml); column
descriptions and tests live in [`schema.yml`](bitcoin_cash/models/schema.yml).

## Tests

The project ships all three kinds of dbt test (run automatically by `dbt build`):

| Test | Type | What it asserts |
|------|------|-----------------|
| `unique`, `not_null` on key columns | generic (built-in) | `hash` is a unique, non-null key; `address`/`balance` non-null; etc. |
| [`dbt_utils.expression_is_true`](bitcoin_cash/models/schema.yml) on staging | generic (from a package) | The monthly partition column matches the timestamp's month, so partition pruning is trustworthy. |
| [`assert_no_coinbase_addresses_in_mart`](bitcoin_cash/tests/assert_no_coinbase_addresses_in_mart.sql) | singular (custom) | No coinbase address leaked into the mart — the core business rule. |
| [`assert_staging_within_three_months`](bitcoin_cash/tests/assert_staging_within_three_months.sql) | singular (custom) | Staging holds only the last 3 months relative to the latest available data. |

> Note: `hash` is a **reserved keyword** in BigQuery, so its column tests are
> marked `quote: true` in `schema.yml` to force backtick-quoting.

## Prerequisites

Install on your machine:

- **uv** (Python package/venv manager) — <https://docs.astral.sh/uv/getting-started/installation/>.
  `uv` provisions the pinned Python (3.12.9, see [`.python-version`](.python-version))
  and installs the locked dbt dependencies — **you do not need a separate Python
  install**.
- **Google Cloud SDK** (`gcloud`) — <https://cloud.google.com/sdk/docs/install>,
  used to obtain Application Default Credentials for local runs.

You also need, for **local** runs:

- The GCP **project and datasets** already created by Terraform.
- A Google identity with BigQuery access on that project — at minimum
  `roles/bigquery.jobUser` plus read access to the datasets (project **Owner**,
  which you get by creating the project, already covers this). This is separate
  from the CI service account; locally you run **as yourself**.

## 1 · Install

```bash
cd dbt_repo
uv sync          # reads pyproject.toml + uv.lock, installs dbt-core & dbt-bigquery
uv run dbt deps  # downloads package dependencies (dbt_utils) into dbt_packages/
```

> `dbt deps` is required before the first build — without it the
> `dbt_utils.expression_is_true` test can't be found. It only downloads code; no
> BigQuery calls, no cost.

## 2 · Authenticate (local)

The `dev` target uses OAuth / Application Default Credentials, so authenticate as
yourself once:

```bash
gcloud auth application-default login
```

## 3 · Configure

The profile ([`profiles.yml`](profiles.yml)) is committed and fully driven by env
vars (no secrets). For local `dev` runs set:

```bash
export DBT_BIGQUERY_PROJECT="blockchain-cash-analysis"   # your GCP project id
export DBT_BIGQUERY_DATASET="staging"                    # default dataset
```

(The `ci` target reads `GCP_PROJECT_ID` / `BQ_LOCATION`, which CI injects
automatically — see below.)

## 4 · Run

```bash
uv run dbt debug     # verify config + connection (fail-fast preflight)
uv run dbt build     # build staging_model → mart_model AND run all tests, in order
```

`dbt build` runs models and tests together in dependency order. If you want them
separately: `uv run dbt run` then `uv run dbt test`. To use the CI profile
explicitly, append `--target ci` to any command.

## Continuous Integration

[`.github/workflows/dbt_ci.yml`](.github/workflows/dbt_ci.yml) runs on every pull
request to `main`/`master`. It:

1. Checks out the repo and installs dependencies with `uv sync`.
2. Authenticates to Google Cloud **keylessly** via Workload Identity Federation,
   assuming the `dbt-runner` service account provisioned by Terraform. The
   `GCP_WORKLOAD_IDENTITY_PROVIDER` / `GCP_SERVICE_ACCOUNT` secrets and
   `GCP_PROJECT_ID` / `BQ_LOCATION` variables are all set **by Terraform** — no
   manual GitHub configuration needed.
3. Runs `dbt deps`, `dbt debug`, and **`dbt build`** (`--target ci`) — so a
   failing data test (e.g. a coinbase address leaking into the mart) fails the
   job and blocks the merge.

## Project structure

```text
dbt_repo/
├── dbt_project.yml          # project config (paths, materializations, schemas)
├── packages.yml             # dbt package deps (dbt_utils)
├── profiles.yml             # dev + ci connection targets (env-var driven, no secrets)
├── pyproject.toml / uv.lock # Python + dbt dependency pins (managed by uv)
└── bitcoin_cash/
    ├── models/
    │   ├── sources.yml      # the public source declaration
    │   ├── schema.yml       # model/column docs + tests
    │   ├── staging/staging_model.sql
    │   └── mart/mart_model.sql
    ├── tests/               # singular (custom-SQL) tests
    └── macros/              # generate_schema_name override (bare staging/mart datasets)
```

## Design choices

- **Last 3 months only**, anchored to the latest available data — keeps every
  query partition-pruned and inside the BigQuery free tier.
- **Coinbase exclusion via a `NOT IN` with a `NULL` guard** — addresses can be
  `NULL` in unnested outputs, and an unguarded `NOT IN` against a set containing
  `NULL` returns no rows; the `where address is not null` subquery filter avoids
  that trap.
- **Committed, env-var-only `profiles.yml`** — works identically for local dev
  and CI with zero secrets in version control.
- **Keyless CI auth** — the pipeline authenticates as the service account via
  WIF, never a downloaded JSON key.
