# dbt — Bitcoin Cash transformations

A dbt-core project that turns the public Bitcoin Cash dataset into a staging table
and a per-address balance mart, tested and CI-validated on every pull request.

> **Run [`terraform_repo`](../terraform_repo/README.md) first** — it creates the
> `staging`/`mart` datasets and the `dbt-runner` service account (plus the CI
> credentials) that this project depends on.

## What this project does

**Inflow.** Reads the public, append-only Bitcoin Cash ledger
(`bigquery-public-data.crypto_bitcoin_cash.transactions`) — one row per transaction,
each carrying nested `inputs` (coins being spent), nested `outputs` (coins being
received), the block timestamp, and an `is_coinbase` flag (true for mined/block-reward
transactions). This source is read-only and never modified.

**Transform.**
1. **`staging_model`** narrows the firehose to a **strict last-3-months** slice,
   partition-pruned so it stays in the free tier — a clean, time-bounded copy of the
   raw transactions.
2. **`mart_model`** turns those transactions into an **address ledger**: it unnests
   every output (`+value` received) and every input (`−value` spent), sums them per
   address to get a **net balance**, and excludes any address that ever received a
   coinbase (mined) payout.

**Outflow.** **`mart.mart_model`** — one row per address with its net balance — is the
consumable product, ready to feed BI dashboards or ML features. `staging.staging_model`
is the intermediate layer the mart is built from.

```
bigquery-public-data.crypto_bitcoin_cash.transactions   ← inflow (read-only source)
        │   staging_model  — strict last 3 months, partition-pruned
        ▼
   staging.staging_model                                  (intermediate)
        │   mart_model     — unnest inputs/outputs → net balance per address,
        ▼                     coinbase addresses excluded
     mart.mart_model                                       → outflow (BI / ML consumes this)
```

## Models

| Model | Materialized | Description |
|-------|--------------|-------------|
| [`staging_model`](bitcoin_cash/models/staging/staging_model.sql) | table → `staging` | A **strict 3-month window** ending at the latest transaction date. The anchor is resolved at compile time (the public dataset is frozen ~May 2024, so `current_date()` would yield an empty window): a free metadata lookup finds the latest partition, then a tiny partition-pruned query reads the true latest date. Pruned on `block_timestamp_month` to stay free-tier. |
| [`mart_model`](bitcoin_cash/models/mart/mart_model.sql) | table → `mart` | **Balance per address** = Σ(outputs received) − Σ(inputs spent) over the staged window. Addresses that ever appeared in a coinbase (block-reward) transaction are excluded via a NULL-safe `NOT IN`. |

> **Assumption — windowed balance.** Staging is limited to 3 months to stay in the
> free tier, so the mart balance is the **net change over those 3 months**, not an
> address's all-time balance (which would require scanning full history). This is
> the deliberate, free-tier-consistent reading of the brief's "current balance".

## Tests

`dbt build` runs all ten on every PR; any failure blocks the merge.

| Test | Kind | Asserts |
|------|------|---------|
| `unique` on `staging.hash` | built-in generic | Transaction hash is a unique key. |
| `not_null` on `staging.hash` | built-in generic | Hash is never null. |
| `not_null` on `staging.block_timestamp` | built-in generic | Every row is timestamped. |
| `not_null` on `staging.is_coinbase` | built-in generic | Coinbase flag present (drives the mart exclusion). |
| `dbt_utils.expression_is_true` on staging | package generic | `block_timestamp_month` equals the timestamp's month → partition pruning is trustworthy. |
| `unique` on `mart.address` | built-in generic | One balance row per address. |
| `not_null` on `mart.address` | built-in generic | No null addresses. |
| `not_null` on `mart.balance` | built-in generic | Every address has a computed balance. |
| [`assert_no_coinbase_addresses_in_mart`](bitcoin_cash/tests/assert_no_coinbase_addresses_in_mart.sql) | singular (custom) | **Core rule:** no coinbase address leaked into the mart. |
| [`assert_staging_within_three_months`](bitcoin_cash/tests/assert_staging_within_three_months.sql) | singular (custom) | No transaction older than 3 months before the latest — enforces the strict window. |

> `hash` is a BigQuery reserved word, so its tests use `quote: true` to force backtick-quoting.

## Prerequisites

- **uv** — https://docs.astral.sh/uv/getting-started/installation/ — provisions Python 3.12.9 + dbt; no separate Python install needed.
- **gcloud** — https://cloud.google.com/sdk/docs/install — for local Application Default Credentials.
- The GCP project + datasets from `terraform_repo`, and a Google identity with BigQuery access (project **Owner**, which you get by creating it, suffices). Locally you run **as yourself**, not the service account.

## Run locally

```bash
cd dbt_repo
uv sync                              # install dbt-core + dbt-bigquery (pinned)
uv run dbt deps                      # download dbt_utils into dbt_packages/
gcloud auth application-default login

export DBT_BIGQUERY_PROJECT="blockchain-cash-analysis"
export DBT_BIGQUERY_DATASET="staging"

uv run dbt debug                     # verify config + connection (fail-fast)
uv run dbt build                     # build models AND run all tests
```

`dbt build` runs models and tests in dependency order; `dbt run` + `dbt test`
separately also works. Append `--target ci` to use the CI profile.

## Continuous Integration

[`.github/workflows/dbt_ci.yml`](.github/workflows/dbt_ci.yml) runs on every PR to `main`/`master`:

1. `uv sync` — install dbt and dependencies.
2. **Keyless auth** to GCP via Workload Identity Federation, as the `dbt-runner` SA. The WIF provider, SA email, project id, and location are injected by Terraform — no manual GitHub setup.
3. `dbt deps` → `dbt debug` → **`dbt build`** — so a failing test (e.g. a coinbase address in the mart) fails the job and blocks the merge.

## Configuration

- [`profiles.yml`](profiles.yml) — committed and **fully env-var driven (no secrets)**, with two targets: `dev` (default, local, authenticates as you) and `ci` (the pipeline, authenticates as the SA).
- [`generate_schema_name.sql`](bitcoin_cash/macros/generate_schema_name.sql) — overrides dbt's default `<target>_<schema>` naming so models land in the bare `staging`/`mart` datasets Terraform created.

## Project structure

```
dbt_repo/
├── dbt_project.yml          # paths, materializations, target schemas
├── packages.yml             # dbt package deps (dbt_utils)
├── profiles.yml             # dev + ci targets (env-var driven)
├── pyproject.toml / uv.lock # Python + dbt version pins (uv)
└── bitcoin_cash/
    ├── models/
    │   ├── sources.yml      # public source declaration
    │   ├── schema.yml       # model/column docs + generic tests
    │   ├── staging/staging_model.sql
    │   └── mart/mart_model.sql
    ├── tests/               # singular (custom-SQL) tests
    └── macros/              # generate_schema_name override
```

## Design choices

- **Strict 3-month window**, anchored to the latest transaction date — literal to the brief and free-tier friendly.
- **Coinbase exclusion via a NULL-safe `NOT IN`** — unnested addresses can be null, and an unguarded `NOT IN` against a set containing null returns nothing; the `where address is not null` subquery filter avoids that trap.
- **Three test layers** — built-in generic, package generic (`dbt_utils`), and singular custom — covering keys, partition integrity, the window, and the core coinbase rule.
- **Keyless CI** and **env-var-only profiles** — no secrets in version control.
