-- Optional companion for V4: only add the viewer role to the EXISTING
-- requirement-board whitelist in the two existing XICHA registration checks.
-- Run AFTER V4 schema upgrade, only if the earlier registration-compatibility
-- patch was installed. Does not disable travel registration-code checks.
BEGIN;
DO $patch$
DECLARE r record; source_sql text; needle text := 'm.role in (''admin'',''operator'',''developer'')';
        replacement text := 'm.role in (''admin'',''operator'',''developer'',''viewer'')';
        found_count integer := 0;
BEGIN
 IF to_regclass('public.team_members') IS NULL THEN RAISE EXCEPTION 'Team board is not installed'; END IF;
 FOR r IN
   SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE (n.nspname='public' AND p.proname='xicha_before_user_created'
           AND pg_get_function_identity_arguments(p.oid)='event jsonb')
      OR (n.nspname='xicha_private' AND p.proname='enforce_registration_code'
           AND pg_get_function_identity_arguments(p.oid)='')
 LOOP
   found_count := found_count + 1;
   source_sql := pg_get_functiondef(r.oid);
   IF position(needle IN source_sql) > 0 THEN
     source_sql := replace(source_sql,needle,replacement);
     EXECUTE source_sql;
   ELSIF position(replacement IN source_sql) > 0 THEN
     -- This function was already updated for viewer; leave it unchanged.
     NULL;
   ELSE
     RAISE EXCEPTION 'XICHA function % does not contain the expected team-only whitelist. Stop rather than altering unknown registration code.', r.oid::regprocedure;
   END IF;
 END LOOP;
 IF found_count<>2 THEN
   RAISE EXCEPTION 'Expected two XICHA registration functions; found %. Existing code unchanged.',found_count;
 END IF;
END $patch$;
COMMIT;
