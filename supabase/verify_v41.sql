-- READ-ONLY verification; run after upgrade_v41.sql and before uploading frontend.
SELECT
 to_regclass('public.board_projects') AS projects,
 to_regclass('public.board_iterations') AS iterations,
 to_regclass('public.requirements') AS requirements,
 to_regclass('public.board_activity') AS activity;

-- Should show 0 in both columns.
SELECT
 (SELECT count(*) FROM public.requirements r WHERE r.iteration_id IS NULL) AS missing_iteration,
 (SELECT count(*) FROM public.requirements r WHERE NOT EXISTS(
   SELECT 1 FROM public.board_iterations b
   WHERE b.id=r.iteration_id AND b.project_id=r.project_id)) AS mismatched_project;

-- How many batches/tasks each project has. Do not use a hard-coded project ID.
SELECT p.name AS project_name,b.name AS iteration_name,b.is_closed,
 count(r.id) AS requirement_count
FROM public.board_iterations b JOIN public.board_projects p ON p.id=b.project_id
LEFT JOIN public.requirements r ON r.iteration_id=b.id AND r.project_id=b.project_id
GROUP BY p.id,p.name,b.id,b.name,b.is_closed,b.created_at
ORDER BY p.name,b.created_at DESC;

-- Confirm per-project read/write policies exist (DB authorization, not UI hiding).
SELECT policyname,cmd,roles,qual,with_check
FROM pg_policies WHERE schemaname='public' AND tablename='board_iterations'
ORDER BY policyname;
