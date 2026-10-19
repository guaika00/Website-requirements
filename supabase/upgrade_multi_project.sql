-- Website requirements board v3 / IN-PLACE MIGRATION
-- Run ONCE in the existing Supabase SQL Editor before deploying the new frontend.
-- Designed to be rerunnable. Does not modify the Travel app schemas or XICHA Auth hooks.
-- Preserve team_members (registration whitelist), requirements, progress, private images.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS public.board_projects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE DEFAULT gen_random_uuid()::text,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
  description text NOT NULL DEFAULT '',
  is_archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.board_project_members (
  project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
  email text NOT NULL REFERENCES public.team_members(email) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('operator','developer')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(project_id,email),
  CHECK(email = lower(btrim(email)))
);
CREATE INDEX IF NOT EXISTS board_member_email_idx ON public.board_project_members(email);
CREATE TABLE IF NOT EXISTS public.board_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 60 AND name=btrim(name)),
  sort_order integer NOT NULL DEFAULT 999999,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS board_categories_name_unique ON public.board_categories(project_id,lower(name));
CREATE INDEX IF NOT EXISTS board_categories_order_idx ON public.board_categories(project_id,sort_order);
CREATE TABLE IF NOT EXISTS public.board_migration_records (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());

-- The former single workspace becomes the original/default project.
INSERT INTO public.board_projects(slug,name,description)
VALUES('website-requirements-original','沃德丰网站','原需求看板迁移的项目')
ON CONFLICT (slug) DO NOTHING;

ALTER TABLE public.requirements ADD COLUMN IF NOT EXISTS project_id uuid REFERENCES public.board_projects(id);
ALTER TABLE public.requirements ADD COLUMN IF NOT EXISTS priority text NOT NULL DEFAULT 'normal';
DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname='board_requirement_priority_check' AND conrelid='public.requirements'::regclass) THEN
    ALTER TABLE public.requirements ADD CONSTRAINT board_requirement_priority_check CHECK(priority IN ('normal','important','urgent'));
  END IF;
END $$;
ALTER TABLE public.board_assets ADD COLUMN IF NOT EXISTS project_id uuid REFERENCES public.board_projects(id);
ALTER TABLE public.requirement_progress ADD COLUMN IF NOT EXISTS project_id uuid REFERENCES public.board_projects(id);

-- Existing rows are assigned to the original project, keeping IDs and progress.
-- Temporarily suppress ONLY the board's audit stamps while adding project IDs,
-- preserving pre-migration updated_at/updated_by/completed_at. This is atomic:
-- if anything fails, the transaction also rolls back the trigger toggles.
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.requirements'::regclass AND tgname='requirements_stamp') THEN
   EXECUTE 'ALTER TABLE public.requirements DISABLE TRIGGER requirements_stamp';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.requirement_progress'::regclass AND tgname='progress_stamp') THEN
   EXECUTE 'ALTER TABLE public.requirement_progress DISABLE TRIGGER progress_stamp';
 END IF;
END $$;
UPDATE public.requirements SET project_id=(SELECT id FROM public.board_projects WHERE slug='website-requirements-original') WHERE project_id IS NULL;
UPDATE public.board_assets SET project_id=(SELECT id FROM public.board_projects WHERE slug='website-requirements-original') WHERE project_id IS NULL;
UPDATE public.requirement_progress p SET project_id=r.project_id FROM public.requirements r
 WHERE p.requirement_id=r.id AND p.project_id IS DISTINCT FROM r.project_id;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.requirements'::regclass AND tgname='requirements_stamp') THEN
   EXECUTE 'ALTER TABLE public.requirements ENABLE TRIGGER requirements_stamp';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.requirement_progress'::regclass AND tgname='progress_stamp') THEN
   EXECUTE 'ALTER TABLE public.requirement_progress ENABLE TRIGGER progress_stamp';
 END IF;
END $$;
ALTER TABLE public.requirements ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE public.board_assets ALTER COLUMN project_id SET NOT NULL;
ALTER TABLE public.requirement_progress ALTER COLUMN project_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS req_project_plan_idx ON public.requirements(project_id,sort_order,created_at);
CREATE INDEX IF NOT EXISTS progress_project_idx ON public.requirement_progress(project_id);
CREATE INDEX IF NOT EXISTS board_assets_project_idx ON public.board_assets(project_id);

-- Import the existing category names ONLY into their own project.
INSERT INTO public.board_categories(project_id,name,sort_order)
SELECT project_id,btrim(category),min(sort_order)
FROM public.requirements GROUP BY project_id,btrim(category)
ON CONFLICT DO NOTHING;
INSERT INTO public.board_categories(project_id,name,sort_order)
SELECT p.id,v.name,v.seq FROM public.board_projects p
CROSS JOIN (VALUES('产品页面',10),('侧边购物车',20),('产品模块设计',30),('类目页升级',40),('Banner',50)) AS v(name,seq)
WHERE p.slug='website-requirements-original'
  AND NOT EXISTS(SELECT 1 FROM public.board_migration_records WHERE name='v3_seeded_categories')
ON CONFLICT DO NOTHING;
INSERT INTO public.board_migration_records(name) VALUES('v3_seeded_categories') ON CONFLICT DO NOTHING;
INSERT INTO public.board_categories(project_id,name,sort_order)
SELECT p.id,'常规需求',1000 FROM public.board_projects p
WHERE NOT EXISTS(SELECT 1 FROM public.board_categories c WHERE c.project_id=p.id)
ON CONFLICT DO NOTHING;

-- ONE-TIME membership migration: members who previously shared the old board stay
-- on the default project. Future team_members additions are NEVER auto-assigned.
DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.board_migration_records WHERE name='v3_initial_membership') THEN
    INSERT INTO public.board_project_members(project_id,email,role)
    SELECT p.id,m.email,m.role FROM public.board_projects p
    CROSS JOIN public.team_members m
    WHERE p.slug='website-requirements-original' AND m.role IN ('operator','developer')
    ON CONFLICT(project_id,email) DO NOTHING;
    INSERT INTO public.board_migration_records(name) VALUES('v3_initial_membership');
  END IF;
END $$;

-- Administrator role is GLOBAL, other roles are PROJECT-SCOPED.
-- All functions use an empty search_path and only trusted membership tables.
CREATE OR REPLACE FUNCTION public.board_global_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT (SELECT auth.uid()) IS NOT NULL
  AND coalesce(auth.jwt()->>'is_anonymous','false') <> 'true'
  AND EXISTS(SELECT 1 FROM public.team_members t
    WHERE t.email=lower(auth.jwt()->>'email') AND t.role='admin');
$$;
CREATE OR REPLACE FUNCTION public.board_project_role(p_project uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT CASE
  WHEN (SELECT auth.uid()) IS NULL OR coalesce(auth.jwt()->>'is_anonymous','false')='true' THEN NULL
  WHEN public.board_global_admin() THEN 'admin'
  ELSE (SELECT pm.role FROM public.board_project_members pm
        JOIN public.board_projects p ON p.id=pm.project_id AND NOT p.is_archived
        WHERE pm.project_id=p_project AND pm.email=lower(auth.jwt()->>'email') LIMIT 1)
 END;
$$;
CREATE OR REPLACE FUNCTION public.board_can_view(p_project uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT public.board_project_role(p_project) IS NOT NULL;
$$;
CREATE OR REPLACE FUNCTION public.board_can_edit(p_project uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT public.board_project_role(p_project) IN ('admin','operator');
$$;
CREATE OR REPLACE FUNCTION public.board_can_progress(p_project uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT public.board_project_role(p_project) IN ('admin','developer');
$$;
REVOKE ALL ON FUNCTION public.board_global_admin() FROM public,anon;
REVOKE ALL ON FUNCTION public.board_project_role(uuid) FROM public,anon;
REVOKE ALL ON FUNCTION public.board_can_view(uuid) FROM public,anon;
REVOKE ALL ON FUNCTION public.board_can_edit(uuid) FROM public,anon;
REVOKE ALL ON FUNCTION public.board_can_progress(uuid) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.board_global_admin(),public.board_project_role(uuid),public.board_can_view(uuid),public.board_can_edit(uuid),public.board_can_progress(uuid) TO authenticated;

-- Automatic initial category for every project created from the dashboard.
CREATE OR REPLACE FUNCTION public.board_new_project_category()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 INSERT INTO public.board_categories(project_id,name,sort_order) VALUES(NEW.id,'常规需求',100);
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_new_project_category_trigger ON public.board_projects;
CREATE TRIGGER board_new_project_category_trigger AFTER INSERT ON public.board_projects
 FOR EACH ROW EXECUTE FUNCTION public.board_new_project_category();

-- Rename a category atomically across existing tasks without changing its project.
CREATE OR REPLACE FUNCTION public.board_category_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF TG_OP='DELETE' THEN
   IF EXISTS(SELECT 1 FROM public.requirements r WHERE r.project_id=OLD.project_id AND lower(r.category)=lower(OLD.name)) THEN
     RAISE EXCEPTION '分类仍有关联需求，请先移动需求或停用分类';
   END IF;
   RETURN OLD;
 END IF;
 IF NEW.project_id IS DISTINCT FROM OLD.project_id THEN RAISE EXCEPTION '不能跨项目移动分类'; END IF;
 NEW.name=btrim(NEW.name);
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_category_guard_trigger ON public.board_categories;
CREATE TRIGGER board_category_guard_trigger BEFORE UPDATE OR DELETE ON public.board_categories
 FOR EACH ROW EXECUTE FUNCTION public.board_category_guard();
CREATE OR REPLACE FUNCTION public.board_category_cascade_rename()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NEW.name IS DISTINCT FROM OLD.name THEN
   UPDATE public.requirements r SET category=NEW.name
   WHERE r.project_id=OLD.project_id AND lower(r.category)=lower(OLD.name);
 END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_category_cascade_rename_trigger ON public.board_categories;
CREATE TRIGGER board_category_cascade_rename_trigger AFTER UPDATE OF name ON public.board_categories
 FOR EACH ROW EXECUTE FUNCTION public.board_category_cascade_rename();

-- Requirements never move silently between projects. Validate category and stamp audit.
CREATE OR REPLACE FUNCTION public.stamp_requirement()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
 IF TG_OP='UPDATE' AND NEW.project_id IS DISTINCT FROM OLD.project_id THEN RAISE EXCEPTION '不能修改需求所属项目'; END IF;
 IF TG_OP='INSERT' THEN
   IF NOT EXISTS(SELECT 1 FROM public.board_categories c
     WHERE c.project_id=NEW.project_id AND c.name=NEW.category AND c.is_active) THEN
       RAISE EXCEPTION '该项目中没有可用的分类：%',NEW.category;
   END IF;
 ELSIF NEW.category IS DISTINCT FROM OLD.category THEN
   IF NOT EXISTS(SELECT 1 FROM public.board_categories c
     WHERE c.project_id=NEW.project_id AND c.name=NEW.category AND c.is_active) THEN
       RAISE EXCEPTION '该项目中没有可用的分类：%',NEW.category;
   END IF;
 END IF;
 NEW.updated_at=now(); NEW.updated_by=auth.uid(); NEW.updated_by_email=lower(auth.jwt()->>'email');
 IF TG_OP='INSERT' THEN
   NEW.created_at=now(); NEW.created_by=auth.uid();
 ELSE
   NEW.created_at=OLD.created_at; NEW.created_by=OLD.created_by;
 END IF;
 RETURN NEW;
END;$$;
-- Original requirements_stamp trigger continues to call this replacement function.

-- Keep progress.project_id consistent with the parent requirement.
CREATE OR REPLACE FUNCTION public.create_initial_progress()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 INSERT INTO public.requirement_progress(requirement_id,project_id) VALUES(NEW.id,NEW.project_id)
 ON CONFLICT(requirement_id) DO NOTHING;
 RETURN NEW;
END;$$;
CREATE OR REPLACE FUNCTION public.board_validate_progress_project()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE real_project uuid;
BEGIN
 SELECT project_id INTO real_project FROM public.requirements WHERE id=NEW.requirement_id;
 IF real_project IS NULL OR real_project IS DISTINCT FROM NEW.project_id THEN
   RAISE EXCEPTION '进度与需求所属项目不匹配';
 END IF;
 IF TG_OP='UPDATE' AND (NEW.project_id IS DISTINCT FROM OLD.project_id OR NEW.requirement_id IS DISTINCT FROM OLD.requirement_id) THEN
   RAISE EXCEPTION '不能转移需求进度';
 END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_progress_project_guard_trigger ON public.requirement_progress;
CREATE TRIGGER board_progress_project_guard_trigger BEFORE INSERT OR UPDATE ON public.requirement_progress
 FOR EACH ROW EXECUTE FUNCTION public.board_validate_progress_project();

-- Keep extra/reference assets in their project.
CREATE OR REPLACE FUNCTION public.board_asset_project_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
 IF TG_OP='UPDATE' AND NEW.project_id IS DISTINCT FROM OLD.project_id THEN
   RAISE EXCEPTION '不能跨项目移动附件';
 END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_asset_guard_trigger ON public.board_assets;
CREATE TRIGGER board_asset_guard_trigger BEFORE UPDATE ON public.board_assets
 FOR EACH ROW EXECUTE FUNCTION public.board_asset_project_guard();

-- Policies are REPLACED, including previously broad single-board policies.
ALTER TABLE public.board_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_project_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.requirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.requirement_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_migration_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.board_projects,public.board_project_members,public.board_categories,public.board_migration_records FROM anon;
GRANT SELECT,INSERT,UPDATE ON public.board_projects TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.board_project_members,public.board_categories TO authenticated;
-- No client permissions for the internal migration marker table.
REVOKE ALL ON public.board_migration_records FROM anon,authenticated;

DROP POLICY IF EXISTS board_projects_read ON public.board_projects;
CREATE POLICY board_projects_read ON public.board_projects FOR SELECT TO authenticated
 USING (public.board_can_view(id));
DROP POLICY IF EXISTS board_projects_add ON public.board_projects;
CREATE POLICY board_projects_add ON public.board_projects FOR INSERT TO authenticated
 WITH CHECK (public.board_global_admin());
DROP POLICY IF EXISTS board_projects_edit ON public.board_projects;
CREATE POLICY board_projects_edit ON public.board_projects FOR UPDATE TO authenticated
 USING (public.board_global_admin()) WITH CHECK (public.board_global_admin());
DROP POLICY IF EXISTS board_project_members_read ON public.board_project_members;
CREATE POLICY board_project_members_read ON public.board_project_members FOR SELECT TO authenticated
 USING (public.board_can_view(project_id));
DROP POLICY IF EXISTS board_project_members_add ON public.board_project_members;
CREATE POLICY board_project_members_add ON public.board_project_members FOR INSERT TO authenticated
 WITH CHECK(public.board_global_admin());
DROP POLICY IF EXISTS board_project_members_edit ON public.board_project_members;
CREATE POLICY board_project_members_edit ON public.board_project_members FOR UPDATE TO authenticated
 USING(public.board_global_admin()) WITH CHECK(public.board_global_admin());
DROP POLICY IF EXISTS board_project_members_delete ON public.board_project_members;
CREATE POLICY board_project_members_delete ON public.board_project_members FOR DELETE TO authenticated
 USING(public.board_global_admin());
DROP POLICY IF EXISTS board_categories_read ON public.board_categories;
CREATE POLICY board_categories_read ON public.board_categories FOR SELECT TO authenticated
 USING(public.board_can_view(project_id));
DROP POLICY IF EXISTS board_categories_add ON public.board_categories;
CREATE POLICY board_categories_add ON public.board_categories FOR INSERT TO authenticated
 WITH CHECK(public.board_can_edit(project_id));
DROP POLICY IF EXISTS board_categories_edit ON public.board_categories;
CREATE POLICY board_categories_edit ON public.board_categories FOR UPDATE TO authenticated
 USING(public.board_can_edit(project_id)) WITH CHECK(public.board_can_edit(project_id));
DROP POLICY IF EXISTS board_categories_delete ON public.board_categories;
CREATE POLICY board_categories_delete ON public.board_categories FOR DELETE TO authenticated
 USING(public.board_can_edit(project_id));

DROP POLICY IF EXISTS requirements_read ON public.requirements;
CREATE POLICY requirements_read ON public.requirements FOR SELECT TO authenticated
 USING(public.board_can_view(project_id));
DROP POLICY IF EXISTS requirements_add ON public.requirements;
CREATE POLICY requirements_add ON public.requirements FOR INSERT TO authenticated
 WITH CHECK(public.board_can_edit(project_id));
DROP POLICY IF EXISTS requirements_edit ON public.requirements;
CREATE POLICY requirements_edit ON public.requirements FOR UPDATE TO authenticated
 USING(public.board_can_edit(project_id)) WITH CHECK(public.board_can_edit(project_id));
DROP POLICY IF EXISTS requirements_delete ON public.requirements;
CREATE POLICY requirements_delete ON public.requirements FOR DELETE TO authenticated
 USING(public.board_global_admin());
DROP POLICY IF EXISTS progress_read ON public.requirement_progress;
CREATE POLICY progress_read ON public.requirement_progress FOR SELECT TO authenticated
 USING(public.board_can_view(project_id));
DROP POLICY IF EXISTS progress_add ON public.requirement_progress;
CREATE POLICY progress_add ON public.requirement_progress FOR INSERT TO authenticated
 WITH CHECK(public.board_can_progress(project_id));
DROP POLICY IF EXISTS progress_edit ON public.requirement_progress;
CREATE POLICY progress_edit ON public.requirement_progress FOR UPDATE TO authenticated
 USING(public.board_can_progress(project_id)) WITH CHECK(public.board_can_progress(project_id));
DROP POLICY IF EXISTS board_assets_read ON public.board_assets;
CREATE POLICY board_assets_read ON public.board_assets FOR SELECT TO authenticated
 USING(public.board_can_view(project_id));
DROP POLICY IF EXISTS board_assets_add ON public.board_assets;
CREATE POLICY board_assets_add ON public.board_assets FOR INSERT TO authenticated
 WITH CHECK(public.board_can_edit(project_id));
DROP POLICY IF EXISTS board_assets_delete ON public.board_assets;
CREATE POLICY board_assets_delete ON public.board_assets FOR DELETE TO authenticated
 USING(public.board_global_admin());

-- Image isolation for legacy uploads and new per-project storage paths.
-- A legacy image is visible only when referenced in a requirement/asset of a visible project.
CREATE OR REPLACE FUNCTION public.board_storage_can_read(p_path text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE part text;
BEGIN
 IF (SELECT auth.uid()) IS NULL THEN RETURN false; END IF;
 IF split_part(p_path,'/',1)='projects' AND split_part(p_path,'/',3)='uploads' THEN
   part:=split_part(p_path,'/',2);
   IF part ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
     RETURN public.board_can_view(part::uuid);
   END IF;
   RETURN false;
 END IF;
 RETURN EXISTS(SELECT 1 FROM public.requirements r
   WHERE public.board_can_view(r.project_id)
     AND (p_path=ANY(r.sources) OR p_path=ANY(r."references")))
   OR EXISTS(SELECT 1 FROM public.board_assets a
     WHERE a.path=p_path AND public.board_can_view(a.project_id));
END;$$;
CREATE OR REPLACE FUNCTION public.board_storage_can_upload(p_path text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE part text;
BEGIN
 IF split_part(p_path,'/',1)<>'projects' OR split_part(p_path,'/',3)<>'uploads' THEN RETURN false; END IF;
 part:=split_part(p_path,'/',2);
 IF part !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN false; END IF;
 RETURN public.board_can_edit(part::uuid);
END;$$;
REVOKE ALL ON FUNCTION public.board_storage_can_read(text),public.board_storage_can_upload(text) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.board_storage_can_read(text),public.board_storage_can_upload(text) TO authenticated;
DROP POLICY IF EXISTS requirements_image_read ON storage.objects;
DROP POLICY IF EXISTS requirements_image_upload ON storage.objects;
DROP POLICY IF EXISTS requirements_image_delete ON storage.objects;
DROP POLICY IF EXISTS board_private_project_read ON storage.objects;
CREATE POLICY board_private_project_read ON storage.objects FOR SELECT TO authenticated
 USING(bucket_id='requirements-private' AND public.board_storage_can_read(name));
DROP POLICY IF EXISTS board_private_project_upload ON storage.objects;
CREATE POLICY board_private_project_upload ON storage.objects FOR INSERT TO authenticated
 WITH CHECK(bucket_id='requirements-private' AND public.board_storage_can_upload(name));
DROP POLICY IF EXISTS board_private_project_delete ON storage.objects;
CREATE POLICY board_private_project_delete ON storage.objects FOR DELETE TO authenticated
 USING(bucket_id='requirements-private' AND public.board_global_admin());

-- Transactional ordering; project row serializes concurrent planners.
CREATE OR REPLACE FUNCTION public.board_set_task_position(p_task text,p_position integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_project uuid; v_order text[]; v_rest text[]; v_new text[]:='{}'; v_n integer; v_cur integer; v_i integer; v_j integer:=1; v_pos integer;
BEGIN
 SELECT r.project_id INTO v_project FROM public.requirements r WHERE r.id=p_task;
 IF v_project IS NULL OR NOT public.board_can_edit(v_project) THEN RAISE EXCEPTION '没有排序权限'; END IF;
 PERFORM 1 FROM public.board_projects WHERE id=v_project FOR UPDATE;
 SELECT array_agg(r.id ORDER BY r.sort_order,r.created_at,r.id) INTO v_order
 FROM public.requirements r WHERE r.project_id=v_project;
 v_n:=coalesce(array_length(v_order,1),0); v_cur:=array_position(v_order,p_task);
 IF v_cur IS NULL OR v_n=0 THEN RAISE EXCEPTION '需求不存在'; END IF;
 v_pos:=greatest(1,least(coalesce(p_position,v_cur),v_n));
 IF v_pos=v_cur THEN RETURN; END IF;
 v_rest:=array_remove(v_order,p_task);
 FOR v_i IN 1..v_n LOOP
   IF v_i=v_pos THEN v_new:=array_append(v_new,p_task);
   ELSE v_new:=array_append(v_new,v_rest[v_j]); v_j:=v_j+1; END IF;
 END LOOP;
 UPDATE public.requirements r SET sort_order=(t.n*100)::integer
 FROM unnest(v_new) WITH ORDINALITY AS t(id,n)
 WHERE r.id=t.id AND r.project_id=v_project AND r.sort_order IS DISTINCT FROM (t.n*100)::integer;
END;$$;
CREATE OR REPLACE FUNCTION public.board_set_category_position(p_category uuid,p_position integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_project uuid; v_order uuid[]; v_rest uuid[]; v_new uuid[]:='{}'; v_n integer; v_cur integer; v_i integer; v_j integer:=1; v_pos integer;
BEGIN
 SELECT c.project_id INTO v_project FROM public.board_categories c WHERE c.id=p_category;
 IF v_project IS NULL OR NOT public.board_can_edit(v_project) THEN RAISE EXCEPTION '没有分类排序权限'; END IF;
 PERFORM 1 FROM public.board_projects WHERE id=v_project FOR UPDATE;
 SELECT array_agg(c.id ORDER BY c.sort_order,c.created_at,c.id) INTO v_order
 FROM public.board_categories c WHERE c.project_id=v_project;
 v_n:=coalesce(array_length(v_order,1),0); v_cur:=array_position(v_order,p_category);
 IF v_cur IS NULL OR v_n=0 THEN RAISE EXCEPTION '分类不存在'; END IF;
 v_pos:=greatest(1,least(coalesce(p_position,v_cur),v_n));
 IF v_pos=v_cur THEN RETURN; END IF;
 v_rest:=array_remove(v_order,p_category);
 FOR v_i IN 1..v_n LOOP
   IF v_i=v_pos THEN v_new:=array_append(v_new,p_category);
   ELSE v_new:=array_append(v_new,v_rest[v_j]); v_j:=v_j+1; END IF;
 END LOOP;
 UPDATE public.board_categories c SET sort_order=(t.n*100)::integer
 FROM unnest(v_new) WITH ORDINALITY AS t(id,n)
 WHERE c.id=t.id AND c.project_id=v_project AND c.sort_order IS DISTINCT FROM (t.n*100)::integer;
END;$$;
REVOKE ALL ON FUNCTION public.board_set_task_position(text,integer),public.board_set_category_position(uuid,integer) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.board_set_task_position(text,integer),public.board_set_category_position(uuid,integer) TO authenticated;

-- Important for strict tenant isolation: Supabase Postgres Changes cannot fully
-- authorize/filter DELETE events. Remove ONLY this board's tables from the shared
-- realtime publication; other apps/tables, including the travel app, are untouched.
-- The v3 frontend uses permission-checked polling every 15 seconds instead.
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['requirements','requirement_progress','board_assets',
    'board_projects','board_project_members','board_categories'] LOOP
    IF EXISTS(SELECT 1 FROM pg_publication_tables
      WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=t) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime DROP TABLE public.%I',t);
    END IF;
  END LOOP;
END $$;
COMMIT;
