-- =====================================================================
-- 변경 002: 교과선생님이 나이스 "/"도 해제(출석 확인) 가능, 변경 없이 저장(확인) 가능
-- Supabase → SQL Editor 에 전체 붙여 넣고 Run (한 번만)
-- =====================================================================

alter table teacher_marks add column if not exists kind text not null default 'absent';
do $$ begin
  alter table teacher_marks add constraint teacher_marks_kind_chk check (kind in ('absent','present'));
exception when duplicate_object then null; end $$;

create or replace function get_today(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_now    timestamp := kst_now();
  v_d      date      := v_now::date;
  v_period int;
  v_next   jsonb;
begin
  perform check_key(p_key);
  v_period := current_period(v_now);

  select jsonb_build_object('period', s.period, 'start', to_char(s.start_t, 'HH24:MI'))
    into v_next
    from schedule_for(v_d) s
   where s.start_t > v_now::time
   order by s.start_t limit 1;

  return jsonb_build_object(
    'date',    v_d,
    'now',     to_char(v_now, 'HH24:MI'),
    'label',   (select value from config where key = 'class_label'),
    'period',  v_period,
    'teacher', case when v_period is null then null else teacher_for(v_d, v_period) end,
    'next',    v_next,
    'schedule', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'period', s.period,
                 'start',  to_char(s.start_t, 'HH24:MI'),
                 'end',    to_char(s.end_t,   'HH24:MI'),
                 'teacher', teacher_for(v_d, s.period)) order by s.period)
          from schedule_for(v_d) s), '[]'::jsonb),
    'students', coalesce((
        select jsonb_agg(jsonb_build_object('no', no, 'name', name, 'excluded', excluded) order by no)
          from students), '[]'::jsonb),
    'neis', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'slot', slot))
          from neis_marks where d = v_d), '[]'::jsonb),
    'marks', coalesce((
        select jsonb_agg(jsonb_build_object('no', student_no, 'period', period, 'kind', kind))
          from teacher_marks where d = v_d), '[]'::jsonb)
  );
end $$;

drop function if exists save_marks(text, int, int[], int[]);

-- p_absent : 이 교시에 "없음"으로 바꿀 학생 / p_present : "출석"으로 바꿀 학생
create or replace function save_marks(p_key text, p_period int, p_absent int[], p_present int[])
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_now     timestamp := kst_now();
  v_d       date      := v_now::date;
  v_period  int;
  v_teacher text;
  v_label   text := (select value from config where key = 'class_label');
  r         record;
  v_neis    boolean;
  n_abs     text[] := '{}';   -- 새로 없음
  n_pre     text[] := '{}';   -- 나이스 "/" 해제 (출석 확인)
  c_pre     text[] := '{}';   -- 정정: 없음 → 출석
  c_abs     text[] := '{}';   -- 정정: 출석 확인 취소 → 다시 없음
  v_parts   text[] := '{}';
  v_body    text[] := '{}';
  v_cnt     int;
begin
  perform check_key(p_key);
  v_period := current_period(v_now);
  if v_period is null then raise exception 'not_in_class'; end if;
  if p_period is distinct from v_period then raise exception 'period_changed'; end if;
  v_teacher := coalesce(teacher_for(v_d, v_period), '시간표 미등록');

  -- 없음으로
  for r in select s.no, s.name from students s
            where s.no = any(coalesce(p_absent, '{}')) and not s.excluded order by s.no loop
    v_neis := exists (select 1 from neis_marks n where n.d = v_d and n.student_no = r.no and n.slot = v_period::text);
    if v_neis then
      delete from teacher_marks where d = v_d and period = v_period and student_no = r.no and kind = 'present';
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        c_abs := c_abs || (r.no || '번 ' || r.name);
        insert into mark_log(d, period, student_no, action, teacher) values (v_d, v_period, r.no, 'unpresent', v_teacher);
      end if;
    else
      insert into teacher_marks(d, period, student_no, teacher, kind) values (v_d, v_period, r.no, v_teacher, 'absent')
      on conflict do nothing;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        n_abs := n_abs || (r.no || '번 ' || r.name);
        insert into mark_log(d, period, student_no, action, teacher) values (v_d, v_period, r.no, 'add', v_teacher);
      end if;
    end if;
  end loop;

  -- 출석으로
  for r in select s.no, s.name from students s
            where s.no = any(coalesce(p_present, '{}')) and not s.excluded order by s.no loop
    v_neis := exists (select 1 from neis_marks n where n.d = v_d and n.student_no = r.no and n.slot = v_period::text);
    if v_neis then
      insert into teacher_marks(d, period, student_no, teacher, kind) values (v_d, v_period, r.no, v_teacher, 'present')
      on conflict do nothing;
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        n_pre := n_pre || (r.no || '번 ' || r.name);
        insert into mark_log(d, period, student_no, action, teacher) values (v_d, v_period, r.no, 'present', v_teacher);
      end if;
    else
      delete from teacher_marks where d = v_d and period = v_period and student_no = r.no and kind = 'absent';
      get diagnostics v_cnt = row_count;
      if v_cnt > 0 then
        c_pre := c_pre || (r.no || '번 ' || r.name);
        insert into mark_log(d, period, student_no, action, teacher) values (v_d, v_period, r.no, 'remove', v_teacher);
      end if;
    end if;
  end loop;

  if cardinality(n_abs) + cardinality(n_pre) + cardinality(c_pre) + cardinality(c_abs) = 0 then
    insert into mark_log(d, period, student_no, action, teacher) values (v_d, v_period, 0, 'check', v_teacher);
  else
    if cardinality(n_abs) > 0 then
      v_parts := v_parts || ('없음 ' || cardinality(n_abs) || '명');
      v_body  := v_body  || ('없음: ' || array_to_string(n_abs, ', '));
    end if;
    if cardinality(n_pre) > 0 then
      v_parts := v_parts || ('출석 확인 ' || cardinality(n_pre) || '명');
      v_body  := v_body  || ('출석 확인(나이스 / 해제): ' || array_to_string(n_pre, ', '));
    end if;
    if cardinality(c_pre) + cardinality(c_abs) > 0 then
      v_parts := v_parts || ('정정 ' || (cardinality(c_pre) + cardinality(c_abs)) || '명');
      if cardinality(c_pre) > 0 then v_body := v_body || ('정정 → 출석: ' || array_to_string(c_pre, ', ')); end if;
      if cardinality(c_abs) > 0 then v_body := v_body || ('정정 → 다시 없음: ' || array_to_string(c_abs, ', ')); end if;
    end if;
    v_body := v_body || (v_teacher || ' 선생님 · ' || to_char(v_now, 'HH24:MI'));
    perform notify_ntfy(
      format('%s %s교시 · %s', v_label, v_period, array_to_string(v_parts, ' · ')),
      array_to_string(v_body, E'\n'),
      case when cardinality(n_abs) > 0 then 5 else 4 end,
      case when cardinality(n_abs) > 0 then array['rotating_light'] else array['pencil2'] end);
  end if;

  return jsonb_build_object('period', v_period,
    'absent', cardinality(n_abs), 'present', cardinality(n_pre),
    'corrected', cardinality(c_pre) + cardinality(c_abs));
end $$;

revoke execute on function save_marks(text,int,int[],int[]) from public;
grant  execute on function get_today(text), save_marks(text,int,int[],int[]) to anon, authenticated;
