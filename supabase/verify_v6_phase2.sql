SELECT 'board_time_sessions' AS object_name, to_regclass('public.board_time_sessions') IS NOT NULL AS exists
UNION ALL
SELECT 'board_time_entries', to_regclass('public.board_time_entries') IS NOT NULL
UNION ALL
SELECT 'board_project_documents.storage_path', EXISTS (
 SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='board_project_documents' AND column_name='storage_path'
);

SELECT routine_name
FROM information_schema.routines
WHERE routine_schema='public'
  AND routine_name IN ('board_start_timer','board_stop_timer')
ORDER BY routine_name;

SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname='public' AND tablename='board_time_sessions';

SELECT policyname, cmd
FROM pg_policies
WHERE schemaname='public' AND tablename='board_time_sessions'
ORDER BY policyname;
