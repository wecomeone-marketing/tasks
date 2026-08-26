-- Wecomeone Task Board, adds the "Review completed" status
-- Run this before using the new status, otherwise saving a task as
-- Review completed is rejected by the database ("Could not save"),
-- and the "review complete" / "sent back" emails won't go out.
-- Prepared by Wecomeone Marketing And Comms

-- 1. Allow the new status value.
alter table tasks drop constraint if exists tasks_status_check;
alter table tasks add constraint tasks_status_check
  check (status in ('not_started','in_progress','waiting','blocked','review','review_completed','done'));

-- 2. Widen the update trigger so it also fires when a task LEAVES review
--    (sent back for changes, or approved into Review completed) -- not just
--    when it enters review, like before.
drop trigger if exists task_updated_email on tasks;
create trigger task_updated_email
  after update on tasks
  for each row
  when (
    old.assignee is distinct from new.assignee
    or (old.status is distinct from new.status and (old.status = 'review' or new.status = 'review'))
  )
  execute function notify_task_email();
