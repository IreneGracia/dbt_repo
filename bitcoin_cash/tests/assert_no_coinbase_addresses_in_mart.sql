-- The data mart must not contain an address that ever appeared
-- in a coinbase transaction.

-- A dbt test passes when it returns zero rows. Any row returned here is an
-- address that leaked past the coinbase exclusion in mart_model, which fails
-- the test (and, in CI, the pull request).

with coinbase_addresses as (

    select distinct addr as address
    from {{ ref('staging_model') }}
    cross join unnest(outputs) as o
    cross join unnest(o.addresses) as addr
    where is_coinbase = true

)

select m.address
from {{ ref('mart_model') }} m
inner join coinbase_addresses c
    on m.address = c.address
