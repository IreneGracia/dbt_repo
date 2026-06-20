{%- set src = source('crypto_bitcoin_cash', 'transactions') -%}

{#
  Anchor the 3-month window to the LATEST TRANSACTION DATE so the staging table
  holds a strict last-three-months slice (e.g. 24 Feb -> 24 May), per the brief's
  "only the last three months of data".

  Two compile-time steps:
    1. Free metadata lookup (no table scan) for the latest populated monthly
       partition. This is only a MONTH boundary (e.g. 2024-05-01) — too coarse to
       anchor a day-precise window on its own.
    2. Read the true latest transaction DATE, scanning ONLY that one latest
       partition (partition-pruned: one column, one month — negligible bytes).

  The public crypto_bitcoin_cash dataset is frozen (last data ~May 2024), so
  current_date() would select an empty future window — hence the lookup.
#}
{%- set latest_partition_query -%}
  select format_date('%Y-%m-%d', max(parse_date('%Y%m%d', partition_id)))
  from `{{ src.database }}.{{ src.schema }}.INFORMATION_SCHEMA.PARTITIONS`
  where table_name = '{{ src.identifier }}'
    and partition_id not in ('__NULL__', '__UNPARTITIONED__')
{%- endset -%}

{%- if execute -%}
  {%- set latest_month = run_query(latest_partition_query).rows[0][0] -%}
  {%- set latest_date_query -%}
    select format_date('%Y-%m-%d', max(date(block_timestamp)))
    from {{ src }}
    where block_timestamp_month = date('{{ latest_month }}')
  {%- endset -%}
  {%- set anchor_date = run_query(latest_date_query).rows[0][0] -%}
{%- else -%}
  {%- set anchor_date = '1970-01-01' -%}
{%- endif %}

with source as (
  select *
  from {{ src }}
  where
    -- partition pruning on the monthly partition column: skip months entirely
    -- outside the window
    block_timestamp_month >= date_trunc(date_sub(date('{{ anchor_date }}'), interval 3 month), month)
    -- strict, day-precise 3-month window ending at the latest transaction date
    and block_timestamp >= timestamp(date_sub(date('{{ anchor_date }}'), interval 3 month))
)

select *
from source
