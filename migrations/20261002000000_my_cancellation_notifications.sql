-- Let a customer see what actually happened when their reservation was
-- cancelled, instead of My Trips just saying "cancelled" with nothing else.
--
-- Two sources, both scoped to the caller's own reservation:
--   1. cancellation_notifications -- the emailed notice (status/timing/
--      whether it actually sent). Its `message` column is a static,
--      non-personalized template ("Your reservation has been cancelled by
--      an administrator.") -- it does NOT carry the admin's reason.
--   2. admin_audit_log.reason -- the actual free-text reason the admin
--      typed into "Cancel this booking" (admin_cancel_reservation requires
--      >=3 chars, see 20260926000000_s2_07_admin_audit_hardening.sql).
--      This is the part worth showing someone; the notification row alone
--      is just delivery plumbing.
--
-- Neither table has RLS policies defined (cancellation_notifications isn't
-- in 20260921040000_baseline_rls_policies.sql, and admin_audit_log has
-- insert/update/delete revoked from clients but no SELECT policy either),
-- so a customer could not safely be given direct table access to either
-- one -- admin_audit_log in particular is otherwise admin/manager-only
-- (get_admin_audit_log()). This RPC re-checks reservation ownership itself
-- and returns only the one reason string, nothing else from that log.

create or replace function public.get_my_cancellation_notifications(p_reservation_id uuid)
returns table(
  notification_id uuid,
  event text,
  notification_type text,
  status text,
  message text,
  created_at timestamptz,
  sent_at timestamptz,
  failure_reason text,
  admin_reason text,
  admin_cancelled_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $function$
begin
  -- Ownership check: the reservation must belong to the caller. (Checking
  -- against reservations.user_id rather than cancellation_notifications.
  -- user_id directly means this still raises a clear error if the
  -- reservation doesn't exist at all, instead of silently returning zero
  -- rows either way.)
  if not exists (
    select 1 from public.reservations r
    where r.id = p_reservation_id and r.user_id = auth.uid()
  ) then
    raise exception 'Reservation not found';
  end if;

  -- Viewing it counts as read, same idea as any other notification inbox.
  update public.cancellation_notifications n
  set read_at = now()
  where n.reservation_id = p_reservation_id
    and n.user_id = auth.uid()
    and n.read_at is null;

  return query
  select n.id,
         n.event,
         n.notification_type,
         n.status,
         n.message,
         n.created_at,
         n.sent_at,
         n.failure_reason,
         a.reason,
         a.created_at
  from public.cancellation_notifications n
  left join lateral (
    select al.reason, al.created_at
    from public.admin_audit_log al
    where al.target_reservation_id = p_reservation_id
      and al.action = 'admin_cancel_reservation'
    order by al.created_at desc
    limit 1
  ) a on true
  where n.reservation_id = p_reservation_id
    and n.user_id = auth.uid()
  order by n.created_at desc;
end;
$function$;

grant execute on function public.get_my_cancellation_notifications(uuid) to authenticated;

-- Verify after running:
--   select proname, prosecdef from pg_proc where proname = 'get_my_cancellation_notifications';
-- then, signed in as a customer with a reservation an admin cancelled with
-- a reason:
--   select * from get_my_cancellation_notifications('<that reservation's id>');
-- -- admin_reason should show the exact text the admin typed, not the
-- generic cancellation_notifications.message.
-- Also confirm it raises "Reservation not found" for a reservation_id that
-- belongs to someone else.
