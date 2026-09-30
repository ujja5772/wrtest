-- =====================================================================
-- 오늘의 영어 쓰기 v5 업데이트 (update-v4.sql 다음에 실행, 여러 번 실행해도 안전)
-- 유료 예비 키: 무료 키를 먼저 쓰고, 무료 키가 막힐 때만 유료 키를 씀
-- =====================================================================
alter table class_settings add column if not exists ai_paid_keys text[] not null default '{}';

create or replace function student_enter(p_code text, p_no int, p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c class_settings; s student_pins; is_first boolean := false;
begin
  select * into c from class_settings where class_code = trim(p_code);
  if not found then raise exception '학급 코드를 찾을 수 없어요. 선생님께 학급 코드를 다시 확인해 주세요.'; end if;
  if coalesce(array_length(c.ai_keys, 1), 0) + coalesce(array_length(c.ai_paid_keys, 1), 0) = 0 then raise exception 'NO_KEYS'; end if;
  if p_no is null or p_no < 1 or p_no > 60 then raise exception '번호를 확인해 주세요.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception '이름을 적어 주세요.'; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then raise exception 'PIN은 숫자 4자리예요.'; end if;

  select * into s from student_pins where class_code = c.class_code and student_no = p_no;
  if not found then
    insert into student_pins (class_code, student_no, student_name, pin_hash, last_seen)
    values (c.class_code, p_no, trim(p_name), crypt(p_pin, gen_salt('bf')), now());
    is_first := true;
  elsif s.pin_hash is null then
    update student_pins set pin_hash = crypt(p_pin, gen_salt('bf')), student_name = trim(p_name), last_seen = now()
     where class_code = c.class_code and student_no = p_no;
    is_first := true;
  elsif s.pin_hash <> crypt(p_pin, s.pin_hash) then
    raise exception 'PIN이 맞지 않아요. 처음 입장할 때 입력한 숫자 4자리를 넣어 주세요. 기억나지 않으면 선생님께 초기화를 부탁해요.';
  else
    update student_pins set student_name = trim(p_name), last_seen = now()
     where class_code = c.class_code and student_no = p_no;
  end if;

  insert into activity_log (class_code, kind) values (c.class_code, 'enter');
  return jsonb_build_object(
    'first', is_first, 'class_code', c.class_code, 'unit_name', c.unit_name, 'topic', c.topic,
    'words', c.words, 'key_expressions', c.key_expressions,
    'messages', (select coalesce(jsonb_agg(jsonb_build_object('message', message, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
                 from teacher_messages where class_code = c.class_code));
end $$;

create or replace function svc_ai_context(p_code text, p_no int, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c class_settings;
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  select * into c from class_settings where class_code = p_code;
  return jsonb_build_object('keys', c.ai_keys, 'paid_keys', c.ai_paid_keys, 'unit_name', c.unit_name, 'topic', c.topic, 'guide', c.guide,
    'words', c.words, 'key_expressions', c.key_expressions, 'criteria', c.criteria, 'grade', c.grade,
    'photo_search_enabled', (select photo_search_enabled from admin_config where id = 1));
end $$;

create or replace function teacher_overview(p_code text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  return jsonb_build_object(
    'name', (select name from teachers where id = t),
    'classes', (select coalesce(jsonb_agg(jsonb_build_object(
        'class_code', c.class_code, 'grade', c.grade, 'class_no', c.class_no, 'school', c.school,
        'unit_name', c.unit_name, 'current_unit_id', c.current_unit_id, 'topic', c.topic,
        'key_count', coalesce(array_length(c.ai_keys, 1), 0) + coalesce(array_length(c.ai_paid_keys, 1), 0), 'expected_students', c.expected_students,
        'students', (select count(*) from student_pins p where p.class_code = c.class_code),
        'submissions', (select count(*) from submissions s where s.class_code = c.class_code),
        'posted', (select count(*) from submissions s where s.class_code = c.class_code and s.posted))
        order by c.school, c.grade, c.class_no), '[]'::jsonb)
      from class_settings c where c.teacher_id = t),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) order by r.requested_at desc), '[]'::jsonb)
      from class_deletion_requests r where r.teacher_id = t and r.status = 'pending'),
    'new_replies', (select count(*) from teacher_feedback f where f.teacher_id = t and f.replied_at > now() - interval '7 days'));
end $$;

create or replace function teacher_keys_overview(p_code text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'class_code', c.class_code, 'grade', c.grade, 'class_no', c.class_no,
            'keys', (select coalesce(jsonb_agg(left(k, 6) || '…' || right(k, 4) order by i), '[]'::jsonb)
                     from unnest(c.ai_keys) with ordinality as a(k, i)),
            'paid', (select coalesce(jsonb_agg(left(k, 6) || '…' || right(k, 4) order by i), '[]'::jsonb)
                     from unnest(c.ai_paid_keys) with ordinality as a(k, i)))
          order by c.school, c.grade, c.class_no), '[]'::jsonb)
          from class_settings c where c.teacher_id = t);
end $$;

drop function if exists teacher_add_key_many(text, text, text[], text);
create or replace function teacher_add_key_many(p_code text, p_pw text, p_targets text[], p_key text, p_paid boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); k text := trim(coalesce(p_key, '')); x text;
        n_added int := 0; n_full int := 0; n_dup int := 0; c class_settings;
begin
  if length(k) < 20 then raise exception '키가 너무 짧아요. 복사한 키 전체를 붙여 넣어 주세요.'; end if;
  foreach x in array coalesce(p_targets, '{}'::text[]) loop
    perform _own(t, x);
    select * into c from class_settings where class_code = x;
    if k = any(c.ai_keys) or k = any(c.ai_paid_keys) then n_dup := n_dup + 1;
    elsif p_paid and coalesce(array_length(c.ai_paid_keys, 1), 0) >= 2 then n_full := n_full + 1;
    elsif not p_paid and coalesce(array_length(c.ai_keys, 1), 0) >= 4 then n_full := n_full + 1;
    elsif p_paid then update class_settings set ai_paid_keys = ai_paid_keys || k where class_code = x; n_added := n_added + 1;
    else update class_settings set ai_keys = ai_keys || k where class_code = x; n_added := n_added + 1;
    end if;
  end loop;
  return jsonb_build_object('added', n_added, 'full', n_full, 'dup', n_dup);
end $$;

create or replace function teacher_remove_paid_key(p_code text, p_pw text, p_target text, p_index int) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  perform _own(t, p_target);
  update class_settings
     set ai_paid_keys = coalesce((select array_agg(k order by i) from unnest(ai_paid_keys) with ordinality as a(k, i) where i <> p_index + 1), '{}')
   where class_code = p_target;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like '\_%' or p.proname like 'svc\_%'
             or p.proname = 'get_public_config' or p.proname like 'student\_%' or p.proname like 'teacher\_%' or p.proname like 'admin\_%') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'svc\_%' then
      execute format('grant execute on function %s to service_role', f.sig);
    elsif f.proname not like '\_%' then
      execute format('grant execute on function %s to anon, authenticated, service_role', f.sig);
    end if;
  end loop;
end $$;
