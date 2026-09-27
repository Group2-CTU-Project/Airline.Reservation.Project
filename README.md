# Cloud Nine Airline Reservations

-Site link: https://Group4-CTU-Project.github.io/Airline.Reservation.Project/

A Sprint 1 demo project for an airline reservation system, built with a static HTML/JS front end and a Supabase backend (Postgres + RPC functions for auth, bookings, payments, and seat selection).

## Structure

- `index.html` — the demo app. Open it directly in a browser (no build step). On first load, replace `SUPABASE_URL` and `SUPABASE_ANON_KEY` near the bottom of the file with your own Supabase project's values (Settings → API).
- `migrations/` — SQL migrations, in the order they should be run, based on their timestamp prefix (`YYYYMMDDHHMMSS_description.sql`). Apply them in order against your Supabase project.

## Features

- Account creation, login with failed-attempt lockout, and role-based content (server-enforced via RPC).
- Flight search, round-trip booking with automatic return-flight lookup, and seat selection.
- Payment step with saved payment methods.
- "My trips" view with e-tickets/receipts and trip cancellation.

## Working on this repo

To keep history clean and avoid overwriting each other's work:

1. **Don't upload files directly to `main`.** Create a branch first (or use GitHub's "Create a new branch and start a pull request" option when uploading).
2. **Open a pull request** for any change, even a small one, so it's easy to see what changed and to review before it lands on `main`.
3. **Merge through the PR**, not by re-uploading the same file to `main`.

This avoids duplicate files (like the old `index.html` copies) and lost work sitting only on someone's laptop.

## How to create a branch (step by step)

Before making any change — even a small one — create a branch first. Don't upload or edit files directly on `main`.

1. **Go to the repo's main page** and make sure the branch dropdown (top left, next to the repo name) shows `main`. Branches are always created *from* whatever branch you're currently on, so start from `main` unless you have a reason not to.
2. **Click the branch dropdown.** A search box appears.
3. **Type a name for your branch.** Use something short that describes the change, like `add-seat-map` or `fix-login-bug` — not your name or the date.
4. **Click "Create branch: [your branch name] from main."** GitHub creates it and switches you onto it — check that the dropdown now shows your new branch name instead of `main`.
5. **Make your changes on this branch.** Edit files, upload files, or use "Add file → Upload files" as normal — anything you do now happens on your branch, not on `main`, so `main` stays untouched.
   - **To edit an existing file's code:** double-check the branch dropdown still shows your branch (not `main`), then click into the file you want to change. Click the pencil (✏️) icon in the top right of the file view to open the editor.
   - Make your changes directly in the editor. GitHub highlights lines you've changed in green (added) and red (removed) in a preview tab, so you can double check what you actually changed before committing.
   - Scroll to the bottom. Under "Commit changes," write a short message describing what you changed (e.g. "Add password reset flow").
   - Make sure **"Commit directly to the `[your branch name]` branch"** is selected — not `main`. This option only appears if you're on a branch other than `main`, which is another reason step 1 matters.
   - Click **"Commit changes."** This saves your edit to the branch only; `main` still has the old version until you merge.
6. **When you're ready, open a pull request.** Go to the "Pull requests" tab → "New pull request." Set `base: main` and `compare: [your branch name]`, then click "Create pull request."
7. **Review the changes, then merge.** Once you (or your teammate) have looked over the diff and it looks right, click "Merge pull request," then confirm.
8. **Delete the branch after merging** (GitHub will offer a button for this right after the merge). Its work is now safely part of `main`, so the branch has done its job.

**If you're uploading a file** (via "Add file → Upload files") instead of editing in the browser: after choosing your file(s), scroll down to the commit box at the bottom. There's an option there to **"Create a new branch for this commit and start a pull request."** Selecting that does steps 1–6 above automatically in one motion — it's the fastest way to avoid uploading straight to `main` by accident.
