-- webob 注册当月销售额和订单数
-- 动态参数：
-- ${s_date}：支付事件开始日期
-- ${e_date}：支付事件结束日期
-- ${event_name}：健走 / 瑜伽 / 舞蹈 / 健身 / 拉伸
--
-- 口径：
-- 1. events.user_id = users.id
-- 2. 支付事件发生月份 = users.webob_uid_create_time 所在月份
-- 3. 月份按支付事件 e.date 归属，${s_date} / ${e_date} 也过滤支付事件日期
-- 4. 统计注册当月发生的全部 webob 支付，不限制新增/续订
-- 5. 事件侧先按 order_id 去重；销售额 = sum(origin_money)，订单数 = count(*)
-- 6. 只统计订阅商品，并排除支付入口 75、10042、30033、100040、50024
-- 7. webob_uid_create_time 为毫秒级 BIGINT，先除以 1000 再转 timestamp

with filtered_users as (
  select
    u.id,
    date_trunc(
      'month',
      cast(
        from_unixtime(cast(u.webob_uid_create_time / 1000 as bigint))
        as timestamp
      )
    ) as registration_month
  from users u
  where u.webob_uid_create_time is not null
    and u.webob_uid_create_time >= unix_timestamp(
      date_trunc('month', cast('${s_date}' as timestamp))
    ) * 1000
    and u.webob_uid_create_time < unix_timestamp(
      add_months(date_trunc('month', cast('${e_date}' as timestamp)), 1)
    ) * 1000
),

filtered_orders as (
  select
    e.order_id,
    max(e.date) as pay_date,
    max(e.product_id_all_product) as product_id_all_product,
    max(coalesce(e.origin_money, 0)) as origin_money,
    max(e.webob_product_type_is_double_extra) as webob_product_type_is_double_extra,
    max(e.webob_product_type) as webob_product_type,
    max(e.all_product_order_type) as order_type
  from events e
  join filtered_users u
    on e.user_id = u.id
   and e.time >= u.registration_month
   and e.time < add_months(u.registration_month, 1)
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
    and (
      e.purchase_entrance_all_product is null
      or e.purchase_entrance_all_product not in ('75', '10042', '30033', '100040', '50024')
    )
  group by e.order_id
),

registration_month_orders_raw as (
  select
    o.order_id,
    date_trunc('month', o.pay_date) as stat_month,
    o.pay_date,
    o.product_id_all_product,
    o.origin_money,
    o.order_type,
    case
      when o.webob_product_type_is_double_extra = '二级增值' then '二级增值'
      when o.webob_product_type_is_double_extra = '非二级增值'
        and o.webob_product_type = '增值' then '一级增值'
      when o.webob_product_type = '会员' then '会员'
    end as product_type_group,
    cast(
      regexp_extract(
        o.product_id_all_product,
        '([0-9]+\\.?[0-9]*)d([0-9]+)-([0-9]+\\.?[0-9]*)d([0-9]+)',
        1
      ) as double
    ) as first_price,
    cast(
      regexp_extract(
        o.product_id_all_product,
        '([0-9]+\\.?[0-9]*)d([0-9]+)-([0-9]+\\.?[0-9]*)d([0-9]+)',
        2
      ) as int
    ) as first_days,
    cast(
      regexp_extract(
        o.product_id_all_product,
        '([0-9]+\\.?[0-9]*)d([0-9]+)-([0-9]+\\.?[0-9]*)d([0-9]+)',
        4
      ) as int
    ) as renew_days
  from filtered_orders o
),

registration_month_orders as (
  select
    order_id,
    stat_month,
    pay_date,
    origin_money,
    order_type,
    product_type_group,
    case
      when first_price = 0
        and first_days = 7
        and renew_days in (28, 30) then '0元7天-月'
      when first_price = 0
        and first_days = 7
        and renew_days in (84, 90) then '0元7天-季'
      when first_price = 0
        and first_days in (28, 30)
        and renew_days in (28, 30) then '首月0元'
      when first_price > 0
        and first_days = 7
        and renew_days in (28, 30) then '7天-月_首付非0'
      when first_days = 14 and renew_days = 14 then '半月'
      when first_days in (28, 30) and renew_days in (28, 30) then '月'
      when first_days in (84, 90) and renew_days in (84, 90) then '季'
      when first_days = 168 and renew_days = 168 then '半年'
    end as period_group
  from registration_month_orders_raw
  where product_type_group is not null
),

product_agg as (
  select
    stat_month,
    product_type_group,
    period_group,
    round(sum(origin_money), 2) as revenue,
    count(*) as order_count
  from registration_month_orders
  where period_group is not null
  group by stat_month, product_type_group, period_group
),

new_order_agg as (
  select
    stat_month,
    round(sum(case
      when product_type_group = '会员'
        and period_group = '7天-月_首付非0'
        and order_type = '新增'
        then origin_money
      else 0
    end), 2) as member_7d_month_new_revenue,
    round(sum(case
      when product_type_group = '会员'
        and period_group = '半月'
        and order_type = '新增'
        then origin_money
      else 0
    end), 2) as member_half_month_new_revenue,
    sum(case
      when product_type_group = '一级增值'
        and period_group = '0元7天-月'
        and order_type = '新增'
        then 1
      else 0
    end) as extra1_zero_7d_month_new_orders,
    sum(case
      when product_type_group = '一级增值'
        and period_group = '0元7天-季'
        and order_type = '新增'
        then 1
      else 0
    end) as extra1_zero_7d_quarter_new_orders,
    round(sum(case
      when product_type_group = '会员'
        and period_group = '7天-月_首付非0'
        and order_type = '新增'
        and pay_date >= date_add(add_months(stat_month, 1), -7)
        then origin_money
      else 0
    end), 2) as member_7d_month_last_7d_new_revenue,
    round(sum(case
      when product_type_group = '会员'
        and period_group = '半月'
        and order_type = '新增'
        and pay_date >= date_add(add_months(stat_month, 1), -14)
        then origin_money
      else 0
    end), 2) as member_half_month_last_14d_new_revenue,
    sum(case
      when product_type_group = '一级增值'
        and period_group = '0元7天-月'
        and order_type = '新增'
        and pay_date >= date_add(add_months(stat_month, 1), -7)
        then 1
      else 0
    end) as extra1_zero_7d_month_last_7d_new_orders,
    sum(case
      when product_type_group = '一级增值'
        and period_group = '0元7天-季'
        and order_type = '新增'
        and pay_date >= date_add(add_months(stat_month, 1), -7)
        then 1
      else 0
    end) as extra1_zero_7d_quarter_last_7d_new_orders
  from registration_month_orders
  where period_group is not null
  group by stat_month
),

metric_long as (
  select
    '销售额' as metric_type,
    stat_month,
    product_type_group,
    period_group,
    revenue as metric_value
  from product_agg

  union all

  select
    '订单数' as metric_type,
    stat_month,
    product_type_group,
    period_group,
    order_count as metric_value
  from product_agg
)

select
  m.metric_type as `指标类型`,
  m.stat_month as `月份`,
  coalesce(max(case
    when product_type_group = '会员' and period_group = '7天-月_首付非0'
      then metric_value
  end), 0) as `【会员】7天_月（首付非0）`,
  coalesce(max(case
    when product_type_group = '会员' and period_group = '月'
      then metric_value
  end), 0) as `【会员】月`,
  coalesce(max(case
    when product_type_group = '会员' and period_group = '季'
      then metric_value
  end), 0) as `【会员】季`,
  coalesce(max(case
    when product_type_group = '会员' and period_group = '半月'
      then metric_value
  end), 0) as `【会员】半月（14d）`,
  coalesce(max(case
    when product_type_group = '会员' and period_group = '半年'
      then metric_value
  end), 0) as `【会员】半年（168d）`,
  coalesce(max(case
    when product_type_group = '一级增值' and period_group = '首月0元'
      then metric_value
  end), 0) as `【一级增值】首月0元`,
  coalesce(max(case
    when product_type_group = '一级增值' and period_group = '月'
      then metric_value
  end), 0) as `【一级增值】月`,
  coalesce(max(case
    when product_type_group = '一级增值' and period_group = '季'
      then metric_value
  end), 0) as `【一级增值】季`,
  coalesce(max(case
    when product_type_group = '一级增值' and period_group = '0元7天-月'
      then metric_value
  end), 0) as `【一级增值】7天_月（首付0元）`,
  coalesce(max(case
    when product_type_group = '一级增值' and period_group = '0元7天-季'
      then metric_value
  end), 0) as `【一级增值】7天_季（首付0元）`,
  coalesce(max(case
    when product_type_group = '二级增值' and period_group = '月'
      then metric_value
  end), 0) as `【二级增值】月`,
  coalesce(max(case
    when m.product_type_group = '二级增值' and m.period_group = '季'
      then metric_value
  end), 0) as `【二级增值】季`,
  case
    when m.metric_type = '销售额' then coalesce(n.member_7d_month_new_revenue, 0)
    else 0
  end as `【会员】7天_月（首付非0）-新增销售额`,
  case
    when m.metric_type = '销售额' then coalesce(n.member_half_month_new_revenue, 0)
    else 0
  end as `【会员】半月（14d）-新增销售额`,
  case
    when m.metric_type = '订单数' then coalesce(n.extra1_zero_7d_month_new_orders, 0)
    else 0
  end as `【一级增值】7天_月（首付0元）-新增订单数`,
  case
    when m.metric_type = '订单数' then coalesce(n.extra1_zero_7d_quarter_new_orders, 0)
    else 0
  end as `【一级增值】7天_季（首付0元）-新增订单数`,
  case
    when m.metric_type = '销售额' then coalesce(n.member_7d_month_last_7d_new_revenue, 0)
    else 0
  end as `【会员】7天_月（首付非0）-当月最后7天的新增销售额`,
  case
    when m.metric_type = '销售额' then coalesce(n.member_half_month_last_14d_new_revenue, 0)
    else 0
  end as `【会员】半月（14d）-新增销售额-当月最后14天的新增销售额`,
  case
    when m.metric_type = '订单数' then coalesce(n.extra1_zero_7d_month_last_7d_new_orders, 0)
    else 0
  end as `【一级增值】7天_月（首付0元）-当月最后7天的新增订单数`,
  case
    when m.metric_type = '订单数' then coalesce(n.extra1_zero_7d_quarter_last_7d_new_orders, 0)
    else 0
  end as `【一级增值】7天_季（首付0元）-当月最后7天的新增订单数`
from metric_long m
left join new_order_agg n
  on m.stat_month = n.stat_month
group by
  m.metric_type,
  m.stat_month,
  n.member_7d_month_new_revenue,
  n.member_half_month_new_revenue,
  n.extra1_zero_7d_month_new_orders,
  n.extra1_zero_7d_quarter_new_orders,
  n.member_7d_month_last_7d_new_revenue,
  n.member_half_month_last_14d_new_revenue,
  n.extra1_zero_7d_month_last_7d_new_orders,
  n.extra1_zero_7d_quarter_last_7d_new_orders
order by
  m.stat_month asc,
  case when m.metric_type = '销售额' then 1 else 2 end asc;
