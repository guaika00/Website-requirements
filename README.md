# V4.1 Manager role patch

1. Back up your shared Supabase project.
2. Run `supabase/upgrade_manager_role.sql` in the V4.1 Supabase project. It grants `yukilulumark@gmail.com` the global `manager` role.
3. Run `supabase/verify_manager_role.sql` to confirm the role and helper functions.
4. If this email has not registered and the XICHA registration-code hook still rejects team emails, run `supabase/allow_manager_team_signup.sql` as a separate optional patch.
5. Replace `public/app.js` in GitHub with this file and commit to `main`; Vercel redeploys automatically.

`admin` remains the top-level administrator. `manager` can manage all projects and project members, but cannot manage global admin/manager accounts.
