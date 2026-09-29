-- ===========================================================================
-- 28. A place for the sync to say what it did
-- ===========================================================================
-- Every failure this pipeline has had was invisible until someone reconciled
-- totals by hand: n8n's backfill timing out for months, 29,284 phantom lines
-- accumulating, a refresh that only ever worked on the 1st. The runs now write
-- a log on the machine that ran them, which is better than nothing and no use
-- at all from a phone.
--
-- One row per JOB, not per run. `all` does ten of them and the useful question
-- is almost always "which one broke", not "did something break".
--
-- ---------------------------------------------------------------------------
-- THE FAILURE THIS TABLE CANNOT RECORD
-- ---------------------------------------------------------------------------
-- If the sync cannot reach Supabase -- no network, wrong service key, project
-- paused -- it writes nothing. There is no error row, because writing the
-- error row is the thing that failed. A page listing errors would show a clean
-- green history through a total outage.
--
-- So the page's primary element is not the error list, it is how long it has
-- been since a run last SUCCEEDED. Absence has to be visible, not just
-- failure. sync_health() below exists for exactly that and is deliberately the
-- first thing the page asks for.
--
-- Run in: Supabase -> SQL Editor. Safe to re-run.

create table if not exists public.dashboard_sync_runs (
  id          bigserial   primary key,
  -- One id per invocation of the CLI, so ten job rows can be shown as one run.
  run_id      uuid        not null,
  job         text        not null,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  rows        bigint,
  -- 'running' is a real state, not a placeholder: a job that is still marked
  -- running long after it started is how a killed process shows up. Without it
  -- a crash mid-job would leave no trace at all.
  status      text        not null default 'running'
              check (status in ('running', 'ok', 'failed')),
  error       text,
  host        text,
  -- One row per job per run. The sync writes twice for each job -- once when
  -- it starts, once when it ends -- and this is what makes the second write an
  -- update rather than a duplicate.
  unique (run_id, job)
);

create index if not exists idx_sync_runs_started
  on public.dashboard_sync_runs (started_at desc);
create index if not exists idx_sync_runs_run
  on public.dashboard_sync_runs (run_id);

alter table public.dashboard_sync_runs enable row level security;
drop policy if exists sync_runs_read on public.dashboard_sync_runs;
create policy sync_runs_read on public.dashboard_sync_runs
  for select to authenticated using (true);
grant select on public.dashboard_sync_runs to authenticated;

-- ---------------------------------------------------------------------------
-- sync_health -- the one number that matters
-- ---------------------------------------------------------------------------
-- Answers "is the data current", which is a different question from "did
-- anything error". A sync that has not run at all for three days is the worst
-- case and produces no errors whatsoever.
create or replace function public.sync_health()
returns table (
  last_success        timestamptz,
  hours_since_success numeric,
  last_run            timestamptz,
  last_run_status     text,
  failed_last_24h     bigint,
  stale               boolean
)
language sql
stable
security invoker
as $$
  with ok as (
    select max(finished_at) as t
    from public.dashboard_sync_runs
    where status = 'ok' and job = 'refresh'
  ),
  any_run as (
    select started_at, status
    from public.dashboard_sync_runs
    order by started_at desc
    limit 1
  )
  select ok.t,
         round(extract(epoch from (now() - ok.t)) / 3600.0, 1),
         any_run.started_at,
         any_run.status,
         (select count(*) from public.dashboard_sync_runs
           where status = 'failed' and started_at > now() - interval '24 hours'),
         -- 36 hours, not 24: the schedule is daily, so a run that slipped by a
         -- few hours -- a machine switched on late -- is not yet a problem.
         -- Flagging that would train someone to ignore the banner, which is
         -- the only way this page can fail at its job.
         coalesce(ok.t, timestamptz '-infinity') < now() - interval '36 hours'
  from ok, any_run;
$$;

grant execute on function public.sync_health() to authenticated;

-- ---------------------------------------------------------------------------
-- sync_runs -- recent history, newest run first
-- ---------------------------------------------------------------------------
create or replace function public.sync_runs(p_limit integer default 60)
returns table (
  run_id      uuid,
  job         text,
  started_at  timestamptz,
  finished_at timestamptz,
  seconds     numeric,
  rows        bigint,
  status      text,
  error       text,
  host        text
)
language sql
stable
security invoker
as $$
  select r.run_id, r.job, r.started_at, r.finished_at,
         round(extract(epoch from (coalesce(r.finished_at, now()) - r.started_at))::numeric, 1),
         r.rows, r.status, r.error, r.host
  from public.dashboard_sync_runs r
  order by r.started_at desc
  limit greatest(coalesce(p_limit, 60), 1);
$$;

grant execute on function public.sync_runs(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Housekeeping
-- ---------------------------------------------------------------------------
-- Ten rows a day is nothing, but nothing times forever is still a table nobody
-- prunes. Ninety days answers "when did this start going wrong" and stops.
create or replace function public.prune_sync_runs()
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare n bigint;
begin
  delete from public.dashboard_sync_runs where started_at < now() - interval '90 days';
  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.prune_sync_runs() to service_role;

-- ---------------------------------------------------------------------------
-- sync_record -- the one call the sync makes
-- ---------------------------------------------------------------------------
-- An RPC rather than a PostgREST insert/patch pair, because the sync's client
-- has rpc() and not much else, and because "start" and "finish" being the same
-- call means there is no path where a job records a start and then cannot
-- record its ending for want of a different method.
create or replace function public.sync_record(
  p_run_id uuid,
  p_job    text,
  p_status text,
  p_rows   bigint default null,
  p_error  text   default null,
  p_host   text   default null
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.dashboard_sync_runs
    (run_id, job, status, rows, error, host, started_at, finished_at)
  values (p_run_id, p_job, p_status, p_rows, p_error, p_host, now(),
          case when p_status = 'running' then null else now() end)
  on conflict (run_id, job) do update
    set status      = excluded.status,
        rows        = coalesce(excluded.rows, public.dashboard_sync_runs.rows),
        error       = excluded.error,
        -- started_at belongs to the FIRST write. Overwriting it on the closing
        -- call would make every job appear to take zero seconds.
        finished_at = excluded.finished_at;
$$;

grant execute on function public.sync_record(uuid, text, text, bigint, text, text)
  to service_role;

select * from public.sync_health();
