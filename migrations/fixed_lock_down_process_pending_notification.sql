-- S2-08: found by authorization tests T05/T26. process_pending_notification()
-- is internal: it is only called by the after-insert trigger and by
-- process_pending_notifications(), both SECURITY DEFINER functions owned by
-- postgres, and never by the web client. Visitors and customers could call it
-- directly and mark notification rows as processed.
revoke all on function public.process_pending_notification(uuid) from public, anon, authenticated;
