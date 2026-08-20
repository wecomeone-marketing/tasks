# How this board is built

Prepared by Wecomeone Marketing And Comms

The whole tool is one file, `index.html` in the root of this repo, served by GitHub Pages at
[tasks.wecomeone.me](https://tasks.wecomeone.me). It has no build step and no dependencies to
install. Edit the file, commit it, and the live site updates itself within a minute.

Everything in this `setup` folder is the database side. You do not need any of it to use the
board or to change how it looks. You need it if you ever rebuild the backend from scratch, or
if someone other than Andreas has to understand how the pieces fit.

## The pieces

| Piece | Where it lives | What it does |
|---|---|---|
| The board | `index.html`, this repo | Everything you see and click |
| The database | Supabase project `wecomeone-tasks` | Tasks, comments, team profiles |
| Sign in | Supabase Auth | Email and password, invite only |
| Emails | Supabase Edge Function `notify` | Assignment, reassignment, comments, due dates |
| The domain | Cloudflare CNAME on wecomeone.me | tasks.wecomeone.me points at GitHub Pages |

The page talks to Supabase directly from the browser using the publishable key, which is why
that key sits in plain sight inside `index.html`. It is designed to be public. What actually
protects the data is row level security, defined in `02-permissions.sql`. Nothing is readable
without a signed in account.

## Rebuilding from nothing

Run the three scripts below in order in the Supabase SQL editor, then do the four dashboard
steps in between as noted. Finally update the two values in the `CONFIG` block at the top of
`index.html` to point at the new project.

---

## Script 1, the tables

```sql
-- Wecomeone Task Board, step 1 of 4: the database
-- Run once, in the Supabase SQL editor, on a fresh project.
-- Prepared by Wecomeone Marketing And Comms

-- Team profiles, one row per signed in person
create table profiles (
  id uuid primary key references auth.users on delete cascade,
  full_name text not null,
  email text,
  role text not null default 'member' check (role in ('admin','member'))
);

-- Tasks
create table tasks (
  id uuid primary key default gen_random_uuid(),
  client text not null default '',
  project text not null default '',
  title text not null,
  type text not null default 'Content',
  assignee uuid references profiles(id),
  priority text not null default 'medium' check (priority in ('low','medium','high','urgent')),
  status text not null default 'not_started'
    check (status in ('not_started','in_progress','waiting','blocked','review','done')),
  date_started date,
  due_date date,
  date_completed date,
  notes text default '',
  links text default '',
  waiting_on text default '',
  waiting_since date,
  created_by uuid references profiles(id) default auth.uid(),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Comment thread per task
create table comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid references tasks(id) on delete cascade,
  author uuid references profiles(id) default auth.uid(),
  body text not null,
  created_at timestamptz default now()
);

-- Keep updated_at honest
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create trigger tasks_touch before update on tasks
  for each row execute function touch_updated_at();

-- Create a profile automatically when someone accepts their invite.
-- The address below becomes the admin. Change it for a different agency.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', initcap(split_part(new.email,'@',1))),
    new.email,
    case when new.email = 'hello@wecomeone.me' then 'admin' else 'member' end
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Useful indexes
create index tasks_status_idx   on tasks(status);
create index tasks_assignee_idx on tasks(assignee);
create index tasks_due_idx      on tasks(due_date);
create index comments_task_idx  on comments(task_id);
```

---

## Script 2, who can see and do what

```sql
-- Wecomeone Task Board, step 2 of 4: who can see and do what
-- Run once, after 01-schema.sql.
-- Prepared by Wecomeone Marketing And Comms
--
-- The rules in one sentence: nothing is readable without signing in, everyone can
-- create and edit, only admins can delete, and a task assigned to an admin is
-- visible only to that admin.

alter table profiles enable row level security;
alter table tasks    enable row level security;
alter table comments enable row level security;

-- Profiles
drop policy if exists "team reads profiles" on profiles;
create policy "team reads profiles" on profiles
  for select to authenticated using (true);

drop policy if exists "admins manage profiles" on profiles;
create policy "admins manage profiles" on profiles
  for update to authenticated using (
    exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
  );

-- Tasks. The admin clause is what makes an admin's own tasks private.
drop policy if exists "team reads tasks" on tasks;
create policy "team reads tasks" on tasks
  for select to authenticated using (
    assignee is null
    or assignee = auth.uid()
    or not exists (
      select 1 from profiles p where p.id = tasks.assignee and p.role = 'admin'
    )
  );

drop policy if exists "team creates tasks" on tasks;
create policy "team creates tasks" on tasks
  for insert to authenticated with check (true);

drop policy if exists "team updates tasks" on tasks;
create policy "team updates tasks" on tasks
  for update to authenticated using (
    assignee is null
    or assignee = auth.uid()
    or not exists (
      select 1 from profiles p where p.id = tasks.assignee and p.role = 'admin'
    )
  );

drop policy if exists "admins delete tasks" on tasks;
create policy "admins delete tasks" on tasks
  for delete to authenticated using (
    exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
  );

-- Comments follow whatever the task allows, so hidden tasks do not leak
-- through their comment thread.
drop policy if exists "team reads comments" on comments;
create policy "team reads comments" on comments
  for select to authenticated using (
    exists (select 1 from tasks t where t.id = comments.task_id)
  );

drop policy if exists "team posts comments" on comments;
create policy "team posts comments" on comments
  for insert to authenticated with check (author = auth.uid());
```

### Then, in the Supabase dashboard

1. **Authentication, Users, Invite user** for each person on the team.
2. **Authentication, Providers, Email**, turn off "Allow new users to sign up", so only invited
   people can get in.
3. **Authentication, URL Configuration**, set the site URL to the live address and add it to the
   redirect list. Skip this and every invite and password reset link points at localhost.
4. **Project Settings, Authentication, SMTP Settings**, point it at a real mail account,
   otherwise you are limited to a couple of emails an hour.

---

## Script 3, the notification emails

Before running this one: deploy `notify.ts` as an Edge Function named `notify`, and add two
secrets under Edge Functions, Secrets: `SMTP_USER` and `SMTP_PASS`.

Then replace `PASTE_SERVICE_ROLE_KEY_HERE` below in both places with the service role key from
Project Settings, API Keys.

```sql
-- Wecomeone Task Board, email triggers and the daily due date job
-- Prepared by Wecomeone Marketing And Comms
--
-- BEFORE RUNNING: replace PASTE_SERVICE_ROLE_KEY_HERE below with your service role key.
-- Find it in Project Settings, API Keys, Legacy anon service_role API keys, the service_role one.
-- It appears twice. Replace both.
--
-- That key is full access. It is safe here because this SQL runs inside your own database
-- and never reaches the browser, but never put it in the HTML page or the GitHub repo.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema extensions;

-- ---------------------------------------------------------------------------
-- 1. One function that pokes the edge function whenever something happens
-- ---------------------------------------------------------------------------

create or replace function notify_task_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url     := 'https://nubkifzfuvmmuwwiqwkk.supabase.co/functions/v1/notify',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer PASTE_SERVICE_ROLE_KEY_HERE'
               ),
    body    := jsonb_build_object(
                 'type',       tg_op,
                 'table',      tg_table_name,
                 'record',     to_jsonb(new),
                 'old_record', case when tg_op = 'UPDATE' then to_jsonb(old) else null end
               )
  );
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. When to fire it
-- ---------------------------------------------------------------------------

drop trigger if exists task_created_email on tasks;
create trigger task_created_email
  after insert on tasks
  for each row execute function notify_task_email();

-- only when the task actually changes hands
drop trigger if exists task_reassigned_email on tasks;
create trigger task_reassigned_email
  after update on tasks
  for each row
  when (old.assignee is distinct from new.assignee)
  execute function notify_task_email();

drop trigger if exists comment_posted_email on comments;
create trigger comment_posted_email
  after insert on comments
  for each row execute function notify_task_email();

-- ---------------------------------------------------------------------------
-- 3. The daily due date run
--    05:00 UTC, which is 08:00 in Cyprus during summer and 07:00 in winter.
-- ---------------------------------------------------------------------------

select cron.unschedule('task-board-due-today')
where exists (select 1 from cron.job where jobname = 'task-board-due-today');

select cron.schedule(
  'task-board-due-today',
  '0 5 * * *',
  $job$
  select net.http_post(
    url     := 'https://nubkifzfuvmmuwwiqwkk.supabase.co/functions/v1/notify',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer PASTE_SERVICE_ROLE_KEY_HERE'
               ),
    body    := jsonb_build_object('mode', 'due-today')
  );
  $job$
);

-- ---------------------------------------------------------------------------
-- Useful later
-- ---------------------------------------------------------------------------
-- See the schedule:            select * from cron.job;
-- See recent runs:             select * from cron.job_run_details order by start_time desc limit 20;
-- See recent outbound calls:   select * from net._http_response order by created desc limit 20;
-- Turn the daily email off:    select cron.unschedule('task-board-due-today');
-- Turn all task emails off:    alter table tasks disable trigger task_created_email;
```

## Rules worth knowing before you change anything

An admin's own tasks are private. That is the third clause in the tasks read policy. It keys off
the admin role, not off a name, so promoting someone to admin also hides their tasks from
everyone else.

Deleting is admin only, deliberately. Members can do everything except delete, which is what
stops accidental data loss on a shared board.

The service role key must never appear in `index.html` or anywhere in this repo. It bypasses
every permission rule. It belongs in the SQL editor and in Edge Function secrets only.

## Client links

One read only page per client, at `/p/#<token>`. The page is `p/index.html`, the database side
is `client-link-setup.sql`, and both are in this repo.

Three moving parts:

- `tasks.client_visible` and `tasks.client_note`. Visibility defaults to true, so a new task on
  a client shows up on their page unless someone unticks it. The note is the only free text a
  client ever reads. The brief, the links and the comment thread stay internal.
- `client_links`, one row per client, each with its own random token. Row level security limits
  the whole table to admins, so a member never sees a token.
- `public.client_progress(text)`, a security definer function granted to `anon`. It is the only
  thing an unauthenticated visitor can reach. It takes a token, nothing else, and returns a fixed
  list of fields built by hand inside the function. Adding a column to `tasks` does not expose it.

The token lives in the URL fragment, after the `#`, which browsers never send to a server. It
stays out of access logs and out of referrer headers.

Completed work drops off the page sixty days after its completion date.

Switching a link off, or replacing the token, kills the old address immediately. Both are one
click in the board, under the avatar menu, Client links.

## Steps inside a task

Some jobs have phases. A month of social is built as a grid first and scheduled after,
and before this the board had no way to say half. `steps-setup.sql` adds a `steps` column
to `tasks`, a jsonb array of `{id, text, done}`, with a check constraint so a bad write
cannot put something other than a list in there.

Steps sit on the task rather than in a table of their own. That keeps them atomic with the
task, needs no second query and no second security policy. The cost is that two people
editing the steps of the same task at the same moment would have the last save win, which
is not worth a table for a team of two.

Three things in the page hang off it:

- The task panel has a Steps list, add with enter, tick to complete, drag to reorder.
- Cards and table rows show a count, and only when a task actually has steps.
- Saving a task as Completed while a step is unticked opens a dialog rather than going
  through quietly. That is the case this was built for.

`TYPE_STEPS` near the top of the script holds the default lists per task type. Social Media
is the only one filled in. Choosing that type on a new task drops the steps in, and they are
ordinary steps from that moment, editable and deletable. Add a type to that object and it
gains the same behaviour, no other change needed.

Steps also feed the Progress by client panel. Where a task has them, the count of ticked
steps is used instead of the status estimate, whichever reads further along. Nothing reaches
a hundred until the task is marked Completed.

The client progress page never sees steps. The `client_progress` function names its columns
by hand and steps is not among them.
