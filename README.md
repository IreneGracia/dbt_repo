# dbt repo

A dbt-core project that turns the public Bitcoin Cash dataset into a staging table
and a per-address balance mart, tested and CI-validated on every pull request.

> **Run [`terraform_repo`](../terraform_repo/README.md) first**: it creates the
> `staging`/`mart` datasets and the `dbt-runner` service account (plus the CI
> credentials) that this project depends on.

## What this project does

**Inflow.** 
Reads the public, append-only Bitcoin Cash ledger
(`bigquery-public-data.crypto_bitcoin_cash.transactions`): one row per transaction,
each carrying nested inputs (coins being spent), nested outputs (coins being
received), the block timestamp and an is_coinbase flag (true for mined/block-reward
transactions). This source is read-only and never modified.

**Transform.**
1. **`staging_model`** narrows the data to a slice of the last 3 months,
   partition-pruned.
2. **`mart_model`** turns those transactions into an address ledger: it unnests
   every output (+value received) and every input (−value spent), sums them per
   address to get a net balance and excludes any address that ever received a
   coinbase payout.

**Outflow.** 
`mart_model`: one row per address with its net balance, which is the
consumable product, ready to feed BI dashboards or ML features. `staging_model`
is the intermediate layer the mart is built from.


## Models

| Model | Materialised | Description |
|-------|--------------|-------------|
| [`staging_model`](bitcoin_cash/models/staging/staging_model.sql) | table → `staging` | A **strict 3-month window** ending at the latest transaction date. The anchor is resolved at compile time (the public dataset is frozen ~May 2024, so `current_date()` would yield an empty window): a free metadata lookup finds the latest partition, then a small partition-pruned query reads the true latest date. Pruned on `block_timestamp_month` to stay free-tier. |
| [`mart_model`](bitcoin_cash/models/mart/mart_model.sql) | table → `mart` | **Balance per address** = Σ(outputs received) − Σ(inputs spent) over the staged window. Addresses that ever appeared in a coinbase transaction are excluded via a NULL-safe `NOT IN`. |


**Assumption: windowed balance.** Staging is limited to 3 months to stay in the free tier, so the mart balance is the net change over those 3 months, not an address's all-time balance (which would require scanning full history). This is the deliberate, free-tier-consistent reading of the brief's "current balance".

### `staging_model`

**Purpose.** Produce a clean, partition-pruned copy of the last three
months of raw transactions.

**How the window is anchored** The window can't use
`current_date()`, because the public dataset is frozen (~May 2024) so "now
minus 3 months" would select an empty future range. Instead the anchor is computed
at compile time in two cheap steps:
1. A **metadata-only** query against `INFORMATION_SCHEMA.PARTITIONS` finds the
   latest populated monthly partition (free, no table scan). This is only a month
   boundary, too coarse for a day-precise window.
2. A **partition-pruned** query reads `max(date(block_timestamp))` from just that
   one latest partition and finds the true latest transaction date (negligible bytes).

That date becomes `anchor_date`, embedded as a literal in the model's SQL.

**The filter.** Two predicates do the work:
- `block_timestamp_month >= date_trunc(anchor_date - 3 months, month)`: prunes whole
  partitions outside the window so BigQuery scans the minimum.
- `block_timestamp >= anchor_date - 3 months`: the strict, day-precise cutoff.

**Output schema.** A passthrough of the source schema (`select *`), materialised as a
**table** in the `staging` dataset. The columns the rest of the project relies on:

| Column | Type | Notes |
|--------|------|-------|
| `hash` | STRING | Transaction hash: the unique key (tested `unique` + `not_null`). |
| `block_timestamp` | TIMESTAMP | Block mining time (shared by all txns in a block); drives the 3-month window. |
| `block_timestamp_month` | DATE | Month-truncated partition column used for pruning. |
| `is_coinbase` | BOOL | True for mined / block-reward transactions; drives the mart exclusion. |
| `inputs` | ARRAY&lt;STRUCT&gt; | Nested; each element has `addresses` and `value` (coins spent). |
| `outputs` | ARRAY&lt;STRUCT&gt; | Nested; each element has `addresses` and `value` (coins received). |

All other raw columns (`block_number`, `fee`, `size`, `input_count`, etc.) are carried through unchanged.

### `mart_model` — a per-address balance ledger

**Purpose.** Collapse transactions into **one row per address** with its net balance,
excluding addresses tied to coinbase (mined) coins. Built entirely from
`staging_model`, so it inherits the 3-month window.

**How it works** (four CTEs):
1. **`coinbase_addresses`** — unnests the `outputs` of every `is_coinbase = true`
   transaction to collect every address that ever received freshly-minted coins.
   These are the addresses to exclude.
2. **`ledger`** — turns transactions into signed amounts per address:
   - unnest `outputs` → `+value` (coins **received** by an address), and
   - unnest `inputs` → `−value` (coins that address **spent**),
   combined with `UNION ALL`. (In Bitcoin Cash, an input spends a prior output, so
   inputs carry the spender's address and value.)
3. **`balances`** — `sum(amount)` grouped by address = the net balance over the window.
4. **Final select** — returns `address, balance`, excluding coinbase addresses with a
   **NULL-safe `NOT IN`** (`where address is not null` inside the subquery — see Design
   choices for why this matters).

**Output schema.** One row per address, materialized as a **table** in the `mart`
dataset — the consumable product:

| Column | Type | Description |
|--------|------|-------------|
| `address` | STRING | Bitcoin Cash address (unique, not null). |
| `balance` | NUMERIC | Net balance in **satoshis** over the staged window = Σ(received) − Σ(spent). Can be negative if an address spent more than it received within the window. |

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
| [`assert_staging_within_three_months`](bitcoin_cash/tests/assert_staging_within_three_months.sql) | singular (custom) | No transaction older than 3 months before the latest: enforces the strict window. |


## Sources, macros & packages

Beyond models and tests, the project uses these dbt building blocks:

- **Source** — [`sources.yml`](bitcoin_cash/models/sources.yml) declares the public
  `bigquery-public-data.crypto_bitcoin_cash.transactions` table as a dbt source.
  Models reference it via `{{ source('crypto_bitcoin_cash', 'transactions') }}` instead
  of hard-coding the path.

- **Macro** — [`generate_schema_name.sql`](bitcoin_cash/macros/generate_schema_name.sql)
  overrides dbt's built-in `generate_schema_name`. By default dbt names schemas
  `<target>_<custom>` (e.g. `staging_staging`); this override uses the configured
  `+schema`, so models land in the bare `staging` / `mart` datasets that
  Terraform created. Separately, `staging_model` uses inline Jinja + `run_query` at compile time to resolve its 3-month anchor date.

- **Package** — [`packages.yml`](packages.yml) declares `dbt_utils` (dbt Labs' standard
  helper package). `dbt deps` installs it into `dbt_packages/` (git-ignored), and CI runs
  `dbt deps` before `dbt build`. It supplies the `dbt_utils.expression_is_true` generic
  test used on the staging model.

- **Materialisations** — both models are materialised as tables, so the mart and staging outputs persist as queryable BigQuery tables.

## Prerequisites

- **uv**: https://docs.astral.sh/uv/getting-started/installation/ provisions Python 3.12.9 + dbt; no separate Python install needed.
- **gcloud**: https://cloud.google.com/sdk/docs/install — for local Application Default Credentials.
- The GCP project + datasets from `terraform_repo`, and a Google identity with BigQuery access (project Owner suffices). Local runs happen as users, not the service account.

## Run locally

```bash
cd dbt_repo
uv sync                              # install dbt-core + dbt-bigquery (pinned)
uv run dbt deps                      # download dbt_utils into dbt_packages/
gcloud auth application-default login

export DBT_BIGQUERY_PROJECT="blockchain-cash-analysis"
export DBT_BIGQUERY_DATASET="staging"

uv run dbt debug                     # verify config + connection
uv run dbt build                     # build models and run all tests
```

Append `--target ci` to use the CI profile.

## Continuous Integration

[`.github/workflows/dbt_ci.yml`](.github/workflows/dbt_ci.yml) runs on every PR to `main`/`master`:

1. `uv sync` — install dbt and dependencies.
2. Keyless auth to GCP via Workload Identity Federation, as the `dbt-runner` SA. The WIF provider, SA email, project id, and location are injected by Terraform: no manual GitHub setup.
3. `dbt deps` → `dbt debug` → `dbt build` — so a failing test (e.g. a coinbase address in the mart) fails the job and blocks the merge.

## Configuration

- [`profiles.yml`](profiles.yml): committed and fully env-var driven (no secrets), with two targets: `dev` (default, local, authenticates as you) and `ci` (the pipeline, authenticates as the SA).
- [`generate_schema_name.sql`](bitcoin_cash/macros/generate_schema_name.sql): overrides dbt's default `<target>_<schema>` naming so models land in the bare `staging`/`mart` datasets Terraform created.

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

- **Three test layers**: built-in generic, package generic (`dbt_utils`), and singular custom covering keys, partition integrity, the window, and the core coinbase rule.
- **Keyless CI** and **env-var-only profiles**: no secrets in version control.
