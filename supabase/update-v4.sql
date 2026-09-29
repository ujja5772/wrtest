-- =====================================================================
-- 오늘의 영어 쓰기 v4 업데이트 (update-v3.sql 다음에 실행, 여러 번 실행해도 안전)
-- 교사 화면: 모든 학급의 AI 키를 한곳에서 관리, 관리자 의견함에 학교 이름 표시
-- =====================================================================

create or replace function teacher_keys_overview(p_code text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'class_code', c.class_code, 'grade', c.grade, 'class_no', c.class_no,
            'keys', (select coalesce(jsonb_agg(left(k, 6) || '…' || right(k, 4) order by i), '[]'::jsonb)
                     from unnest(c.ai_keys) with ordinality as a(k, i)))
          order by c.school, c.grade, c.class_no), '[]'::jsonb)
          from class_settings c where c.teacher_id = t);
end $$;

create or replace function teacher_add_key_many(p_code text, p_pw text, p_targets text[], p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); k text := trim(coalesce(p_key, '')); x text; n_added int := 0; n_full int := 0; n_dup int := 0; c class_settings;
begin
  if length(k) < 20 then raise exception '키가 너무 짧아요. 복사한 키 전체를 붙여 넣어 주세요.'; end if;
  foreach x in array coalesce(p_targets, '{}'::text[]) loop
    perform _own(t, x);
    select * into c from class_settings where class_code = x;
    if k = any(c.ai_keys) then n_dup := n_dup + 1;
    elsif coalesce(array_length(c.ai_keys, 1), 0) >= 4 then n_full := n_full + 1;
    else update class_settings set ai_keys = ai_keys || k where class_code = x; n_added := n_added + 1;
    end if;
  end loop;
  return jsonb_build_object('added', n_added, 'full', n_full, 'dup', n_dup);
end $$;

create or replace function admin_feedback(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_pin);
  return (select coalesce(jsonb_agg(to_jsonb(f) || jsonb_build_object(
            'schools', (select coalesce(jsonb_agg(distinct c.school), '[]'::jsonb) from class_settings c where c.teacher_id = f.teacher_id),
            'teacher_classes', (select coalesce(jsonb_agg(c.class_code order by c.class_code), '[]'::jsonb) from class_settings c where c.teacher_id = f.teacher_id))
          order by f.created_at desc), '[]'::jsonb) from teacher_feedback f);
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
