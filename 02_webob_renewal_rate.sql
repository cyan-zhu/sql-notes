-- webob 多周期续订率 + 续订收入基数
-- 动态参数：
-- ${s_date}：漏斗开始日期
-- ${e_date}：漏斗结束日期
-- ${event_name}：健走 / 瑜伽 / 舞蹈 / 健身 / 拉伸
--
-- 口径：
-- 1. 只统计 product_id_all_product like '%webob%'
-- 2. all_product_order_type = '新增' 为首续，'续订' 为非首续
-- 3. 同用户、同 event、同 product_id_all_product 才算续订
-- 4. 新增和续订均保留全部基数订单，不限制同一用户同月只取最早一笔
-- 5. 7 天 SKU 的首续窗口为 35 天，非首续按续订周期计算
-- 6. 续订率按用户计算：同月同分组多笔基数订单中任一笔续订成功，该用户即成功
-- 7. 全局排除支付入口 75、10042、30033、100040、50024，适用于基数新增、基数续订和窗口期续订
-- 8. 月份归属和扫描范围使用 date，步骤先后和窗口期使用精确事件时间 time

with first_pay_raw as (
  select distinct
    e.event,
    case '${event_name}'
      when '健走' then '健走'
      when '瑜伽' then '瑜伽'
      when '舞蹈' then '舞蹈'
      when '健身' then '健身'
      when '拉伸' then '拉伸'
    end as event_cn,
    e.date,
    e.time,
    e.user_id as first_user_id,
    e.product_id_all_product,
    e.all_product_order_type as order_type,
    e.origin_money as first_origin_money,
    case
      when e.webob_product_type_is_double_extra = '二级增值' then '二级增值'
      when e.webob_product_type_is_double_extra = '非二级增值' and e.webob_product_type = '增值' then '一级增值'
      when e.webob_product_type = '会员' then '会员'
    end as product_type_group,
    cast(regexp_extract(e.product_id_all_product, '([0-9]+\\.?[0-9]*)d([0-9]+)-([0-9]+\\.?[0-9]*)d([0-9]+)', 1) as double) as first_price,
    cast(regexp_extract(e.product_id_all_product, '([0-9]+\\.?[0-9]*)d([0-9]+)-([0-9]+\\.?[0-9]*)d([0-9]+)', 2) as int) as first_days,
    cast(regexp_extract(e.product_id_all_product, '([0-9]+\\.?[0-9]*)d([0-9]+)-([0-9]+\\.?[0-9]*)d([0-9]+)', 4) as int) as renew_days
  from events e
  where e.event = case '${event_name}'
      when '健走' then 'purchase_vip_order_wup_h2o'
      when '瑜伽' then 'purchase_vip_order_h2o'
      when '舞蹈' then 'purchase_vip_order_df_h2o'
      when '健身' then 'purchase_vip_order_mm_h2o'
      when '拉伸' then 'purchase_vip_order_db_h2o'
      else '__unknown__'
    end
    and e.date >= '${s_date}'
    and e.date <= '${e_date}'
    and e.product_id_all_product like '%webob%'
    and e.product_is_subscribe = 1
    and e.all_product_order_type in ('新增', '续订')
    and (
      e.purchase_entrance_all_product is null
      or e.purchase_entrance_all_product not in ('75','10042','30033','100040','50024')
    )
),

first_pay as (
  select
    event,
    event_cn,
    date_trunc('month', date) as first_month,
    first_user_id,
    product_id_all_product,
    order_type,
    product_type_group,
    coalesce(first_origin_money, 0) as first_origin_money,
    time as first_time,
    case
      when first_price = 0 and first_days = 7 and renew_days in (28, 30) then '0元7天-月'
      when first_price = 0 and first_days = 7 and renew_days in (84, 90) then '0元7天-季度'
      when first_price = 0 and first_days in (28, 30) and renew_days in (28, 30) then '0元-月'
      when first_price > 0 and first_days = 7 and renew_days in (28, 30) then '7天-月'
      when first_days = 14 and renew_days = 14 then '半月'
      when first_days in (28, 30) and renew_days in (28, 30) then '月'
      when first_days in (84, 90) and renew_days in (84, 90) then '季度'
      when first_days = 168 and renew_days = 168 then '半年'
    end as product_period_type,
    case
      when order_type = '新增' then first_days
      when order_type = '续订' then renew_days
    end as window_days_raw
  from first_pay_raw
  where product_type_group is not null
),

first_pay_with_window as (
  select
    *,
    case
      when order_type = '新增' and window_days_raw = 7 then 35
      when window_days_raw = 14 then 17
      when window_days_raw in (28, 30) then 35
      when window_days_raw in (84, 90) then 99
      when window_days_raw = 168 then 190
    end as diff_days
  from first_pay
  where product_period_type is not null
    and window_days_raw is not null
),

base_pay as (
  select *
  from first_pay_with_window
),

first_keys as (
  select distinct
    event,
    first_user_id as user_id,
    product_id_all_product
  from base_pay
),

repay as (
  select distinct
    e.event,
    e.user_id,
    e.product_id_all_product,
    e.time as repay_time
  from events e
  join first_keys k
    on e.event = k.event
   and e.user_id = k.user_id
   and e.product_id_all_product = k.product_id_all_product
  where e.event = case '${event_name}'
      when '健走' then 'purchase_vip_order_wup_h2o'
      when '瑜伽' then 'purchase_vip_order_h2o'
      when '舞蹈' then 'purchase_vip_order_df_h2o'
      when '健身' then 'purchase_vip_order_mm_h2o'
      when '拉伸' then 'purchase_vip_order_db_h2o'
      else '__unknown__'
    end
    and e.date > '${s_date}'
    and e.date <= date_add('${e_date}', 190)
    and e.product_id_all_product like '%webob%'
    and e.product_is_subscribe = 1
    and e.all_product_order_type = '续订'
    and (
      e.purchase_entrance_all_product is null
      or e.purchase_entrance_all_product not in ('75','10042','30033','100040','50024')
    )
),

first_with_repay as (
  select
    f.event_cn,
    f.first_month,
    f.product_type_group,
    f.product_period_type,
    f.order_type,
    f.first_user_id,
    max(case when r.user_id is not null then 1 else 0 end) as has_repay
  from base_pay f
  left join repay r
    on f.event = r.event
   and f.first_user_id = r.user_id
   and f.product_id_all_product = r.product_id_all_product
   and r.repay_time > f.first_time
   and r.repay_time <= date_add(f.first_time, f.diff_days)
  group by
    f.event_cn,
    f.first_month,
    f.product_type_group,
    f.product_period_type,
    f.order_type,
    f.first_user_id
),

user_agg as (
  select
    event_cn,
    first_month,
    product_type_group,
    product_period_type,
    order_type,
    count(distinct first_user_id) as base_users,
    count(distinct case when has_repay = 1 then first_user_id end) as repay_users
  from first_with_repay
  group by event_cn, first_month, product_type_group, product_period_type, order_type
),

revenue_agg as (
  select
    event_cn,
    first_month,
    product_type_group,
    product_period_type,
    order_type,
    cast(round(sum(first_origin_money), 0) as bigint) as revenue_base
  from base_pay
  group by event_cn, first_month, product_type_group, product_period_type, order_type
),

metric_long as (
  select
    '续订率' as `指标类型`,
    event_cn as `项目`,
    first_month as `续订基数发生月份`,
    product_type_group as `产品类型`,
    product_period_type,
    case when order_type = '新增' then '首续' else '非首续' end as `是否首续`,
    case when base_users > 0 then round(repay_users * 1.0 / base_users, 4) end as metric_value
  from user_agg

  union all

  select
    '续订收入基数' as `指标类型`,
    event_cn as `项目`,
    first_month as `续订基数发生月份`,
    product_type_group as `产品类型`,
    product_period_type,
    case when order_type = '新增' then '首续' else '非首续' end as `是否首续`,
    revenue_base as metric_value
  from revenue_agg
)

select
  `指标类型`,
  `续订基数发生月份`,
  `是否首续`,
  max(case when `产品类型` = '会员' and product_period_type = '7天-月' then metric_value end) as `【会员】7天_月（首付非0）`,
  max(case when `产品类型` = '会员' and product_period_type = '月' then metric_value end) as `【会员】月`,
  max(case when `产品类型` = '会员' and product_period_type = '季度' then metric_value end) as `【会员】季`,
  max(case when `产品类型` = '会员' and product_period_type = '半月' then metric_value end) as `【会员】半月（14d）`,
  max(case when `产品类型` = '会员' and product_period_type = '半年' then metric_value end) as `【会员】半年（168d）`,
  max(case when `产品类型` = '一级增值' and product_period_type = '0元-月' then metric_value end) as `【一级增值】首月0元`,
  max(case when `产品类型` = '一级增值' and product_period_type = '月' then metric_value end) as `【一级增值】月`,
  max(case when `产品类型` = '一级增值' and product_period_type = '季度' then metric_value end) as `【一级增值】季`,
  max(case when `产品类型` = '一级增值' and product_period_type = '0元7天-月' then metric_value end) as `【一级增值】7天_月（首付0元）`,
  max(case when `产品类型` = '一级增值' and product_period_type = '0元7天-季度' then metric_value end) as `【一级增值】7天_季（首付0元）`,
  max(case when `产品类型` = '二级增值' and product_period_type = '月' then metric_value end) as `【二级增值】月`,
  max(case when `产品类型` = '二级增值' and product_period_type = '季度' then metric_value end) as `【二级增值】季`
from metric_long
group by `指标类型`, `续订基数发生月份`, `是否首续`
order by
  case when `指标类型` = '续订率' then 1 else 2 end asc,
  `续订基数发生月份` asc,
  case when `是否首续` = '首续' then 1 else 2 end asc;
