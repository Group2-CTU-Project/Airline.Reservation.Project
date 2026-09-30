-- =============================================================================
-- Cloud Nine - S2-08 / S2-09 authorization, row-level security and PII tests
-- =============================================================================
-- Run in the Supabase SQL editor (or via the MCP execute_sql tool).
-- The script impersonates real accounts (anonymous visitor, two different
-- customers, a manager and an admin) by setting the same JWT claims and
-- database role that the Supabase API uses, then tries what each should and
-- should not be able to do.
--
-- EVERYTHING IS ROLLED BACK: the block ends by raising an exception whose
-- message is the result table, so no test write ever persists.
-- Result format:  Txx | PASS/FAIL | who | what was tried | observed
-- =============================================================================
do $tests$
declare
  v_admin uuid; v_mgr uuid; v_c1 uuid; v_c2 uuid; v_c2_email text;
  v_res uuid; v_res_status text; v_flight2 uuid; v_notif uuid;
  v_n bigint; v_txt text; v_ok boolean; v_err text;
  v_expected_own bigint;
  out text[] := '{}';
begin
  -- ---------- fixtures (read as the database owner) -------------------------
  select id into v_admin from public.profiles where role = 'admin'   order by id limit 1;
  select id into v_mgr   from public.profiles where role = 'manager' order by id limit 1;
  select r.id, r.user_id, r.status into v_res, v_c1, v_res_status
    from public.reservations r join public.profiles p on p.id = r.user_id
   where p.role = 'customer' and r.status in ('confirmed', 'pending')
   order by r.created_at desc limit 1;
  select id, email into v_c2, v_c2_email from public.profiles
   where role = 'customer' and id <> v_c1 order by id limit 1;
  select flight_id into v_flight2 from public.flights
   where flight_id <> (select flight_id from public.reservations where id = v_res) limit 1;
  select id into v_notif from public.cancellation_notifications limit 1;
  select count(*) into v_expected_own from public.reservations where user_id = v_c1;

  if v_admin is null or v_mgr is null or v_c1 is null or v_c2 is null or v_res is null then
    raise exception 'Missing fixtures: need an admin, a manager, and two customers (one with an active reservation).';
  end if;

  -- =========================================================================
  -- A. Anonymous visitor (not logged in)
  -- =========================================================================
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  perform set_config('role', 'anon', true);

  select count(*) into v_n from public.flights;
  out := out || format('T01|%s|Visitor|Browse flights (public)|%s rows visible', case when v_n > 0 then 'PASS' else 'FAIL' end, v_n);

  begin select count(*) into v_n from public.reservations;
    out := out || format('T02|%s|Visitor|Read reservations table|%s rows visible', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);
  exception when others then out := out || format('T02|PASS|Visitor|Read reservations table|blocked: %s', sqlerrm); end;

  begin select count(*) into v_n from public.profiles;
    out := out || format('T03|%s|Visitor|Read user profiles (names, emails)|%s rows visible', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);
  exception when others then out := out || format('T03|PASS|Visitor|Read user profiles (names, emails)|blocked: %s', sqlerrm); end;

  begin perform public.get_all_reservations(null,null,null,null,null,null,10,0);
    out := array_append(out, 'T04|FAIL|Visitor|Call manager reservation search|call succeeded');
  exception when others then out := out || format('T04|PASS|Visitor|Call manager reservation search|blocked: %s', sqlerrm); end;

  begin perform public.process_pending_notification(v_notif);
    out := array_append(out, 'T05|FAIL|Visitor|Mark a cancellation email as processed|call succeeded');
  exception when others then out := out || format('T05|PASS|Visitor|Mark a cancellation email as processed|blocked: %s', sqlerrm); end;

  begin select count(*) into v_n from public.app_settings;
    out := out || format('T06|%s|Visitor|Read app settings|%s rows visible', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);
  exception when others then out := out || format('T06|PASS|Visitor|Read app settings|blocked: %s', sqlerrm); end;

  -- =========================================================================
  -- B. Customer 2 trying to reach Customer 1's data
  -- =========================================================================
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', json_build_object('sub',v_c2,'role','authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  select count(*) into v_n from public.reservations where user_id = v_c1;
  out := out || format('T07|%s|Customer|Read another customer''s reservations|%s rows visible', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);

  select count(*) into v_n from public.profiles;
  out := out || format('T08|%s|Customer|Read other users'' profiles|%s profile(s) visible (own only = 1)', case when v_n <= 1 then 'PASS' else 'FAIL' end, v_n);

  select count(*) into v_n from public.cancellation_notifications where user_id <> v_c2;
  out := out || format('T09|%s|Customer|Read other users'' cancellation emails|%s rows visible', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);

  begin select count(*) into v_n from public.payments;
    out := out || format('T10|%s|Customer|Read payments table directly|%s rows visible', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);
  exception when others then out := out || format('T10|PASS|Customer|Read payments table directly|blocked: %s', sqlerrm); end;

  begin select count(*) into v_n from public.payment_methods;
    out := out || format('T11|%s|Customer|Read saved cards table directly|%s rows visible', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);
  exception when others then out := out || format('T11|PASS|Customer|Read saved cards table directly|blocked: %s', sqlerrm); end;

  begin perform public.cancel_reservation(v_res);
    out := array_append(out, 'T12|FAIL|Customer|Cancel another customer''s booking|call succeeded');
  exception when others then out := out || format('T12|PASS|Customer|Cancel another customer''s booking|blocked: %s', sqlerrm); end;

  begin perform public.rebook_reservation(v_res, v_flight2);
    out := array_append(out, 'T13|FAIL|Customer|Rebook another customer''s booking|call succeeded');
  exception when others then out := out || format('T13|PASS|Customer|Rebook another customer''s booking|blocked: %s', sqlerrm); end;

  begin perform public.process_payment(v_res, 'Visa', '4242', 'tok_test', false);
    out := array_append(out, 'T14|FAIL|Customer|Pay for another customer''s booking|call succeeded');
  exception when others then out := out || format('T14|PASS|Customer|Pay for another customer''s booking|blocked: %s', sqlerrm); end;

  begin select count(*) into v_n from public.get_alternate_flights(v_res);
    out := out || format('T15|%s|Customer|List rebooking options on another''s booking|%s rows returned', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);
  exception when others then out := out || format('T15|PASS|Customer|List rebooking options on another''s booking|blocked: %s', sqlerrm); end;

  begin
    update public.profiles set role = 'admin' where id = v_c2;
    get diagnostics v_n = row_count;
    out := out || format('T16|%s|Customer|Promote own account to admin (direct update)|%s rows changed', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);
  exception when others then out := out || format('T16|PASS|Customer|Promote own account to admin (direct update)|blocked: %s', sqlerrm); end;

  begin perform public.set_user_role_by_email(v_c2_email, 'admin');
    out := array_append(out, 'T17|FAIL|Customer|Promote own account to admin (role function)|call succeeded');
  exception when others then out := out || format('T17|PASS|Customer|Promote own account to admin (role function)|blocked: %s', sqlerrm); end;

  begin
    update public.reservations set status = 'confirmed' where user_id = v_c2;
    get diagnostics v_n = row_count;
    out := out || format('T18|%s|Customer|Edit own reservation rows directly (price/status)|%s rows changed', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);
  exception when others then out := out || format('T18|PASS|Customer|Edit own reservation rows directly (price/status)|blocked: %s', sqlerrm); end;

  begin
    update public.flights set flight_id = flight_id;
    get diagnostics v_n = row_count;
    out := out || format('T19|%s|Customer|Edit flights (prices, seats)|%s rows changed', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);
  exception when others then out := out || format('T19|PASS|Customer|Edit flights (prices, seats)|blocked: %s', sqlerrm); end;

  begin select count(*) into v_n from public.admin_audit_log;
    out := out || format('T20|%s|Customer|Read admin audit log|%s rows visible', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);
  exception when others then out := out || format('T20|PASS|Customer|Read admin audit log|blocked: %s', sqlerrm); end;

  -- Customer calling manager/admin-only functions
  begin perform public.get_all_reservations(null,null,null,null,null,null,10,0);
    out := array_append(out, 'T21|FAIL|Customer|Search all reservations (manager)|call succeeded');
  exception when others then out := out || format('T21|PASS|Customer|Search all reservations (manager)|blocked: %s', sqlerrm); end;

  begin perform public.get_revenue_summary(null, null);
    out := array_append(out, 'T22|FAIL|Customer|View revenue report (manager)|call succeeded');
  exception when others then out := out || format('T22|PASS|Customer|View revenue report (manager)|blocked: %s', sqlerrm); end;

  begin perform public.get_reservation_status_counts();
    out := array_append(out, 'T23|FAIL|Customer|View dashboard counts (manager)|call succeeded');
  exception when others then out := out || format('T23|PASS|Customer|View dashboard counts (manager)|blocked: %s', sqlerrm); end;

  begin perform public.admin_cancel_reservation(v_res, 'authorization test');
    out := array_append(out, 'T24|FAIL|Customer|Admin-cancel a booking|call succeeded');
  exception when others then out := out || format('T24|PASS|Customer|Admin-cancel a booking|blocked: %s', sqlerrm); end;

  begin perform public.get_notification_queue_summary();
    out := array_append(out, 'T25|FAIL|Customer|View email queue (manager)|call succeeded');
  exception when others then out := out || format('T25|PASS|Customer|View email queue (manager)|blocked: %s', sqlerrm); end;

  begin perform public.process_pending_notification(v_notif);
    out := array_append(out, 'T26|FAIL|Customer|Mark a cancellation email as processed|call succeeded');
  exception when others then out := out || format('T26|PASS|Customer|Mark a cancellation email as processed|blocked: %s', sqlerrm); end;

  -- =========================================================================
  -- C. Customer 1 reading their own data (must still work)
  -- =========================================================================
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', json_build_object('sub',v_c1,'role','authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  select count(*) into v_n from public.get_my_reservations();
  out := out || format('T27|%s|Customer|View own trips (My Trips)|%s of %s own reservations returned', case when v_n = v_expected_own then 'PASS' else 'FAIL' end, v_n, v_expected_own);

  -- =========================================================================
  -- D. Manager: can monitor, cannot administer, sees masked PII
  -- =========================================================================
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', json_build_object('sub',v_mgr,'role','authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  select count(*), bool_and(passenger_email is null or passenger_email like '%**%@%')
    into v_n, v_ok from public.get_all_reservations(null,null,null,null,null,null,1000,0);
  out := out || format('T28|%s|Manager|Search all reservations|%s rows returned', case when v_n > 0 then 'PASS' else 'FAIL' end, v_n);
  out := out || format('T29|%s|Manager|Passenger emails are masked (PII minimization)|all masked = %s', case when coalesce(v_ok, true) then 'PASS' else 'FAIL' end, coalesce(v_ok, true));

  begin perform public.get_revenue_summary(null, null);
    out := array_append(out, 'T30|PASS|Manager|View revenue report|allowed');
  exception when others then out := out || format('T30|FAIL|Manager|View revenue report|blocked: %s', sqlerrm); end;

  begin perform public.get_notification_queue_summary();
    out := array_append(out, 'T31|PASS|Manager|View email queue|allowed');
  exception when others then out := out || format('T31|FAIL|Manager|View email queue|blocked: %s', sqlerrm); end;

  begin perform public.admin_cancel_reservation(v_res, 'authorization test');
    out := array_append(out, 'T32|FAIL|Manager|Admin-cancel a booking (admin only)|call succeeded');
  exception when others then out := out || format('T32|PASS|Manager|Admin-cancel a booking (admin only)|blocked: %s', sqlerrm); end;

  -- Designed feature: the "Assign a role" panel lets managers set roles for
  -- other accounts (20260921050000_add_manager_role.sql). Verify it works,
  -- and that a manager cannot change their own role.
  begin perform public.set_user_role_by_email(v_c2_email, 'manager');
    out := array_append(out, 'T33|PASS|Manager|Assign a role to another account (designed feature)|allowed and audit-logged');
  exception when others then out := out || format('T33|FAIL|Manager|Assign a role to another account (designed feature)|blocked: %s', sqlerrm); end;

  begin perform public.set_user_role(v_mgr, 'admin');
    out := array_append(out, 'T39|FAIL|Manager|Promote own account to admin|call succeeded');
  exception when others then out := out || format('T39|PASS|Manager|Promote own account to admin|blocked: %s', sqlerrm); end;

  begin select count(*) into v_n from public.get_admin_audit_log(null, 10, 0);
    out := out || format('T34|FAIL|Manager|Read admin audit log (admin only)|%s rows returned', v_n);
  exception when others then out := out || format('T34|PASS|Manager|Read admin audit log (admin only)|blocked: %s', sqlerrm); end;

  -- =========================================================================
  -- E. Admin: full access works
  -- =========================================================================
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', json_build_object('sub',v_admin,'role','authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  begin select count(*) into v_n from public.get_admin_audit_log(null, 10, 0);
    out := out || format('T35|PASS|Admin|Read admin audit log|%s rows returned', v_n);
  exception when others then out := out || format('T35|FAIL|Admin|Read admin audit log|blocked: %s', sqlerrm); end;

  v_ok := true;
  begin perform public.admin_cancel_reservation(v_res, 'authorization test (rolled back)');
  exception when others then v_ok := false; v_err := sqlerrm; end;

  -- =========================================================================
  -- F. Structural PII checks (as owner)
  -- =========================================================================
  perform set_config('role', 'none', true);

  select pg_get_function_result('public.get_taken_seats(uuid)'::regprocedure) into v_txt;
  out := out || format('T37|%s|Any user|Seat map exposes only seat numbers|returns %s', case when v_txt = 'TABLE(seat_number text)' then 'PASS' else 'FAIL' end, v_txt);

  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name in ('payments','payment_methods')
     and (column_name ilike '%card_number%' or column_name ilike '%cvv%' or column_name ilike '%cvc%' or column_name ilike '%pan%');
  out := out || format('T38|%s|System|No full card numbers or CVV stored|%s such columns', case when v_n = 0 then 'PASS' else 'FAIL' end, v_n);

  if v_ok then
    select status into v_txt from public.reservations where id = v_res;
    out := out || format('T36|%s|Admin|Admin-cancel a booking|status became %s (undone by rollback)', case when v_txt = 'cancelled' then 'PASS' else 'FAIL' end, v_txt);
  else
    out := out || format('T36|FAIL|Admin|Admin-cancel a booking|blocked: %s', v_err);
  end if;

  raise exception E'RESULTS\n%', (select string_agg(x, E'\n' order by x) from unnest(out) x);
end
$tests$;
