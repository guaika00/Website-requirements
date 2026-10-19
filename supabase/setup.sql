-- V2 legacy setup. Do NOT rerun after installing the v3 multi-project upgrade.
-- On an empty database, run this original setup ONCE, then upgrade_multi_project.sql.
DO $$ BEGIN
 IF to_regclass('public.board_projects') IS NOT NULL THEN
   RAISE EXCEPTION 'Multi-project v3 is already installed. Do NOT rerun legacy setup.sql; use upgrade_multi_project.sql instead.';
 END IF;
END $$;

-- Website requirements collaboration board / Supabase schema
-- Run once in Supabase SQL Editor. A second run is safe for the same schema.
-- After running, replace YOU@COMPANY.COM in the bootstrap statement in README.

create extension if not exists pgcrypto;

create table if not exists public.team_members (
  email text primary key,
  display_name text not null default '',
  role text not null check(role in ('admin','operator','developer')),
  created_at timestamptz not null default now(),
  constraint member_email_normalized check(email=lower(btrim(email)) and length(email) between 3 and 254)
);

-- Roles must come from a trusted DB table (not user-editable Auth user_metadata).
-- This function is owned by the SQL Editor's trusted database owner.
create or replace function public.current_team_role()
returns text language sql stable security definer set search_path = ''
as $$
 select m.role from public.team_members m
 where (select auth.uid()) is not null
   and coalesce(auth.jwt()->>'is_anonymous','false') <> 'true'
   and m.email=lower(auth.jwt()->>'email')
 limit 1;
$$;
revoke all on function public.current_team_role() from public, anon;
grant execute on function public.current_team_role() to authenticated;

create table if not exists public.requirements (
  id text primary key default ('custom-' || gen_random_uuid()::text),
  title text not null check (length(btrim(title)) between 1 and 160),
  category text not null check (length(category) between 1 and 100),
  description text not null default '',
  links text[] not null default '{}',
  sources text[] not null default '{}',
  "references" text[] not null default '{}',
  source text not null default '协作新增',
  is_custom boolean not null default true,
  sort_order integer not null default 999999,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid,
  updated_by uuid,
  updated_by_email text
);
alter table public.requirements add column if not exists updated_by_email text;
create index if not exists requirements_order_idx on public.requirements(sort_order,created_at);

create table if not exists public.requirement_progress (
  requirement_id text primary key references public.requirements(id) on delete cascade,
  status text not null default 'todo' check (status in ('todo','doing','done')),
  note text not null default '',
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  updated_by_email text
);
alter table public.requirement_progress add column if not exists updated_by_email text;
create index if not exists req_progress_updated_idx on public.requirement_progress(updated_at desc);

create table if not exists public.board_assets (
  id uuid primary key default gen_random_uuid(),
  label text not null default '补充参考素材',
  path text not null unique,
  sort_order integer not null default 999999,
  created_at timestamptz not null default now()
);

create or replace function public.stamp_requirement()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  new.updated_at=now();
  new.updated_by=auth.uid();
  new.updated_by_email=lower(auth.jwt()->>'email');
  if tg_op='INSERT' then
    new.created_at=now();
    new.created_by=auth.uid();
  else
    new.created_at=old.created_at;
    new.created_by=old.created_by;
  end if;
  return new;
end;$$;
drop trigger if exists requirements_stamp on public.requirements;
create trigger requirements_stamp before insert or update on public.requirements
 for each row execute function public.stamp_requirement();

create or replace function public.create_initial_progress()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.requirement_progress(requirement_id) values(new.id)
  on conflict (requirement_id) do nothing;
  return new;
end;$$;
drop trigger if exists create_requirement_progress on public.requirements;
create trigger create_requirement_progress after insert on public.requirements
 for each row execute function public.create_initial_progress();

create or replace function public.stamp_progress()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  new.updated_at=now();
  new.updated_by=auth.uid();
  new.updated_by_email=lower(auth.jwt()->>'email');
  if new.status='done' then
    if tg_op='INSERT' then
      new.completed_at=coalesce(new.completed_at,now());
    elsif old.status <> 'done' then
      new.completed_at=coalesce(new.completed_at,now());
    else
      new.completed_at=old.completed_at;
    end if;
  else
    new.completed_at=null;
  end if;
  return new;
end;$$;
drop trigger if exists progress_stamp on public.requirement_progress;
create trigger progress_stamp before insert or update on public.requirement_progress
 for each row execute function public.stamp_progress();

-- Keep the last administrator to prevent accidental total lockout.
create or replace function public.guard_last_admin()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op='DELETE' then
    if old.role='admin' and (select count(*) from public.team_members where role='admin') <= 1 then
      raise exception 'At least one administrator is required';
    end if;
    return old;
  end if;
  if new.email<>old.email then
    raise exception 'Member email cannot be edited; remove/add a member instead';
  end if;
  if old.role='admin' and new.role<>'admin'
     and (select count(*) from public.team_members where role='admin') <= 1 then
    raise exception 'At least one administrator is required';
  end if;
  return new;
end;$$;
drop trigger if exists team_guard_last_admin on public.team_members;
create trigger team_guard_last_admin before update or delete on public.team_members
 for each row execute function public.guard_last_admin();

alter table public.team_members enable row level security;
alter table public.requirements enable row level security;
alter table public.requirement_progress enable row level security;
alter table public.board_assets enable row level security;

-- Explicit grants and policies: no anonymous reads/writes. Authenticated user
-- identity alone isn't enough: the email must be pre-approved in team_members.
revoke all on public.team_members, public.requirements,
 public.requirement_progress, public.board_assets from anon;
grant select,insert,update,delete on public.team_members,
 public.requirements, public.requirement_progress, public.board_assets to authenticated;

drop policy if exists members_read on public.team_members;
create policy members_read on public.team_members for select to authenticated
 using (email=lower(auth.jwt()->>'email') or (select public.current_team_role())='admin');
drop policy if exists members_add on public.team_members;
create policy members_add on public.team_members for insert to authenticated
 with check ((select public.current_team_role())='admin');
drop policy if exists members_edit on public.team_members;
create policy members_edit on public.team_members for update to authenticated
 using ((select public.current_team_role())='admin')
 with check ((select public.current_team_role())='admin');
drop policy if exists members_delete on public.team_members;
create policy members_delete on public.team_members for delete to authenticated
 using ((select public.current_team_role())='admin');

drop policy if exists requirements_read on public.requirements;
create policy requirements_read on public.requirements for select to authenticated
 using ((select public.current_team_role()) is not null);
drop policy if exists requirements_add on public.requirements;
create policy requirements_add on public.requirements for insert to authenticated
 with check ((select public.current_team_role()) in ('admin','operator'));
drop policy if exists requirements_edit on public.requirements;
create policy requirements_edit on public.requirements for update to authenticated
 using ((select public.current_team_role()) in ('admin','operator'))
 with check ((select public.current_team_role()) in ('admin','operator'));
drop policy if exists requirements_delete on public.requirements;
create policy requirements_delete on public.requirements for delete to authenticated
 using ((select public.current_team_role())='admin');

drop policy if exists progress_read on public.requirement_progress;
create policy progress_read on public.requirement_progress for select to authenticated
 using ((select public.current_team_role()) is not null);
drop policy if exists progress_add on public.requirement_progress;
create policy progress_add on public.requirement_progress for insert to authenticated
 with check ((select public.current_team_role()) in ('admin','developer'));
drop policy if exists progress_edit on public.requirement_progress;
create policy progress_edit on public.requirement_progress for update to authenticated
 using ((select public.current_team_role()) in ('admin','developer'))
 with check ((select public.current_team_role()) in ('admin','developer'));
-- No client-side deletion of progress: requirement deletion (admin) cascades.

drop policy if exists board_assets_read on public.board_assets;
create policy board_assets_read on public.board_assets for select to authenticated
 using ((select public.current_team_role()) is not null);
drop policy if exists board_assets_add on public.board_assets;
create policy board_assets_add on public.board_assets for insert to authenticated
 with check ((select public.current_team_role()) in ('admin','operator'));
drop policy if exists board_assets_delete on public.board_assets;
create policy board_assets_delete on public.board_assets for delete to authenticated
 using ((select public.current_team_role())='admin');

-- Private bucket: files are accessed via temporary signed URLs after login.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('requirements-private','requirements-private',false,10485760,
 array['image/png','image/jpeg','image/webp'])
on conflict(id) do update set public=false, file_size_limit=10485760,
 allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists requirements_image_read on storage.objects;
create policy requirements_image_read on storage.objects for select to authenticated
 using (bucket_id='requirements-private' and (select public.current_team_role()) is not null);
drop policy if exists requirements_image_upload on storage.objects;
create policy requirements_image_upload on storage.objects for insert to authenticated
 with check (bucket_id='requirements-private' and name like 'uploads/%'
 and (select public.current_team_role()) in ('admin','operator'));
-- Only admins may physically delete or overwrite objects. UI just unlinks images.
drop policy if exists requirements_image_delete on storage.objects;
create policy requirements_image_delete on storage.objects for delete to authenticated
 using (bucket_id='requirements-private' and (select public.current_team_role())='admin');

-- Enable Postgres Changes for automatic cross-device updates.
do $$ begin
  alter publication supabase_realtime add table public.requirements;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.requirement_progress;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.board_assets;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.team_members;
exception when duplicate_object then null;
end $$;
