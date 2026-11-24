-- V5.1 verification: expected tables, columns, functions and policies.
SELECT name, to_regclass('public.'||name) AS table_name
FROM (VALUES ('board_task_templates'),('board_project_documents'),('board_time_entries'),('board_task_dependencies'),('board_share_links')) AS t(name);
SELECT column_name,data_type FROM information_schema.columns
WHERE table_schema='public' AND table_name='requirements' AND column_name IN ('start_date','estimated_minutes') ORDER BY column_name;
SELECT p.proname,pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN ('board_clone_project','board_create_share_link','board_public_share');
SELECT schemaname,tablename,policyname,cmd
FROM pg_policies WHERE schemaname='public' AND tablename IN ('board_task_templates','board_project_documents','board_time_entries','board_task_dependencies','board_share_links')
ORDER BY tablename,policyname;
