-- Wecomeone Task Board, steps inside a task
-- Prepared by Wecomeone Marketing And Comms
--
-- Safe to run more than once. No credentials in this file.
--
-- Why this exists: some tasks have phases. A month of social is one job with two
-- stages, build the grid and then schedule it. Without this the only honest options
-- were to keep the task In progress and lose track of how far it had got, or to
-- split it into two tasks and double the rows on every retainer, every month.
--
-- The shape of each step:  { "id": "abc123", "text": "Build the grid", "done": true }
--
-- Steps live on the task as jsonb rather than in a table of their own. That keeps
-- them atomic with the task, needs no second query and no second security policy.
-- The cost: two people editing the steps of the SAME task at the same moment would
-- have the last save win. With a team of two that is not worth a table for.

alter table tasks add column if not exists steps jsonb not null default '[]'::jsonb;

-- Reject anything that is not a list, so a bad write cannot break the board
alter table tasks drop constraint if exists tasks_steps_is_array;
alter table tasks add constraint tasks_steps_is_array check (jsonb_typeof(steps) = 'array');

comment on column tasks.steps is
  'Phases within one task. Array of {id, text, done}. The client progress page never sees these.';

-- ---------------------------------------------------------------------------
-- Useful later
-- ---------------------------------------------------------------------------
-- Tasks marked completed with a step still open, which should be nothing:
--   select title, steps from tasks
--    where status = 'done'
--      and exists (select 1 from jsonb_array_elements(steps) s where (s->>'done')::boolean is not true);
--
-- How far through its steps everything is:
--   select title,
--          jsonb_array_length(steps) as total,
--          (select count(*) from jsonb_array_elements(steps) s where (s->>'done')::boolean) as done
--     from tasks where jsonb_array_length(steps) > 0 order by title;
