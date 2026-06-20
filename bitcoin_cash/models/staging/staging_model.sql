{%- set src = source('crypto_bitcoin_cash', 'transactions') -%}

-- Anchor the 3-month window to the LATEST TRANSACTION DATE (the dataset is frozen
-- ~May 2024, so current_date() would be empty). Resolved at compile time: a free
-- metadata lookup finds the latest month, then a small pruned query reads the exact
-- latest date used as the window anchor.

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
