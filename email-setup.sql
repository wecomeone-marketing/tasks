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
                 'actor',      auth.uid(),
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

-- One trigger for edits, not two. If a task both changes hands and moves into
-- Review in the same save, this fires once and the function decides what to send.
-- Two separate triggers would fire twice and send everything twice.
drop trigger if exists task_reassigned_email on tasks;
drop trigger if exists task_review_email on tasks;
drop trigger if exists task_updated_email on tasks;
create trigger task_updated_email
  after update on tasks
  for each row
  when (
    old.assignee is distinct from new.assignee
    or (old.status is distinct from new.status and new.status = 'review')
  )
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
--                              alter table tasks disable trigger task_updated_email;
