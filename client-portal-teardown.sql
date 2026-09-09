-- ════════════════════════════════════════════════════════════════════
-- Techstar Client Portal — teardown script
-- Undoes everything created by client-portal-setup.sql.
-- Run this once in Supabase Studio → SQL Editor → New query → Run.
-- Safe to re-run (every step uses IF EXISTS).
--
-- This restores your database to how it was before the Client Portal
-- was set up: dev_support / func_support / projects go back to having
-- no RLS at all (matching their original, pre-portal state), and every
-- portal-only table, view, and mapping is dropped.
--
-- Your original internal app tables/data (dev_support, func_support,
-- projects, and their actual ticket rows) are NOT touched — only the
-- portal scaffolding around them is removed.
-- ════════════════════════════════════════════════════════════════════

-- 1) Drop the locked-down portal views ──────────────────────────────
drop view if exists public.portal_dev_support;
drop view if exists public.portal_func_support;
drop view if exists public.portal_projects;

-- 2) Drop portal-only tables ─────────────────────────────────────────
drop table if exists public.helpdesk_status_map;
drop table if exists public.client_requesters;
drop table if exists public.client_accounts;

-- 3) Remove the policies added on dev_support / func_support / projects
drop policy if exists dev_support_anon_full   on public.dev_support;
drop policy if exists func_support_anon_full  on public.func_support;
drop policy if exists projects_anon_full      on public.projects;
drop policy if exists dev_support_client_read  on public.dev_support;
drop policy if exists func_support_client_read on public.func_support;
drop policy if exists projects_client_read     on public.projects;

-- 4) Turn RLS back off on those tables, restoring their original,
--    pre-portal state (open access via the anon key, no RLS involved).
alter table public.dev_support  disable row level security;
alter table public.func_support disable row level security;
alter table public.projects     disable row level security;

-- 5) Restore default table privileges for `authenticated` on the raw
--    tables (the setup script revoked these; Supabase's default is to
--    grant them, so we put that back in case anything else in your
--    project relies on the default authenticated grants).
grant all on public.dev_support  to authenticated;
grant all on public.func_support to authenticated;
grant all on public.projects     to authenticated;

-- Done. The Supabase Auth *users* you created for client logins (via
-- index.html → Client Portal → Add Client Login, or via signups) are
-- NOT deleted by this script — Postgres row deletion here doesn't
-- reach into auth.users. If you also want those logins gone, remove
-- them from Supabase Studio → Authentication → Users, or leave them —
-- they no longer grant any portal access since client_accounts (and
-- the views that depended on it) are gone.
