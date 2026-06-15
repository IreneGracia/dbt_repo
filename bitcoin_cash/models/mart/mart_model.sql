
with staging as (

    select * from {{ ref('staging_model') }}

),

-- Addresses that ever received freshly-minted coins (miners) — to exclude
coinbase_addresses as (

    select distinct addr as address
    from staging
    cross join unnest(outputs) as o
    cross join unnest(o.addresses) as addr
    where staging.is_coinbase = true

),

ledger as (

    -- received
    select addr as address, o.value as amount
    from staging
    cross join unnest(outputs) as o
    cross join unnest(o.addresses) as addr

    union all

    -- spent
    select addr as address, -i.value as amount
    from staging
    cross join unnest(inputs) as i
    cross join unnest(i.addresses) as addr

),

balances as (

    select
        address,
        sum(amount) as balance
    from ledger
    group by address

)

select b.address, b.balance
from balances b
where b.address not in (
    select address
    from coinbase_addresses
    where address is not null      -- guards against the NULL trap
)
