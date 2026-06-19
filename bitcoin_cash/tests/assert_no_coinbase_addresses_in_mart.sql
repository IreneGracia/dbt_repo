-- Singular test: the data mart must NEVER contain an address that ever appeared
-- in a coinbase (newly-minted / miner-reward) transaction. This is the core
-- business rule of mart_model, so we assert it directly.
--
-- A dbt test passes when it returns ZERO rows. Any row returned here is an
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
