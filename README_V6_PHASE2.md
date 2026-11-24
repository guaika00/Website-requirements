# Project Tracker V6 · Phase 2 enhancements

This update builds on the V5.1 source already used by the live project. It improves three practical areas:

1. **Gantt schedule editing**: start/end dates can be edited directly inside the Gantt view. Saving writes to `requirements.start_date` and `requirements.due_date`, so the existing requirement-version trigger can retain the change history. End dates earlier than start dates are rejected in the UI.
2. **Real time tracking**: developers and project managers can start and stop a timer against a project or requirement. The database allows only one active timer per user. Stopping a timer creates a completed `board_time_entries` row with rounded-up minutes. Manual time entry remains available.
3. **Private project files**: project documents can be external links or uploaded files. Uploaded files go to the existing private `requirements-private` bucket under `projects/<project_uuid>/uploads/`; signed URLs are generated for display. The document metadata stores `storage_path`, not a public URL.

Existing V5.1 features retained: templates, project copy, dependency validation, weekly Markdown report, batch comparison, and expiring/revocable read-only share links.

## Upgrade requirements
- V5.1 migration has been successfully installed.
- Existing `requirements`, `board_time_entries`, `board_project_documents`, and helper functions `board_can_view`, `board_can_edit`, `board_can_progress`, `board_storage_can_upload` exist.
- The Storage bucket `requirements-private` exists and is private.

## Safe deployment
1. Back up the shared Supabase project. This database is also used by Travel app.
2. Run `supabase/upgrade_v6_phase2.sql` as one complete query.
3. Run `supabase/verify_v6_phase2.sql` and confirm `board_time_sessions`, `storage_path`, both timer RPCs, and RLS are present.
4. Only after SQL succeeds, deploy the `public/` directory and `vercel.json` from this patch to GitHub `main`.
5. Test with a developer account: start a timer, switch projects, stop the timer, and confirm one time-entry row is created. Attempting to start a second timer while one is active must return a clear error.
6. Test project file upload as an operator, open the signed file, then delete it. Test that a user from another project cannot read the file.

## Important boundaries
- No Travel app business tables, Auth users, XICHA registration hooks, or global role definitions are modified.
- Timer RPCs only allow a user to stop their own timer. The unique partial index enforces one active timer per account.
- Uploaded files are private and use existing project Storage policies. Public share links do not expose these private file paths.
- SQL has not been run against the user's live Supabase instance. Verify before deploying frontend files.
