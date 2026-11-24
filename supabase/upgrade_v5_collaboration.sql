-- Project Tracker V5: dashboard data, task comments/@mentions, notifications, change history.
-- Requires V4.1 + manager-role migration. Only board_* tables/functions are touched.
BEGIN;
DO $$ BEGIN
 IF to_regclass('public.board_projects') IS NULL OR to_regclass('public.board_project_members') IS NULL
 OR to_regclass('public.board_iterations') IS NULL OR to_regclass('public.board_activity') IS NULL
 THEN RAISE EXCEPTION 'V5 requires the V4.1 board schema and manager-role migration'; END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.board_comments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 requirement_id text NOT NULL REFERENCES public.requirements(id) ON DELETE CASCADE,
 parent_id uuid REFERENCES public.board_comments(id) ON DELETE CASCADE,
 author_id uuid NOT NULL DEFAULT auth.uid(),
 author_email text NOT NULL DEFAULT lower(auth.jwt()->>'email'),
 body text NOT NULL CHECK(length(btrim(body)) BETWEEN 1 AND 5000),
 mentioned_emails text[] NOT NULL DEFAULT '{}',
 is_deleted boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(project_id,id)
);
CREATE INDEX IF NOT EXISTS board_comments_task_idx ON public.board_comments(project_id,requirement_id,created_at);
CREATE INDEX IF NOT EXISTS board_comments_author_idx ON public.board_comments(author_email,created_at DESC);
CREATE OR REPLACE FUNCTION public.board_v5_comment_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE parent_project uuid; parent_task text;
BEGIN
 IF TG_OP='INSERT' AND NEW.parent_id IS NOT NULL THEN
  SELECT project_id,requirement_id INTO parent_project,parent_task FROM public.board_comments WHERE id=NEW.parent_id;
  IF parent_project IS DISTINCT FROM NEW.project_id OR parent_task IS DISTINCT FROM NEW.requirement_id THEN
   RAISE EXCEPTION 'A reply must belong to the same project and requirement as its parent comment';
  END IF;
 END IF;
 IF TG_OP='UPDATE' AND (NEW.project_id IS DISTINCT FROM OLD.project_id OR NEW.requirement_id IS DISTINCT FROM OLD.requirement_id OR NEW.author_id IS DISTINCT FROM OLD.author_id OR NEW.author_email IS DISTINCT FROM OLD.author_email) THEN
  RAISE EXCEPTION 'Comment ownership and location cannot be changed';
 END IF;
 NEW.body:=btrim(NEW.body); NEW.updated_at:=now();
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v5_comment_guard_trigger ON public.board_comments;
CREATE TRIGGER board_v5_comment_guard_trigger BEFORE INSERT OR UPDATE ON public.board_comments
 FOR EACH ROW EXECUTE FUNCTION public.board_v5_comment_guard();

CREATE TABLE IF NOT EXISTS public.board_notifications (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 recipient_email text NOT NULL,
 project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 requirement_id text REFERENCES public.requirements(id) ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN ('mention','comment','assigned','status','review','returned','due')),
 title text NOT NULL,
 body text NOT NULL DEFAULT '',
 actor_email text,
 source_id uuid,
 is_read boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(recipient_email,kind,source_id)
);
CREATE INDEX IF NOT EXISTS board_notifications_inbox_idx ON public.board_notifications(recipient_email,is_read,created_at DESC);

CREATE TABLE IF NOT EXISTS public.board_requirement_versions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 project_id uuid NOT NULL REFERENCES public.board_projects(id) ON DELETE CASCADE,
 requirement_id text NOT NULL REFERENCES public.requirements(id) ON DELETE CASCADE,
 actor_email text NOT NULL DEFAULT coalesce(lower(auth.jwt()->>'email'),'system'),
 changed_at timestamptz NOT NULL DEFAULT now(),
 change_reason text NOT NULL DEFAULT '',
 before_data jsonb NOT NULL,
 after_data jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS board_req_versions_idx ON public.board_requirement_versions(project_id,requirement_id,changed_at DESC);

ALTER TABLE public.board_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_requirement_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.board_comments,public.board_notifications,public.board_requirement_versions FROM anon;
GRANT SELECT,INSERT,UPDATE ON public.board_comments TO authenticated;
GRANT SELECT ON public.board_notifications TO authenticated;
GRANT UPDATE(is_read) ON public.board_notifications TO authenticated;
GRANT SELECT ON public.board_requirement_versions TO authenticated;

DROP POLICY IF EXISTS board_comments_read ON public.board_comments;
CREATE POLICY board_comments_read ON public.board_comments FOR SELECT TO authenticated USING(public.board_can_view(project_id));
DROP POLICY IF EXISTS board_comments_add ON public.board_comments;
CREATE POLICY board_comments_add ON public.board_comments FOR INSERT TO authenticated WITH CHECK(
 public.board_can_progress(project_id) AND author_id=auth.uid() AND author_email=lower(auth.jwt()->>'email')
 AND EXISTS(SELECT 1 FROM public.requirements r WHERE r.id=requirement_id AND r.project_id=board_comments.project_id AND NOT r.is_withdrawn)
);
DROP POLICY IF EXISTS board_comments_edit ON public.board_comments;
CREATE POLICY board_comments_edit ON public.board_comments FOR UPDATE TO authenticated USING(
 author_id=auth.uid() AND created_at>now()-interval '30 minutes' AND public.board_can_progress(project_id)
) WITH CHECK(author_id=auth.uid() AND author_email=lower(auth.jwt()->>'email') AND public.board_can_progress(project_id));

DROP POLICY IF EXISTS board_notifications_read ON public.board_notifications;
CREATE POLICY board_notifications_read ON public.board_notifications FOR SELECT TO authenticated USING(recipient_email=lower(auth.jwt()->>'email') AND public.board_can_view(project_id));
DROP POLICY IF EXISTS board_notifications_mark_read ON public.board_notifications;
CREATE POLICY board_notifications_mark_read ON public.board_notifications FOR UPDATE TO authenticated USING(recipient_email=lower(auth.jwt()->>'email') AND public.board_can_view(project_id)) WITH CHECK(recipient_email=lower(auth.jwt()->>'email') AND public.board_can_view(project_id));

DROP POLICY IF EXISTS board_versions_read ON public.board_requirement_versions;
CREATE POLICY board_versions_read ON public.board_requirement_versions FOR SELECT TO authenticated USING(public.board_can_view(project_id));

CREATE OR REPLACE FUNCTION public.board_v5_task_version()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE reason text;
BEGIN
 IF TG_OP='UPDATE' THEN
  IF (to_jsonb(NEW)-'updated_at'-'updated_by'-'updated_by_email') IS DISTINCT FROM (to_jsonb(OLD)-'updated_at'-'updated_by'-'updated_by_email') THEN
   reason:=coalesce(nullif(current_setting('app.board_change_reason',true),''),'需求内容或排期发生修改');
   INSERT INTO public.board_requirement_versions(project_id,requirement_id,actor_email,change_reason,before_data,after_data)
   VALUES(OLD.project_id,OLD.id,coalesce(lower(auth.jwt()->>'email'),'system'),reason,to_jsonb(OLD),to_jsonb(NEW));
  END IF;
 END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v5_task_version_trigger ON public.requirements;
CREATE TRIGGER board_v5_task_version_trigger AFTER UPDATE ON public.requirements
 FOR EACH ROW EXECUTE FUNCTION public.board_v5_task_version();

CREATE OR REPLACE FUNCTION public.board_v5_comment_notify()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE target record; task_title text; notify_email text;
BEGIN
 SELECT title INTO task_title FROM public.requirements WHERE id=NEW.requirement_id AND project_id=NEW.project_id;
 -- Notify the task assignee, unless they authored the comment.
 SELECT assignee_email INTO notify_email FROM public.requirements WHERE id=NEW.requirement_id;
 IF notify_email IS NOT NULL AND notify_email<>NEW.author_email THEN
  INSERT INTO public.board_notifications(recipient_email,project_id,requirement_id,kind,title,body,actor_email,source_id)
  VALUES(notify_email,NEW.project_id,NEW.requirement_id,'comment','需求有新评论',coalesce(task_title,'')||'：'||left(NEW.body,180),NEW.author_email,NEW.id)
  ON CONFLICT DO NOTHING;
 END IF;
 -- @mentions are matched against actual project members, never arbitrary email text.
 FOR target IN SELECT DISTINCT lower(pm.email) AS email FROM public.board_project_members pm
   WHERE pm.project_id=NEW.project_id AND pm.email<>NEW.author_email
   AND position('@'||lower(pm.email) IN lower(NEW.body))>0
 LOOP
  INSERT INTO public.board_notifications(recipient_email,project_id,requirement_id,kind,title,body,actor_email,source_id)
  VALUES(target.email,NEW.project_id,NEW.requirement_id,'mention','你在评论中被提及',coalesce(task_title,'')||'：'||left(NEW.body,180),NEW.author_email,NEW.id)
  ON CONFLICT DO NOTHING;
 END LOOP;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v5_comment_notify_trigger ON public.board_comments;
CREATE TRIGGER board_v5_comment_notify_trigger AFTER INSERT ON public.board_comments
 FOR EACH ROW EXECUTE FUNCTION public.board_v5_comment_notify();

-- Notify project members about task status changes recorded in board_activity.
CREATE OR REPLACE FUNCTION public.board_v5_activity_notify()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE target record; task_title text; recipient text;
BEGIN
 SELECT title,assignee_email INTO task_title,recipient FROM public.requirements WHERE id=NEW.requirement_id AND project_id=NEW.project_id;
 FOR target IN SELECT lower(pm.email) AS email FROM public.board_project_members pm
  WHERE pm.project_id=NEW.project_id AND pm.email<>coalesce(NEW.actor_email,'')
  AND (pm.role='operator' OR pm.email=recipient OR NEW.kind IN ('status','requirement'))
 LOOP
  INSERT INTO public.board_notifications(recipient_email,project_id,requirement_id,kind,title,body,actor_email,source_id)
  VALUES(target.email,NEW.project_id,NEW.requirement_id,
   CASE WHEN NEW.kind='status' AND coalesce(NEW.metadata->>'after','')='review' THEN 'review'
        WHEN NEW.kind='status' AND coalesce(NEW.metadata->>'after','')='doing' THEN 'returned' ELSE 'status' END,
   '需求进度有更新',coalesce(task_title,'')||'：'||left(coalesce(NEW.body,'进度已更新'),180),NEW.actor_email,NEW.id)
  ON CONFLICT DO NOTHING;
 END LOOP;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS board_v5_activity_notify_trigger ON public.board_activity;
CREATE TRIGGER board_v5_activity_notify_trigger AFTER INSERT ON public.board_activity
 FOR EACH ROW EXECUTE FUNCTION public.board_v5_activity_notify();

REVOKE ALL ON FUNCTION public.board_v5_task_version(),public.board_v5_comment_notify(),public.board_v5_activity_notify(),public.board_v5_comment_guard() FROM PUBLIC,anon,authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
