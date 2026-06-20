-- Singular test: the staging model must contain only the last three months of
-- data, day-precise. The window is anchored to the latest transaction present
-- (the source is frozen, so it can't use current_date()). The staging model now
-- anchors to the true latest transaction DATE, so this strict, day-precise check
-- holds exactly — a row more than three months older than the latest one means
-- the window filter is too wide.
--
-- This is a singular (not a generic) test because the cutoff is data-derived:
-- it needs a self-referential max() over the model.
--
-- A dbt test passes when it returns ZERO rows. Any row returned fails the test
-- (and, in CI, the pull request).

with anchor as (

    select max(block_timestamp) as latest_ts
    from {{ ref('staging_model') }}

)

select s.block_timestamp
from {{ ref('staging_model') }} s
cross join anchor a
where date(s.block_timestamp) < date_sub(date(a.latest_ts), interval 3 month)
