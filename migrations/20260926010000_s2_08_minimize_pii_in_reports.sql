-- S2-08 (PB-09/PB-10): minimize PII in management reports.
--
-- get_all_reservations() -- the query behind the Manager Dashboard's
-- reservation list -- currently returns every passenger's full email
-- address to every manager/admin who loads the dashboard, even though nothing
-- in the UI actually needs it:
--   * The ticket view (tripToTicketData() / renderTicketHTML() in the
--     frontend) shows passenger name, confirmation code, fare and card
--     brand/last4 -- never email.
--   * The "Cancel booking" flow (admin_cancel_reservation) takes a
--     reservation id, not an email.
--   * The dashboard's own "Search passenger name or email" filter matches
--     against the real stored email server-side -- that still needs to work
--     even once the *displayed* value is masked, since the match happens in
--     the WHERE clause below, not against whatever gets returned to the
--     browser.
-- So displaying the full address is pure unnecessary exposure -- a bulk
-- report is a bigger leak surface than a single lookup (one page load hands
-- out every customer's email at once), and nothing downstream depends on
-- having the real value. This masks it in the report output while leaving
-- search fully working.
--
-- passenger_name is deliberately NOT masked here -- unlike email, the name
-- is what a manager actually needs to identify whose reservation they're
-- looking at (that's the report's whole purpose), and it's already the
-- thing "Search passenger name" matches display-visible text against. Email
-- is the piece that's collectable/contactable PII with no in-app use once
-- you're past the search box, which is what makes it the one worth cutting.

create or replace function public.mask_email(p_email text)
returns text
language plpgsql
immutable
as $function$
declare
  at_pos integer;
  local_part text;
  domain_part text;
  visible_len integer;
begin
  if p_email is null then
    return null;
  end if;

  at_pos := position('@' in p_email);
  if at_pos < 2 then
    -- Not a recognizable "something@something" shape -- mask the whole
    -- string rather than pass through something that isn't actually an
    -- email (and might not even be PII) unmasked.
    return repeat('*', greatest(length(p_email), 3));
  end if;

  local_part := substring(p_email from 1 for at_pos - 1);
  domain_part := substring(p_email from at_pos); -- includes the leading '@'
  visible_len := least(2, length(local_part));

  -- Keep the domain visible (jane@company.com -> a manager can still tell
  -- it's a company.com address, which is often operationally useful and
  -- isn't personally identifying on its own) and always mask at least 2
  -- characters of the local part, even for very short ones, so a 1-2
  -- character local part doesn't end up fully or near-fully visible.
  return left(local_part, visible_len)
    || repeat('*', greatest(length(local_part) - visible_len, 2))
    || domain_part;
end;
$function$;

-- Same signature/return shape as the version in
-- 20260921050000_add_manager_role.sql, so `create or replace` is safe here
-- too -- only the passenger_email column of the SELECT list changes, from
-- the raw column to a masked one; every other column, the WHERE clause
-- (including the real, unmasked r.passenger_email match for search), and
-- the admin-or-manager role check are unchanged.
--
-- NOTE: if get_all_reservations() was touched by a migration after this
-- one's baseline (20260921050000_add_manager_role.sql) -- e.g. as part of
-- 20260921070000's revenue widening or the S2-07 hardening migration -- and
-- picked up columns/logic not shown here, re-check this against the current
-- live definition before running:
--   select pg_get_functiondef('public.get_all_reservations'::regproc);
create or replace function public.get_all_reservations(
  p_status text default null,
  p_origin text default null,
  p_destination text default null,
  p_date_from date default null,
  p_date_to date default null,
  p_search text default null,
  p_limit integer default 25,
  p_offset integer default 0
)
returns table(
  reservation_id uuid,
  status text,
  price_paid numeric,
  created_at timestamptz,
  passenger_name text,
  passenger_email text,
  flight_id uuid,
  origin text,
  destination text,
  departure_time timestamptz,
  arrival_time timestamptz,
  seat_number text,
  return_date date,
  return_flight_id uuid,
  return_origin text,
  return_destination text,
  return_departure_time timestamptz,
  return_arrival_time timestamptz,
  return_seat_number text,
  card_brand text,
  last4 text,
  payment_result text,
  total_count bigint
)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists (
    select 1 from public.profiles pr
    where pr.id = auth.uid() and pr.role in ('admin', 'manager')
  ) then
    raise exception 'Access denied: admin or manager role required';
  end if;

  p_limit := least(greatest(coalesce(p_limit, 25), 1), 100);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  return query
  select
    r.id,
    r.status,
    r.price_paid,
    r.created_at,
    r.passenger_name,
    public.mask_email(r.passenger_email), -- was: r.passenger_email
    f.flight_id,
    f.origin,
    f.destination,
    f.departure_time,
    f.arrival_time,
    r.seat_number,
    r.return_date,
    rf.flight_id,
    rf.origin,
    rf.destination,
    rf.departure_time,
    rf.arrival_time,
    r.return_seat_number,
    p.card_brand,
    p.last4,
    p.result,
    count(*) over()::bigint as total_count
  from public.reservations r
  join public.flights f on f.flight_id = r.flight_id
  left join public.flights rf on rf.flight_id = r.return_flight_id
  left join public.payments p on p.reservation_id = r.id
  where (p_status is null or p_status = '' or r.status = p_status)
    and (p_origin is null or p_origin = '' or f.origin ilike '%' || p_origin || '%')
    and (p_destination is null or p_destination = '' or f.destination ilike '%' || p_destination || '%')
    and (p_date_from is null or f.departure_time::date >= p_date_from)
    and (p_date_to is null or f.departure_time::date <= p_date_to)
    and (
      -- Search still matches against the REAL email, not the masked one --
      -- a manager typing a full address they already know should still find
      -- the reservation; masking only affects what's displayed afterward.
      p_search is null or p_search = ''
      or r.passenger_name ilike '%' || p_search || '%'
      or r.passenger_email ilike '%' || p_search || '%'
      or r.id::text ilike p_search || '%'
    )
  order by r.created_at desc
  limit p_limit offset p_offset;
end;
$function$;

-- No grant changes needed -- get_all_reservations already has
-- `grant execute ... to authenticated` from 20260921050000_add_manager_role.sql,
-- and mask_email() is only ever called from inside a security definer
-- function (never directly by the client), so it needs no grant of its own.
