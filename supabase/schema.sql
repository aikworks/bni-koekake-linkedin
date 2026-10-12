-- LinkedIn声掛けツール（Web版）テーブル一式。既存プロジェクトに同居できるよう lk_ 接頭辞にしている。

-- チャプター単位の設定（定例会、申込フォーム、うまくいった例、月の予算）
create table if not exists public.lk_chapters (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  meeting text default '',
  form_url text default '',
  style text default '',
  examples text default '',
  monthly_budget_jpy integer not null default 5000,
  daily_cap integer not null default 20,
  created_at timestamptz not null default now()
);

-- メンバー（Supabase Auth のユーザーに1対1）
create table if not exists public.lk_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  chapter_id uuid not null references public.lk_chapters(id) on delete cascade,
  display_name text not null,
  biz text default '',
  role text not null default 'member' check (role in ('member','admin')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- 声掛け相手
create table if not exists public.lk_contacts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.lk_members(user_id) on delete cascade,
  chapter_id uuid not null references public.lk_chapters(id) on delete cascade,
  name text not null default '',
  headline text default '',
  profile text default '',
  posts text default '',
  stage text not null default 'before'
    check (stage in ('before','sent','connected','talking','oneonone','invited','registered','pass')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists lk_contacts_owner on public.lk_contacts(owner_id);
create index if not exists lk_contacts_chapter on public.lk_contacts(chapter_id, stage);

-- やり取り（相手から来た文・自分が送った文）
create table if not exists public.lk_messages (
  id bigint generated always as identity primary key,
  contact_id uuid not null references public.lk_contacts(id) on delete cascade,
  owner_id uuid not null references public.lk_members(user_id) on delete cascade,
  who text not null check (who in ('them','me')),
  body text not null,
  created_at timestamptz not null default now()
);
create index if not exists lk_messages_contact on public.lk_messages(contact_id, created_at);

-- 段階の変化の記録（管理画面の「どう繋がったか」）
create table if not exists public.lk_stage_events (
  id bigint generated always as identity primary key,
  contact_id uuid not null references public.lk_contacts(id) on delete cascade,
  owner_id uuid not null references public.lk_members(user_id) on delete cascade,
  from_stage text,
  to_stage text not null,
  created_at timestamptz not null default now()
);

-- AI利用の記録（誰がどれだけ使ったか、費用の見える化）
create table if not exists public.lk_generations (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.lk_members(user_id) on delete cascade,
  chapter_id uuid not null references public.lk_chapters(id) on delete cascade,
  contact_id uuid references public.lk_contacts(id) on delete set null,
  model text not null,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  cost_jpy numeric(10,2) not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists lk_generations_chapter_month on public.lk_generations(chapter_id, created_at);

-- 段階が変わったら自動で記録し、updated_at を更新
create or replace function public.lk_on_contact_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' then
    insert into lk_stage_events(contact_id, owner_id, from_stage, to_stage) values (new.id, new.owner_id, null, new.stage);
  elsif new.stage is distinct from old.stage then
    insert into lk_stage_events(contact_id, owner_id, from_stage, to_stage) values (new.id, new.owner_id, old.stage, new.stage);
  end if;
  return new;
end $$;
drop trigger if exists lk_contacts_stage on public.lk_contacts;
create trigger lk_contacts_stage before insert or update on public.lk_contacts
  for each row execute function public.lk_on_contact_update();

-- 権限まわりの補助関数
create or replace function public.lk_my_chapter() returns uuid
language sql stable security definer set search_path = public as $$
  select chapter_id from lk_members where user_id = auth.uid() and active
$$;
create or replace function public.lk_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from lk_members where user_id = auth.uid() and role = 'admin' and active)
$$;

alter table public.lk_chapters enable row level security;
alter table public.lk_members enable row level security;
alter table public.lk_contacts enable row level security;
alter table public.lk_messages enable row level security;
alter table public.lk_stage_events enable row level security;
alter table public.lk_generations enable row level security;

-- チャプター設定: メンバーは読める、管理者だけ更新
drop policy if exists lk_chapters_read on public.lk_chapters;
create policy lk_chapters_read on public.lk_chapters for select to authenticated using (id = lk_my_chapter());
drop policy if exists lk_chapters_admin on public.lk_chapters;
create policy lk_chapters_admin on public.lk_chapters for update to authenticated using (id = lk_my_chapter() and lk_is_admin());

-- メンバー: 自分は読める・自分の名前と仕事は直せる。管理者は同じチャプターを全員読める
drop policy if exists lk_members_read on public.lk_members;
create policy lk_members_read on public.lk_members for select to authenticated
  using (user_id = auth.uid() or (chapter_id = lk_my_chapter() and lk_is_admin()));
drop policy if exists lk_members_self on public.lk_members;
create policy lk_members_self on public.lk_members for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- 本人が変えられるのは名前と仕事だけ（役割やチャプターは変えられない）
revoke insert, update, delete on public.lk_members from authenticated, anon;
grant update (display_name, biz) on public.lk_members to authenticated;
revoke insert, delete on public.lk_chapters from authenticated, anon;
revoke update on public.lk_chapters from authenticated, anon;
grant update (meeting, form_url, style, examples, monthly_budget_jpy, daily_cap) on public.lk_chapters to authenticated;
revoke insert, update, delete on public.lk_generations, public.lk_stage_events from authenticated, anon;

-- 相手・やり取り・段階: 本人は読み書き、管理者は同じチャプターを読める
drop policy if exists lk_contacts_own on public.lk_contacts;
create policy lk_contacts_own on public.lk_contacts for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid() and chapter_id = lk_my_chapter());
drop policy if exists lk_contacts_admin on public.lk_contacts;
create policy lk_contacts_admin on public.lk_contacts for select to authenticated
  using (chapter_id = lk_my_chapter() and lk_is_admin());

drop policy if exists lk_messages_own on public.lk_messages;
create policy lk_messages_own on public.lk_messages for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid() and exists(select 1 from lk_contacts c where c.id = contact_id and c.owner_id = auth.uid()));
drop policy if exists lk_messages_admin on public.lk_messages;
create policy lk_messages_admin on public.lk_messages for select to authenticated
  using (lk_is_admin() and exists(select 1 from lk_contacts c where c.id = contact_id and c.chapter_id = lk_my_chapter()));

drop policy if exists lk_stage_events_read on public.lk_stage_events;
create policy lk_stage_events_read on public.lk_stage_events for select to authenticated
  using (owner_id = auth.uid() or (lk_is_admin() and exists(select 1 from lk_contacts c where c.id = contact_id and c.chapter_id = lk_my_chapter())));

-- AI利用: 書き込みはサーバー（service role）だけ。本人と管理者が読める
drop policy if exists lk_generations_read on public.lk_generations;
create policy lk_generations_read on public.lk_generations for select to authenticated
  using (user_id = auth.uid() or (chapter_id = lk_my_chapter() and lk_is_admin()));

-- 管理画面用の集計ビュー（呼び出した人の権限で絞られる）
create or replace view public.lk_member_summary with (security_invoker = true) as
select m.user_id, m.display_name, m.role, m.active,
  count(distinct c.id) filter (where c.stage <> 'before') as contacted,
  count(distinct c.id) filter (where c.stage in ('talking','oneonone','invited','registered')) as in_conversation,
  count(distinct c.id) filter (where c.stage = 'oneonone') as oneonone,
  count(distinct c.id) filter (where c.stage = 'invited') as invited,
  count(distinct c.id) filter (where c.stage = 'registered') as registered,
  (select count(*) from lk_messages x where x.owner_id = m.user_id and x.who = 'me' and x.created_at >= date_trunc('day', now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo') as sent_today,
  (select coalesce(sum(g.cost_jpy),0) from lk_generations g where g.user_id = m.user_id and g.created_at >= date_trunc('month', now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo') as cost_month_jpy,
  (select count(*) from lk_generations g where g.user_id = m.user_id and g.created_at >= date_trunc('month', now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo') as generations_month,
  max(c.updated_at) as last_activity
from lk_members m left join lk_contacts c on c.owner_id = m.user_id
group by m.user_id;
