-- READ ONLY: run after the complete V4 migration to verify schema and policies.
SELECT to_regclass('public.board_projects') AS projects,
 to_regclass('public.board_project_members') AS project_members,
 to_regclass('public.board_categories') AS categories,
 to_regclass('public.requirements') AS requirements,
 to_regclass('public.board_activity') AS timeline;
SELECT (SELECT count(*) FROM public.board_projects) AS project_count,
 (SELECT count(*) FROM public.requirements) AS task_count,
 (SELECT count(*) FROM public.board_categories) AS category_count,
 (SELECT count(*) FROM public.board_project_members) AS assignment_count;
SELECT table_name,column_name,data_type
 FROM information_schema.columns
 WHERE table_schema='public' AND (
 (table_name='requirements' AND column_name IN ('project_id','assignee_email','due_date','is_withdrawn')) OR
 (table_name='requirement_progress' AND column_name IN ('project_id','status','is_blocked')))
 ORDER BY table_name,column_name;
SELECT tablename,policyname,cmd,roles,qual,with_check
 FROM pg_policies
 WHERE schemaname='public' AND tablename IN (
 'board_projects','board_project_members','board_categories','requirements','requirement_progress','board_activity','board_assets')
 ORDER BY tablename,policyname;
SELECT routine_name FROM information_schema.routines
 WHERE routine_schema='public' AND routine_name IN (
 'board_create_project','board_assign_member','board_remove_member','board_transition_task','board_add_comment','board_can_view')
 ORDER BY routine_name;
