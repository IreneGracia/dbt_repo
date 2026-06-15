-- Staging model: the last three months of Bitcoin Cash transactions.
--
-- Only recent data is selected so every query stays inside the BigQuery free
-- tier (see README). Two predicates on purpose:
--   * block_timestamp_month -> partition pruning (cheap, coarse, monthly)
--   * block_timestamp       -> trims to an exact rolling 3-month window
with source as (
  select *
  from {{ source("crypto_bitcoin_cash", "transactions") }}
  where
    -- partition pruning: only the recent monthly partitions are read
    block_timestamp_month >= date_trunc(date_sub(current_date(), interval 3 month), month)
    -- exact 3-month window
    and block_timestamp >= timestamp(date_sub(current_date(), interval 3 month))
)

select *
from source
