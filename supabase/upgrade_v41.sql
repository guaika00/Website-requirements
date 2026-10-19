-- Project Tracker V4.1: requirement iterations (batches) and priority-safe ordering.
-- Run ONCE after V4. No travel tables, auth hooks, users or existing task content are dropped.
-- Treat this as a database migration. Back up your shared Supabase project first.
BEGIN;
DO $$ BEGIN
 IF to_regclass('public.board_projects') IS NULL
 OR to_regclass('public.requirements') IS NULL
 OR to_regclass('public.board_activity') IS NULL
 OR to_regclass('public.board_project_members') IS NULL
 THEN RAISE EXCEPTION 'Please complete V4 installation before upgrade_v41.sql'; END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.board_iterations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 name text NOT NULL CHECK(length(btrim(name)) BETWEEN 1 AND 80),
 description text NOT NULL DEFAULT '' CHECK(length(description)<=600),
 is_closed boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT board_iterations_project_name_key UNIQUE(project_id,name),
 CONSTRAINT board_iterations_project_id_id_key UNIQUE(project_id,id)
);
CREATE INDEX IF NOT EXISTS board_iterations_project_idx ON public.board_iterations(project_id,created_at DESC);
ALTER TABLE public.board_iterations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.board_iterations FROM anon;
GRANT SELECT ON public.board_iterations TO authenticated;
GRANT INSERT(project_id,name,description),UPDATE(name,description,is_closed) ON public.board_iterations TO authenticated;
REVOKE DELETE ON public.board_iterations FROM authenticated;
DROP POLICY IF EXISTS board_iterations_read ON public.board_iterations;
CREATE POLICY board_iterations_read ON public.board_iterations FOR SELECT TO authenticated USING(public.board_can_view(project_id));
DROP POLICY IF EXISTS board_iterations_add ON public.board_iterations;
CREATE POLICY board_iterations_add ON public.board_iterations FOR INSERT TO authenticated WITH CHECK(public.board_can_edit(project_id));
DROP POLICY IF EXISTS board_iterations_edit ON public.board_iterations;
CREATE POLICY board_iterations_edit ON public.board_iterations FOR UPDATE TO authenticated
 USING(public.board_can_edit(project_id)) WITH CHECK(public.board_can_edit(project_id));

CREATE OR REPLACE FUNCTION public.board_v41_guard_iteration()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 NEW.name := btrim(NEW.name);
 NEW.description := btrim(coalesce(NEW.description,''));
 IF length(NEW.name) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION 'Batch name must be 1-80 characters'; END IF;
 IF length(NEW.description)>600 THEN RAISE EXCEPTION 'Batch description too long'; END IF;
 IF TG_OP='UPDATE' AND (NEW.id IS DISTINCT FROM OLD.id OR NEW.project_id IS DISTINCT FROM OLD.project_id) THEN
  RAISE EXCEPTION 'Cannot move a batch to a different project';
 END IF;
 NEW.updated_at := now();
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v41_iteration_guard_trigger ON public.board_iterations;
CREATE TRIGGER board_v41_iteration_guard_trigger BEFORE INSERT OR UPDATE ON public.board_iterations
 FOR EACH ROW EXECUTE FUNCTION public.board_v41_guard_iteration();

-- Backfill a first iteration for each existing project, retaining all original tasks.
INSERT INTO public.board_iterations(project_id,name,description)
SELECT p.id,'初始需求（升级前）','V4.1 升级时已存在的需求统一保留在此批次'
FROM public.board_projects p
WHERE NOT EXISTS(SELECT 1 FROM public.board_iterations b WHERE b.project_id=p.id);
ALTER TABLE public.requirements ADD COLUMN IF NOT EXISTS iteration_id uuid;
UPDATE public.requirements r SET iteration_id=(
 SELECT b.id FROM public.board_iterations b WHERE b.project_id=r.project_id
 ORDER BY b.created_at,b.id LIMIT 1
) WHERE r.iteration_id IS NULL;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.requirements WHERE iteration_id IS NULL) THEN
  RAISE EXCEPTION 'Some requirements have no project iteration. Fix existing orphaned data before upgrading';
 END IF;
END $$;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname='board_requirements_iteration_fk' AND conrelid='public.requirements'::regclass) THEN
  ALTER TABLE public.requirements ADD CONSTRAINT board_requirements_iteration_fk
    FOREIGN KEY(project_id,iteration_id) REFERENCES public.board_iterations(project_id,id) ON DELETE RESTRICT;
 END IF;
END $$;
ALTER TABLE public.requirements ALTER COLUMN iteration_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS board_requirements_iteration_priority_idx
 ON public.requirements(project_id,iteration_id,priority,sort_order);

-- Ensure every newly created project starts with a usable first iteration.
CREATE OR REPLACE FUNCTION public.board_v41_default_iteration()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 INSERT INTO public.board_iterations(project_id,name,description) VALUES(NEW.id,'第 1 批 · 初始需求','');
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v41_new_project_iteration_trigger ON public.board_projects;
CREATE TRIGGER board_v41_new_project_iteration_trigger AFTER INSERT ON public.board_projects
 FOR EACH ROW EXECUTE FUNCTION public.board_v41_default_iteration();

-- Protect cross-project batch movement. Older import clients can omit iteration_id;
-- the newest OPEN iteration is then assigned automatically.
CREATE OR REPLACE FUNCTION public.board_v41_guard_task_iteration()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_closed boolean;
BEGIN
 IF NEW.iteration_id IS NULL THEN
  SELECT b.id INTO NEW.iteration_id FROM public.board_iterations b
   WHERE b.project_id=NEW.project_id AND NOT b.is_closed
   ORDER BY b.created_at DESC,b.id DESC LIMIT 1;
 END IF;
 IF NEW.iteration_id IS NULL THEN RAISE EXCEPTION 'Create an open batch before adding tasks'; END IF;
 SELECT b.is_closed INTO v_closed FROM public.board_iterations b
  WHERE b.id=NEW.iteration_id AND b.project_id=NEW.project_id FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Task batch does not belong to this project'; END IF;
 IF TG_OP='INSERT' THEN
  IF v_closed THEN RAISE EXCEPTION 'Cannot insert tasks into a closed batch'; END IF;
 ELSE
  IF NEW.project_id IS DISTINCT FROM OLD.project_id THEN
   RAISE EXCEPTION 'Cannot move tasks between projects';
  END IF;
  IF NEW.iteration_id IS DISTINCT FROM OLD.iteration_id AND v_closed THEN
   RAISE EXCEPTION 'Cannot move tasks into a closed batch';
  END IF;
 END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v41_requirement_iteration_trigger ON public.requirements;
CREATE TRIGGER board_v41_requirement_iteration_trigger BEFORE INSERT OR UPDATE OF iteration_id,project_id ON public.requirements
 FOR EACH ROW EXECUTE FUNCTION public.board_v41_guard_task_iteration();

-- Priority and manual ordering are ALWAYS scoped to the SAME batch + priority.
-- This redefines the existing RPC so even older UI clients cannot scramble other groups.
CREATE OR REPLACE FUNCTION public.board_set_task_position(p_task text,p_position integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_project uuid; v_batch uuid; v_priority text; v_order text[]; v_rest text[];
 v_new text[]:='{}'; v_n integer; v_cur integer; v_i integer; v_j integer:=1; v_pos integer;
BEGIN
 SELECT r.project_id,r.iteration_id,r.priority INTO v_project,v_batch,v_priority
 FROM public.requirements r WHERE r.id=p_task;
 IF v_project IS NULL OR NOT public.board_can_edit(v_project) THEN RAISE EXCEPTION '没有排序权限'; END IF;
 IF EXISTS(SELECT 1 FROM public.board_iterations b WHERE b.id=v_batch AND b.is_closed) THEN
  RAISE EXCEPTION '已结束批次不能调整执行顺序';
 END IF;
 -- Project row lock serializes parallel reorder requests across browsers.
 PERFORM 1 FROM public.board_projects p WHERE p.id=v_project FOR UPDATE;
 SELECT array_agg(r.id ORDER BY r.sort_order,r.created_at,r.id) INTO v_order
 FROM public.requirements r WHERE r.project_id=v_project AND r.iteration_id=v_batch AND r.priority=v_priority;
 v_n:=coalesce(array_length(v_order,1),0); v_cur:=array_position(v_order,p_task);
 IF v_cur IS NULL THEN RAISE EXCEPTION '需求不存在'; END IF;
 v_pos:=greatest(1,least(coalesce(p_position,v_cur),v_n));
 IF v_pos=v_cur THEN RETURN; END IF;
 v_rest:=array_remove(v_order,p_task);
 FOR v_i IN 1..v_n LOOP
   IF v_i=v_pos THEN v_new:=array_append(v_new,p_task);
   ELSE v_new:=array_append(v_new,v_rest[v_j]);v_j:=v_j+1;END IF;
 END LOOP;
 UPDATE public.requirements r SET sort_order=(x.n*100)::integer
 FROM unnest(v_new) WITH ORDINALITY AS x(id,n)
 WHERE r.id=x.id AND r.project_id=v_project AND r.iteration_id=v_batch
   AND r.priority=v_priority AND r.sort_order IS DISTINCT FROM (x.n*100)::integer;
END;$$;
REVOKE ALL ON FUNCTION public.board_set_task_position(text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.board_set_task_position(text,integer) TO authenticated;
REVOKE ALL ON FUNCTION public.board_v41_guard_iteration(),public.board_v41_default_iteration(),
 public.board_v41_guard_task_iteration() FROM PUBLIC,anon,authenticated;

-- Preserve append-only task history, including movement between batches.
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
   IF NEW.iteration_id IS DISTINCT FROM OLD.iteration_id THEN changes:=changes||jsonb_build_object('iteration',jsonb_build_array(OLD.iteration_id,NEW.iteration_id)); END IF;
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
NOTIFY pgrst, 'reload schema';
COMMIT;
