-- Optional: allow pre-authorized board team emails (including manager) to sign up
-- without a travel registration code. Non-team emails MUST still use a valid XICHA code.
-- Run only after upgrade_manager_role.sql. This updates only the two XICHA auth functions.
BEGIN;
DO $precheck$
BEGIN
 IF to_regclass('public.team_members') IS NULL OR to_regclass('xicha_private.registration_codes') IS NULL THEN
  RAISE EXCEPTION 'Expected team_members or XICHA registration_codes table is missing';
 END IF;
END;
$precheck$;

CREATE OR REPLACE FUNCTION public.xicha_before_user_created(event jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
 registration_code text := lower(btrim(event #>> '{user,user_metadata,registration_code}'));
 email_address text := lower(btrim(event #>> '{user,email}'));
 denied jsonb := jsonb_build_object('error',jsonb_build_object('http_code',403,'message','XICHA_REGISTRATION_CODE_REJECTED'));
BEGIN
 IF email_address IS NULL OR length(email_address)>254
    OR email_address !~ '^[^[:space:]<>@]+@[^[:space:]<>@]+\.[^[:space:]<>@]+$'
    OR event #>> '{user,app_metadata,provider}' IS DISTINCT FROM 'email'
    OR coalesce(event #>> '{user,phone}','')<>''
    OR event #> '{user,is_anonymous}' IS DISTINCT FROM 'false'::jsonb THEN
   RETURN denied;
 END IF;
 IF EXISTS(SELECT 1 FROM public.team_members m WHERE m.email=email_address
   AND m.role IN ('admin','manager','operator','developer','viewer')) THEN
   RETURN '{}'::jsonb;
 END IF;
 IF jsonb_typeof(event #> '{user,user_metadata,registration_code}') IS DISTINCT FROM 'string'
    OR registration_code IS NULL OR registration_code !~ '^[a-f0-9]{64}$' THEN
   RETURN denied;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM xicha_private.registration_codes c
   WHERE c.code_hash=sha256(convert_to(registration_code,'UTF8'))
     AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()
     AND c.used_count<c.max_uses AND (c.allowed_email IS NULL OR c.allowed_email=email_address)) THEN
   RETURN denied;
 END IF;
 RETURN '{}'::jsonb;
END;
$$;

CREATE OR REPLACE FUNCTION xicha_private.enforce_registration_code()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE registration_code text:=lower(btrim(new.raw_user_meta_data->>'registration_code'));
        email_address text:=lower(btrim(new.email)); consumed_id uuid;
BEGIN
 IF TG_OP='UPDATE' THEN
   new.raw_user_meta_data:=coalesce(new.raw_user_meta_data,'{}'::jsonb)-'registration_code';
   RETURN new;
 END IF;
 IF email_address IS NULL OR length(email_address)>254
    OR email_address !~ '^[^[:space:]<>@]+@[^[:space:]<>@]+\.[^[:space:]<>@]+$'
    OR new.raw_app_meta_data->>'provider' IS DISTINCT FROM 'email'
    OR coalesce(new.phone,'')<>'' OR new.is_anonymous IS DISTINCT FROM false THEN
   RAISE EXCEPTION 'XICHA_REGISTRATION_CODE_REJECTED';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.team_members m WHERE m.email=email_address
   AND m.role IN ('admin','manager','operator','developer','viewer')) THEN
   IF jsonb_typeof(new.raw_user_meta_data->'registration_code') IS DISTINCT FROM 'string'
      OR registration_code IS NULL OR registration_code !~ '^[a-f0-9]{64}$' THEN
     RAISE EXCEPTION 'XICHA_REGISTRATION_CODE_REJECTED';
   END IF;
   UPDATE xicha_private.registration_codes c SET used_count=c.used_count+1
   WHERE c.code_hash=sha256(convert_to(registration_code,'UTF8'))
     AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()
     AND c.used_count<c.max_uses AND (c.allowed_email IS NULL OR c.allowed_email=email_address)
   RETURNING c.id INTO consumed_id;
   IF consumed_id IS NULL THEN RAISE EXCEPTION 'XICHA_REGISTRATION_CODE_REJECTED'; END IF;
 END IF;
 new.raw_user_meta_data:=coalesce(new.raw_user_meta_data,'{}'::jsonb)-'registration_code';
 RETURN new;
END;
$$;
NOTIFY pgrst,'reload schema';
COMMIT;
