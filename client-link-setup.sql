-- Wecomeone Task Board, client facing progress links
-- Prepared by Wecomeone Marketing And Comms
--
-- Safe to run more than once.
-- No credentials in this file. Paste it into the SQL editor and run it.
--
-- What it does:
--   1. Adds two fields to tasks: whether a task may appear on a client link,
--      and a short update line written for the client to read.
--   2. Creates a table of links, one row per client, each with its own secret token.
--   3. Creates one read only function that a browser with a token may call.
--      It is the ONLY thing an unauthenticated visitor can reach, it returns
--      a fixed list of harmless fields, and it never returns briefs or comments.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- 1. Two new fields on tasks
-- ---------------------------------------------------------------------------

alter table tasks add column if not exists client_visible boolean not null default true;
alter table tasks add column if not exists client_note text not null default '';

comment on column tasks.client_visible is
  'False hides this task from the client progress link. Internal work, pitches, anything not for their eyes.';
comment on column tasks.client_note is
  'The one line the client reads. The brief and the comments never leave the board.';

-- ---------------------------------------------------------------------------
-- 2. The links
-- ---------------------------------------------------------------------------

create table if not exists client_links (
  id             uuid primary key default gen_random_uuid(),
  client         text not null unique,
  token          text not null unique default encode(extensions.gen_random_bytes(16),'hex'),
  headline       text not null default '',
  intro          text not null default '',
  show_dates     boolean not null default true,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  created_by     uuid references profiles(id) default auth.uid(),
  last_viewed_at timestamptz,
  view_count     integer not null default 0
);

alter table client_links enable row level security;

-- Only admins see or touch the links. Members never see the tokens.
drop policy if exists "admins manage client links" on client_links;
create policy "admins manage client links" on client_links
  for all to authenticated
  using      (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'))
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'));

-- ---------------------------------------------------------------------------
-- 3. The one door open to the outside world
--
--    security definer means this function reads the tasks table with the
--    privileges of its owner, bypassing row level security. That is the point,
--    the visitor has no account. It is safe only because the function itself
--    decides exactly which rows and which columns come back, and callers cannot
--    change that. It takes a token and nothing else.
-- ---------------------------------------------------------------------------

create or replace function public.client_progress(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l client_links%rowtype;
  items jsonb;
begin
  if p_token is null or length(p_token) < 16 then
    return jsonb_build_object('ok', false);
  end if;

  select * into l from client_links
   where token = p_token and active = true
   limit 1;

  if not found then
    return jsonb_build_object('ok', false);
  end if;

  update client_links
     set last_viewed_at = now(),
         view_count = view_count + 1
   where id = l.id;

  -- Note the shape of this: the only columns that can ever reach a client are
  -- the ones named here. Adding a field to tasks does not expose it.
  select coalesce(
           jsonb_agg(x.item order by x.sort_rank, x.sort_due nulls last, x.sort_title),
           '[]'::jsonb)
    into items
    from (
      select
        jsonb_build_object(
          'project',        t.project,
          'title',          t.title,
          'type',           t.type,
          'status',         t.status,
          'date_started',   case when l.show_dates then t.date_started   else null end,
          'due_date',       case when l.show_dates then t.due_date       else null end,
          'date_completed', case when l.show_dates then t.date_completed else null end,
          'client_note',    t.client_note
        ) as item,
        case t.status
          when 'in_progress' then 1
          when 'review'      then 2
          when 'waiting'     then 3
          when 'blocked'     then 4
          when 'not_started' then 5
          when 'done'        then 6
          else 7
        end as sort_rank,
        t.due_date as sort_due,
        t.title    as sort_title
      from tasks t
      where lower(trim(t.client)) = lower(trim(l.client))
        and t.client_visible = true
        -- completed work stays on the page for 60 days, then drops off
        and not (t.status = 'done'
                 and t.date_completed is not null
                 and t.date_completed < current_date - 60)
    ) x;

  return jsonb_build_object(
    'ok',         true,
    'client',     l.client,
    'headline',   l.headline,
    'intro',      l.intro,
    'show_dates', l.show_dates,
    'as_of',      now(),
    'tasks',      items
  );
end;
$$;

revoke all on function public.client_progress(text) from public;
grant execute on function public.client_progress(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Useful later
-- ---------------------------------------------------------------------------
-- Every link and how often it has been opened:
--   select client, token, active, view_count, last_viewed_at from client_links order by client;
--
-- Kill a link immediately, the URL stops working the moment this runs:
--   update client_links set active = false where client = 'CyLink';
--
-- Issue a fresh token for a client, the old URL dies:
--   update client_links set token = encode(extensions.gen_random_bytes(16),'hex') where client = 'CyLink';
--
-- See exactly what a client would see, without opening the page:
--   select jsonb_pretty(public.client_progress('PASTE_THE_TOKEN'));
