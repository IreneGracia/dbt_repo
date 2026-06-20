-- Singular test: the staging model must contain ONLY the last three months of
-- data. Because the public source is frozen, the window is anchored to the
-- latest transaction actually present (max block_timestamp), not current_date()
-- — this mirrors the compile-time anchor logic in the staging model and proves
-- that the 3-month filter actually worked.
--
-- This is a singular (not a generic) test because the cutoff is data-derived:
-- it needs a self-referential max() over the model, which a per-row generic
-- test like expression_is_true cannot express cleanly.
--
-- A dbt test passes when it returns ZERO rows. Any row returned is a transaction
-- older than the allowed window, which fails the test (and the PR).

with anchor as (

    select max(block_timestamp) as latest_ts
    from {{ ref('staging_model') }}

)

select s.block_timestamp
from {{ ref('staging_model') }} s
cross join anchor a
where date(s.block_timestamp) < date_sub(date(a.latest_ts), interval 3 month)
