-- =====================================================================
-- 영어 쓰기 교실 v2 업데이트 (schema.sql 다음에 실행, 여러 번 실행해도 안전)
-- 교사 단위 단원 관리, 여러 학년 학급 만들기, 첨삭→다듬기→게시 흐름,
-- 게시글 수정·삭제, 교사→관리자 의견함
-- =====================================================================

alter table teachers add column if not exists name text not null default '';
alter table submissions add column if not exists draft_text text not null default '';
alter table class_settings add column if not exists current_unit_id uuid;

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'submissions' and column_name = 'posted') then
    alter table submissions add column posted boolean not null default false;
    alter table submissions add column posted_at timestamptz;
    -- v1에서 제출한 글은 이미 갤러리에 보였으므로 게시된 것으로 옮김
    update submissions set posted = true, posted_at = updated_at, draft_text = original_text where final_text <> '';
  end if;
end $$;

create table if not exists teacher_units (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references teachers(id) on delete cascade,
  name text not null,
  topic text not null default '', guide text not null default '', words text not null default '',
  key_expressions text not null default '', criteria text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists teacher_feedback (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid references teachers(id) on delete cascade,
  sender_name text not null default '',
  message text not null,
  created_at timestamptz not null default now(),
  reply text not null default '',
  replied_at timestamptz
);

alter table teacher_units enable row level security;
alter table teacher_feedback enable row level security;
revoke all on table teacher_units from anon, authenticated;
revoke all on table teacher_feedback from anon, authenticated;

-- v1 단원·학습 설정을 교사 단원으로 옮기기
insert into teacher_units (teacher_id, name, topic, guide, words, key_expressions, criteria)
select distinct on (c.teacher_id, c.unit_name) c.teacher_id, c.unit_name, c.topic, c.guide, c.words, c.key_expressions, c.criteria
from class_settings c
where c.unit_name <> ''
  and not exists (select 1 from teacher_units t where t.teacher_id = c.teacher_id and t.name = c.unit_name)
order by c.teacher_id, c.unit_name, c.created_at;

insert into teacher_units (teacher_id, name, topic, guide, words, key_expressions, criteria, created_at)
select distinct on (c.teacher_id, u.name) c.teacher_id, u.name, u.topic, u.guide, u.words, u.key_expressions, u.criteria, u.created_at
from class_units u join class_settings c on c.class_code = u.class_code
where not exists (select 1 from teacher_units t where t.teacher_id = c.teacher_id and t.name = u.name)
order by c.teacher_id, u.name, u.created_at desc;

update class_settings c set current_unit_id = t.id
from teacher_units t
where c.current_unit_id is null and c.unit_name <> '' and t.teacher_id = c.teacher_id and t.name = c.unit_name;

-- =====================================================================
-- 학급 만들기 (여러 학년 한 번에)
-- =====================================================================
create or replace function _make_classes2(t uuid, p_school text, p_items jsonb) returns text[]
language plpgsql security definer set search_path = public as $$
declare it jsonb; g int; n int; code text; made text[] := '{}';
        s text := regexp_replace(trim(coalesce(p_school, '')), '\s+', '', 'g');
begin
  if s = '' or s like '%-%' or s not like '%학교' then
    raise exception '학교 이름은 "행복초등학교"처럼 전체 이름으로, 띄어쓰기와 - 없이 적어 주세요.';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception '반을 하나 이상 골라 주세요.'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception '한 번에 30개 반까지만 만들 수 있어요.'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    g := (it->>'grade')::int; n := (it->>'class_no')::int;
    if g is null or g < 1 or g > 6 then raise exception '학년은 1~6 사이예요.'; end if;
    if n is null or n < 1 or n > 30 then raise exception '반은 1~30 사이예요.'; end if;
    code := s || '-' || g || '-' || n;
    if exists (select 1 from class_settings where class_code = code) then
      raise exception '이미 있는 학급 코드예요: %', code;
    end if;
    insert into class_settings (class_code, teacher_id, school, grade, class_no) values (code, t, s, g, n);
    made := made || code;
  end loop;
  return made;
end $$;

create or replace function teacher_signup2(p_join text, p_pw text, p_name text, p_school text, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare t uuid;
begin
  if coalesce(p_join, '') <> (select teacher_join_code from admin_config where id = 1) then
    raise exception '교사 가입 코드가 맞지 않아요.';
  end if;
  if length(coalesce(p_pw, '')) < 4 then raise exception '교사 비밀번호는 4자 이상이에요.'; end if;
  insert into teachers (pw_hash, name) values (crypt(p_pw, gen_salt('bf')), trim(coalesce(p_name, ''))) returning id into t;
  return jsonb_build_object('codes', _make_classes2(t, p_school, p_items));
end $$;

create or replace function teacher_add_classes2(p_code text, p_pw text, p_school text, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  return jsonb_build_object('codes', _make_classes2(t, p_school, p_items));
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
        'key_count', coalesce(array_length(c.ai_keys, 1), 0), 'expected_students', c.expected_students,
        'students', (select count(*) from student_pins p where p.class_code = c.class_code),
        'submissions', (select count(*) from submissions s where s.class_code = c.class_code),
        'posted', (select count(*) from submissions s where s.class_code = c.class_code and s.posted))
        order by c.school, c.grade, c.class_no), '[]'::jsonb)
      from class_settings c where c.teacher_id = t),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) order by r.requested_at desc), '[]'::jsonb)
      from class_deletion_requests r where r.teacher_id = t and r.status = 'pending'),
    'new_replies', (select count(*) from teacher_feedback f where f.teacher_id = t and f.replied_at > now() - interval '7 days'));
end $$;

create or replace function teacher_set_name(p_code text, p_pw text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  update teachers set name = trim(coalesce(p_name, '')) where id = t;
end $$;

-- =====================================================================
-- 단원 (교사 단위) — 단원 내용 + 적용 학급을 한곳에서
-- =====================================================================
create or replace function _copy_unit(p_unit uuid, p_class text) returns void
language plpgsql security definer set search_path = public as $$
declare u teacher_units;
begin
  select * into u from teacher_units where id = p_unit;
  update class_settings set current_unit_id = u.id, unit_name = u.name, topic = u.topic, guide = u.guide,
    words = u.words, key_expressions = u.key_expressions, criteria = u.criteria
  where class_code = p_class;
end $$;

create or replace function teacher_units_list(p_code text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  return (select coalesce(jsonb_agg(to_jsonb(u) || jsonb_build_object('classes',
            (select coalesce(jsonb_agg(c.class_code order by c.grade, c.class_no), '[]'::jsonb)
             from class_settings c where c.current_unit_id = u.id))
          order by u.created_at desc), '[]'::jsonb)
          from teacher_units u where u.teacher_id = t);
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
        and not exists (select 1 from submissions s2 where s2.class_code = s.class_code and s2.student_no = s.student_no and s2.unit_name = nm);
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

create or replace function teacher_delete_unit2(p_code text, p_pw text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  if not exists (select 1 from teacher_units where id = p_id and teacher_id = t) then raise exception '단원을 찾을 수 없어요.'; end if;
  update class_settings set current_unit_id = null where current_unit_id = p_id;
  delete from teacher_units where id = p_id;
end $$;

-- =====================================================================
-- 첨삭 저장 (서버 함수 전용) · 게시 · 게시글 수정/삭제
-- =====================================================================
create or replace function svc_save_feedback(p_code text, p_no int, p_pin text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c class_settings; nm text; r submissions;
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  select * into c from class_settings where class_code = p_code;
  select student_name into nm from student_pins where class_code = p_code and student_no = p_no;
  insert into submissions (class_code, student_no, student_name, unit_name, topic, write_mode,
                           original_text, draft_text, final_text, feedback, grade, report)
  values (p_code, p_no, nm, c.unit_name, c.topic, coalesce(d->>'mode', ''),
          d->>'text', d->>'text', '', d->'feedback', d->>'grade', d->>'report')
  on conflict (class_code, student_no, unit_name) do update set
    student_name = excluded.student_name, topic = excluded.topic, write_mode = excluded.write_mode,
    draft_text = excluded.draft_text, feedback = excluded.feedback, grade = excluded.grade, report = excluded.report,
    submit_count = submissions.submit_count + 1, updated_at = now()
  returning * into r;
  insert into activity_log (class_code, kind) values (p_code, 'feedback');
  return jsonb_build_object('id', r.id);
end $$;

create or replace function student_post(p_code text, p_no int, p_pin text, p_text text, p_photo jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare c class_settings;
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  if coalesce(trim(p_text), '') = '' then raise exception '완성한 글이 비어 있어요.'; end if;
  select * into c from class_settings where class_code = p_code;
  update submissions set final_text = trim(p_text), posted = true, posted_at = now(), updated_at = now(),
    photo_path = p_photo->>'path', photo_url = p_photo->>'url',
    photo_credit = p_photo->>'credit', photo_credit_link = p_photo->>'credit_link'
  where class_code = p_code and student_no = p_no and unit_name = c.unit_name;
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
      'final_text', s.final_text, 'photo_path', s.photo_path, 'photo_url', s.photo_url,
      'photo_credit', s.photo_credit, 'photo_credit_link', s.photo_credit_link, 'posted_at', s.posted_at,
      'hearts', (select count(*) from hearts h where h.submission_id = s.id),
      'liked', exists (select 1 from hearts h where h.submission_id = s.id and h.student_no = p_no),
      'mine', s.student_no = p_no,
      'teacher_comment', case when s.student_no = p_no then s.teacher_comment else '' end) as x
    from submissions s where s.class_code = p_code and s.posted) q);
end $$;

create or replace function student_edit_post(p_code text, p_no int, p_pin text, p_id uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  if coalesce(trim(p_text), '') = '' then raise exception '글이 비어 있어요.'; end if;
  update submissions set final_text = trim(p_text), updated_at = now()
  where id = p_id and class_code = p_code and student_no = p_no and posted;
  if not found then raise exception '내 글만 고칠 수 있어요.'; end if;
end $$;

create or replace function student_delete_post(p_code text, p_no int, p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  update submissions set posted = false where id = p_id and class_code = p_code and student_no = p_no;
  if not found then raise exception '내 글만 지울 수 있어요.'; end if;
  delete from hearts where submission_id = p_id;
end $$;

-- 학생에게는 상·중·하 평가와 통지표 문장을 보내지 않음
create or replace function student_portfolio(p_code text, p_no int, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(s) - 'class_code' - 'grade' - 'report' order by s.created_at desc), '[]'::jsonb)
          from submissions s where s.class_code = p_code and s.student_no = p_no);
end $$;

create or replace function teacher_edit_post(p_code text, p_pw text, p_id uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); cc text;
begin
  select class_code into cc from submissions where id = p_id;
  perform _own(t, cc);
  if coalesce(trim(p_text), '') = '' then raise exception '글이 비어 있어요.'; end if;
  update submissions set final_text = trim(p_text), updated_at = now() where id = p_id;
end $$;

create or replace function teacher_remove_post(p_code text, p_pw text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); cc text;
begin
  select class_code into cc from submissions where id = p_id;
  perform _own(t, cc);
  update submissions set posted = false where id = p_id;
  delete from hearts where submission_id = p_id;
end $$;

-- =====================================================================
-- 교사 → 관리자 의견함
-- =====================================================================
create or replace function teacher_send_feedback(p_code text, p_pw text, p_name text, p_message text) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  if coalesce(trim(p_message), '') = '' then raise exception '보낼 내용을 적어 주세요.'; end if;
  if coalesce(trim(p_name), '') <> '' then update teachers set name = trim(p_name) where id = t; end if;
  insert into teacher_feedback (teacher_id, sender_name, message)
  values (t, coalesce(nullif(trim(p_name), ''), (select name from teachers where id = t), ''), trim(p_message));
end $$;

create or replace function teacher_feedback_list(p_code text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  return (select coalesce(jsonb_agg(to_jsonb(f) - 'teacher_id' order by f.created_at desc), '[]'::jsonb)
          from teacher_feedback f where f.teacher_id = t);
end $$;

create or replace function admin_feedback(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_pin);
  return (select coalesce(jsonb_agg(to_jsonb(f) || jsonb_build_object(
            'teacher_name', (select name from teachers where id = f.teacher_id),
            'teacher_classes', (select coalesce(jsonb_agg(c.class_code order by c.class_code), '[]'::jsonb) from class_settings c where c.teacher_id = f.teacher_id))
          order by f.created_at desc), '[]'::jsonb) from teacher_feedback f);
end $$;

create or replace function admin_reply_feedback(p_pin text, p_id uuid, p_reply text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_pin);
  update teacher_feedback set reply = coalesce(trim(p_reply), ''), replied_at = now() where id = p_id;
end $$;

create or replace function admin_delete_feedback(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin perform _admin(p_pin); delete from teacher_feedback where id = p_id; end $$;

create or replace function admin_requests(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_pin);
  return (select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object(
            'teacher_name', (select name from teachers where id = r.teacher_id),
            'teacher_classes', (select coalesce(jsonb_agg(c.class_code), '[]'::jsonb) from class_settings c where c.teacher_id = r.teacher_id),
            'ready', r.requested_at <= now() - interval '3 days')
          order by r.requested_at), '[]'::jsonb)
          from class_deletion_requests r where r.status = 'pending');
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
