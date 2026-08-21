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
    check (status in ('not_started','in_progress','review','waiting','done')),
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
-- visible only to that admin unless it is Under review.

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
-- The review clause is the one exception: work handed over for checking stays
-- visible to the person who handed it over, otherwise it vanishes from their
-- board at the moment they most want to keep an eye on it.
drop policy if exists "team reads tasks" on tasks;
create policy "team reads tasks" on tasks
  for select to authenticated using (
    assignee is null
    or assignee = auth.uid()
    or status = 'review'
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
    or status = 'review'
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
                 -- who is actually doing this, so the function can avoid
                 -- emailing someone about a change they made themselves
                 'actor',      auth.uid(),
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

An admin's own tasks are private. That is the last clause in the tasks read policy. It keys off
the admin role, not off a name, so promoting someone to admin also hides their tasks from
everyone else.

The one exception is `status = 'review'`. Without it the board punished the handover it was
built for: a member finishes a job, moves it to Under review and puts it on the admin, and it
disappears off her own board at the moment she most wants to watch it. So work Under review is
visible to everyone regardless of whose list it is on. The moment it moves on, to Completed or
back to In progress, the privacy rule applies again.

That cuts both ways and it is deliberate. Completed work on an admin's list is private, which
means an admin who finishes someone else's task without handing it back takes it out of their
sight for good, archive included. Put it back on their name before completing it.

Deleting is admin only, deliberately. Members can do everything except delete, which is what
stops accidental data loss on a shared board.

The service role key must never appear in `index.html` or anywhere in this repo. It bypasses
every permission rule. It belongs in the SQL editor and in Edge Function secrets only.

## The steps column, kept but not used

`steps-setup.sql` added a `steps` column to `tasks`, a jsonb array of `{id, text, done}`.
The board had a checklist on the task panel for a while, so that a month of social could
show the grid built and the scheduling still open.

That checklist was removed. Nothing in `index.html` reads or writes `steps` any more.

The column is still there on purpose. It holds the steps that were entered before the
feature came out, so nothing was thrown away, and it costs nothing to leave in place. If
the checklist ever comes back the data is waiting for it. If you are sure it never will,
`alter table tasks drop column steps;` and delete `steps-setup.sql` from the repo.

Task type is a plain text column holding one or more types, comma separated, for example
`Graphic Design, Social Media`. The card offers them as checkboxes. A filter on a type
matches a task when that type is one of several, so anything tagged partly SEO still shows
up under SEO.
