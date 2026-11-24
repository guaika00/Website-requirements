-- Run after upgrade_v5_collaboration.sql.
SELECT
 to_regclass('public.board_comments') AS board_comments,
 to_regclass('public.board_notifications') AS board_notifications,
 to_regclass('public.board_requirement_versions') AS board_requirement_versions;
SELECT event_object_table, trigger_name
FROM information_schema.triggers
WHERE trigger_schema='public'
 AND trigger_name IN ('board_v5_task_version_trigger','board_v5_comment_notify_trigger','board_v5_activity_notify_trigger','board_v5_comment_guard_trigger')
ORDER BY event_object_table,trigger_name;
SELECT schemaname,tablename,policyname,cmd
FROM pg_policies
WHERE schemaname='public'
 AND tablename IN ('board_comments','board_notifications','board_requirement_versions')
ORDER BY tablename,policyname;
