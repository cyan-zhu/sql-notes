-- 健走 ABT 训练情况
-- 动态参数：${start_date}, ${end_date}
-- 输出：分组、场景、用户基数、开训用户数、完训用户数、复训率

with user_groups as (
  select distinct '实验组' as group_name, user_id from user_group_user_group_zjza5syz
  union all
  select distinct '对照组' as group_name, user_id from user_group_user_group_zjza5dzz
),
group_base_users as (
  select group_name, count(distinct user_id) as user_base, min(case when group_name = '实验组' then 1 else 2 end) as group_order
  from user_groups
  group by group_name
),
walk_base_users as (
  select g.group_name, count(distinct e.user_id) as user_base
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'pageview_general_wup_h2o' and e.page_id = 60000 and e.date >= '${start_date}' and e.date <= '${end_date}'
  group by g.group_name
),
workout_base_users as (
  select g.group_name, count(distinct e.user_id) as user_base
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'pageview_general_wup_h2o' and e.page_id = 60001 and e.date >= '${start_date}' and e.date <= '${end_date}'
  group by g.group_name
),
tab_home_base_users as (
  select g.group_name, count(distinct e.user_id) as user_base
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'pageview_general_wup_h2o' and e.page_id = 60001 and e.pageinfo = 'Homeworkout' and e.date >= '${start_date}' and e.date <= '${end_date}'
  group by g.group_name
),
tab_walkbeat_base_users as (
  select g.group_name, count(distinct e.user_id) as user_base
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'pageview_general_wup_h2o' and e.page_id = 60001 and e.pageinfo = 'WalBeat' and e.date >= '${start_date}' and e.date <= '${end_date}'
  group by g.group_name
),
filter_page_users as (
  select distinct g.group_name, e.user_id
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'pageview_general_wup_h2o' and e.page_id = 60067 and e.date >= '${start_date}' and e.date <= '${end_date}'
),
filter_page_base_users as (
  select group_name, count(distinct user_id) as user_base from filter_page_users group by group_name
),
filter_used_users as (
  select distinct g.group_name, e.user_id
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'click_general_wup_h2o' and e.click_id = 600077 and e.click_source_url = '筛选' and e.date >= '${start_date}' and e.date <= '${end_date}'
),
filter_used_base_users as (
  select group_name, count(distinct user_id) as user_base from filter_used_users group by group_name
),
filter_not_used_users as (
  select f.group_name, f.user_id
  from filter_page_users f
  left join filter_used_users u on f.group_name = u.group_name and f.user_id = u.user_id
  where u.user_id is null
),
filter_not_used_base_users as (
  select group_name, count(distinct user_id) as user_base from filter_not_used_users group by group_name
),
scenario_users as (
  select group_name, user_id, '进入筛选二级页面' as scene from filter_page_users
  union all select group_name, user_id, '使用筛选' as scene from filter_used_users
  union all select group_name, user_id, '未使用筛选' as scene from filter_not_used_users
),
start_events_long as (
  select g.group_name, 'walk整体' as scene, e.user_id
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'start_action_wup_h2o' and e.date >= '${start_date}' and e.date <= '${end_date}'
  union all
  select g.group_name, 'workout页面' as scene, e.user_id
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'start_action_wup_h2o' and e.date >= '${start_date}' and e.date <= '${end_date}'
    and (e.action_entrance_wup in ('504', '503') or (e.action_entrance_wup = '502' and e.action_entrance_id_wup = '2'))
  union all
  select g.group_name, 'tab_home' as scene, e.user_id
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'start_action_wup_h2o' and e.date >= '${start_date}' and e.date <= '${end_date}' and e.action_entrance_wup = '504'
  union all
  select g.group_name, 'tab_walkbeat' as scene, e.user_id
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'start_action_wup_h2o' and e.date >= '${start_date}' and e.date <= '${end_date}' and e.action_entrance_wup = '503'
  union all
  select s.group_name, s.scene, e.user_id
  from events e join scenario_users s on e.user_id = s.user_id
  where e.event = 'start_action_wup_h2o' and e.date >= '${start_date}' and e.date <= '${end_date}'
),
complete_events_long as (
  select g.group_name, 'walk整体' as scene, e.user_id
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'end_action_wup_h2o' and e.date >= '${start_date}' and e.date <= '${end_date}'
  union all
  select g.group_name, 'workout页面' as scene, e.user_id
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'end_action_wup_h2o' and e.date >= '${start_date}' and e.date <= '${end_date}'
    and (e.action_entrance_wup in ('504', '503') or (e.action_entrance_wup = '502' and e.action_entrance_id_wup = '2'))
  union all
  select g.group_name, 'tab_home' as scene, e.user_id
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'end_action_wup_h2o' and e.date >= '${start_date}' and e.date <= '${end_date}' and e.action_entrance_wup = '504'
  union all
  select g.group_name, 'tab_walkbeat' as scene, e.user_id
  from events e join user_groups g on e.user_id = g.user_id
  where e.event = 'end_action_wup_h2o' and e.date >= '${start_date}' and e.date <= '${end_date}' and e.action_entrance_wup = '503'
  union all
  select s.group_name, s.scene, e.user_id
  from events e join scenario_users s on e.user_id = s.user_id
  where e.event = 'end_action_wup_h2o' and e.date >= '${start_date}' and e.date <= '${end_date}'
),
start_stats as (
  select group_name, scene, count(distinct user_id) as start_uv from start_events_long group by group_name, scene
),
complete_stats as (
  select group_name, scene, count(distinct user_id) as complete_uv from complete_events_long group by group_name, scene
),
retrain_stats as (
  select group_name, scene, count(distinct user_id) as retrain_uv
  from (
    select group_name, scene, user_id from start_events_long group by group_name, scene, user_id having count(*) >= 2
  ) t
  group by group_name, scene
),
scene_metrics as (
  select g.group_name, 'walk整体' as scene, coalesce(w.user_base, 0) as user_base, g.group_order, 1 as scene_order from group_base_users g left join walk_base_users w on g.group_name = w.group_name
  union all select g.group_name, 'workout页面' as scene, coalesce(w.user_base, 0) as user_base, g.group_order, 2 as scene_order from group_base_users g left join workout_base_users w on g.group_name = w.group_name
  union all select g.group_name, 'tab_home' as scene, coalesce(h.user_base, 0) as user_base, g.group_order, 3 as scene_order from group_base_users g left join tab_home_base_users h on g.group_name = h.group_name
  union all select g.group_name, 'tab_walkbeat' as scene, coalesce(wb.user_base, 0) as user_base, g.group_order, 4 as scene_order from group_base_users g left join tab_walkbeat_base_users wb on g.group_name = wb.group_name
  union all select g.group_name, '进入筛选二级页面' as scene, coalesce(fp.user_base, 0) as user_base, g.group_order, 5 as scene_order from group_base_users g left join filter_page_base_users fp on g.group_name = fp.group_name
  union all select g.group_name, '使用筛选' as scene, coalesce(fu.user_base, 0) as user_base, g.group_order, 6 as scene_order from group_base_users g left join filter_used_base_users fu on g.group_name = fu.group_name
  union all select g.group_name, '未使用筛选' as scene, coalesce(fnu.user_base, 0) as user_base, g.group_order, 7 as scene_order from group_base_users g left join filter_not_used_base_users fnu on g.group_name = fnu.group_name
)
select
  m.group_name as `分组`,
  m.scene as `场景`,
  m.user_base as `用户基数`,
  coalesce(st.start_uv, 0) as `开训（用户数）`,
  coalesce(cp.complete_uv, 0) as `完训（用户数）`,
  case when coalesce(st.start_uv, 0) = 0 then 0 else round(coalesce(rt.retrain_uv, 0) * 1.0 / st.start_uv, 4) end as `复训率`
from scene_metrics m
left join start_stats st on m.group_name = st.group_name and m.scene = st.scene
left join complete_stats cp on m.group_name = cp.group_name and m.scene = cp.scene
left join retrain_stats rt on m.group_name = rt.group_name and m.scene = rt.scene
order by m.group_order, m.scene_order;
