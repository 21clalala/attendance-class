-- =====================================================================
-- 변경 012: 담임 직접 입력 (조회~종례 "/", 마감 종류·사유)
--  · homeroom_marks: 담임이 칸마다 정한 값 (absent = "/", present = 해제)
--  · day_manual: 담임이 입력한 마감 종류·비고 (나이스 업로드 값보다 우선)
--  · 교과선생님 화면의 회색 "/" = 나이스 "/" + 담임 "/" − 담임 해제
--  · mark_log 에 칸 이름·이전값·새값·입력자·메모를 기록
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

create table if not exists homeroom_marks (
  class_id   int  not null references classes(id) on delete cascade,
  d          date not null,
  student_no int  not null,
  slot       text not null,                       -- '조회','1'~'9','종례'
  state      text not null check (state in ('absent','present')),
  by_email   text,
  at         timestamptz not null default now(),
  primary key (class_id, d, student_no, slot)
);

create table if not exists day_manual (
  class_id   int  not null references classes(id) on delete cascade,
  d          date not null,
  student_no int  not null,
  kind       text,                                -- 예: 질병결석
  note       text,                                -- 비고
  by_email   text,
  at         timestamptz not null default now(),
  primary key (class_id, d, student_no)
);

alter table mark_log alter column period drop not null;
alter table mark_log add column if not exists slot     text;
alter table mark_log add column if not exists before   text;
alter table mark_log add column if not exists after    text;
alter table mark_log add column if not exists by_email text;
alter table mark_log add column if not exists memo     text;

do $$
declare t text;
begin
  foreach t in array array['homeroom_marks','day_manual'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists class_rw on %I', t);
    execute format('create policy class_rw on %I for all to authenticated using (can_manage(class_id)) with check (can_manage(class_id))', t);
    execute format('revoke all on %I from anon', t);
  end loop;
  begin execute 'alter publication supabase_realtime add table homeroom_marks'; exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table day_manual';     exception when others then null; end;
end $$;

-- 미리 표시된 "/" 인가 (담임 값이 있으면 그것, 없으면 나이스)
create or replace function base_absent(p_class int, p_d date, p_no int, p_slot text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select state = 'absent' from homeroom_marks where class_id = p_class and d = p_d and student_no = p_no and slot = p_slot),
    exists (select 1 from neis_marks where class_id = p_class and d = p_d and student_no = p_no and slot = p_slot))
$$;
revoke execute on function base_absent(int,date,int,text) from public, anon, authenticated;

create or replace function get_today(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c        classes := class_by_key(p_key);
  v_now    timestamp := kst_now();
  v_d      date      := v_now::date;
  v_period int       := current_period(c.id, v_now);
  v_next   jsonb;
begin
  select jsonb_build_object('period', s.period, 'start', to_char(s.start_t, 'HH24:MI'))
    into v_next
    from schedule_for(c.id, v_d) s
   where s.start_t > v_now::time
   order by s.start_t limit 1;

  return jsonb_build_object(
    'date',    v_d,
    'now',     to_char(v_now, 'HH24:MI'),
    'label',   c.label,
    'period',  v_period,
    'teacher', case when v_period is null then null else teacher_for(c.id, v_d, v_period) end,
    'next',    v_next,
    'teachers', coalesce((
        select jsonb_agg(t order by t) from (
          select teacher as t from timetable where class_id = c.id
          union select teacher from teacher_override where class_id = c.id and d >= v_d - 7
          union select nullif(trim(c.homeroom), '')
          union select comci_name(s.teacher_idx) from comci_slot s
                 where s.label = norm_label(c.label) and s.d between v_d - 7 and v_d + 14 and s.teacher_idx is not null) x
          where t is not null and t <> ''), '[]'::jsonb),
    'schedule', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'period', s.period,
                 'start',  to_char(s.start_t, 'HH24:MI'),
                 'end',    to_char(s.end_t,   'HH24:MI'),
                 'teacher', teacher_for(c.id, v_d, s.period)) order by s.period)
          from schedule_for(c.id, v_d) s), '[]'::jsonb),
    'students', coalesce((
        select jsonb_agg(jsonb_build_object('no', no, 'name', name, 'excluded', excluded, 'tag', tag) order by no)
          from students where class_id = c.id), '[]'::jsonb),
    'neis', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'slot', slot))
          from (select student_no, slot from neis_marks where class_id = c.id and d = v_d
                union select student_no, slot from homeroom_marks where class_id = c.id and d = v_d and state = 'absent'
                except select student_no, slot from homeroom_marks where class_id = c.id and d = v_d and state = 'present') b), '[]'::jsonb),
    'marks', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'period', period, 'kind', kind))
          from teacher_marks where class_id = c.id and d = v_d), '[]'::jsonb)
  );
end $$;





create or replace function save_marks(p_key text, p_period int, p_teacher text, p_absent int[], p_present int[])
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  c         classes   := class_by_key(p_key);
  v_now     timestamp := kst_now();
  v_d       date      := v_now::date;
  v_period  int;
  v_teacher text;
  r         record;
  v_neis    boolean;
  n_abs     text[] := '{}';
  n_pre     text[] := '{}';
  c_pre     text[] := '{}';
  c_abs     text[] := '{}';
  v_parts   text[] := '{}';
  v_body    text[] := '{}';
  v_cnt     int;
begin
  v_period := current_period(c.id, v_now);
  if v_period is null then raise exception 'not_in_class'; end if;
  if p_period is distinct from v_period then raise exception 'period_changed'; end if;
  v_teacher := teacher_for(c.id, v_d, v_period);
  if v_teacher is null then raise exception 'no_teacher'; end if;
  if p_teacher is distinct from v_teacher then raise exception 'not_your_period'; end if;

  for r in select s.no, s.name from students s
            where s.class_id = c.id and s.no = any(coalesce(p_absent, '{}')) and not s.excluded order by s.no loop
    v_neis := base_absent(c.id, v_d, r.no, v_period::text);
    if v_neis then
      delete from teacher_marks where class_id = c.id and d = v_d and period = v_period and student_no = r.no and kind = 'present';
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        c_abs := c_abs || (r.no || '번 ' || r.name);
        insert into mark_log(class_id, d, period, student_no, action, teacher) values (c.id, v_d, v_period, r.no, 'unpresent', v_teacher);
      end if;
    else
      insert into teacher_marks(class_id, d, period, student_no, teacher, kind) values (c.id, v_d, v_period, r.no, v_teacher, 'absent')
      on conflict do nothing;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        n_abs := n_abs || (r.no || '번 ' || r.name);
        insert into mark_log(class_id, d, period, student_no, action, teacher) values (c.id, v_d, v_period, r.no, 'add', v_teacher);
      end if;
    end if;
  end loop;

  for r in select s.no, s.name from students s
            where s.class_id = c.id and s.no = any(coalesce(p_present, '{}')) and not s.excluded order by s.no loop
    v_neis := base_absent(c.id, v_d, r.no, v_period::text);
    if v_neis then
      insert into teacher_marks(class_id, d, period, student_no, teacher, kind) values (c.id, v_d, v_period, r.no, v_teacher, 'present')
      on conflict do nothing;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        n_pre := n_pre || (r.no || '번 ' || r.name);
        insert into mark_log(class_id, d, period, student_no, action, teacher) values (c.id, v_d, v_period, r.no, 'present', v_teacher);
      end if;
    else
      delete from teacher_marks where class_id = c.id and d = v_d and period = v_period and student_no = r.no and kind = 'absent';
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        c_pre := c_pre || (r.no || '번 ' || r.name);
        insert into mark_log(class_id, d, period, student_no, action, teacher) values (c.id, v_d, v_period, r.no, 'remove', v_teacher);
      end if;
    end if;
  end loop;

  if cardinality(n_abs) + cardinality(n_pre) + cardinality(c_pre) + cardinality(c_abs) = 0 then
    insert into mark_log(class_id, d, period, student_no, action, teacher) values (c.id, v_d, v_period, 0, 'check', v_teacher);
  else
    if cardinality(n_abs) > 0 then
      v_parts := v_parts || ('없음 ' || cardinality(n_abs) || '명');
      v_body  := v_body  || ('없음: ' || array_to_string(n_abs, ', '));
    end if;
    if cardinality(n_pre) > 0 then
      v_parts := v_parts || ('출석 확인 ' || cardinality(n_pre) || '명');
      v_body  := v_body  || ('출석 확인(미리 표시된 / 해제): ' || array_to_string(n_pre, ', '));
    end if;
    if cardinality(c_pre) + cardinality(c_abs) > 0 then
      v_parts := v_parts || ('정정 ' || (cardinality(c_pre) + cardinality(c_abs)) || '명');
      if cardinality(c_pre) > 0 then v_body := v_body || ('정정 → 출석: ' || array_to_string(c_pre, ', ')); end if;
      if cardinality(c_abs) > 0 then v_body := v_body || ('정정 → 다시 없음: ' || array_to_string(c_abs, ', ')); end if;
    end if;
    v_body := v_body || (v_teacher || ' 선생님 · ' || to_char(v_now, 'HH24:MI'));
    perform notify_ntfy(c.ntfy_topic,
      format('%s %s교시 · %s', c.label, v_period, array_to_string(v_parts, ' · ')),
      array_to_string(v_body, E'\n'),
      case when cardinality(n_abs) > 0 then 5 else 4 end,
      case when cardinality(n_abs) > 0 then array['rotating_light'] else array['pencil2'] end);
  end if;

  return jsonb_build_object('period', v_period,
    'absent', cardinality(n_abs), 'present', cardinality(n_pre),
    'corrected', cardinality(c_pre) + cardinality(c_abs));
end $$;



grant execute on function get_today(text), save_marks(text,int,text,int[],int[]) to anon, authenticated;
