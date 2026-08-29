-- DQ-10  Invalid provider NPI                              Validity / HIGH
-- Failure condition: provider_npi is not 10 numeric digits, or the tenth digit
-- fails the Luhn check calculated over the constant 80840 prefix plus the first
-- nine digits (the CMS NPI standard). Such a claim rejects at the clearinghouse.
set search_path = rcm, public;

create or replace view rcm.dq10_invalid_npi as
select
    'DQ-10'::text  as check_id,
    'HIGH'::text   as severity,
    'claim'::text  as entity_type,
    claim_id       as entity_key,
    claim_id,
    payer_id,
    payer_name,
    date_of_service,
    cpt_code,
    billed_amount,
    billed_amount  as amount_impact,
    case
        when provider_npi is null              then 'provider_npi is blank'
        when provider_npi !~ '^[0-9]{10}$'     then format('provider_npi "%s" is not 10 numeric digits', provider_npi)
        else format('provider_npi %s fails the Luhn check digit', provider_npi)
    end as finding
from rcm.v_claim_unique
where provider_npi is null
   or not rcm.fn_npi_is_valid(provider_npi);
