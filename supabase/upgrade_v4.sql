-- Website Requirements Board V4: safe incremental upgrade after V3.
-- Run the entire file as ONE query. Travel app tables and XICHA hooks untouched.
BEGIN;

DO $$ BEGIN
 IF to_regclass('public.board_projects') IS NULL THEN RAISE EXCEPTION 'V3 project tables missing. Run install_v4_from_v2.sql instead.'; END IF;
END $$;

-- Expand the existing login whitelist and per-project roles.
ALTER TABLE public.team_members DROP CONSTRAINT IF EXISTS team_members_role_check;
ALTER TABLE public.team_members ADD CONSTRAINT team_members_role_check CHECK (role IN ('admin','operator','developer','viewer'));
ALTER TABLE public.board_project_members DROP CONSTRAINT IF EXISTS board_project_members_role_check;
ALTER TABLE public.board_project_members ADD CONSTRAINT board_project_members_role_check CHECK (role IN ('operator','developer','viewer'));
ALTER TABLE public.requirement_progress DROP CONSTRAINT IF EXISTS requirement_progress_status_check;
ALTER TABLE public.requirement_progress ADD CONSTRAINT requirement_progress_status_check CHECK (status IN ('todo','doing','review','done'));
ALTER TABLE public.requirement_progress ADD COLUMN IF NOT EXISTS is_blocked boolean NOT NULL DEFAULT false;
ALTER TABLE public.requirements ADD COLUMN IF NOT EXISTS assignee_email text;
ALTER TABLE public.requirements ADD COLUMN IF NOT EXISTS due_date date;
ALTER TABLE public.requirements ADD COLUMN IF NOT EXISTS is_withdrawn boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS board_tasks_assignee_idx ON public.requirements(project_id,assignee_email);
CREATE INDEX IF NOT EXISTS board_tasks_due_idx ON public.requirements(project_id,due_date);

-- Every update to the task definition must stay within its project.
CREATE OR REPLACE FUNCTION public.board_v4_guard_requirement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NEW.assignee_email IS NOT NULL THEN
   NEW.assignee_email := lower(btrim(NEW.assignee_email));
   IF NEW.assignee_email = '' THEN NEW.assignee_email := NULL; END IF;
 END IF;
 IF NEW.assignee_email IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.board_project_members pm
    WHERE pm.project_id=NEW.project_id AND pm.email=NEW.assignee_email AND pm.role IN ('developer','operator')
 ) THEN RAISE EXCEPTION 'Assignee must be a project developer or operator'; END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v4_requirement_guard_trigger ON public.requirements;
CREATE TRIGGER board_v4_requirement_guard_trigger BEFORE INSERT OR UPDATE OF assignee_email,project_id ON public.requirements
FOR EACH ROW EXECUTE FUNCTION public.board_v4_guard_requirement();

-- History is append-only. Direct web clients cannot update/delete/insert entries.
CREATE TABLE IF NOT EXISTS public.board_activity (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 requirement_id text NOT NULL REFERENCES public.requirements(id) ON DELETE CASCADE,
 actor_id uuid NOT NULL,
 actor_email text NOT NULL,
 kind text NOT NULL CHECK(kind IN ('comment','status','requirement')),
 body text NOT NULL DEFAULT '',
 metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
 attachment_paths text[] NOT NULL DEFAULT '{}',
 link text,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS board_activity_task_idx ON public.board_activity(project_id,requirement_id,created_at DESC);
ALTER TABLE public.board_activity ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.board_activity FROM anon,authenticated;
GRANT SELECT ON public.board_activity TO authenticated;
DROP POLICY IF EXISTS board_activity_read ON public.board_activity;
CREATE POLICY board_activity_read ON public.board_activity FOR SELECT TO authenticated USING(public.board_can_view(project_id));

-- V4 permission helpers. Global admin remains global, operators own their projects.
CREATE OR REPLACE FUNCTION public.board_can_progress(p_project uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT public.board_project_role(p_project) IN ('admin','operator','developer');
$$;
CREATE OR REPLACE FUNCTION public.board_can_manage_members(p_project uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT public.board_project_role(p_project) IN ('admin','operator');
$$;
CREATE OR REPLACE FUNCTION public.board_can_create_project()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT auth.uid() IS NOT NULL AND coalesce(auth.jwt()->>'is_anonymous','false')<>'true'
  AND (public.board_global_admin()
   OR EXISTS (SELECT 1 FROM public.team_members m WHERE m.email=lower(auth.jwt()->>'email') AND m.role='operator')
   OR EXISTS (SELECT 1 FROM public.board_project_members pm WHERE pm.email=lower(auth.jwt()->>'email') AND pm.role='operator'));
$$;
REVOKE ALL ON FUNCTION public.board_can_manage_members(uuid),public.board_can_create_project() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.board_can_manage_members(uuid),public.board_can_create_project() TO authenticated;

-- Project creators become project operators, without touching other projects.
CREATE OR REPLACE FUNCTION public.board_create_project(p_name text,p_description text DEFAULT '')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE pid uuid; uname text;
BEGIN
 IF NOT public.board_can_create_project() THEN RAISE EXCEPTION 'Not authorized to create projects'; END IF;
 uname := btrim(coalesce(p_name,''));
 IF length(uname) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Project name must be 1-100 characters'; END IF;
 IF length(coalesce(p_description,''))>500 THEN RAISE EXCEPTION 'Project description too long'; END IF;
 INSERT INTO public.board_projects(name,description) VALUES(uname,btrim(coalesce(p_description,''))) RETURNING id INTO pid;
 IF NOT public.board_global_admin() THEN
   INSERT INTO public.board_project_members(project_id,email,role) VALUES(pid,lower(auth.jwt()->>'email'),'operator');
 END IF;
 RETURN pid;
END;$$;

-- Project operators can invite developers and viewers. Only global admins can appoint other operators.
CREATE OR REPLACE FUNCTION public.board_assign_member(p_project uuid,p_email text,p_role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_email text; old_role text;
BEGIN
 IF NOT public.board_can_manage_members(p_project) THEN RAISE EXCEPTION 'Cannot manage this project'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.board_projects WHERE id=p_project AND NOT is_archived) THEN
  RAISE EXCEPTION 'Project is archived or missing'; END IF;
 v_email := lower(btrim(coalesce(p_email,'')));
 IF length(v_email) NOT BETWEEN 5 AND 254 OR v_email !~ '^[^[:space:]<>@]+@[^[:space:]<>@]+\.[^[:space:]<>@]+$' THEN
  RAISE EXCEPTION 'Invalid email address'; END IF;
 IF p_role NOT IN ('operator','developer','viewer') THEN RAISE EXCEPTION 'Invalid member role'; END IF;
 IF p_role='operator' AND NOT public.board_global_admin() THEN RAISE EXCEPTION 'Only global admins can appoint operators'; END IF;
 SELECT role INTO old_role FROM public.board_project_members WHERE project_id=p_project AND email=v_email FOR UPDATE;
 IF old_role='operator' AND NOT public.board_global_admin() THEN RAISE EXCEPTION 'Cannot change another project operator'; END IF;
 INSERT INTO public.team_members(email,role,display_name) VALUES(v_email,p_role,'') ON CONFLICT (email) DO NOTHING;
 INSERT INTO public.board_project_members(project_id,email,role) VALUES(p_project,v_email,p_role)
   ON CONFLICT(project_id,email) DO UPDATE SET role=excluded.role;
 IF p_role='viewer' THEN UPDATE public.requirements SET assignee_email=NULL
  WHERE project_id=p_project AND assignee_email=v_email; END IF;
END;$$;
CREATE OR REPLACE FUNCTION public.board_remove_member(p_project uuid,p_email text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_email text; old_role text;
BEGIN
 IF NOT public.board_can_manage_members(p_project) THEN RAISE EXCEPTION 'Cannot manage this project'; END IF;
 v_email:=lower(btrim(coalesce(p_email,'')));
 SELECT role INTO old_role FROM public.board_project_members WHERE project_id=p_project AND email=v_email FOR UPDATE;
 IF old_role='operator' AND NOT public.board_global_admin() THEN RAISE EXCEPTION 'Only global admins can remove operators'; END IF;
 UPDATE public.requirements SET assignee_email=NULL WHERE project_id=p_project AND assignee_email=v_email;
 DELETE FROM public.board_project_members WHERE project_id=p_project AND email=v_email;
END;$$;

-- Remove the old direct membership write privilege; the RPCs are the only writers.
REVOKE INSERT,UPDATE,DELETE ON public.board_project_members FROM authenticated;
GRANT SELECT ON public.board_project_members TO authenticated;
DROP POLICY IF EXISTS board_project_members_add ON public.board_project_members;
DROP POLICY IF EXISTS board_project_members_edit ON public.board_project_members;
DROP POLICY IF EXISTS board_project_members_delete ON public.board_project_members;

-- Operators can edit project name and description, but not archive it or alter slug.
CREATE OR REPLACE FUNCTION public.board_v4_guard_project()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NOT public.board_global_admin() AND
   (NEW.is_archived IS DISTINCT FROM OLD.is_archived OR NEW.slug IS DISTINCT FROM OLD.slug OR NEW.id IS DISTINCT FROM OLD.id) THEN
  RAISE EXCEPTION 'Only global admins can archive or reassign a project';
 END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v4_project_guard_trigger ON public.board_projects;
CREATE TRIGGER board_v4_project_guard_trigger BEFORE UPDATE ON public.board_projects
FOR EACH ROW EXECUTE FUNCTION public.board_v4_guard_project();
REVOKE UPDATE ON public.board_projects FROM authenticated;
GRANT UPDATE(name,description,is_archived) ON public.board_projects TO authenticated;
DROP POLICY IF EXISTS board_projects_edit ON public.board_projects;
CREATE POLICY board_projects_edit ON public.board_projects FOR UPDATE TO authenticated
 USING(public.board_can_manage_members(id)) WITH CHECK(public.board_can_manage_members(id));

-- Transition and comment operations are atomic, audited, project-scoped and RLS-safe.
CREATE OR REPLACE FUNCTION public.board_transition_task(
 p_task text,p_status text,p_blocked boolean DEFAULT NULL,p_note text DEFAULT ''
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE pid uuid; v_role text; old_status text; old_blocked boolean; new_blocked boolean; msg text; withdrawn boolean;
BEGIN
 SELECT project_id,is_withdrawn INTO pid,withdrawn FROM public.requirements WHERE id=p_task;
 IF pid IS NULL THEN RAISE EXCEPTION 'Task not found'; END IF;
 IF withdrawn THEN RAISE EXCEPTION 'Withdrawn tasks cannot be progressed'; END IF;
 v_role:=public.board_project_role(pid);
 IF v_role NOT IN ('admin','operator','developer') OR v_role IS NULL THEN RAISE EXCEPTION 'Not authorized to update task'; END IF;
 IF p_status NOT IN ('todo','doing','review','done') THEN RAISE EXCEPTION 'Invalid status'; END IF;
 IF p_status='done' AND v_role NOT IN ('admin','operator') THEN RAISE EXCEPTION 'Only project owners can accept completed work'; END IF;
 msg:=btrim(coalesce(p_note,''));
 IF length(msg)>4000 THEN RAISE EXCEPTION 'Comment too long'; END IF;
 SELECT status,is_blocked INTO old_status,old_blocked FROM public.requirement_progress WHERE requirement_id=p_task FOR UPDATE;
 IF old_status IS NULL THEN RAISE EXCEPTION 'Task progress missing'; END IF;
 IF old_status='done' AND v_role='developer' AND p_status<>'done' THEN RAISE EXCEPTION 'Only an operator can reopen accepted work'; END IF;
 IF p_status='done' AND old_status NOT IN ('review','done') THEN RAISE EXCEPTION 'Submit for review before final acceptance'; END IF;
 IF old_status='review' AND p_status='doing' AND v_role IN ('admin','operator') AND msg='' THEN RAISE EXCEPTION 'Please explain why work was returned'; END IF;
 new_blocked:=coalesce(p_blocked,old_blocked);
 IF p_status='done' AND new_blocked THEN RAISE EXCEPTION 'Unblock the task before accepting'; END IF;
 IF new_blocked IS TRUE AND old_blocked IS DISTINCT FROM TRUE AND msg='' THEN RAISE EXCEPTION 'Please describe why the task is blocked'; END IF;
 IF old_status IS NOT DISTINCT FROM p_status AND old_blocked IS NOT DISTINCT FROM new_blocked AND msg='' THEN RETURN; END IF;
 UPDATE public.requirement_progress SET status=p_status,is_blocked=new_blocked
 WHERE requirement_id=p_task AND project_id=pid;
 INSERT INTO public.board_activity(project_id,requirement_id,actor_id,actor_email,kind,body,metadata)
 VALUES(pid,p_task,auth.uid(),lower(auth.jwt()->>'email'),
        CASE WHEN old_status IS DISTINCT FROM p_status OR old_blocked IS DISTINCT FROM new_blocked THEN 'status' ELSE 'comment' END,
        msg,jsonb_build_object('before',old_status,'after',p_status,'blocked_before',old_blocked,'blocked_after',new_blocked));
END;$$;
CREATE OR REPLACE FUNCTION public.board_add_comment(
 p_task text,p_body text,p_paths text[] DEFAULT '{}',p_link text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE pid uuid; v_role text; body_text text; item text; prefix text;
BEGIN
 SELECT project_id INTO pid FROM public.requirements WHERE id=p_task;
 IF pid IS NULL THEN RAISE EXCEPTION 'Task not found'; END IF;
 v_role:=public.board_project_role(pid);
 IF v_role NOT IN ('admin','operator','developer') OR v_role IS NULL THEN RAISE EXCEPTION 'Cannot comment on this project'; END IF;
 body_text:=btrim(coalesce(p_body,''));
 IF length(body_text)>4000 THEN RAISE EXCEPTION 'Comment too long'; END IF;
 IF coalesce(cardinality(p_paths),0)>5 THEN RAISE EXCEPTION 'Maximum five attachments'; END IF;
 IF body_text='' AND coalesce(cardinality(p_paths),0)=0 AND nullif(btrim(coalesce(p_link,'')),'') IS NULL THEN
  RAISE EXCEPTION 'Add a comment, image or link'; END IF;
 prefix:='projects/'||pid::text||'/uploads/';
 FOREACH item IN ARRAY coalesce(p_paths,'{}') LOOP
  IF left(item,length(prefix))<>prefix OR length(item)>500 OR position('..' in item)>0 THEN RAISE EXCEPTION 'Invalid attachment path'; END IF;
 END LOOP;
 IF p_link IS NOT NULL AND p_link<>'' AND p_link !~* '^https?://[^[:space:]]+$' THEN RAISE EXCEPTION 'Invalid result link'; END IF;
 INSERT INTO public.board_activity(project_id,requirement_id,actor_id,actor_email,kind,body,attachment_paths,link)
 VALUES(pid,p_task,auth.uid(),lower(auth.jwt()->>'email'),'comment',body_text,coalesce(p_paths,'{}'),nullif(btrim(coalesce(p_link,'')),''));
END;$$;

-- Audit requirement-definition changes without exposing the history table for clients.
CREATE OR REPLACE FUNCTION public.board_v4_audit_requirement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE changes jsonb:='{}'::jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RETURN NEW; END IF;
 IF TG_OP='INSERT' THEN
   INSERT INTO public.board_activity(project_id,requirement_id,actor_id,actor_email,kind,body)
   VALUES(NEW.project_id,NEW.id,auth.uid(),lower(auth.jwt()->>'email'),'requirement','Created requirement');
 ELSE
   IF NEW.title IS DISTINCT FROM OLD.title THEN changes:=changes||jsonb_build_object('title',jsonb_build_array(OLD.title,NEW.title)); END IF;
   IF NEW.category IS DISTINCT FROM OLD.category THEN changes:=changes||jsonb_build_object('category',jsonb_build_array(OLD.category,NEW.category)); END IF;
   IF NEW.priority IS DISTINCT FROM OLD.priority THEN changes:=changes||jsonb_build_object('priority',jsonb_build_array(OLD.priority,NEW.priority)); END IF;
   IF NEW.assignee_email IS DISTINCT FROM OLD.assignee_email THEN changes:=changes||jsonb_build_object('assignee',jsonb_build_array(OLD.assignee_email,NEW.assignee_email)); END IF;
   IF NEW.due_date IS DISTINCT FROM OLD.due_date THEN changes:=changes||jsonb_build_object('due_date',jsonb_build_array(OLD.due_date,NEW.due_date)); END IF;
   IF NEW.is_withdrawn IS DISTINCT FROM OLD.is_withdrawn THEN changes:=changes||jsonb_build_object('withdrawn',jsonb_build_array(OLD.is_withdrawn,NEW.is_withdrawn)); END IF;
   IF NEW.sort_order IS DISTINCT FROM OLD.sort_order THEN changes:=changes||jsonb_build_object('position_changed',true); END IF;
   IF NEW.description IS DISTINCT FROM OLD.description OR NEW.links IS DISTINCT FROM OLD.links THEN changes:=changes||jsonb_build_object('details_changed',true); END IF;
   IF changes='{}'::jsonb THEN RETURN NEW; END IF;
   INSERT INTO public.board_activity(project_id,requirement_id,actor_id,actor_email,kind,body,metadata)
   VALUES(NEW.project_id,NEW.id,auth.uid(),lower(auth.jwt()->>'email'),'requirement','Updated requirement',changes);
 END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v4_requirement_audit_trigger ON public.requirements;
CREATE TRIGGER board_v4_requirement_audit_trigger AFTER INSERT OR UPDATE ON public.requirements
FOR EACH ROW EXECUTE FUNCTION public.board_v4_audit_requirement();

-- Only RPC calls can modify task progress; normal authenticated SQL cannot bypass audit.
REVOKE INSERT,UPDATE,DELETE ON public.requirement_progress FROM authenticated;
GRANT SELECT ON public.requirement_progress TO authenticated;
DROP POLICY IF EXISTS progress_add ON public.requirement_progress;
DROP POLICY IF EXISTS progress_edit ON public.requirement_progress;

-- Project-scoped private image uploads also include developers' progress screenshots.
CREATE OR REPLACE FUNCTION public.board_storage_can_upload(p_path text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE part text;
BEGIN
 IF split_part(p_path,'/',1)<>'projects' OR split_part(p_path,'/',3)<>'uploads' THEN RETURN false; END IF;
 part:=split_part(p_path,'/',2);
 IF part !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN false; END IF;
 IF p_path !~* '\.(png|jpe?g|webp)$' THEN RETURN false; END IF;
 RETURN public.board_can_progress(part::uuid);
END;$$;

-- Re-grant only callable functions. No direct table writer privilege on member/activity/progress.
REVOKE ALL ON FUNCTION public.board_create_project(text,text),
 public.board_assign_member(uuid,text,text),public.board_remove_member(uuid,text),
 public.board_transition_task(text,text,boolean,text),public.board_add_comment(text,text,text[],text)
 FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.board_create_project(text,text),
 public.board_assign_member(uuid,text,text),public.board_remove_member(uuid,text),
 public.board_transition_task(text,text,boolean,text),public.board_add_comment(text,text,text[],text)
 TO authenticated;
REVOKE ALL ON FUNCTION public.board_v4_guard_requirement(), public.board_v4_guard_project(), public.board_v4_audit_requirement() FROM PUBLIC,anon,authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
