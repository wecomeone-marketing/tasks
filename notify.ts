// Wecomeone Task Board, email notifications
// Prepared by Wecomeone Marketing And Comms
//
// Handles four jobs:
//   1. a task is created            -> email the assignee
//   2. a task is reassigned         -> email the new assignee
//   2b. a task moves into Under review -> email the admins, it is waiting on them
//   3. a comment is posted          -> email the task assignee
//   4. a daily run each morning     -> email assignee and admins about tasks due today
//
// Secrets this function needs (Edge Functions, Secrets):
//   SMTP_USER  hello@wecomeone.me
//   SMTP_PASS  the Google app password, no spaces

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const BOARD_URL = "https://tasks.wecomeone.me";
const TIMEZONE = "Europe/Nicosia";
const FROM_NAME = "Wecomeone Task Board";

const SMTP_USER = Deno.env.get("SMTP_USER")!;
const SMTP_PASS = Deno.env.get("SMTP_PASS")!;

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const STATUS_LABEL: Record<string, string> = {
  not_started: "Not started",
  in_progress: "In progress",
  review: "Under review",
  waiting: "Waiting",
  done: "Completed",
};

const PRIORITY_LABEL: Record<string, string> = {
  low: "Low", medium: "Medium", high: "High", urgent: "Urgent",
};

function today(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: TIMEZONE }).format(new Date());
}

function niceDate(d: string | null): string {
  if (!d) return "no date set";
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: TIMEZONE, day: "2-digit", month: "short", year: "numeric",
  }).format(new Date(d + "T00:00:00Z"));
}

function esc(s: unknown): string {
  return String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
}

// ---------------------------------------------------------------- email shell

function shell(heading: string, intro: string, body: string): string {
  return `<!doctype html><html><body style="margin:0;padding:24px;background:#f9f9f7;
    font-family:system-ui,-apple-system,'Segoe UI',sans-serif;color:#0b0b0b">
    <div style="max-width:560px;margin:0 auto;background:#fcfcfb;border:1px solid #e1e0d9;
                border-radius:12px;padding:28px">
      <p style="margin:0 0 4px;font-size:12px;letter-spacing:.05em;text-transform:uppercase;
                color:#898781">Wecomeone Task Board</p>
      <h1 style="margin:0 0 12px;font-size:19px;letter-spacing:-.01em">${esc(heading)}</h1>
      <p style="margin:0 0 20px;font-size:14px;color:#52514e;line-height:1.5">${intro}</p>
      ${body}
      <p style="margin:24px 0 0">
        <a href="${BOARD_URL}" style="display:inline-block;background:#0b0b0b;color:#fff;
           text-decoration:none;padding:10px 18px;border-radius:8px;font-size:14px;
           font-weight:500">Open the board</a>
      </p>
    </div>
  </body></html>`;
}

function taskCard(t: Record<string, unknown>): string {
  const rows: [string, string][] = [
    ["Client", `${esc(t.client)}${t.project ? " &middot; " + esc(t.project) : ""}`],
    ["Type", esc(t.type)],
    ["Priority", esc(PRIORITY_LABEL[t.priority as string] ?? t.priority)],
    ["Status", esc(STATUS_LABEL[t.status as string] ?? t.status)],
    ["Due", esc(niceDate(t.due_date as string | null))],
  ];
  return `<div style="border:1px solid #e1e0d9;border-radius:10px;padding:16px;background:#fff">
    <p style="margin:0 0 12px;font-size:16px;font-weight:600">${esc(t.title)}</p>
    <table style="width:100%;border-collapse:collapse;font-size:13px">
      ${rows.map(([k, v]) => `<tr>
        <td style="padding:3px 0;color:#898781;width:80px">${k}</td>
        <td style="padding:3px 0">${v}</td></tr>`).join("")}
    </table>
    ${t.notes ? `<p style="margin:12px 0 0;padding-top:12px;border-top:1px solid #e1e0d9;
       font-size:13px;color:#52514e;white-space:pre-wrap">${esc(t.notes)}</p>` : ""}
  </div>`;
}

// ---------------------------------------------------------------- sending

async function send(to: string, subject: string, html: string) {
  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: { username: SMTP_USER, password: SMTP_PASS },
    },
  });
  try {
    await client.send({
      from: `${FROM_NAME} <${SMTP_USER}>`,
      to,
      subject,
      html,
      content: "This message needs an email client that can show formatting.",
    });
  } finally {
    await client.close();
  }
}

// ---------------------------------------------------------------- lookups

async function profile(id: string | null) {
  if (!id) return null;
  const { data } = await db.from("profiles")
    .select("id, full_name, email, role").eq("id", id).maybeSingle();
  return data;
}

async function admins() {
  const { data } = await db.from("profiles")
    .select("id, full_name, email").eq("role", "admin");
  return data ?? [];
}

// ---------------------------------------------------------------- handlers

async function onTaskCreated(task: Record<string, unknown>) {
  const who = await profile(task.assignee as string | null);
  if (!who?.email) return "no assignee";
  // do not email someone about a task they just created for themselves
  if (task.created_by && task.created_by === task.assignee) return "self assigned, skipped";

  const from = await profile(task.created_by as string | null);
  await send(
    who.email,
    `New task: ${task.title}`,
    shell(
      "A task has been assigned to you",
      `${esc(from?.full_name ?? "Someone")} added this to your list.`,
      taskCard(task),
    ),
  );
  return `sent to ${who.email}`;
}

async function onTaskReassigned(task: Record<string, unknown>, actor: string | null) {
  const who = await profile(task.assignee as string | null);
  if (!who?.email) return "no assignee";
  // taking a task onto your own list is not news to you
  if (actor && actor === task.assignee) return "took it themselves, skipped";
  // handing back finished work is filing, not an assignment. It appears in their
  // archive the moment it is saved, which is all the notice anyone needs.
  if (task.status === "done") return "already finished, no email";

  const from = await profile(actor);
  await send(
    who.email,
    `Reassigned to you: ${task.title}`,
    shell(
      "A task has been handed to you",
      from?.full_name
        ? `${esc(from.full_name)} moved this onto your list.`
        : "This was on someone else's list and is now on yours.",
      taskCard(task),
    ),
  );
  return `sent to ${who.email}`;
}

async function onMovedToReview(task: Record<string, unknown>, actor: string | null) {
  const who = await profile(task.assignee as string | null);
  const mover = await profile(actor);
  const sent: string[] = [];

  for (const admin of await admins()) {
    if (!admin.email) continue;
    if (admin.id === actor) continue;           // you moved it yourself, you know
    await send(
      admin.email,
      `Ready for review: ${task.title}`,
      shell(
        "A task is waiting on you",
        `${esc(mover?.full_name ?? who?.full_name ?? "Someone")} moved this into Under review.`,
        taskCard(task),
      ),
    );
    sent.push(admin.email);
  }
  return sent.length ? `sent to ${sent.join(", ")}` : "no admin to tell";
}

async function onComment(comment: Record<string, unknown>) {
  const { data: task } = await db.from("tasks")
    .select("*").eq("id", comment.task_id as string).maybeSingle();
  if (!task) return "task gone";

  const author = await profile(comment.author as string | null);
  const owner = await profile(task.assignee as string | null);
  if (!owner?.email) return "no assignee";
  if (owner.id === comment.author) return "own comment, skipped";

  const quote = `<div style="border-left:3px solid #e1e0d9;padding:2px 0 2px 14px;margin:0 0 16px;
      font-size:14px;color:#52514e;white-space:pre-wrap">${esc(comment.body)}</div>`;
  await send(
    owner.email,
    `New comment: ${task.title}`,
    shell(
      `${author?.full_name ?? "Someone"} commented`,
      "On a task assigned to you.",
      quote + taskCard(task),
    ),
  );
  return `sent to ${owner.email}`;
}

async function dueToday() {
  const day = today();
  const { data: tasks } = await db.from("tasks")
    .select("*").eq("due_date", day).neq("status", "done");

  if (!tasks || tasks.length === 0) return "nothing due today";

  // one email per person, listing everything of theirs due today
  const buckets = new Map<string, Record<string, unknown>[]>();
  for (const t of tasks) {
    if (!t.assignee) continue;
    if (!buckets.has(t.assignee)) buckets.set(t.assignee, []);
    buckets.get(t.assignee)!.push(t);
  }

  const sent: string[] = [];

  for (const [assignee, list] of buckets) {
    const who = await profile(assignee);
    if (!who?.email) continue;
    await send(
      who.email,
      list.length === 1 ? `Due today: ${list[0].title}` : `${list.length} tasks due today`,
      shell(
        list.length === 1 ? "You have a task due today" : `You have ${list.length} tasks due today`,
        `Due ${esc(niceDate(day))}.`,
        list.map(taskCard).join('<div style="height:10px"></div>'),
      ),
    );
    sent.push(who.email);
  }

  // admins get the whole picture, including their own
  for (const admin of await admins()) {
    if (!admin.email) continue;
    if (sent.includes(admin.email) && buckets.size === 1) continue;
    const named = await Promise.all(tasks.map(async (t) => {
      const who = await profile(t.assignee as string | null);
      return `<p style="margin:0 0 6px;font-size:13px;color:#898781">${esc(who?.full_name ?? "Unassigned")}</p>`
        + taskCard(t);
    }));
    await send(
      admin.email,
      `Team: ${tasks.length} task${tasks.length > 1 ? "s" : ""} due today`,
      shell(
        "Due across the team today",
        `Everything with a due date of ${esc(niceDate(day))} that is not completed.`,
        named.join('<div style="height:10px"></div>'),
      ),
    );
    sent.push(admin.email);
  }

  return `sent to ${sent.join(", ")}`;
}

// ---------------------------------------------------------------- entry point

Deno.serve(async (req) => {
  try {
    const body = await req.json();

    // the daily job
    if (body.mode === "due-today") {
      return new Response(await dueToday(), { status: 200 });
    }

    // database webhooks
    const { type, table, record, old_record, actor } = body;

    if (table === "tasks" && type === "INSERT") {
      return new Response(await onTaskCreated(record), { status: 200 });
    }
    if (table === "tasks" && type === "UPDATE") {
      const results: string[] = [];
      if (record.assignee && old_record && record.assignee !== old_record.assignee) {
        results.push(await onTaskReassigned(record, actor ?? null));
      }
      if (old_record && old_record.status !== "review" && record.status === "review") {
        results.push(await onMovedToReview(record, actor ?? null));
      }
      return new Response(results.length ? results.join(" | ") : "nothing worth an email", { status: 200 });
    }
    if (table === "comments" && type === "INSERT") {
      return new Response(await onComment(record), { status: 200 });
    }

    return new Response("nothing to do", { status: 200 });
  } catch (err) {
    console.error(err);
    return new Response(`error: ${err instanceof Error ? err.message : String(err)}`, {
      status: 500,
    });
  }
});
