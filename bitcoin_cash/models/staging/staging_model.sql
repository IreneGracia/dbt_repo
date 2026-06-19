{%- set src = source('crypto_bitcoin_cash', 'transactions') -%}
{%- set latest_date_query -%}
  select format_date('%Y-%m-%d', max(parse_date('%Y%m%d', partition_id)))
  from `{{ src.database }}.{{ src.schema }}.INFORMATION_SCHEMA.PARTITIONS`
  where table_name = '{{ src.identifier }}'
    and partition_id not in ('__NULL__', '__UNPARTITIONED__')
{%- endset -%}
{%- if execute -%}
  {%- set anchor_date = run_query(latest_date_query).rows[0][0] -%}
{%- else -%}
  {%- set anchor_date = '1970-01-01' -%}
{%- endif %}

-- Staging model: the most recent three months of Bitcoin Cash transactions that
-- actually exist in the source. The public `crypto_bitcoin_cash` dataset is
-- frozen (last data ~May 2024), so current_date() would select an empty future
-- window. Instead we look up the latest populated month at COMPILE time from
-- INFORMATION_SCHEMA.PARTITIONS (metadata only — free, no table scan) and embed
-- it as a literal, which keeps partition pruning on so queries stay free-tier.
with source as (
  select *
  from {{ src }}
  where
    -- partition pruning on the monthly partition column
    block_timestamp_month >= date_trunc(date_sub(date('{{ anchor_date }}'), interval 3 month), month)
    -- 3-month window ending at the latest available data
    and block_timestamp >= timestamp(date_sub(date('{{ anchor_date }}'), interval 3 month))
)

select *
from source
