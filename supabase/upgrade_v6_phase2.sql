-- Project Tracker V6 Phase 2 enhancements
-- Requires V5.1 schema. Adds safe timer sessions and private project-file support.
-- Only board_* objects and board_project_documents are touched; Travel app data is untouched.
BEGIN;
DO $$ BEGIN
 IF to_regclass('public.board_projects') IS NULL
 OR to_regclass('public.board_time_entries') IS NULL
 OR to_regclass('public.board_project_documents') IS NULL
 OR to_regclass('public.requirements') IS NULL THEN
  RAISE EXCEPTION 'V5.1 schema is required before V6 Phase 2 migration';
 END IF;
END $$;

-- Private file uploads can coexist with external links in the project library.
ALTER TABLE public.board_project_documents ALTER COLUMN url DROP NOT NULL;
ALTER TABLE public.board_project_documents ADD COLUMN IF NOT EXISTS storage_path text;
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='board_project_documents_source_check' AND conrelid='public.board_project_documents'::regclass) THEN
  ALTER TABLE public.board_project_documents ADD CONSTRAINT board_project_documents_source_check
   CHECK (nullif(btrim(coalesce(url,'')),'') IS NOT NULL OR nullif(btrim(coalesce(storage_path,'')),'') IS NOT NULL);
 END IF;
END $$;

-- Timer sessions are separate from completed time entries. One active timer per user.
CREATE TABLE IF NOT EXISTS public.board_time_sessions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 requirement_id text REFERENCES public.requirements(id) ON DELETE SET NULL,
 task_title text NOT NULL DEFAULT '项目级工时',
 actor_email text NOT NULL,
 started_at timestamptz NOT NULL DEFAULT now(),
 stopped_at timestamptz,
 note text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK (stopped_at IS NULL OR stopped_at >= started_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS board_time_sessions_one_active_per_user
 ON public.board_time_sessions(actor_email) WHERE stopped_at IS NULL;
CREATE INDEX IF NOT EXISTS board_time_sessions_project_idx
 ON public.board_time_sessions(project_id,started_at DESC);
ALTER TABLE public.board_time_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.board_time_sessions FROM anon,authenticated;
GRANT SELECT ON public.board_time_sessions TO authenticated;
DROP POLICY IF EXISTS board_time_sessions_read ON public.board_time_sessions;
CREATE POLICY board_time_sessions_read ON public.board_time_sessions FOR SELECT TO authenticated
 USING (public.board_can_view(project_id) AND (actor_email=lower(auth.jwt()->>'email') OR public.board_can_edit(project_id)));

CREATE OR REPLACE FUNCTION public.board_start_timer(p_project uuid,p_requirement text DEFAULT NULL,p_note text DEFAULT '')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE sid uuid; task_name text:='项目级工时'; actor text;
BEGIN
 actor:=lower(auth.jwt()->>'email');
 IF auth.uid() IS NULL OR coalesce(auth.jwt()->>'is_anonymous','false')='true' OR NOT public.board_can_progress(p_project) THEN
  RAISE EXCEPTION 'No permission to start a timer for this project';
 END IF;
 IF p_requirement IS NOT NULL THEN
  SELECT title INTO task_name FROM public.requirements
   WHERE id=p_requirement AND project_id=p_project AND NOT is_withdrawn;
  IF task_name IS NULL THEN RAISE EXCEPTION 'Task does not belong to this project or is withdrawn'; END IF;
 END IF;
 IF EXISTS(SELECT 1 FROM public.board_time_sessions WHERE actor_email=actor AND stopped_at IS NULL) THEN
  RAISE EXCEPTION 'You already have an active timer. Stop it before starting another.';
 END IF;
 INSERT INTO public.board_time_sessions(project_id,requirement_id,task_title,actor_email,note)
 VALUES(p_project,p_requirement,task_name,actor,left(btrim(coalesce(p_note,'')),1000)) RETURNING id INTO sid;
 RETURN sid;
EXCEPTION WHEN unique_violation THEN
 RAISE EXCEPTION 'You already have an active timer. Stop it before starting another.';
END;$$;

CREATE OR REPLACE FUNCTION public.board_stop_timer(p_session uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE s public.board_time_sessions%ROWTYPE; mins integer; actor text;
BEGIN
 actor:=lower(auth.jwt()->>'email');
 SELECT * INTO s FROM public.board_time_sessions WHERE id=p_session FOR UPDATE;
 IF s.id IS NULL OR s.stopped_at IS NOT NULL THEN RAISE EXCEPTION 'Active timer not found'; END IF;
 IF s.actor_email<>actor THEN RAISE EXCEPTION 'Only the timer owner can stop this timer'; END IF;
 IF NOT public.board_can_progress(s.project_id) THEN RAISE EXCEPTION 'Project access was removed'; END IF;
 mins:=greatest(1,least(1440,ceil(extract(epoch FROM (clock_timestamp()-s.started_at))/60.0)::integer));
 UPDATE public.board_time_sessions SET stopped_at=clock_timestamp() WHERE id=s.id;
 INSERT INTO public.board_time_entries(project_id,requirement_id,task_title,actor_email,started_at,minutes,note)
 VALUES(s.project_id,s.requirement_id,s.task_title,s.actor_email,(s.started_at AT TIME ZONE 'UTC')::date,mins,s.note);
 DELETE FROM public.board_time_sessions WHERE id=s.id;
 RETURN mins;
END;$$;
REVOKE ALL ON FUNCTION public.board_start_timer(uuid,text,text),public.board_stop_timer(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.board_start_timer(uuid,text,text),public.board_stop_timer(uuid) TO authenticated;

-- Project members with edit permission may remove files stored in their own project folder.
DROP POLICY IF EXISTS board_private_project_delete ON storage.objects;
CREATE POLICY board_private_project_delete ON storage.objects FOR DELETE TO authenticated
 USING (bucket_id='requirements-private' AND public.board_storage_can_upload(name));

NOTIFY pgrst,'reload schema';
COMMIT;
