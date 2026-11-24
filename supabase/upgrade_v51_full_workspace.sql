-- Project Tracker V5.1: Gantt dates, templates, knowledge base, time tracking,
-- dependencies, project cloning, weekly-report support and secure public read-only links.
-- Requires V5 collaboration + V4.1 schema. Does not alter Travel app tables or XICHA hooks.
BEGIN;
DO $$ BEGIN
 IF to_regclass('public.board_projects') IS NULL OR to_regclass('public.board_iterations') IS NULL
 OR to_regclass('public.board_comments') IS NULL OR to_regclass('public.board_notifications') IS NULL
 THEN RAISE EXCEPTION 'Install V4.1 and V5 collaboration migration first'; END IF;
END $$;

ALTER TABLE public.requirements ADD COLUMN IF NOT EXISTS start_date date;
ALTER TABLE public.requirements ADD COLUMN IF NOT EXISTS estimated_minutes integer CHECK(estimated_minutes IS NULL OR estimated_minutes BETWEEN 1 AND 1000000);
CREATE INDEX IF NOT EXISTS board_requirements_gantt_idx ON public.requirements(project_id,start_date,due_date);

CREATE TABLE IF NOT EXISTS public.board_task_templates (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 name text NOT NULL CHECK(length(btrim(name)) BETWEEN 1 AND 100), description text NOT NULL DEFAULT '', category text,
 template_data jsonb NOT NULL DEFAULT '{}'::jsonb, created_by text NOT NULL DEFAULT lower(auth.jwt()->>'email'), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS board_templates_project_idx ON public.board_task_templates(project_id,created_at DESC);
CREATE TABLE IF NOT EXISTS public.board_project_documents (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 title text NOT NULL CHECK(length(btrim(title)) BETWEEN 1 AND 140), kind text NOT NULL DEFAULT '其他',
 url text NOT NULL CHECK(url ~* '^https?://'), description text NOT NULL DEFAULT '', created_by text NOT NULL DEFAULT lower(auth.jwt()->>'email'), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS board_docs_project_idx ON public.board_project_documents(project_id,created_at DESC);
CREATE TABLE IF NOT EXISTS public.board_time_entries (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 requirement_id text REFERENCES public.requirements(id) ON DELETE SET NULL, task_title text NOT NULL DEFAULT '',
 actor_email text NOT NULL DEFAULT lower(auth.jwt()->>'email'), started_at date NOT NULL DEFAULT current_date,
 minutes integer NOT NULL CHECK(minutes BETWEEN 1 AND 1440), note text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS board_time_project_idx ON public.board_time_entries(project_id,started_at DESC);
CREATE TABLE IF NOT EXISTS public.board_task_dependencies (
 project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 requirement_id text NOT NULL REFERENCES public.requirements(id) ON DELETE CASCADE,
 depends_on_id text NOT NULL REFERENCES public.requirements(id) ON DELETE CASCADE,
 created_by text NOT NULL DEFAULT lower(auth.jwt()->>'email'), created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(requirement_id,depends_on_id), CHECK(requirement_id<>depends_on_id)
);
CREATE INDEX IF NOT EXISTS board_dependencies_project_idx ON public.board_task_dependencies(project_id);
CREATE TABLE IF NOT EXISTS public.board_share_links (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 token text NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(24),'hex'), label text NOT NULL DEFAULT '项目只读分享',
 created_by text NOT NULL DEFAULT lower(auth.jwt()->>'email'), created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz, revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS board_share_project_idx ON public.board_share_links(project_id,created_at DESC);

DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['board_task_templates','board_project_documents','board_time_entries','board_task_dependencies','board_share_links'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM anon',t);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON public.%I TO authenticated',t);
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_read',t);
  EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING(public.board_can_view(project_id))',t||'_read',t);
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_write',t);
  IF t='board_time_entries' THEN
   EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK(public.board_can_progress(project_id) AND actor_email=lower(auth.jwt()->>''email''))',t||'_write',t);
  ELSIF t='board_share_links' THEN
   EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK(public.board_can_edit(project_id) AND created_by=lower(auth.jwt()->>''email''))',t||'_write',t);
  ELSE
   EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK(public.board_can_edit(project_id))',t||'_write',t);
  END IF;
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_update',t);
  IF t='board_time_entries' THEN
   EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING(public.board_can_edit(project_id) OR (actor_email=lower(auth.jwt()->>''email'') AND public.board_can_progress(project_id))) WITH CHECK(public.board_can_edit(project_id) OR (actor_email=lower(auth.jwt()->>''email'') AND public.board_can_progress(project_id)))',t||'_update',t);
  ELSIF t='board_share_links' THEN
   EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING(public.board_can_edit(project_id)) WITH CHECK(public.board_can_edit(project_id))',t||'_update',t);
  ELSE
   EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING(public.board_can_edit(project_id)) WITH CHECK(public.board_can_edit(project_id))',t||'_update',t);
  END IF;
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_delete',t);
  EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING(public.board_can_edit(project_id))',t||'_delete',t);
 END LOOP;
END $$;

-- Enforce dependency edges within the same project and reject cycles.
CREATE OR REPLACE FUNCTION public.board_v51_dependency_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a uuid; b uuid;
BEGIN
 SELECT project_id INTO a FROM public.requirements WHERE id=NEW.requirement_id;
 SELECT project_id INTO b FROM public.requirements WHERE id=NEW.depends_on_id;
 IF a IS NULL OR b IS NULL OR a<>b OR a<>NEW.project_id THEN RAISE EXCEPTION 'Dependencies must reference tasks in the same project'; END IF;
 IF EXISTS(WITH RECURSIVE chain(id) AS (SELECT NEW.depends_on_id UNION SELECT d.depends_on_id FROM public.board_task_dependencies d JOIN chain c ON d.requirement_id=c.id WHERE d.project_id=NEW.project_id) SELECT 1 FROM chain WHERE id=NEW.requirement_id) THEN RAISE EXCEPTION 'Task dependency cycle detected'; END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v51_dependency_guard_trigger ON public.board_task_dependencies;
CREATE TRIGGER board_v51_dependency_guard_trigger BEFORE INSERT OR UPDATE ON public.board_task_dependencies FOR EACH ROW EXECUTE FUNCTION public.board_v51_dependency_guard();

-- Clone a project structure and open iterations/categories/tasks into a new project.
-- Completed task statuses are intentionally reset to todo; source remains untouched.
CREATE OR REPLACE FUNCTION public.board_clone_project(p_source uuid,p_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE new_id uuid; old record; new_iteration uuid; iter_map jsonb:='{}'::jsonb; task_map jsonb:='{}'::jsonb; new_task text;
BEGIN
 IF NOT public.board_can_view(p_source) OR NOT public.board_can_create_project() THEN RAISE EXCEPTION 'Not authorized to clone this project'; END IF;
 new_id:=public.board_create_project(p_name,'由项目复制创建');
 INSERT INTO public.board_categories(project_id,name,sort_order,is_active) SELECT new_id,name,sort_order,is_active FROM public.board_categories WHERE project_id=p_source;
 FOR old IN SELECT * FROM public.board_iterations WHERE project_id=p_source ORDER BY created_at LOOP
  INSERT INTO public.board_iterations(project_id,name,description,is_closed) VALUES(new_id,old.name,old.description,false) RETURNING id INTO new_iteration;
  iter_map:=iter_map||jsonb_build_object(old.id::text,new_iteration::text);
 END LOOP;
 -- Copy task records without IDs; retain requirement fields and reset status to todo.
 FOR old IN SELECT * FROM public.requirements WHERE project_id=p_source AND NOT is_withdrawn ORDER BY sort_order,created_at LOOP
  INSERT INTO public.requirements(project_id,iteration_id,title,description,category,priority,sort_order,links,sources,"references",assignee_email,due_date,start_date,estimated_minutes,is_withdrawn)
  VALUES(new_id,(iter_map->>old.iteration_id::text)::uuid,old.title,old.description,old.category,old.priority,old.sort_order,old.links,'{}','{}',NULL,old.due_date,old.start_date,old.estimated_minutes,false)
  RETURNING id INTO new_task;
  INSERT INTO public.requirement_progress(requirement_id,project_id,status,is_blocked,note) VALUES(new_task,new_id,'todo',false,'');
 END LOOP;
 RETURN new_id;
END;$$;
REVOKE ALL ON FUNCTION public.board_clone_project(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.board_clone_project(uuid,text) TO authenticated;

-- Share links are deliberately public-read only and expose a minimal snapshot.
CREATE OR REPLACE FUNCTION public.board_create_share_link(p_project uuid,p_label text DEFAULT '项目只读分享',p_days integer DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE tok text;
BEGIN
 IF NOT public.board_can_edit(p_project) THEN RAISE EXCEPTION 'Not authorized'; END IF;
 IF p_days IS NOT NULL AND p_days NOT BETWEEN 1 AND 365 THEN RAISE EXCEPTION 'Expiry must be 1-365 days'; END IF;
 INSERT INTO public.board_share_links(project_id,label,expires_at)
 VALUES(p_project,left(btrim(coalesce(p_label,'项目只读分享')),100),CASE WHEN p_days IS NULL THEN NULL ELSE now()+make_interval(days=>p_days) END)
 RETURNING token INTO tok;
 RETURN tok;
END;$$;
CREATE OR REPLACE FUNCTION public.board_public_share(p_token text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE WHEN l.id IS NULL THEN NULL ELSE jsonb_build_object(
  'project',jsonb_build_object('name',p.name,'description',p.description,'shared_at',l.created_at),
  'requirements',coalesce((SELECT jsonb_agg(jsonb_build_object('title',r.title,'category',r.category,'priority',r.priority,'status',pr.status,'blocked',pr.is_blocked,'due_date',r.due_date,'iteration',it.name) ORDER BY r.priority,r.sort_order)
    FROM public.requirements r LEFT JOIN public.requirement_progress pr ON pr.requirement_id=r.id LEFT JOIN public.board_iterations it ON it.id=r.iteration_id
    WHERE r.project_id=p.id AND NOT r.is_withdrawn),'[]'::jsonb)) END
 FROM public.board_share_links l JOIN public.board_projects p ON p.id=l.project_id
 WHERE l.token=p_token AND l.revoked_at IS NULL AND (l.expires_at IS NULL OR l.expires_at>now())
 LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.board_create_share_link(uuid,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.board_create_share_link(uuid,text,integer) TO authenticated;
REVOKE ALL ON FUNCTION public.board_public_share(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.board_public_share(text) TO anon,authenticated;

-- Idempotent overdue reminders. The client may invoke this on project load; unique
-- recipient/kind/source prevents duplicate reminders for the same task progress row.
CREATE OR REPLACE FUNCTION public.board_emit_overdue_notifications()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE n integer:=0; item record;
BEGIN
 IF auth.uid() IS NULL OR coalesce(auth.jwt()->>'is_anonymous','false')='true' THEN RAISE EXCEPTION 'Authentication required'; END IF;
 FOR item IN
  SELECT r.project_id,r.id AS requirement_id,r.title,r.due_date,pr.id AS progress_id,pm.email
  FROM public.requirements r JOIN public.requirement_progress pr ON pr.requirement_id=r.id AND pr.project_id=r.project_id
  JOIN public.board_project_members pm ON pm.project_id=r.project_id
  WHERE public.board_can_view(r.project_id) AND NOT r.is_withdrawn AND pr.status<>'done'
    AND r.due_date<current_date AND pm.email<>lower(auth.jwt()->>'email')
    AND (pm.role='operator' OR pm.email=r.assignee_email)
 LOOP
  INSERT INTO public.board_notifications(recipient_email,project_id,requirement_id,kind,title,body,actor_email,source_id)
  VALUES(item.email,item.project_id,item.requirement_id,'due','需求已逾期',item.title||' · 截止日期 '||item.due_date::text,lower(auth.jwt()->>'email'),item.progress_id)
  ON CONFLICT(recipient_email,kind,source_id) DO NOTHING;
  IF FOUND THEN n:=n+1; END IF;
 END LOOP;
 RETURN n;
END;$$;
REVOKE ALL ON FUNCTION public.board_emit_overdue_notifications() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.board_emit_overdue_notifications() TO authenticated;

-- Weekly summaries are generated client-side from RLS-filtered data; no cross-project data is exposed.
NOTIFY pgrst,'reload schema';
COMMIT;
