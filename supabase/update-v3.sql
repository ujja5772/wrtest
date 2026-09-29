-- =====================================================================
-- 오늘의 영어 쓰기 v3 업데이트 (update-v2.sql 다음에 실행, 여러 번 실행해도 안전)
-- '천천히 쓰기'와 '바로 쓰기'를 완전히 따로: 첨삭·완성 글·게시가 방법별로 따로 저장됨
-- =====================================================================

update submissions set write_mode = 'self' where write_mode not in ('self', 'slow');
alter table submissions drop constraint if exists submissions_class_code_student_no_unit_name_key;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'submissions_mode_unique') then
    alter table submissions add constraint submissions_mode_unique unique (class_code, student_no, unit_name, write_mode);
  end if;
end $$;

create or replace function svc_save_feedback(p_code text, p_no int, p_pin text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c class_settings; nm text; r submissions; m text := case when d->>'mode' = 'slow' then 'slow' else 'self' end;
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  select * into c from class_settings where class_code = p_code;
  select student_name into nm from student_pins where class_code = p_code and student_no = p_no;
  insert into submissions (class_code, student_no, student_name, unit_name, topic, write_mode,
                           original_text, draft_text, final_text, feedback, grade, report)
  values (p_code, p_no, nm, c.unit_name, c.topic, m, d->>'text', d->>'text', '', d->'feedback', d->>'grade', d->>'report')
  on conflict (class_code, student_no, unit_name, write_mode) do update set
    student_name = excluded.student_name, topic = excluded.topic,
    draft_text = excluded.draft_text, feedback = excluded.feedback, grade = excluded.grade, report = excluded.report,
    submit_count = submissions.submit_count + 1, updated_at = now()
  returning * into r;
  insert into activity_log (class_code, kind) values (p_code, 'feedback');
  return jsonb_build_object('id', r.id);
end $$;

drop function if exists student_post(text, int, text, text, jsonb);
create or replace function student_post(p_code text, p_no int, p_pin text, p_text text, p_photo jsonb, p_mode text) returns void
language plpgsql security definer set search_path = public as $$
declare c class_settings; m text := case when p_mode = 'slow' then 'slow' else 'self' end;
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  if coalesce(trim(p_text), '') = '' then raise exception '완성한 글이 비어 있어요.'; end if;
  select * into c from class_settings where class_code = p_code;
  update submissions set final_text = trim(p_text), posted = true, posted_at = now(), updated_at = now(),
    photo_path = p_photo->>'path', photo_url = p_photo->>'url',
    photo_credit = p_photo->>'credit', photo_credit_link = p_photo->>'credit_link'
  where class_code = p_code and student_no = p_no and unit_name = c.unit_name and write_mode = m;
  if not found then raise exception '먼저 첨삭을 받아 주세요.'; end if;
  insert into activity_log (class_code, kind) values (p_code, 'submit');
end $$;

create or replace function student_gallery(p_code text, p_no int, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  return (select coalesce(jsonb_agg(x order by x->>'posted_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', s.id, 'student_no', s.student_no, 'student_name', s.student_name, 'unit_name', s.unit_name,
      'final_text', s.final_text, 'write_mode', s.write_mode, 'photo_path', s.photo_path, 'photo_url', s.photo_url,
      'photo_credit', s.photo_credit, 'photo_credit_link', s.photo_credit_link, 'posted_at', s.posted_at,
      'hearts', (select count(*) from hearts h where h.submission_id = s.id),
      'liked', exists (select 1 from hearts h where h.submission_id = s.id and h.student_no = p_no),
      'mine', s.student_no = p_no,
      'teacher_comment', case when s.student_no = p_no then s.teacher_comment else '' end) as x
    from submissions s where s.class_code = p_code and s.posted) q);
end $$;

create or replace function teacher_save_unit(p_code text, p_pw text, p_id uuid, u jsonb, p_classes text[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); uid uuid := p_id; nm text := trim(coalesce(u->>'name', '')); old_name text; x text;
begin
  if nm = '' then raise exception '단원 이름을 적어 주세요.'; end if;
  if exists (select 1 from teacher_units where teacher_id = t and name = nm and id is distinct from p_id) then
    raise exception '같은 이름의 단원이 이미 있어요: %', nm;
  end if;
  if uid is null then
    insert into teacher_units (teacher_id, name, topic, guide, words, key_expressions, criteria)
    values (t, nm, coalesce(u->>'topic', ''), coalesce(u->>'guide', ''), coalesce(u->>'words', ''),
            coalesce(u->>'key_expressions', ''), coalesce(u->>'criteria', ''))
    returning id into uid;
  else
    select name into old_name from teacher_units where id = uid and teacher_id = t;
    if not found then raise exception '단원을 찾을 수 없어요.'; end if;
    update teacher_units set name = nm, topic = coalesce(u->>'topic', ''), guide = coalesce(u->>'guide', ''),
      words = coalesce(u->>'words', ''), key_expressions = coalesce(u->>'key_expressions', ''),
      criteria = coalesce(u->>'criteria', ''), updated_at = now()
    where id = uid;
    if old_name <> nm then -- 이름이 바뀌면 이미 쓴 글도 새 이름으로 따라가게
      update submissions s set unit_name = nm
      where s.unit_name = old_name
        and s.class_code in (select class_code from class_settings where teacher_id = t)
        and not exists (select 1 from submissions s2 where s2.class_code = s.class_code and s2.student_no = s.student_no and s2.unit_name = nm and s2.write_mode = s.write_mode);
    end if;
  end if;
  for x in select class_code from class_settings where current_unit_id = uid loop
    perform _copy_unit(uid, x);
  end loop;
  foreach x in array coalesce(p_classes, '{}'::text[]) loop
    perform _own(t, x);
    perform _copy_unit(uid, x);
  end loop;
  return uid;
end $$;

-- =====================================================================
-- 실행 권한 정리
-- =====================================================================
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
