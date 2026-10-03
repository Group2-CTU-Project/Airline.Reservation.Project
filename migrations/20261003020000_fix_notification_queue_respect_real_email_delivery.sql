-- S2-05 fix: the every-minute cron (process_notification_queue) was marking
-- queued EMAIL notifications as 'sent' without delivering them, so the
-- send-cancellation-notifications Edge Function (Resend) never saw them.
-- When app_settings.real_email_delivery = true, email rows are now skipped
-- here and left 'queued' for the Edge Function.

create or replace function public.process_notification_queue(p_batch integer default 100)
returns table(sent_count integer, failed_count integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_sent integer := 0;
  v_failed integer := 0;
  v_real boolean;
  n record;
begin
  select coalesce((value)::boolean, false) into v_real
  from public.app_settings where key = 'real_email_delivery';
  v_real := coalesce(v_real, false);

  for n in
    select c.id, c.passenger_email
    from public.cancellation_notifications c
    where c.status = 'queued'
      -- When real delivery is on, email rows belong to the
      -- send-cancellation-notifications Edge Function (Resend).
      and not (v_real and c.notification_type = 'email')
    order by c.created_at
    limit greatest(p_batch, 1)
    for update skip locked
  loop
    if n.passenger_email ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' and n.passenger_email !~* '\.invalid$' then
      update public.cancellation_notifications c
         set status = 'sent', sent_at = now(), attempts = c.attempts + 1,
             failure_reason = 'Simulated delivery: real email delivery is turned off for this project.'
       where c.id = n.id;
      v_sent := v_sent + 1;
    else
      update public.cancellation_notifications c
         set status = 'failed', attempts = c.attempts + 1, failure_reason = 'Invalid email address'
       where c.id = n.id;
      v_failed := v_failed + 1;
    end if;
  end loop;
  return query select v_sent, v_failed;
end;
$function$;
