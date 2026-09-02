-- ════════════════════════════════════════════════════════════════════
-- Techstar Client Portal — one-time Supabase setup (v5 — Finished vs
-- Pending Payments split, Deployed mapping, hidden statuses)
-- Run this once in Supabase Studio → SQL Editor → New query → Run.
-- Safe to re-run (uses IF NOT EXISTS / DROP ... IF EXISTS throughout,
-- and never overwrites a mapping you've since customized).
--
-- SECURITY MODEL
-- ─────────────────────────────────────────────────────────────────────
-- Row-level AND column-level enforcement live in the database, not in
-- the browser. A logged-in client can never retrieve another client's
-- rows, and can never retrieve any column beyond the 5 approved ones —
-- even by editing the request in dev tools, changing an id, or asking
-- for select=* — because:
--
--   1. The `authenticated` role (what a logged-in portal user becomes)
--      is given ZERO privileges on the raw dev_support / func_support /
--      projects tables. No SELECT, no INSERT, no UPDATE, no DELETE.
--      Querying those tables directly returns nothing / permission
--      denied, no matter what filters are attached to the request.
--
--   2. Instead, `authenticated` is granted SELECT on three narrow VIEWS
--      (portal_dev_support / portal_func_support / portal_projects)
--      that expose ONLY: description, month, year, completed_date,
--      invoice_number, and helpdesk_status (a translated Kanban stage
--      name — see step 3). No hours, no rates, no raw internal status,
--      no payment state, no developer info, nothing else — those
--      columns simply do not exist in the view, so they cannot be
--      requested at all.
--
--   3. Each view's WHERE clause hard-codes the row filter to
--      "req is one of the requester names assigned to the caller's own
--      company (via client_requesters), looked up through auth.uid()".
--      This filter is baked into the view server-side — it is not a
--      client-supplied parameter, and cannot be overridden, widened,
--      or removed by anything sent from the browser.
--
--   4. Your existing internal app (index.html, using the anon key,
--      unauthenticated) is completely unaffected — it keeps its
--      existing full-table anon policy and full column access.
--
--   5. `client_accounts` (which maps a login to a company) is never
--      readable via the anon key, and a logged-in client can only ever
--      read their OWN single row in it.
-- ════════════════════════════════════════════════════════════════════

-- 1) client_accounts table ─────────────────────────────────────────────
create table if not exists public.client_accounts (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text not null,
  company_name text not null,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

create index if not exists client_accounts_company_idx on public.client_accounts (company_name);

alter table public.client_accounts enable row level security;

drop policy if exists client_accounts_self_select on public.client_accounts;
create policy client_accounts_self_select
  on public.client_accounts
  for select
  to authenticated
  using (id = auth.uid());

-- No anon policies, and no authenticated insert/update/delete policies,
-- are created on purpose: creating and managing client logins is done
-- from index.html using your service_role key, which always bypasses RLS.

-- 2) Enable RLS on your existing ticket tables ──────────────────────────
alter table public.dev_support  enable row level security;
alter table public.func_support enable row level security;
alter table public.projects     enable row level security;

-- 2a) Preserve full access for your existing internal app (anon key) ────
drop policy if exists dev_support_anon_full on public.dev_support;
create policy dev_support_anon_full
  on public.dev_support for all to anon using (true) with check (true);

drop policy if exists func_support_anon_full on public.func_support;
create policy func_support_anon_full
  on public.func_support for all to anon using (true) with check (true);

drop policy if exists projects_anon_full on public.projects;
create policy projects_anon_full
  on public.projects for all to anon using (true) with check (true);

-- 2b) Remove any prior "authenticated can read raw rows" policy — this is
-- the exact hole that used to let a logged-in client fetch every column
-- (hours, rates, dev pay, status, etc.) for their own rows. Clients now
-- get access ONLY through the narrow views created in step 3.
drop policy if exists dev_support_client_read  on public.dev_support;
drop policy if exists func_support_client_read on public.func_support;
drop policy if exists projects_client_read     on public.projects;

-- 2c) Belt-and-suspenders: explicitly strip ALL table privileges from
-- `authenticated` on the raw tables, regardless of RLS policy state.
revoke all on public.dev_support  from authenticated;
revoke all on public.func_support from authenticated;
revoke all on public.projects     from authenticated;

-- 3) Client → requester name mapping ────────────────────────────────
-- `req` on your tickets holds individual staff names (e.g. "Theekshana",
-- "Udara"), not a company identifier — one client can have many
-- requesters. This table maps "these requester names belong to this
-- client company", so a client login can cover every ticket raised by
-- anyone at that company, and this scales cleanly if you add a second
-- client with a different set of names later.

create table if not exists public.client_requesters (
  company_name    text not null,
  requester_name  text not null,
  primary key (company_name, requester_name)
);

alter table public.client_requesters enable row level security;
revoke all on public.client_requesters from authenticated, anon, public;
-- No grants for anon/authenticated on purpose — only read from inside
-- the owner-executed portal views below, and managed via the
-- service_role key from index.html → Client Portal tab.

-- Seed: assign every requester name currently in use to Techstar
-- Packaging (Private) Limited (today's only client). Safe to re-run —
-- ON CONFLICT means it will never duplicate or remove an assignment
-- you've since changed. To onboard a second client later, insert rows
-- here (or from the admin UI) mapping their requester names to their
-- own company_name instead.
insert into public.client_requesters (company_name, requester_name)
select 'Techstar Packaging (Private) Limited', req
from (
  select distinct req from public.dev_support where req is not null and req <> ''
  union
  select distinct req from public.func_support where req is not null and req <> ''
  union
  select distinct req from public.projects where req is not null and req <> ''
) r
on conflict (company_name, requester_name) do nothing;

-- 4) Help Desk status mapping ────────────────────────────────────────
-- The internal app's Project Status values ('With Developer',
-- 'Prepare Quote/Scope', etc.) are internal process language and are
-- NEVER sent to the portal. Instead, this lookup table translates each
-- internal status into one of the 8 client-facing Kanban stage names.
-- The RAW status column itself is never exposed in the portal views
-- below — only the translated helpdesk_status ever reaches the browser.
--
-- To change the mapping later, just run an UPDATE/INSERT against this
-- table — no code changes, no redeploy, no need to touch the views.
-- (This table is also editable from index.html → Client Portal tab.)

create table if not exists public.helpdesk_status_map (
  internal_status  text primary key,
  helpdesk_status  text not null,
  hidden           boolean not null default false,
  updated_at       timestamptz not null default now()
);

-- Seed the current mapping (only inserted if the row doesn't exist yet,
-- so re-running this script never overwrites a mapping you've since
-- customized in the admin UI). "Finished" is the status that also
-- triggers moving a ticket into Invoiced Dev/Func/Projects internally.
-- "Pending Payments" does NOT move it internally — it just flags it for
-- this Kanban column. "SetOff Action" is hidden entirely — it's an
-- internal accounting status with no client-facing meaning.
insert into public.helpdesk_status_map (internal_status, helpdesk_status, hidden) values
  ('With Developer',      'New Request',               false),
  ('Prepare Quote/Scope',  'Scope & SRS In-Progress',  false),
  ('Approve Quote/Scope',  'Pending Client Approval',  false),
  ('Client Testing',       'Client Testing',           false),
  ('Deployed',             'Deployed Production',      false),
  ('Pending Payments',     'Pending Payment - Projects', false),
  ('Finished',             'Finished',                  false),
  ('SetOff Action',        'New Request',               true)
on conflict (internal_status) do nothing;

-- The 8 valid Kanban columns, in board order. Enforced with a check
-- constraint so a typo in the admin UI can't silently create a 9th,
-- unrecognized column that would never render on the board.
alter table public.helpdesk_status_map drop constraint if exists helpdesk_status_valid;
alter table public.helpdesk_status_map add constraint helpdesk_status_valid
  check (helpdesk_status in (
    'New Request','Scope & SRS In-Progress','Pending Client Approval',
    'Functional Testing','Client Testing','Deployed Production',
    'Pending Payment - Projects','Finished'
  ));

-- Not exposed to anon or authenticated directly — it's only ever read
-- from inside the owner-executed portal views below (and managed from
-- index.html via the service_role key, which bypasses RLS entirely).
alter table public.helpdesk_status_map enable row level security;

-- 5) Locked-down, column-limited views for the portal ───────────────────
-- Ordinary (non security_invoker) views run with the privileges of the
-- view's owner, not the caller — so `authenticated` never needs, and
-- never gets, direct access to the underlying tables. The WHERE clause
-- below is the only row filter that matters, and it cannot be bypassed
-- from the browser. Raw `status` is deliberately NOT selected — only
-- the mapped `helpdesk_status` is, via the lookup table above. Rows are
-- scoped by ANY requester name assigned to the caller's company via
-- client_requesters — not by req = company_name directly (req holds an
-- individual's name, not a company).

drop view if exists public.portal_dev_support;
create view public.portal_dev_support as
  select
    t.id,
    t.dev  as description,
    t.month,
    t.year,
    t.comp as completed_date,
    t.inv  as invoice_number,
    coalesce(m.helpdesk_status, 'New Request') as helpdesk_status
  from public.dev_support t
  left join public.helpdesk_status_map m on m.internal_status = t.status
  where coalesce(m.hidden, false) = false
    and t.req in (
    select cr.requester_name
    from public.client_requesters cr
    join public.client_accounts ca on ca.company_name = cr.company_name
    where ca.id = auth.uid() and ca.active
  );

drop view if exists public.portal_func_support;
create view public.portal_func_support as
  select
    t.id,
    t.dev  as description,
    t.month,
    t.year,
    t.comp as completed_date,
    t.inv  as invoice_number,
    coalesce(m.helpdesk_status, 'New Request') as helpdesk_status
  from public.func_support t
  left join public.helpdesk_status_map m on m.internal_status = t.status
  where coalesce(m.hidden, false) = false
    and t.req in (
    select cr.requester_name
    from public.client_requesters cr
    join public.client_accounts ca on ca.company_name = cr.company_name
    where ca.id = auth.uid() and ca.active
  );

drop view if exists public.portal_projects;
create view public.portal_projects as
  select
    t.id,
    t.dev  as description,
    t.month,
    t.year,
    t.comp as completed_date,
    t.inv  as invoice_number,
    coalesce(m.helpdesk_status, 'New Request') as helpdesk_status
  from public.projects t
  left join public.helpdesk_status_map m on m.internal_status = t.status
  where coalesce(m.hidden, false) = false
    and t.req in (
    select cr.requester_name
    from public.client_requesters cr
    join public.client_accounts ca on ca.company_name = cr.company_name
    where ca.id = auth.uid() and ca.active
  );

-- Lock the views down to logged-in portal users only. Note: Supabase
-- auto-grants broad privileges (INSERT/UPDATE/DELETE/etc.) to anon and
-- authenticated on every new object by default — the revokes below
-- strip those back down before the narrow grant is added, so
-- `authenticated` ends up with SELECT and nothing else.
revoke all on public.portal_dev_support  from authenticated, anon, public;
revoke all on public.portal_func_support from authenticated, anon, public;
revoke all on public.portal_projects     from authenticated, anon, public;
grant select on public.portal_dev_support  to authenticated;
grant select on public.portal_func_support to authenticated;
grant select on public.portal_projects     to authenticated;

-- Same reasoning for client_accounts: RLS already restricts authenticated
-- to "select own row only" and anon to nothing, but the raw grants are
-- stripped too so security never depends on RLS alone.
revoke all on public.client_accounts from authenticated, anon, public;
grant select on public.client_accounts to authenticated;

-- helpdesk_status_map is never accessed directly by anon or authenticated
-- — only read from inside the owner-executed portal views, and managed
-- via the service_role key. No grants for either role at all.
revoke all on public.helpdesk_status_map from authenticated, anon, public;

-- Done. Next steps:
--   1. In index.html → "Client Portal" tab, paste your service_role key
--      (Project Settings → API → service_role secret) and create a login
--      for your client (e.g. company name "Techstar Packaging (Private)
--      Limited"). The requester names that belong to that company are
--      controlled by the client_requesters table above, not by matching
--      req to the company name directly.
--   2. Host portal.html at a URL you can share with that client, and
--      send them their email + password.
--
-- Safe to re-run in full at any time — every step uses IF EXISTS / IF
-- NOT EXISTS / ON CONFLICT DO NOTHING, and never overwrites a mapping
-- you've since customized by hand or from the admin UI.
