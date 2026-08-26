-- Wecomeone Task Board, widens the "task updated" email trigger
-- Run this once, otherwise the "task completed" and "sent back for changes"
-- emails never fire (the current trigger only notices a task entering Under
-- review, not leaving it).
-- Prepared by Wecomeone Marketing And Comms

drop trigger if exists task_updated_email on tasks;
create trigger task_updated_email
  after update on tasks
  for each row
  when (
    old.assignee is distinct from new.assignee
    or (old.status is distinct from new.status and (old.status = 'review' or new.status = 'review'))
  )
  execute function notify_task_email();
