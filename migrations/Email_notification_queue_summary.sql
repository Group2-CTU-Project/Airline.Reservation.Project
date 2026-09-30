-- S2-05: counts for the Manager Dashboard "Cancellation emails" panel.
create or replace function public.get_notification_queue_summary()
returns table(queued_count bigint, failed_count bigint, sent_count bigint, real_delivery boolean, last_failure text)
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

  return query
  select
    count(*) filter (where n.status = 'queued')::bigint,
    count(*) filter (where n.status = 'failed')::bigint,
    count(*) filter (where n.status = 'sent')::bigint,
    coalesce((select (s.value)::boolean from public.app_settings s where s.key = 'real_email_delivery'), false),
    (select f.failure_reason from public.cancellation_notifications f
      where f.status = 'failed' order by f.created_at desc limit 1)
  from public.cancellation_notifications n
  where n.notification_type = 'email';
end;
$function$;

revoke all on function public.get_notification_queue_summary() from public, anon;
grant execute on function public.get_notification_queue_summary() to authenticated;

-- Real delivery was switched on after the Resend secrets were configured:
update public.app_settings set value = 'true'::jsonb, updated_at = now()
where key = 'real_email_delivery';
