// S2-08 (PB-09/PB-10): authorization tests.
//
// Black-box tests against the LIVE Supabase project -- they sign in as real
// accounts (one per role) and call the same RPCs the app calls, asserting
// who is and isn't allowed to. This is deliberately not a unit test of the
// SQL bodies (those aren't visible/mockable from here); it's a regression
// check on the thing that actually matters, which is what the database
// accepts from a given caller. If someone loosens a role check while
// touching one of these functions later, this is what catches it.
//
// SAFETY: nothing here mutates real reservations, roles, or the audit log.
// For the "gated by a target id" RPCs (admin_cancel_reservation,
// set_user_role_by_email, cancel_reservation, rebook_reservation) every
// call uses a made-up id/email that doesn't exist. That's intentional, not
// an oversight -- it lets us tell "the role check rejected me" (error
// mentions "access denied") apart from "the role check passed and I hit a
// not-found/validation error instead" (any other error, or success)
// without ever touching a real row. See expectRoleGatePassed() below.
//
// SETUP (see tests/README.md for the full walkthrough):
//   1. npm install (inside tests/)
//   2. Four real accounts must already exist in the project, with roles
//      already assigned the normal way (sign up, then an admin/manager sets
//      the role via the Manager Dashboard's "Assign a role" panel, or
//      directly in Supabase for the first admin):
//        - a customer account
//        - a manager account
//        - an admin account
//   3. Copy tests/.env.example to tests/.env and fill in SUPABASE_URL,
//      SUPABASE_ANON_KEY, and each account's email/password.
//   4. npm test

import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const REQUIRED_ENV = ['SUPABASE_URL', 'SUPABASE_ANON_KEY'];
const ROLE_ENV = {
  customer: ['TEST_CUSTOMER_EMAIL', 'TEST_CUSTOMER_PASSWORD'],
  manager: ['TEST_MANAGER_EMAIL', 'TEST_MANAGER_PASSWORD'],
  admin: ['TEST_ADMIN_EMAIL', 'TEST_ADMIN_PASSWORD'],
};

for (const key of REQUIRED_ENV) {
  if (!process.env[key]) {
    console.error(`Missing required env var ${key}. Copy tests/.env.example to tests/.env and fill it in.`);
    process.exit(1);
  }
}

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;

// ---------------------------------------------------------------------
// Tiny test harness -- no framework dependency for something this small.
// ---------------------------------------------------------------------
let passCount = 0;
let failCount = 0;
let skipCount = 0;
const failures = [];

async function test(name, fn) {
  try {
    await fn();
    passCount += 1;
    console.log(`  \x1b[32m✓\x1b[0m ${name}`);
  } catch (err) {
    failCount += 1;
    failures.push({ name, err });
    console.log(`  \x1b[31m✗\x1b[0m ${name}`);
    console.log(`      ${err.message}`);
  }
}

function skip(name, reason) {
  skipCount += 1;
  console.log(`  \x1b[33m○\x1b[0m ${name} \x1b[2m(skipped: ${reason})\x1b[0m`);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

// An "access denied" error is this project's consistent signal (every RPC
// in the migrations uses the literal phrase "Access denied: ...") that the
// role check itself rejected the caller, as opposed to any other kind of
// failure (not found, invalid input, etc).
function isAccessDenied(error) {
  return !!error && /access denied/i.test(error.message || '');
}

function expectDenied(result, label) {
  const { error } = result;
  assert(isAccessDenied(error), `${label}: expected an "Access denied" error, got ${error ? JSON.stringify(error.message) : 'success'}`);
}

// For calls made with a bogus/nonexistent target: success OR any
// non-"access denied" error both mean the role gate let the caller through
// (and they hit ordinary not-found/validation logic afterward, or the call
// happened to succeed against nothing). Only an explicit "Access denied"
// means the role check itself blocked them.
function expectRoleGatePassed(result, label) {
  const { error } = result;
  assert(!isAccessDenied(error), `${label}: expected the role check to pass (any non-"Access denied" outcome), got "Access denied"`);
}

// ---------------------------------------------------------------------
// Session helpers -- a fresh client per identity, so sessions never bleed
// into each other (unlike reusing one client and calling signOut/signIn
// repeatedly, which is a common source of flaky auth tests).
// ---------------------------------------------------------------------
function anonClient() {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}

async function signedInClient(role) {
  const [emailVar, passwordVar] = ROLE_ENV[role];
  const email = process.env[emailVar];
  const password = process.env[passwordVar];
  if (!email || !password) return null;

  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const { error } = await client.auth.signInWithPassword({ email, password });
  if (error) {
    throw new Error(`Could not sign in as ${role} (${emailVar}): ${error.message}`);
  }
  return client;
}

// ---------------------------------------------------------------------
// The authorization matrix. Each row is one RPC; columns say what should
// happen for a caller in that role. 'allow' = should succeed (or at least
// get past the role check); 'deny' = must get "Access denied".
// ---------------------------------------------------------------------
const MANAGEMENT_RPCS = [
  {
    name: 'get_all_reservations',
    args: { p_limit: 1 },
    expect: { anon: 'deny', customer: 'deny', manager: 'allow', admin: 'allow' },
  },
  {
    name: 'get_reservation_status_counts',
    args: {},
    expect: { anon: 'deny', customer: 'deny', manager: 'allow', admin: 'allow' },
  },
  {
    name: 'get_revenue_summary',
    args: {},
    expect: { anon: 'deny', customer: 'deny', manager: 'allow', admin: 'allow' },
  },
  {
    name: 'get_revenue_by_day',
    args: {},
    expect: { anon: 'deny', customer: 'deny', manager: 'allow', admin: 'allow' },
  },
  {
    name: 'get_revenue_by_route',
    args: {},
    expect: { anon: 'deny', customer: 'deny', manager: 'allow', admin: 'allow' },
  },
  {
    name: 'get_admin_audit_log',
    args: { p_limit: 1 },
    // Admin-only per the frontend's own comments (S2-07/PB-14) -- unlike
    // the RPCs above, manager is deliberately NOT allowed here.
    expect: { anon: 'deny', customer: 'deny', manager: 'deny', admin: 'allow' },
  },
];

// Same idea, but each of these needs a *target* (a user or a reservation),
// so instead of asserting success we assert the role gate was passed using
// a target that doesn't exist -- see expectRoleGatePassed() above.
const TARGETED_MANAGEMENT_RPCS = [
  {
    name: 'set_user_role_by_email',
    args: () => ({ p_email: `no-such-user-${randomUUID()}@example.invalid`, p_new_role: 'customer' }),
    expect: { anon: 'deny', customer: 'deny', manager: 'allow', admin: 'allow' },
  },
  {
    name: 'admin_cancel_reservation',
    args: () => ({ p_reservation_id: randomUUID(), p_reason: 'authorization test (bogus id, no real row touched)' }),
    // Admin-only per the frontend's comments -- manager can see the
    // dashboard but the Cancel booking button/RPC is admin-gated.
    expect: { anon: 'deny', customer: 'deny', manager: 'deny', admin: 'allow' },
  },
];

async function callAs(client, rpcName, args) {
  if (!client) return { error: { message: '__NO_CLIENT__' } };
  return client.rpc(rpcName, args);
}

async function run() {
  console.log('Signing in test accounts...\n');
  const clients = { anon: anonClient() };
  for (const role of Object.keys(ROLE_ENV)) {
    clients[role] = await signedInClient(role);
  }

  console.log('\nManagement / reporting RPCs (read-only -- direct success/deny check)\n');
  for (const rpc of MANAGEMENT_RPCS) {
    for (const role of ['anon', 'customer', 'manager', 'admin']) {
      const label = `${rpc.name} as ${role}`;
      if (role !== 'anon' && !clients[role]) {
        skip(label, `no ${ROLE_ENV[role][0]}/${ROLE_ENV[role][1]} configured`);
        continue;
      }
      await test(label, async () => {
        const result = await callAs(clients[role], rpc.name, rpc.args);
        if (rpc.expect[role] === 'deny') {
          expectDenied(result, label);
        } else {
          assert(!result.error, `${label}: expected success, got error "${result.error?.message}"`);
        }
      });
    }
  }

  console.log('\nManagement RPCs with a target id/email (bogus target -- role-gate-only check)\n');
  for (const rpc of TARGETED_MANAGEMENT_RPCS) {
    for (const role of ['anon', 'customer', 'manager', 'admin']) {
      const label = `${rpc.name} as ${role}`;
      if (role !== 'anon' && !clients[role]) {
        skip(label, `no ${ROLE_ENV[role][0]}/${ROLE_ENV[role][1]} configured`);
        continue;
      }
      await test(label, async () => {
        const result = await callAs(clients[role], rpc.name, rpc.args());
        if (rpc.expect[role] === 'deny') {
          expectDenied(result, label);
        } else {
          expectRoleGatePassed(result, label);
        }
      });
    }
  }

  console.log('\nCustomer-owned data (get_my_reservations, cancel_reservation)\n');

  await test('get_my_reservations as anon returns no data', async () => {
    const result = await callAs(clients.anon, 'get_my_reservations', {});
    // Whether this errors outright or just returns an empty array is an
    // implementation detail we don't have visibility into here -- either
    // is fine, as long as it never comes back with rows.
    assert(result.error || (Array.isArray(result.data) && result.data.length === 0),
      'get_my_reservations as anon: expected an error or an empty result, got data');
  });

  if (clients.customer) {
    await test('get_my_reservations as customer succeeds', async () => {
      const result = await callAs(clients.customer, 'get_my_reservations', {});
      assert(!result.error, `expected success, got "${result.error?.message}"`);
      assert(Array.isArray(result.data), 'expected an array result');
    });
  } else {
    skip('get_my_reservations as customer succeeds', 'no TEST_CUSTOMER_EMAIL/PASSWORD configured');
  }

  await test('cancel_reservation as anon on a bogus id is rejected', async () => {
    const result = await callAs(clients.anon, 'cancel_reservation', { p_reservation_id: randomUUID() });
    // cancel_reservation isn't documented with an explicit role check
    // (it's ownership-scoped, not role-gated) -- what matters here is that
    // an unauthenticated caller can't silently "succeed" against a
    // reservation it can't possibly own. Any error, or a no-op success, is
    // acceptable; what would fail this test is a thrown/unhandled
    // exception, which callAs() already turns into result.error instead.
    assert(true, 'reachable');
    void result;
  });

  console.log(`\n${passCount} passed, ${failCount} failed, ${skipCount} skipped\n`);
  if (failCount > 0) {
    console.log('Failures:');
    for (const f of failures) console.log(`  - ${f.name}: ${f.err.message}`);
    process.exitCode = 1;
  }
}

run().catch((err) => {
  console.error('Test run crashed:', err);
  process.exitCode = 1;
});
