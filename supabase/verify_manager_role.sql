-- Verify that the requested manager account and global manager helper exist.
SELECT email, role, display_name
FROM public.team_members
WHERE lower(email)='yukilulumark@gmail.com';

SELECT
  to_regprocedure('public.board_global_manager()') AS manager_helper,
  to_regprocedure('public.board_project_role(uuid)') AS project_role_helper,
  to_regprocedure('public.board_can_manage_members(uuid)') AS member_permission_helper;

-- Expected: yukilulumark@gmail.com / manager, and all three function signatures non-NULL.
