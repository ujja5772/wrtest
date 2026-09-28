-- =====================================================================
-- 영어 쓰기 교실 — Supabase 설정 SQL
-- Supabase 대시보드 > SQL Editor > New query 에 이 파일 전체를 붙여 넣고 Run.
-- 여러 번 실행해도 안전하도록 작성했습니다.
-- 초기 관리자 PIN: 1234  (관리자 화면에서 꼭 바꿔 주세요)
-- 초기 교사 가입 코드: teacher2026
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 테이블 ----------
create table if not exists admin_config (
  id int primary key default 1 check (id = 1),
  master_pin_hash text not null,
  teacher_join_code text not null default 'teacher2026',
  photo_search_enabled boolean not null default true
);
insert into admin_config (id, master_pin_hash)
values (1, extensions.crypt('1234', extensions.gen_salt('bf')))
on conflict (id) do nothing;

create table if not exists teachers (
  id uuid primary key default gen_random_uuid(),
  pw_hash text not null,
  created_at timestamptz not null default now()
);

create table if not exists class_settings (
  class_code text primary key,
  teacher_id uuid not null references teachers(id) on delete cascade,
  school text not null, grade int not null, class_no int not null,
  unit_name text not null default '',
  topic text not null default '',
  guide text not null default '',
  words text not null default '',
  key_expressions text not null default '',
  criteria text not null default '',
  ai_keys text[] not null default '{}',
  expected_students int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists class_units (
  id uuid primary key default gen_random_uuid(),
  class_code text not null references class_settings(class_code) on delete cascade,
  name text not null, topic text not null default '', guide text not null default '',
  words text not null default '', key_expressions text not null default '', criteria text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists student_pins (
  class_code text not null references class_settings(class_code) on delete cascade,
  student_no int not null,
  student_name text not null default '',
  pin_hash text,
  created_at timestamptz not null default now(),
  last_seen timestamptz,
  primary key (class_code, student_no)
);

create table if not exists submissions (
  id uuid primary key default gen_random_uuid(),
  class_code text not null references class_settings(class_code) on delete cascade,
  student_no int not null,
  student_name text not null default '',
  unit_name text not null default '',
  topic text not null default '',
  write_mode text not null default '',
  original_text text not null default '',
  final_text text not null default '',
  feedback jsonb,
  grade text,
  report text,
  photo_path text, photo_url text, photo_credit text, photo_credit_link text,
  teacher_comment text not null default '',
  submit_count int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (class_code, student_no, unit_name)
);

create table if not exists hearts (
  submission_id uuid not null references submissions(id) on delete cascade,
  class_code text not null,
  student_no int not null,
  primary key (submission_id, student_no)
);

create table if not exists teacher_messages (
  id uuid primary key default gen_random_uuid(),
  class_code text not null references class_settings(class_code) on delete cascade,
  message text not null,
  created_at timestamptz not null default now()
);

create table if not exists class_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('class', 'teacher')),
  class_code text,
  teacher_id uuid,
  requested_at timestamptz not null default now(),
  status text not null default 'pending',
  decided_at timestamptz
);

create table if not exists activity_log (
  id bigserial primary key,
  class_code text,
  kind text not null,
  created_at timestamptz not null default now()
);
create index if not exists activity_log_time on activity_log (created_at);

-- ---------- 직접 접근 차단 (모든 읽기·쓰기는 아래 함수로만) ----------
do $$
declare t text;
begin
  foreach t in array array['admin_config','teachers','class_settings','class_units','student_pins',
    'submissions','hearts','teacher_messages','class_deletion_requests','activity_log'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from anon, authenticated', t);
  end loop;
end $$;

-- ---------- 사진 저장소 (비공개, 업로드·읽기만) ----------
insert into storage.buckets (id, name, public)
values ('student-photos', 'student-photos', false)
on conflict (id) do nothing;
drop policy if exists "student photos upload" on storage.objects;
drop policy if exists "student photos read" on storage.objects;
create policy "student photos upload" on storage.objects for insert to anon
  with check (bucket_id = 'student-photos');
create policy "student photos read" on storage.objects for select to anon
  using (bucket_id = 'student-photos');

-- =====================================================================
-- 내부 도우미 함수
-- =====================================================================
create or replace function _teacher_id(p_code text, p_pw text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare t uuid;
begin
  select tt.id into t from class_settings c join teachers tt on tt.id = c.teacher_id
   where c.class_code = trim(p_code) and tt.pw_hash = crypt(coalesce(p_pw,''), tt.pw_hash);
  if t is null then raise exception '학급 코드 또는 교사 비밀번호가 맞지 않아요.'; end if;
  return t;
end $$;

create or replace function _own(t uuid, p_target text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from class_settings where class_code = p_target and teacher_id = t) then
    raise exception '선생님의 학급이 아니에요: %', p_target;
  end if;
end $$;

create or replace function _student_ok(p_code text, p_no int, p_pin text) returns boolean
language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from student_pins where class_code = p_code and student_no = p_no
                 and pin_hash is not null and pin_hash = crypt(coalesce(p_pin,''), pin_hash));
$$;

create or replace function _admin(p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from admin_config where id = 1 and master_pin_hash = crypt(coalesce(p_pin,''), master_pin_hash)) then
    raise exception '관리자 PIN이 맞지 않아요.';
  end if;
end $$;

create or replace function _apply_patch(p_target text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  update class_settings set
    unit_name = case when p ? 'unit_name' then p->>'unit_name' else unit_name end,
    topic = case when p ? 'topic' then p->>'topic' else topic end,
    guide = case when p ? 'guide' then p->>'guide' else guide end,
    words = case when p ? 'words' then p->>'words' else words end,
    key_expressions = case when p ? 'key_expressions' then p->>'key_expressions' else key_expressions end,
    criteria = case when p ? 'criteria' then p->>'criteria' else criteria end,
    expected_students = case when p ? 'expected_students' then coalesce((p->>'expected_students')::int, 0) else expected_students end
  where class_code = p_target;
end $$;

create or replace function _make_classes(t uuid, p_school text, p_grade int, p_classes int[]) returns text[]
language plpgsql security definer set search_path = public as $$
declare n int; code text; made text[] := '{}'; s text := regexp_replace(trim(p_school), '\s+', '', 'g');
begin
  if s = '' or s like '%-%' or s not like '%학교' then
    raise exception '학교 이름은 "송안초등학교"처럼 전체 이름으로, 띄어쓰기와 - 없이 적어 주세요.';
  end if;
  if p_grade is null or p_grade < 1 or p_grade > 6 then raise exception '학년은 1~6 사이 숫자예요.'; end if;
  if p_classes is null or array_length(p_classes, 1) is null then raise exception '반을 하나 이상 골라 주세요.'; end if;
  if array_length(p_classes, 1) > 15 then raise exception '한 번에 15개 반까지만 만들 수 있어요.'; end if;
  foreach n in array p_classes loop
    if n < 1 or n > 30 then raise exception '반은 1~30 사이 숫자예요.'; end if;
    code := s || '-' || p_grade || '-' || n;
    if exists (select 1 from class_settings where class_code = code) then
      raise exception '이미 있는 학급 코드예요: %', code;
    end if;
    insert into class_settings (class_code, teacher_id, school, grade, class_no) values (code, t, s, p_grade, n);
    made := made || code;
  end loop;
  return made;
end $$;

-- =====================================================================
-- 공개 설정
-- =====================================================================
create or replace function get_public_config() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object('photo_search_enabled', photo_search_enabled) from admin_config where id = 1;
$$;

-- =====================================================================
-- 학생
-- =====================================================================
create or replace function student_enter(p_code text, p_no int, p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c class_settings; s student_pins; is_first boolean := false;
begin
  select * into c from class_settings where class_code = trim(p_code);
  if not found then raise exception '학급 코드를 찾을 수 없어요. 선생님께 학급 코드를 다시 확인해 주세요.'; end if;
  if coalesce(array_length(c.ai_keys, 1), 0) = 0 then raise exception 'NO_KEYS'; end if;
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

create or replace function student_gallery(p_code text, p_no int, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  return (select coalesce(jsonb_agg(x order by x->>'updated_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', s.id, 'student_no', s.student_no, 'student_name', s.student_name, 'unit_name', s.unit_name,
      'final_text', s.final_text, 'photo_path', s.photo_path, 'photo_url', s.photo_url,
      'photo_credit', s.photo_credit, 'photo_credit_link', s.photo_credit_link, 'updated_at', s.updated_at,
      'hearts', (select count(*) from hearts h where h.submission_id = s.id),
      'liked', exists (select 1 from hearts h where h.submission_id = s.id and h.student_no = p_no),
      'mine', s.student_no = p_no,
      'teacher_comment', case when s.student_no = p_no then s.teacher_comment else '' end) as x
    from submissions s where s.class_code = p_code) q);
end $$;

create or replace function student_toggle_heart(p_code text, p_no int, p_pin text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare liked boolean;
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  if not exists (select 1 from submissions where id = p_id and class_code = p_code) then raise exception '글을 찾을 수 없어요.'; end if;
  if exists (select 1 from hearts where submission_id = p_id and student_no = p_no) then
    delete from hearts where submission_id = p_id and student_no = p_no; liked := false;
  else
    insert into hearts values (p_id, p_code, p_no); liked := true;
  end if;
  return jsonb_build_object('liked', liked, 'hearts', (select count(*) from hearts where submission_id = p_id));
end $$;

create or replace function student_portfolio(p_code text, p_no int, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(s) - 'class_code' order by s.created_at desc), '[]'::jsonb)
          from submissions s where s.class_code = p_code and s.student_no = p_no);
end $$;

-- =====================================================================
-- 서버 함수(넷리파이) 전용 — service_role 만 호출 가능
-- =====================================================================
create or replace function svc_ai_context(p_code text, p_no int, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c class_settings;
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  select * into c from class_settings where class_code = p_code;
  return jsonb_build_object('keys', c.ai_keys, 'unit_name', c.unit_name, 'topic', c.topic, 'guide', c.guide,
    'words', c.words, 'key_expressions', c.key_expressions, 'criteria', c.criteria, 'grade', c.grade,
    'photo_search_enabled', (select photo_search_enabled from admin_config where id = 1));
end $$;

create or replace function svc_log(p_code text, p_kind text) returns void
language sql security definer set search_path = public as $$
  insert into activity_log (class_code, kind) values (p_code, p_kind);
$$;

create or replace function svc_save_submission(p_code text, p_no int, p_pin text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c class_settings; nm text; r submissions;
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  select * into c from class_settings where class_code = p_code;
  select student_name into nm from student_pins where class_code = p_code and student_no = p_no;
  insert into submissions (class_code, student_no, student_name, unit_name, topic, write_mode, original_text, final_text,
                           feedback, grade, report, photo_path, photo_url, photo_credit, photo_credit_link)
  values (p_code, p_no, nm, c.unit_name, c.topic, d->>'mode', d->>'text', d->>'text', d->'feedback',
          d->>'grade', d->>'report', d->>'photo_path', d->>'photo_url', d->>'photo_credit', d->>'photo_credit_link')
  on conflict (class_code, student_no, unit_name) do update set
    student_name = excluded.student_name, topic = excluded.topic, write_mode = excluded.write_mode,
    final_text = excluded.final_text, feedback = excluded.feedback, grade = excluded.grade, report = excluded.report,
    photo_path = case when excluded.photo_path is not null or excluded.photo_url is not null then excluded.photo_path else submissions.photo_path end,
    photo_url = case when excluded.photo_path is not null or excluded.photo_url is not null then excluded.photo_url else submissions.photo_url end,
    photo_credit = case when excluded.photo_path is not null or excluded.photo_url is not null then excluded.photo_credit else submissions.photo_credit end,
    photo_credit_link = case when excluded.photo_path is not null or excluded.photo_url is not null then excluded.photo_credit_link else submissions.photo_credit_link end,
    submit_count = submissions.submit_count + 1, updated_at = now()
  returning * into r;
  insert into activity_log (class_code, kind) values (p_code, 'submit');
  return jsonb_build_object('id', r.id, 'submit_count', r.submit_count);
end $$;

-- =====================================================================
-- 교사
-- =====================================================================
create or replace function teacher_signup(p_join text, p_pw text, p_school text, p_grade int, p_classes int[]) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare t uuid; made text[];
begin
  if coalesce(p_join, '') <> (select teacher_join_code from admin_config where id = 1) then
    raise exception '교사 가입 코드가 맞지 않아요.';
  end if;
  if length(coalesce(p_pw, '')) < 4 then raise exception '교사 비밀번호는 4자 이상이에요.'; end if;
  insert into teachers (pw_hash) values (crypt(p_pw, gen_salt('bf'))) returning id into t;
  made := _make_classes(t, p_school, p_grade, p_classes);
  return jsonb_build_object('codes', made);
end $$;

create or replace function teacher_add_classes(p_code text, p_pw text, p_school text, p_grade int, p_classes int[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  return jsonb_build_object('codes', _make_classes(t, p_school, p_grade, p_classes));
end $$;

create or replace function teacher_overview(p_code text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  return jsonb_build_object(
    'classes', (select coalesce(jsonb_agg(jsonb_build_object(
        'class_code', c.class_code, 'unit_name', c.unit_name, 'topic', c.topic,
        'key_count', coalesce(array_length(c.ai_keys, 1), 0), 'expected_students', c.expected_students,
        'students', (select count(*) from student_pins p where p.class_code = c.class_code),
        'submissions', (select count(*) from submissions s where s.class_code = c.class_code))
        order by c.school, c.grade, c.class_no), '[]'::jsonb)
      from class_settings c where c.teacher_id = t),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) order by r.requested_at desc), '[]'::jsonb)
      from class_deletion_requests r
      where r.teacher_id = t and r.status = 'pending'));
end $$;

create or replace function teacher_class_detail(p_code text, p_pw text, p_target text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); c class_settings;
begin
  perform _own(t, p_target);
  select * into c from class_settings where class_code = p_target;
  return jsonb_build_object(
    'class_code', c.class_code, 'unit_name', c.unit_name, 'topic', c.topic, 'guide', c.guide, 'words', c.words,
    'key_expressions', c.key_expressions, 'criteria', c.criteria, 'expected_students', c.expected_students,
    'keys', (select coalesce(jsonb_agg(left(k, 6) || '…' || right(k, 4)), '[]'::jsonb) from unnest(c.ai_keys) k),
    'units', (select coalesce(jsonb_agg(to_jsonb(u) order by u.created_at desc), '[]'::jsonb) from class_units u where u.class_code = p_target),
    'messages', (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at desc), '[]'::jsonb) from teacher_messages m where m.class_code = p_target));
end $$;

create or replace function teacher_add_key(p_code text, p_pw text, p_target text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); k text := trim(p_key);
begin
  perform _own(t, p_target);
  if length(k) < 20 then raise exception '키가 너무 짧아요. 복사한 키 전체를 붙여 넣어 주세요.'; end if;
  if (select coalesce(array_length(ai_keys, 1), 0) from class_settings where class_code = p_target) >= 4 then
    raise exception '학급당 키는 4개까지 등록할 수 있어요.';
  end if;
  if (select k = any(ai_keys) from class_settings where class_code = p_target) then raise exception '이미 등록한 키예요.'; end if;
  update class_settings set ai_keys = ai_keys || k where class_code = p_target;
end $$;

create or replace function teacher_remove_key(p_code text, p_pw text, p_target text, p_index int) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  perform _own(t, p_target);
  update class_settings
     set ai_keys = coalesce((select array_agg(k order by i) from unnest(ai_keys) with ordinality as a(k, i) where i <> p_index + 1), '{}')
   where class_code = p_target;
end $$;

create or replace function teacher_share_keys(p_code text, p_pw text, p_source text) returns int
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); ks text[]; n int;
begin
  perform _own(t, p_source);
  select ai_keys into ks from class_settings where class_code = p_source;
  if coalesce(array_length(ks, 1), 0) = 0 then raise exception '먼저 이 학급에 키를 등록해 주세요.'; end if;
  update class_settings set ai_keys = ks where teacher_id = t and class_code <> p_source;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function teacher_update_settings(p_code text, p_pw text, p_targets text[], p_patch jsonb, p_reset_pins boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); x text; n int := 0;
begin
  foreach x in array p_targets loop
    perform _own(t, x);
    perform _apply_patch(x, p_patch);
    if p_reset_pins then update student_pins set pin_hash = null where class_code = x; end if;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function teacher_change_password(p_code text, p_pw text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  if length(coalesce(p_new, '')) < 4 then raise exception '새 비밀번호는 4자 이상이에요.'; end if;
  update teachers set pw_hash = crypt(p_new, gen_salt('bf')) where id = t;
end $$;

create or replace function teacher_create_unit(p_code text, p_pw text, p_targets text[], u jsonb, p_apply boolean) returns int
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); x text; n int := 0;
begin
  if coalesce(trim(u->>'name'), '') = '' then raise exception '단원 이름을 적어 주세요.'; end if;
  foreach x in array p_targets loop
    perform _own(t, x);
    insert into class_units (class_code, name, topic, guide, words, key_expressions, criteria)
    values (x, trim(u->>'name'), coalesce(u->>'topic', ''), coalesce(u->>'guide', ''), coalesce(u->>'words', ''),
            coalesce(u->>'key_expressions', ''), coalesce(u->>'criteria', ''));
    if p_apply then
      perform _apply_patch(x, jsonb_build_object('unit_name', trim(u->>'name'), 'topic', coalesce(u->>'topic', ''),
        'guide', coalesce(u->>'guide', ''), 'words', coalesce(u->>'words', ''),
        'key_expressions', coalesce(u->>'key_expressions', ''), 'criteria', coalesce(u->>'criteria', '')));
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function teacher_apply_unit(p_code text, p_pw text, p_unit uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); u class_units;
begin
  select * into u from class_units where id = p_unit;
  if not found then raise exception '단원을 찾을 수 없어요.'; end if;
  perform _own(t, u.class_code);
  perform _apply_patch(u.class_code, jsonb_build_object('unit_name', u.name, 'topic', u.topic, 'guide', u.guide,
    'words', u.words, 'key_expressions', u.key_expressions, 'criteria', u.criteria));
end $$;

create or replace function teacher_delete_unit(p_code text, p_pw text, p_unit uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); cc text;
begin
  select class_code into cc from class_units where id = p_unit;
  perform _own(t, cc);
  delete from class_units where id = p_unit;
end $$;

create or replace function teacher_submissions(p_code text, p_pw text, p_target text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  perform _own(t, p_target);
  return (select coalesce(jsonb_agg(to_jsonb(s) || jsonb_build_object('hearts', (select count(*) from hearts h where h.submission_id = s.id))
          order by s.student_no, s.created_at), '[]'::jsonb) from submissions s where s.class_code = p_target);
end $$;

create or replace function teacher_set_comment(p_code text, p_pw text, p_id uuid, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); cc text;
begin
  select class_code into cc from submissions where id = p_id;
  perform _own(t, cc);
  update submissions set teacher_comment = coalesce(p_comment, '') where id = p_id;
end $$;

create or replace function teacher_students(p_code text, p_pw text, p_target text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  perform _own(t, p_target);
  return (select coalesce(jsonb_agg(jsonb_build_object('student_no', p.student_no, 'student_name', p.student_name,
            'has_pin', p.pin_hash is not null, 'last_seen', p.last_seen,
            'submissions', (select count(*) from submissions s where s.class_code = p.class_code and s.student_no = p.student_no))
          order by p.student_no), '[]'::jsonb) from student_pins p where p.class_code = p_target);
end $$;

create or replace function teacher_reset_pin(p_code text, p_pw text, p_target text, p_no int) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  perform _own(t, p_target);
  update student_pins set pin_hash = null where class_code = p_target and student_no = p_no;
end $$;

create or replace function teacher_delete_student(p_code text, p_pw text, p_target text, p_no int) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  perform _own(t, p_target);
  delete from submissions where class_code = p_target and student_no = p_no;
  delete from hearts where class_code = p_target and student_no = p_no;
  delete from student_pins where class_code = p_target and student_no = p_no;
end $$;

create or replace function teacher_post_message(p_code text, p_pw text, p_target text, p_message text) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  perform _own(t, p_target);
  if coalesce(trim(p_message), '') = '' then raise exception '알림 내용을 적어 주세요.'; end if;
  insert into teacher_messages (class_code, message) values (p_target, trim(p_message));
end $$;

create or replace function teacher_delete_message(p_code text, p_pw text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); cc text;
begin
  select class_code into cc from teacher_messages where id = p_id;
  perform _own(t, cc);
  delete from teacher_messages where id = p_id;
end $$;

create or replace function teacher_request_delete(p_code text, p_pw text, p_kind text, p_target text) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  if p_kind = 'class' then
    perform _own(t, p_target);
    if exists (select 1 from class_deletion_requests where kind = 'class' and class_code = p_target and status = 'pending') then
      raise exception '이미 삭제 신청한 학급이에요.';
    end if;
    insert into class_deletion_requests (kind, class_code, teacher_id) values ('class', p_target, t);
  elsif p_kind = 'teacher' then
    if exists (select 1 from class_deletion_requests where kind = 'teacher' and teacher_id = t and status = 'pending') then
      raise exception '이미 탈퇴 신청을 했어요.';
    end if;
    insert into class_deletion_requests (kind, teacher_id, class_code) values ('teacher', t, p_code);
  else
    raise exception '알 수 없는 요청이에요.';
  end if;
end $$;

create or replace function teacher_cancel_request(p_code text, p_pw text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw);
begin
  update class_deletion_requests set status = 'cancelled', decided_at = now()
   where id = p_id and teacher_id = t and status = 'pending';
end $$;

-- =====================================================================
-- 관리자
-- =====================================================================
create or replace function admin_login(p_pin text) returns boolean
language plpgsql security definer set search_path = public as $$
begin perform _admin(p_pin); return true; end $$;

create or replace function admin_get_config(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_pin);
  return (select jsonb_build_object('teacher_join_code', teacher_join_code, 'photo_search_enabled', photo_search_enabled)
          from admin_config where id = 1);
end $$;

create or replace function admin_set_config(p_pin text, p jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_pin);
  if p ? 'teacher_join_code' and length(coalesce(p->>'teacher_join_code', '')) < 4 then
    raise exception '가입 코드는 4자 이상이에요.';
  end if;
  if p ? 'new_pin' and length(coalesce(p->>'new_pin', '')) < 4 then raise exception '새 PIN은 4자 이상이에요.'; end if;
  update admin_config set
    teacher_join_code = case when p ? 'teacher_join_code' then p->>'teacher_join_code' else teacher_join_code end,
    photo_search_enabled = case when p ? 'photo_search_enabled' then (p->>'photo_search_enabled')::boolean else photo_search_enabled end,
    master_pin_hash = case when p ? 'new_pin' then crypt(p->>'new_pin', gen_salt('bf')) else master_pin_hash end
  where id = 1;
end $$;

create or replace function admin_stats(p_pin text) returns jsonb
language plpgsql security definer set search_path = public, storage as $$
begin
  perform _admin(p_pin);
  return jsonb_build_object(
    'teachers', (select count(*) from teachers),
    'classes_count', (select count(*) from class_settings),
    'students', (select count(*) from student_pins),
    'submissions', (select count(*) from submissions),
    'hearts', (select count(*) from hearts),
    'photo_bytes', (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects where bucket_id = 'student-photos'),
    'db_bytes', pg_database_size(current_database()),
    'classes', (select coalesce(jsonb_agg(jsonb_build_object(
        'class_code', c.class_code, 'unit_name', c.unit_name, 'expected', c.expected_students,
        'key_count', coalesce(array_length(c.ai_keys, 1), 0),
        'students', (select count(*) from student_pins p where p.class_code = c.class_code),
        'submitters', (select count(distinct student_no) from submissions s where s.class_code = c.class_code),
        'submissions', (select count(*) from submissions s where s.class_code = c.class_code),
        'hearts', (select count(*) from hearts h where h.class_code = c.class_code),
        'last_active', (select max(created_at) from activity_log a where a.class_code = c.class_code))
        order by c.class_code), '[]'::jsonb) from class_settings c),
    'daily', (select coalesce(jsonb_agg(d order by d->>'day'), '[]'::jsonb) from (
        select jsonb_build_object('day', to_char(created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD'),
          'enter', count(*) filter (where kind = 'enter'), 'chat', count(*) filter (where kind = 'chat'),
          'submit', count(*) filter (where kind = 'submit')) d
        from activity_log where created_at > now() - interval '14 days'
        group by to_char(created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD')) q),
    'hours', (select coalesce(jsonb_agg(h order by (h->>'hour')::int), '[]'::jsonb) from (
        select jsonb_build_object('hour', extract(hour from created_at at time zone 'Asia/Seoul')::int, 'count', count(*)) h
        from activity_log where created_at > now() - interval '14 days'
        group by extract(hour from created_at at time zone 'Asia/Seoul')) q));
end $$;

create or replace function admin_messages(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_pin);
  return (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at desc), '[]'::jsonb) from teacher_messages m);
end $$;

create or replace function admin_delete_message(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin perform _admin(p_pin); delete from teacher_messages where id = p_id; end $$;

create or replace function admin_delete_class(p_pin text, p_target text) returns void
language plpgsql security definer set search_path = public as $$
begin perform _admin(p_pin); delete from class_settings where class_code = p_target; end $$;

create or replace function admin_reset_class_pins(p_pin text, p_target text) returns void
language plpgsql security definer set search_path = public as $$
begin perform _admin(p_pin); update student_pins set pin_hash = null where class_code = p_target; end $$;

create or replace function admin_requests(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_pin);
  return (select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object(
            'teacher_classes', (select coalesce(jsonb_agg(c.class_code), '[]'::jsonb) from class_settings c where c.teacher_id = r.teacher_id),
            'ready', r.requested_at <= now() - interval '3 days')
          order by r.requested_at), '[]'::jsonb)
          from class_deletion_requests r where r.status = 'pending');
end $$;

create or replace function admin_decide(p_pin text, p_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r class_deletion_requests;
begin
  perform _admin(p_pin);
  select * into r from class_deletion_requests where id = p_id and status = 'pending';
  if not found then raise exception '처리할 요청이 없어요.'; end if;
  if not p_approve then
    update class_deletion_requests set status = 'rejected', decided_at = now() where id = p_id; return;
  end if;
  if r.requested_at > now() - interval '3 days' then raise exception '신청 후 3일이 지나야 승인할 수 있어요.'; end if;
  if r.kind = 'class' then
    delete from class_settings where class_code = r.class_code;
  else
    delete from teachers where id = r.teacher_id;
  end if;
  update class_deletion_requests set status = 'approved', decided_at = now() where id = p_id;
end $$;

create or replace function admin_bulk_settings(p_pin text, p_targets text[], p_patch jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare x text; n int := 0;
begin
  perform _admin(p_pin);
  foreach x in array p_targets loop perform _apply_patch(x, p_patch); n := n + 1; end loop;
  return n;
end $$;

-- =====================================================================
-- 실행 권한 정리
-- =====================================================================
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like '\_%' or p.proname like 'svc\_%'
             or p.proname in ('get_public_config') or p.proname like 'student\_%' or p.proname like 'teacher\_%' or p.proname like 'admin\_%') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'svc\_%' then
      execute format('grant execute on function %s to service_role', f.sig);
    elsif f.proname not like '\_%' then
      execute format('grant execute on function %s to anon, authenticated, service_role', f.sig);
    end if;
  end loop;
end $$;
