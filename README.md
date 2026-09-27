# Authorization tests (S2-08 / PB-09, PB-10)

Black-box tests against the live Supabase project: each test signs in as a
real account of a given role and calls the same RPCs the app calls,
asserting who is and isn't allowed to. This catches the case where a future
change accidentally loosens (or over-tightens) a role check on one of the
management/admin RPCs.

**Nothing here mutates real data.** Reservation-cancel and role-change calls
use a made-up id/email that doesn't exist, so we can tell "the role check
rejected me" apart from "the role check passed and I hit a normal
not-found error" without ever touching a real reservation or account.

## One-time setup

1. `npm install` (inside this `tests/` folder).
2. Make sure three real accounts already exist and can log in through the
   app, with roles already assigned the normal way:
   - a **customer** account (the default role after signup)
   - a **manager** account
   - an **admin** account

   If you don't have a manager/admin test account yet, sign up a normal
   account through the app, then use an existing admin/manager's "Assign a
   role" panel on the Manager Dashboard to promote it. (For the very first
   admin account on a fresh project, that has to be set directly in
   Supabase — same as when the manager role itself was first set up.)
3. Copy `.env.example` to `.env` and fill in:
   - `SUPABASE_URL` / `SUPABASE_ANON_KEY` — same values as in `index.html`.
   - Each test account's email and password.

## Running

```
npm test
```

Requires Node 20.6+ (uses `node --env-file`). On an older Node, either
upgrade, or run with the env vars exported another way, e.g.:

```
export $(cat .env | xargs) && node authorization.test.mjs
```

## What's covered

- **Management/reporting RPCs** (`get_all_reservations`,
  `get_reservation_status_counts`, `get_revenue_summary`,
  `get_revenue_by_day`, `get_revenue_by_route`): anonymous and customer
  callers must get "Access denied"; manager and admin must succeed.
- **`get_admin_audit_log`**: admin-only — manager is asserted to be
  *denied* here, unlike the RPCs above, matching the S2-07 design (managers
  see the dashboard but not the audit trail).
- **`set_user_role_by_email`**: anonymous/customer denied; manager and admin
  allowed (both can assign roles, per the S2-03 design).
- **`admin_cancel_reservation`**: admin-only — manager is denied.
- **`get_my_reservations`**: anonymous gets no rows; a signed-in customer
  gets their own (empty is fine — this just checks the call succeeds and
  shapes correctly).

## What's *not* covered yet

This suite only tests the role-gated management/admin RPCs — the layer this
sprint's PII-minimization work touches. It does **not** yet test
cross-customer ownership boundaries (e.g. "can customer A cancel customer
B's reservation?"), because that needs two real customer accounts that each
already have a known reservation, which isn't something this suite sets up
on its own. If you want to extend it: sign in as a second customer, note
one of their real reservation ids, then assert that the *first* customer's
`cancel_reservation`/`rebook_reservation` call against that id fails.
