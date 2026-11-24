-- Add a global Manager role to the existing V4.1 requirements board.
-- Requires the V4 + V4.1 schema to be installed first.
-- Does not alter Travel app tables, auth users, or XICHA registration hooks.
BEGIN;

DO $precheck$
BEGIN
  IF to_regclass('public.team_members') IS NULL
     OR to_regclass('public.board_projects') IS NULL
     OR to_regclass('public.board_project_members') IS NULL
     OR to_regclass('public.board_activity') IS NULL
     OR to_regclass('public.board_iterations') IS NULL THEN
    RAISE EXCEPTION 'V4.1 board schema is incomplete. Install and verify V4.1 before adding the manager role.';
  END IF;
END;
$precheck$;

-- Manager is a GLOBAL board role, not a project_members role.
ALTER TABLE public.team_members DROP CONSTRAINT IF EXISTS team_members_role_check;
ALTER TABLE public.team_members ADD CONSTRAINT team_members_role_check
  CHECK (role IN ('admin','manager','operator','developer','viewer'));

-- Grant the requested email the manager role. This does not create an Auth user.
INSERT INTO public.team_members(email,role,display_name)
VALUES ('yukilulumark@gmail.com','manager','Yuki')
ON CONFLICT (email) DO UPDATE
SET role='manager', display_name=CASE
  WHEN coalesce(public.team_members.display_name,'')='' THEN 'Yuki'
  ELSE public.team_members.display_name END;

-- Admin remains the only role that can manage global admin/manager assignments.
CREATE OR REPLACE FUNCTION public.board_global_manager()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT (SELECT auth.uid()) IS NOT NULL
    AND coalesce(auth.jwt()->>'is_anonymous','false') <> 'true'
    AND EXISTS (
      SELECT 1 FROM public.team_members t
      WHERE t.email=lower(auth.jwt()->>'email') AND t.role IN ('admin','manager')
    );
$$;
REVOKE ALL ON FUNCTION public.board_global_manager() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.board_global_manager() TO authenticated;

CREATE OR REPLACE FUNCTION public.board_project_role(p_project uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE
    WHEN (SELECT auth.uid()) IS NULL OR coalesce(auth.jwt()->>'is_anonymous','false')='true' THEN NULL
    WHEN public.board_global_admin() THEN 'admin'
    WHEN public.board_global_manager() THEN 'manager'
    ELSE (
      SELECT pm.role FROM public.board_project_members pm
      JOIN public.board_projects p ON p.id=pm.project_id AND NOT p.is_archived
      WHERE pm.project_id=p_project AND pm.email=lower(auth.jwt()->>'email')
      LIMIT 1
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public.board_can_edit(p_project uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.board_project_role(p_project) IN ('admin','manager','operator');
$$;

CREATE OR REPLACE FUNCTION public.board_can_progress(p_project uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.board_project_role(p_project) IN ('admin','manager','operator','developer');
$$;

CREATE OR REPLACE FUNCTION public.board_can_manage_members(p_project uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.board_project_role(p_project) IN ('admin','manager','operator');
$$;

CREATE OR REPLACE FUNCTION public.board_can_create_project()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid() IS NOT NULL
    AND coalesce(auth.jwt()->>'is_anonymous','false')<>'true'
    AND (
      public.board_global_manager()
      OR EXISTS (SELECT 1 FROM public.team_members m WHERE m.email=lower(auth.jwt()->>'email') AND m.role='operator')
      OR EXISTS (SELECT 1 FROM public.board_project_members pm WHERE pm.email=lower(auth.jwt()->>'email') AND pm.role='operator')
    );
$$;
REVOKE ALL ON FUNCTION public.board_can_edit(uuid),public.board_can_progress(uuid),public.board_can_manage_members(uuid),public.board_can_create_project() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.board_can_edit(uuid),public.board_can_progress(uuid),public.board_can_manage_members(uuid),public.board_can_create_project() TO authenticated;

CREATE OR REPLACE FUNCTION public.board_create_project(p_name text,p_description text DEFAULT '')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE pid uuid; uname text;
BEGIN
  IF NOT public.board_can_create_project() THEN RAISE EXCEPTION 'Not authorized to create projects'; END IF;
  uname:=btrim(coalesce(p_name,''));
  IF length(uname) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Project name must be 1-100 characters'; END IF;
  IF length(coalesce(p_description,''))>500 THEN RAISE EXCEPTION 'Project description too long'; END IF;
  INSERT INTO public.board_projects(name,description) VALUES(uname,btrim(coalesce(p_description,''))) RETURNING id INTO pid;
  IF NOT public.board_global_manager() THEN
    INSERT INTO public.board_project_members(project_id,email,role)
    VALUES(pid,lower(auth.jwt()->>'email'),'operator');
  END IF;
  RETURN pid;
END;
$$;

-- Managers can manage every project's members, including appointing project operators.
-- They cannot grant global admin/manager: those roles are not valid project roles.
CREATE OR REPLACE FUNCTION public.board_assign_member(p_project uuid,p_email text,p_role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_email text; old_role text;
BEGIN
  IF NOT public.board_can_manage_members(p_project) THEN RAISE EXCEPTION 'Cannot manage this project'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.board_projects WHERE id=p_project AND NOT is_archived) THEN
    RAISE EXCEPTION 'Project is archived or missing';
  END IF;
  v_email:=lower(btrim(coalesce(p_email,'')));
  IF length(v_email) NOT BETWEEN 5 AND 254 OR v_email !~ '^[^[:space:]<>@]+@[^[:space:]<>@]+\.[^[:space:]<>@]+$' THEN
    RAISE EXCEPTION 'Invalid email address';
  END IF;
  IF p_role NOT IN ('operator','developer','viewer') THEN RAISE EXCEPTION 'Invalid project member role'; END IF;
  IF NOT public.board_global_admin() AND EXISTS (SELECT 1 FROM public.team_members tm WHERE tm.email=v_email AND tm.role IN ('admin','manager')) THEN
    RAISE EXCEPTION 'Only the global admin can manage global admin/manager accounts';
  END IF;
  SELECT role INTO old_role FROM public.board_project_members
    WHERE project_id=p_project AND email=v_email FOR UPDATE;
  INSERT INTO public.team_members(email,role,display_name)
    VALUES(v_email,p_role,'') ON CONFLICT(email) DO NOTHING;
  INSERT INTO public.board_project_members(project_id,email,role)
    VALUES(p_project,v_email,p_role)
    ON CONFLICT(project_id,email) DO UPDATE SET role=excluded.role;
  IF p_role='viewer' THEN
    UPDATE public.requirements SET assignee_email=NULL
    WHERE project_id=p_project AND assignee_email=v_email;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.board_remove_member(p_project uuid,p_email text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_email text;
BEGIN
  IF NOT public.board_can_manage_members(p_project) THEN RAISE EXCEPTION 'Cannot manage this project'; END IF;
  v_email:=lower(btrim(coalesce(p_email,'')));
  IF NOT public.board_global_admin() AND EXISTS (SELECT 1 FROM public.team_members tm WHERE tm.email=v_email AND tm.role IN ('admin','manager')) THEN
    RAISE EXCEPTION 'Only the global admin can manage global admin/manager accounts';
  END IF;
  UPDATE public.requirements SET assignee_email=NULL
    WHERE project_id=p_project AND assignee_email=v_email;
  DELETE FROM public.board_project_members
    WHERE project_id=p_project AND email=v_email;
END;
$$;

-- Global managers can archive/unarchive projects; only global admin can change IDs/slugs.
CREATE OR REPLACE FUNCTION public.board_v4_guard_project()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.board_global_manager() AND
    (NEW.is_archived IS DISTINCT FROM OLD.is_archived OR NEW.slug IS DISTINCT FROM OLD.slug OR NEW.id IS DISTINCT FROM OLD.id) THEN
    RAISE EXCEPTION 'Only global managers can archive or reassign a project';
  END IF;
  IF NEW.slug IS DISTINCT FROM OLD.slug OR NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Project ID and slug cannot be changed';
  END IF;
  RETURN NEW;
END;
$$;

-- Manager can perform project-wide task administration and final acceptance.
CREATE OR REPLACE FUNCTION public.board_transition_task(
  p_task text,p_status text,p_blocked boolean DEFAULT NULL,p_note text DEFAULT ''
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE pid uuid; v_role text; old_status text; old_blocked boolean; new_blocked boolean; msg text; withdrawn boolean;
BEGIN
  SELECT project_id,is_withdrawn INTO pid,withdrawn FROM public.requirements WHERE id=p_task;
  IF pid IS NULL THEN RAISE EXCEPTION 'Task not found'; END IF;
  IF withdrawn THEN RAISE EXCEPTION 'Withdrawn tasks cannot be progressed'; END IF;
  v_role:=public.board_project_role(pid);
  IF v_role NOT IN ('admin','manager','operator','developer') OR v_role IS NULL THEN RAISE EXCEPTION 'Not authorized to update task'; END IF;
  IF p_status NOT IN ('todo','doing','review','done') THEN RAISE EXCEPTION 'Invalid status'; END IF;
  IF p_status='done' AND v_role NOT IN ('admin','manager','operator') THEN RAISE EXCEPTION 'Only project owners can accept completed work'; END IF;
  msg:=btrim(coalesce(p_note,''));
  IF length(msg)>4000 THEN RAISE EXCEPTION 'Comment too long'; END IF;
  SELECT status,is_blocked INTO old_status,old_blocked FROM public.requirement_progress WHERE requirement_id=p_task FOR UPDATE;
  IF old_status IS NULL THEN RAISE EXCEPTION 'Task progress missing'; END IF;
  IF old_status='done' AND v_role='developer' AND p_status<>'done' THEN RAISE EXCEPTION 'Only an operator can reopen accepted work'; END IF;
  IF p_status='done' AND old_status NOT IN ('review','done') THEN RAISE EXCEPTION 'Submit for review before final acceptance'; END IF;
  IF old_status='review' AND p_status='doing' AND v_role IN ('admin','manager','operator') AND msg='' THEN RAISE EXCEPTION 'Please explain why work was returned'; END IF;
  new_blocked:=coalesce(p_blocked,old_blocked);
  IF p_status='done' AND new_blocked THEN RAISE EXCEPTION 'Unblock the task before accepting'; END IF;
  IF new_blocked IS TRUE AND old_blocked IS DISTINCT FROM TRUE AND msg='' THEN RAISE EXCEPTION 'Please describe why the task is blocked'; END IF;
  IF old_status IS NOT DISTINCT FROM p_status AND old_blocked IS NOT DISTINCT FROM new_blocked AND msg='' THEN RETURN; END IF;
  UPDATE public.requirement_progress SET status=p_status,is_blocked=new_blocked WHERE requirement_id=p_task AND project_id=pid;
  INSERT INTO public.board_activity(project_id,requirement_id,actor_id,actor_email,kind,body,metadata)
  VALUES(pid,p_task,auth.uid(),lower(auth.jwt()->>'email'),
    CASE WHEN old_status IS DISTINCT FROM p_status OR old_blocked IS DISTINCT FROM new_blocked THEN 'status' ELSE 'comment' END,
    msg,jsonb_build_object('before',old_status,'after',p_status,'blocked_before',old_blocked,'blocked_after',new_blocked));
END;
$$;

CREATE OR REPLACE FUNCTION public.board_add_comment(
  p_task text,p_body text,p_paths text[] DEFAULT '{}',p_link text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE pid uuid; v_role text; body_text text; item text; prefix text;
BEGIN
  SELECT project_id INTO pid FROM public.requirements WHERE id=p_task;
  IF pid IS NULL THEN RAISE EXCEPTION 'Task not found'; END IF;
  v_role:=public.board_project_role(pid);
  IF v_role NOT IN ('admin','manager','operator','developer') OR v_role IS NULL THEN RAISE EXCEPTION 'Cannot comment on this project'; END IF;
  body_text:=btrim(coalesce(p_body,''));
  IF length(body_text)>4000 THEN RAISE EXCEPTION 'Comment too long'; END IF;
  IF coalesce(cardinality(p_paths),0)>5 THEN RAISE EXCEPTION 'Maximum five attachments'; END IF;
  IF body_text='' AND coalesce(cardinality(p_paths),0)=0 AND nullif(btrim(coalesce(p_link,'')),'') IS NULL THEN RAISE EXCEPTION 'Add a comment, image or link'; END IF;
  prefix:='projects/'||pid::text||'/uploads/';
  FOREACH item IN ARRAY coalesce(p_paths,'{}') LOOP
    IF left(item,length(prefix))<>prefix OR length(item)>500 OR position('..' in item)>0 THEN RAISE EXCEPTION 'Invalid attachment path'; END IF;
  END LOOP;
  IF p_link IS NOT NULL AND p_link<>'' AND p_link !~* '^https?://[^[:space:]]+$' THEN RAISE EXCEPTION 'Invalid result link'; END IF;
  INSERT INTO public.board_activity(project_id,requirement_id,actor_id,actor_email,kind,body,attachment_paths,link)
  VALUES(pid,p_task,auth.uid(),lower(auth.jwt()->>'email'),'comment',body_text,coalesce(p_paths,'{}'),nullif(btrim(coalesce(p_link,'')),''));
END;
$$;

-- Let managers perform the same project-wide destructive maintenance as admins.
DROP POLICY IF EXISTS requirements_delete ON public.requirements;
CREATE POLICY requirements_delete ON public.requirements FOR DELETE TO authenticated USING(public.board_global_manager());
DROP POLICY IF EXISTS board_assets_delete ON public.board_assets;
CREATE POLICY board_assets_delete ON public.board_assets FOR DELETE TO authenticated USING(public.board_global_manager());
DROP POLICY IF EXISTS board_private_project_delete ON storage.objects;
CREATE POLICY board_private_project_delete ON storage.objects FOR DELETE TO authenticated
  USING(bucket_id='requirements-private' AND public.board_global_manager());

REVOKE ALL ON FUNCTION public.board_create_project(text,text),public.board_assign_member(uuid,text,text),
  public.board_remove_member(uuid,text),public.board_transition_task(text,text,boolean,text),
  public.board_add_comment(text,text,text[],text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.board_create_project(text,text),public.board_assign_member(uuid,text,text),
  public.board_remove_member(uuid,text),public.board_transition_task(text,text,boolean,text),
  public.board_add_comment(text,text,text[],text) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
