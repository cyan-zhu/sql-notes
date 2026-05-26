-- 目的：
-- 这段 SQL 用来一次性计算某个业务 event 的多周期续订情况。
--
-- 输出两类指标：
-- 1. 续订率：续订人数 / 续订基数用户数
-- 2. 续订收入基数：符合条件的首笔/基准订阅订单收入汇总
--
-- 动态参数：
-- ${s_date}：漏斗开始日期，比如 '2025-01-01'
-- ${e_date}：漏斗结束日期，比如 '2025-01-31'
-- ${event_name}：业务中文名，可填 健走 / 瑜伽 / 舞蹈 / 健身 / 拉伸
--
-- 口径说明：
-- 续订率仍然按用户数计算：续订用户数 / 基准用户数。
-- 续订收入基数按金额计算：基准订单的 origin_money 汇总。
-- 续订收入基数 * 续订率 不等于续订收入，因为两者不是同一个统计口径。

with event_map as (
  select 'purchase_vip_order_wup_h2o' as event, '健走' as event_cn
  union all select 'purchase_vip_order_h2o', '瑜伽'
  union all select 'purchase_vip_order_df_h2o', '舞蹈'
  union all select 'purchase_vip_order_mm_h2o', '健身'
  union all select 'purchase_vip_order_db_h2o', '拉伸'
),

base_events as (
  select distinct
    e.event,
    m.event_cn,
    e.date,
    e.user_id,
    e.product_id_all_product,
    e.is_first_purchase_withmoney,
    e.device_type,
    e.origin_money,
    case
      when e.product_id_all_product regexp '(?i)1_year|12_month|goldyear|yearly|auto\\.year|silveryear|365_day|d365|silveryearsale|salesyear' then '年'
      when e.product_id_all_product regexp '(?i)6_month|180_day|d180' then '半年'
      when e.product_id_all_product regexp '(?i)3_month|90_day|d90' then '季'
      when e.product_id_all_product regexp '(?i)1_month|monthly|goldmonth|auto\\.month|silvermonth|30_day|d30' then '月'
    end as period_type,
    case
      when e.product_id_all_product regexp '(?i)1_year|12_month|goldyear|yearly|auto\\.year|silveryear|365_day|d365|silveryearsale|salesyear' then 380
      when e.product_id_all_product regexp '(?i)6_month|180_day|d180' then 190
      when e.product_id_all_product regexp '(?i)3_month|90_day|d90' then 100
      when e.product_id_all_product regexp '(?i)1_month|monthly|goldmonth|auto\\.month|silvermonth|30_day|d30' then 40
    end as diff_days
  from events e
  join event_map m
    on e.event = m.event
  where m.event_cn = '${event_name}'
    and e.date >= '${s_date}'
    and e.date <= date_add('${e_date}', 380)
    and e.product_id_all_product not like '%webob%'
    and e.origin_money > 0
    and e.product_is_subscribe = 1
    and e.distinct_id != '90451406'
    and e.device_type in ('IOS', 'Android')
),

first_pay as (
  select
    event,
    date_trunc('month', date) as first_month,
    user_id as first_user_id,
    product_id_all_product,
    is_first_purchase_withmoney,
    device_type,
    origin_money as first_origin_money,
    date as first_date,
    period_type,
    diff_days
  from base_events
  where date >= '${s_date}'
    and date <= '${e_date}'
    and period_type is not null
),

repay as (
  select
    event,
    user_id,
    product_id_all_product,
    date as repay_date
  from base_events
  where date >= '${s_date}'
    and date <= date_add('${e_date}', 380)
),

first_with_repay as (
  select
    f.first_month,
    f.first_user_id,
    f.period_type,
    f.is_first_purchase_withmoney,
    f.device_type,
    max(case when r.user_id is not null then 1 else 0 end) as has_repay
  from first_pay f
  left join repay r
    on f.event = r.event
   and f.first_user_id = r.user_id
   and f.product_id_all_product = r.product_id_all_product
   and r.repay_date > f.first_date
   and r.repay_date <= date_add(f.first_date, f.diff_days)
  group by
    f.first_month,
    f.first_user_id,
    f.period_type,
    f.is_first_purchase_withmoney,
    f.device_type
),

user_agg as (
  select
    first_month,

    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 1 and device_type = 'Android' then first_user_id end) as base_year_first_and,
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 1 and device_type = 'IOS' then first_user_id end) as base_year_first_ios,
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 0 and device_type = 'Android' then first_user_id end) as base_year_not_first_and,
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 0 and device_type = 'IOS' then first_user_id end) as base_year_not_first_ios,

    count(distinct case when period_type = '月' and is_first_purchase_withmoney = 1 then first_user_id end) as base_month_first,
    count(distinct case when period_type = '月' and is_first_purchase_withmoney = 0 then first_user_id end) as base_month_not_first,
    count(distinct case when period_type = '季' and is_first_purchase_withmoney = 1 then first_user_id end) as base_quarter_first,
    count(distinct case when period_type = '季' and is_first_purchase_withmoney = 0 then first_user_id end) as base_quarter_not_first,
    count(distinct case when period_type = '半年' and is_first_purchase_withmoney = 1 then first_user_id end) as base_half_first,
    count(distinct case when period_type = '半年' and is_first_purchase_withmoney = 0 then first_user_id end) as base_half_not_first,

    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 1 and device_type = 'Android' and has_repay = 1 then first_user_id end) as repay_year_first_and,
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 1 and device_type = 'IOS' and has_repay = 1 then first_user_id end) as repay_year_first_ios,
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 0 and device_type = 'Android' and has_repay = 1 then first_user_id end) as repay_year_not_first_and,
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 0 and device_type = 'IOS' and has_repay = 1 then first_user_id end) as repay_year_not_first_ios,

    count(distinct case when period_type = '月' and is_first_purchase_withmoney = 1 and has_repay = 1 then first_user_id end) as repay_month_first,
    count(distinct case when period_type = '月' and is_first_purchase_withmoney = 0 and has_repay = 1 then first_user_id end) as repay_month_not_first,
    count(distinct case when period_type = '季' and is_first_purchase_withmoney = 1 and has_repay = 1 then first_user_id end) as repay_quarter_first,
    count(distinct case when period_type = '季' and is_first_purchase_withmoney = 0 and has_repay = 1 then first_user_id end) as repay_quarter_not_first,
    count(distinct case when period_type = '半年' and is_first_purchase_withmoney = 1 and has_repay = 1 then first_user_id end) as repay_half_first,
    count(distinct case when period_type = '半年' and is_first_purchase_withmoney = 0 and has_repay = 1 then first_user_id end) as repay_half_not_first
  from first_with_repay
  group by first_month
),

revenue_agg as (
  select
    first_month,

    sum(case when period_type = '年' and is_first_purchase_withmoney = 1 and device_type = 'Android' then first_origin_money else 0 end) as revenue_year_first_and,
    sum(case when period_type = '年' and is_first_purchase_withmoney = 1 and device_type = 'IOS' then first_origin_money else 0 end) as revenue_year_first_ios,
    sum(case when period_type = '年' and is_first_purchase_withmoney = 0 and device_type = 'Android' then first_origin_money else 0 end) as revenue_year_not_first_and,
    sum(case when period_type = '年' and is_first_purchase_withmoney = 0 and device_type = 'IOS' then first_origin_money else 0 end) as revenue_year_not_first_ios,

    sum(case when period_type = '月' and is_first_purchase_withmoney = 1 then first_origin_money else 0 end) as revenue_month_first,
    sum(case when period_type = '月' and is_first_purchase_withmoney = 0 then first_origin_money else 0 end) as revenue_month_not_first,
    sum(case when period_type = '季' and is_first_purchase_withmoney = 1 then first_origin_money else 0 end) as revenue_quarter_first,
    sum(case when period_type = '季' and is_first_purchase_withmoney = 0 then first_origin_money else 0 end) as revenue_quarter_not_first,
    sum(case when period_type = '半年' and is_first_purchase_withmoney = 1 then first_origin_money else 0 end) as revenue_half_first,
    sum(case when period_type = '半年' and is_first_purchase_withmoney = 0 then first_origin_money else 0 end) as revenue_half_not_first
  from first_pay
  group by first_month
),

final_result as (
  select
    '续订率' as `指标类型`,
    first_month as `续订基数发生月份`,

    round(repay_year_first_and * 1.0 / base_year_first_and, 2) as `年_首付_and`,
    round(repay_year_first_ios * 1.0 / base_year_first_ios, 2) as `年_首付_ios`,
    round(repay_year_not_first_and * 1.0 / base_year_not_first_and, 2) as `年_非首付_and`,
    round(repay_year_not_first_ios * 1.0 / base_year_not_first_ios, 2) as `年_非首付_ios`,

    round(repay_month_first * 1.0 / base_month_first, 2) as `月_首付`,
    round(repay_month_not_first * 1.0 / base_month_not_first, 2) as `月_非首付`,
    round(repay_quarter_first * 1.0 / base_quarter_first, 2) as `季_首付`,
    round(repay_quarter_not_first * 1.0 / base_quarter_not_first, 2) as `季_非首付`,
    round(repay_half_first * 1.0 / base_half_first, 2) as `半年_首付`,
    round(repay_half_not_first * 1.0 / base_half_not_first, 2) as `半年_非首付`
  from user_agg

  union all

  select
    '续订收入基数' as `指标类型`,
    u.first_month as `续订基数发生月份`,

    r.revenue_year_first_and as `年_首付_and`,
    r.revenue_year_first_ios as `年_首付_ios`,
    r.revenue_year_not_first_and as `年_非首付_and`,
    r.revenue_year_not_first_ios as `年_非首付_ios`,

    r.revenue_month_first as `月_首付`,
    r.revenue_month_not_first as `月_非首付`,
    r.revenue_quarter_first as `季_首付`,
    r.revenue_quarter_not_first as `季_非首付`,
    r.revenue_half_first as `半年_首付`,
    r.revenue_half_not_first as `半年_非首付`
  from user_agg u
  left join revenue_agg r
    on u.first_month = r.first_month
)

select *
from final_result
order by
  case when `指标类型` = '续订率' then 1 else 2 end asc,
  `续订基数发生月份` asc;
