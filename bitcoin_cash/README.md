# bitcoin_cash — dbt project package

This folder is the dbt project package itself (models, tests, macros, sources).
The project root is one level up, where `dbt_project.yml` lives.

**For setup, authentication, and run instructions, see the
[dbt_repo README](../README.md).**

## Contents

- `models/staging/` — `staging_model`: last 3 months of transactions.
- `models/mart/` — `mart_model`: per-address balance, coinbase addresses excluded.
- `models/sources.yml` — declaration of the public source table.
- `models/schema.yml` — model/column documentation and tests.
- `tests/` — singular (custom-SQL) data tests.
- `macros/` — `generate_schema_name` override so models land in the bare
  `staging` / `mart` datasets created by Terraform.
