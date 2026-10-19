-- Owner-approved current admissions: Varg 1 Full through 31 Dec 2026 (IST).
-- Retain later or unlimited expiry already granted to existing students.
DO $guard$
DECLARE affected integer;
BEGIN
  PERFORM 1 FROM public.config_plans WHERE plan_id IN ('varg1_biology_full','varg1_chemistry_full','varg1_commerce_full','varg1_english_full','varg1_hindi_full','varg1_mathematics_full','varg1_physics_full') FOR UPDATE;
  SELECT count(*) INTO affected FROM public.config_plans
    WHERE plan_id IN ('varg1_biology_full','varg1_chemistry_full','varg1_commerce_full','varg1_english_full','varg1_hindi_full','varg1_mathematics_full','varg1_physics_full') AND post_id='varg1' AND status='active'
      AND duration_days=105 AND valid_until IS NULL AND amount=999
      AND plan_name='Full Course - 3.5 Months';
  IF affected <> 7 THEN RAISE EXCEPTION 'Varg 1 config changed; expected exactly seven approved rows'; END IF;
END $guard$;

CREATE OR REPLACE FUNCTION public.sync_verified_admission_to_student_access(p_admission_id text, p_session_token_hash text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admission public.admissions%rowtype;
  v_mobile10 text;
  v_student_id text;
  v_duration_days integer;
  v_access_course_id text;
  v_fixed_valid_until timestamptz;
  v_starts_at timestamptz;
  v_expires_at timestamptz;
  v_account_expires_at timestamptz;
begin
  select * into v_admission
  from public.admissions
  where admission_id = p_admission_id
  for update;

  if not found then
    raise exception 'Admission not found: %', p_admission_id;
  end if;
  if upper(coalesce(v_admission.status, '')) not in ('VERIFIED', 'GROUP_LINK_SENT') then
    raise exception 'Admission is not verified: %', p_admission_id;
  end if;

  v_mobile10 := right(regexp_replace(coalesce(v_admission.mobile, ''), '[^0-9]', '', 'g'), 10);
  if v_mobile10 !~ '^[6-9][0-9]{9}$' then
    raise exception 'Admission has invalid Indian mobile: %', p_admission_id;
  end if;

  select
    greatest(coalesce(duration_days, 0), 0),
    nullif(trim(coalesce(access_course_id, '')), ''),
    valid_until
  into v_duration_days, v_access_course_id, v_fixed_valid_until
  from public.config_plans
  where plan_id = v_admission.plan_id
  limit 1;

  v_starts_at := coalesce(v_admission.razorpay_verified_at, now());
  v_expires_at := case
    when v_fixed_valid_until is not null then v_fixed_valid_until
    when coalesce(v_duration_days, 0) > 0 then v_starts_at + make_interval(days => v_duration_days)
    else null
  end;

  if v_fixed_valid_until is not null and v_fixed_valid_until <= v_starts_at then
    raise exception 'Plan validity has ended: %', v_admission.plan_id;
  end if;

  v_student_id := 'STU_' || v_mobile10;

  insert into public.students (
    student_id, mobile10, mobile, mobile_e164, name, email, status, created_at, updated_at
  )
  values (
    v_student_id, v_mobile10, v_mobile10, '+91' || v_mobile10, coalesce(v_admission.name, ''),
    coalesce(v_admission.email, ''), 'active', now(), now()
  )
  on conflict (mobile10) where mobile10 is not null and mobile10 <> ''
  do update set
    mobile = excluded.mobile,
    mobile_e164 = excluded.mobile_e164,
    name = excluded.name,
    email = excluded.email,
    status = 'active',
    updated_at = now();

  select student_id into v_student_id
  from public.students
  where mobile10 = v_mobile10
  limit 1;

  insert into public.entitlements (
    entitlement_id, idempotency_key, student_id, mobile10, mobile, mobile_e164,
    admission_id, post, course, course_id, plan_code, plan_id, plan_name, subject,
    payment_id, source,
    status, starts_at, start_at, expires_at, created_at, updated_at
  )
  values (
    'ENT_' || replace(md5(v_admission.admission_id), '-', ''),
    'ADMISSION:' || v_admission.admission_id,
    v_student_id, v_mobile10, v_mobile10, '+91' || v_mobile10, v_admission.admission_id,
    coalesce(v_admission.post_name, ''), '', v_access_course_id, '', coalesce(v_admission.plan_id, ''),
    coalesce(v_admission.plan_name, ''), coalesce(v_admission.subject_name, ''),
    coalesce(v_admission.razorpay_payment_id, ''), 'ADMISSION_API',
    'active', v_starts_at, v_starts_at, v_expires_at, now(), now()
  )
  on conflict (admission_id) where admission_id is not null and admission_id <> ''
  do update set
    mobile10 = excluded.mobile10,
    mobile = excluded.mobile,
    mobile_e164 = excluded.mobile_e164,
    student_id = excluded.student_id,
    post = excluded.post,
    course = excluded.course,
    course_id = excluded.course_id,
    plan_code = excluded.plan_code,
    plan_id = excluded.plan_id,
    plan_name = excluded.plan_name,
    subject = excluded.subject,
    payment_id = excluded.payment_id,
    source = excluded.source,
    status = 'active',
    starts_at = excluded.starts_at,
    start_at = excluded.start_at,
    expires_at = case
      when excluded.plan_id in (select plan_id from public.config_plans where post_id in ('varg2','varg3') or plan_id in ('varg1_biology_full','varg1_chemistry_full','varg1_commerce_full','varg1_english_full','varg1_hindi_full','varg1_mathematics_full','varg1_physics_full'))
        and (entitlements.expires_at is null or entitlements.expires_at > excluded.expires_at)
      then entitlements.expires_at else excluded.expires_at end,
    updated_at = now();

  select expires_at into v_expires_at
  from public.entitlements where admission_id = p_admission_id;

  select case
      when bool_or(expires_at is null) then null
      else max(expires_at)
    end
    into v_account_expires_at
  from public.entitlements
  where mobile10 = v_mobile10
    and lower(coalesce(status, 'active')) in ('active', 'paid', 'approved', 'valid');

  if nullif(trim(coalesce(p_session_token_hash, '')), '') is not null then
    insert into public.student_sessions (
      session_id, student_id, mobile10, mobile, mobile_e164, token_hash, status,
      expires_at, created_at, last_used_at, source, source_admission_id, source_payment_id
    )
    values (
      'SES_' || left(p_session_token_hash, 32), v_student_id, v_mobile10, v_mobile10,
      '+91' || v_mobile10, p_session_token_hash, 'active', v_account_expires_at, now(), now(),
      'ADMISSION_API', v_admission.admission_id, coalesce(v_admission.razorpay_payment_id, '')
    )
    on conflict (token_hash) where token_hash is not null and token_hash <> ''
    do update set
      mobile10 = excluded.mobile10,
      mobile = excluded.mobile,
      mobile_e164 = excluded.mobile_e164,
      student_id = excluded.student_id,
      status = 'active',
      expires_at = excluded.expires_at,
      last_used_at = now(),
      source = excluded.source,
      source_admission_id = excluded.source_admission_id,
      source_payment_id = excluded.source_payment_id;
  end if;

  update public.student_sessions
  set expires_at = v_account_expires_at
  where mobile10 = v_mobile10
    and lower(coalesce(status, 'active')) = 'active';

  update public.admissions
  set central_registry_sync_status = 'PASS',
      central_registry_sync_at = now(),
      central_registry_sync_error = ''
  where admission_id = p_admission_id;

  return jsonb_build_object(
    'ok', true,
    'mobile10', v_mobile10,
    'course_id', v_access_course_id,
    'expires_at', v_expires_at,
    'account_expires_at', v_account_expires_at,
    'session_created', nullif(trim(coalesce(p_session_token_hash, '')), '') is not null
  );
exception when others then
  update public.admissions
  set central_registry_sync_status = 'FAILED',
      central_registry_sync_at = now(),
      central_registry_sync_error = left(sqlerrm, 500)
  where admission_id = p_admission_id;
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$function$;


UPDATE public.config_plans
SET duration_days=0, valid_until='2026-12-31T18:29:59.999+00:00',
    plan_name='Full Course - Valid Till 31 December 2026'
WHERE plan_id IN ('varg1_biology_full','varg1_chemistry_full','varg1_commerce_full','varg1_english_full','varg1_hindi_full','varg1_mathematics_full','varg1_physics_full');

