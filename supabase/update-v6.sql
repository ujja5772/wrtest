-- =====================================================================
-- 오늘의 영어 쓰기 v6 업데이트 (update-v5.sql 다음에 실행, 여러 번 실행해도 안전)
-- 학생 이름: 처음 등록한 이름을 유지하고, 선생님이 고칠 수 있음. 글에 붙은 이름도 함께 맞춤
-- =====================================================================
alter table student_pins add column if not exists name_locked boolean not null default false;

-- 글에 붙은 이름을 학생 명단의 이름과 맞추기
update submissions s set student_name = p.student_name
from student_pins p
where p.class_code = s.class_code and p.student_no = s.student_no and s.student_name is distinct from p.student_name;

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
  elsif s.pin_hash is null then -- PIN을 초기화한 뒤 다시 들어올 때 (선생님이 고친 이름은 그대로)
    update student_pins set pin_hash = crypt(p_pin, gen_salt('bf')),
      student_name = case when name_locked then student_name else trim(p_name) end, last_seen = now()
     where class_code = c.class_code and student_no = p_no;
    is_first := true;
  elsif s.pin_hash <> crypt(p_pin, s.pin_hash) then
    raise exception 'PIN이 맞지 않아요. 처음 입장할 때 입력한 숫자 4자리를 넣어 주세요. 기억나지 않으면 선생님께 초기화를 부탁해요.';
  else -- 이미 등록된 학생: 이름은 처음 등록한 이름(또는 선생님이 고친 이름)을 그대로 씀
    update student_pins set last_seen = now() where class_code = c.class_code and student_no = p_no;
  end if;

  insert into activity_log (class_code, kind) values (c.class_code, 'enter');
  return jsonb_build_object(
    'student_name', (select student_name from student_pins where class_code = c.class_code and student_no = p_no),
    'first', is_first, 'class_code', c.class_code, 'unit_name', c.unit_name, 'topic', c.topic,
    'words', c.words, 'key_expressions', c.key_expressions,
    'messages', (select coalesce(jsonb_agg(jsonb_build_object('message', message, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
                 from teacher_messages where class_code = c.class_code));
end $$;

create or replace function student_post(p_code text, p_no int, p_pin text, p_text text, p_photo jsonb, p_mode text) returns void
language plpgsql security definer set search_path = public as $$
declare c class_settings; m text := case when p_mode = 'slow' then 'slow' else 'self' end;
begin
  if not _student_ok(p_code, p_no, p_pin) then raise exception '다시 입장해 주세요.'; end if;
  if coalesce(trim(p_text), '') = '' then raise exception '완성한 글이 비어 있어요.'; end if;
  select * into c from class_settings where class_code = p_code;
  update submissions set final_text = trim(p_text), posted = true,
    student_name = (select student_name from student_pins where class_code = p_code and student_no = p_no), posted_at = now(), updated_at = now(),
    photo_path = p_photo->>'path', photo_url = p_photo->>'url',
    photo_credit = p_photo->>'credit', photo_credit_link = p_photo->>'credit_link'
  where class_code = p_code and student_no = p_no and unit_name = c.unit_name and write_mode = m;
  if not found then raise exception '먼저 첨삭을 받아 주세요.'; end if;
  insert into activity_log (class_code, kind) values (p_code, 'submit');
end $$;

create or replace function teacher_rename_student(p_code text, p_pw text, p_target text, p_no int, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := _teacher_id(p_code, p_pw); nm text := trim(coalesce(p_name, ''));
begin
  perform _own(t, p_target);
  if nm = '' then raise exception '이름을 적어 주세요.'; end if;
  update student_pins set student_name = nm, name_locked = true where class_code = p_target and student_no = p_no;
  if not found then raise exception '학생을 찾을 수 없어요.'; end if;
  update submissions set student_name = nm where class_code = p_target and student_no = p_no;
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
