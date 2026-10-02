-- Widen get_admin_audit_log() from admin-only to admin-or-manager, so
-- managers can monitor what admins are doing (specifically: admin
-- cancellations) without being able to perform those actions themselves.
--
-- Nothing else about the function changes -- same signature, same columns,
-- same join/paging logic. Only the role check at the top widens, matching
-- the pattern already used for revenue reporting (see
-- 20260921070000_widen_revenue_reporting_to_manager.sql) and the email
-- queue (20260930000000_notification_queue_summary.sql, admin-or-manager).
--
-- admin_cancel_reservation() itself is UNCHANGED and stays admin-only --
-- this migration only widens who can *read* the trail, not who can act.
-- The client already gates the "Cancel booking" button to admin accounts
-- only (renderManagerReservationCard in index.html), so this migration
-- alone is enough to make "view-only for managers" the enforced reality,
-- not just a UI assumption.

create or replace function public.get_admin_audit_log(
  p_action text default null,
  p_limit integer default 25,
  p_offset integer default 0
)
returns table(
  log_id uuid,
  logged_at timestamptz,
  actor_name text,
  actor_email text,
  action_type text,
  target_reservation_id uuid,
  target_name text,
  reason_text text,
  details_json jsonb,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not exists (
    select 1 from public.profiles pr
    where pr.id = auth.uid() and pr.role in ('admin', 'manager')
  ) then
    raise exception 'Access denied: admin or manager role required';
  end if;

  return query
  select a.id,
         a.created_at,
         actor.full_name,
         actor.email,
         a.action,
         a.target_reservation_id,
         coalesce(res.passenger_name, tgt.full_name, tgt.email),
         a.reason,
         a.details,
         count(*) over ()
  from public.admin_audit_log a
  left join public.profiles actor on actor.id = a.admin_id
  left join public.reservations res on res.id = a.target_reservation_id
  left join public.profiles tgt on tgt.id = a.target_user_id
  where p_action is null or a.action = p_action
  order by a.created_at desc
  limit least(greatest(coalesce(p_limit, 25), 1), 100)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$function$;

-- Verify after running:
--   select pg_get_functiondef('public.get_admin_audit_log'::regproc);
-- should show "role in ('admin', 'manager')" in the check above.
