-- webob 新增订单销售额和订单数
-- 输出结构：数据类型 / 年月 / 各产品周期列
-- 数据类型：销售额 = sum(origin_money)，订单数 = count(distinct order_id)
-- 动态参数：${s_date}, ${e_date}, ${event_name}

with base_orders_raw as (
  select distinct
    e.order_id,
    e.date,
    e.product_id_all_product,
    coalesce(e.origin_money, 0) as origin_money,
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
    and e.all_product_order_type = '新增'
    and (
      e.purchase_entrance_all_product is null
      or e.purchase_entrance_all_product not in ('75','10042','30033','100040','50024')
    )
),
base_orders as (
  select
    order_id,
    date_trunc('month', date) as stat_month,
    origin_money,
    product_type_group,
    case
      when first_price = 0 and first_days = 7 and renew_days in (28, 30) then '0元7天-月'
      when first_price = 0 and first_days = 7 and renew_days in (84, 90) then '0元7天-季'
      when first_price = 0 and first_days in (28, 30) and renew_days in (28, 30) then '首月0元'
      when first_price > 0 and first_days = 7 and renew_days in (28, 30) then '7天-月_首付非0'
      when first_days = 14 and renew_days = 14 then '半月'
      when first_days in (28, 30) and renew_days in (28, 30) then '月'
      when first_days in (84, 90) and renew_days in (84, 90) then '季'
      when first_days = 168 and renew_days = 168 then '半年'
    end as period_group
  from base_orders_raw
  where product_type_group is not null
),
agg as (
  select
    stat_month,
    round(sum(case when product_type_group = '会员' and period_group = '7天-月_首付非0' then origin_money else 0 end), 2) as member_7d_month_nonzero_revenue,
    count(distinct case when product_type_group = '会员' and period_group = '7天-月_首付非0' then order_id end) as member_7d_month_nonzero_orders,
    round(sum(case when product_type_group = '会员' and period_group = '月' then origin_money else 0 end), 2) as member_month_revenue,
    count(distinct case when product_type_group = '会员' and period_group = '月' then order_id end) as member_month_orders,
    round(sum(case when product_type_group = '会员' and period_group = '季' then origin_money else 0 end), 2) as member_quarter_revenue,
    count(distinct case when product_type_group = '会员' and period_group = '季' then order_id end) as member_quarter_orders,
    round(sum(case when product_type_group = '会员' and period_group = '半月' then origin_money else 0 end), 2) as member_half_month_revenue,
    count(distinct case when product_type_group = '会员' and period_group = '半月' then order_id end) as member_half_month_orders,
    round(sum(case when product_type_group = '会员' and period_group = '半年' then origin_money else 0 end), 2) as member_half_year_revenue,
    count(distinct case when product_type_group = '会员' and period_group = '半年' then order_id end) as member_half_year_orders,
    round(sum(case when product_type_group = '一级增值' and period_group = '首月0元' then origin_money else 0 end), 2) as extra1_zero_month_revenue,
    count(distinct case when product_type_group = '一级增值' and period_group = '首月0元' then order_id end) as extra1_zero_month_orders,
    round(sum(case when product_type_group = '一级增值' and period_group = '月' then origin_money else 0 end), 2) as extra1_month_revenue,
    count(distinct case when product_type_group = '一级增值' and period_group = '月' then order_id end) as extra1_month_orders,
    round(sum(case when product_type_group = '一级增值' and period_group = '季' then origin_money else 0 end), 2) as extra1_quarter_revenue,
    count(distinct case when product_type_group = '一级增值' and period_group = '季' then order_id end) as extra1_quarter_orders,
    round(sum(case when product_type_group = '一级增值' and period_group = '0元7天-月' then origin_money else 0 end), 2) as extra1_zero_7d_month_revenue,
    count(distinct case when product_type_group = '一级增值' and period_group = '0元7天-月' then order_id end) as extra1_zero_7d_month_orders,
    round(sum(case when product_type_group = '一级增值' and period_group = '0元7天-季' then origin_money else 0 end), 2) as extra1_zero_7d_quarter_revenue,
    count(distinct case when product_type_group = '一级增值' and period_group = '0元7天-季' then order_id end) as extra1_zero_7d_quarter_orders,
    round(sum(case when product_type_group = '二级增值' and period_group = '月' then origin_money else 0 end), 2) as extra2_month_revenue,
    count(distinct case when product_type_group = '二级增值' and period_group = '月' then order_id end) as extra2_month_orders,
    round(sum(case when product_type_group = '二级增值' and period_group = '季' then origin_money else 0 end), 2) as extra2_quarter_revenue,
    count(distinct case when product_type_group = '二级增值' and period_group = '季' then order_id end) as extra2_quarter_orders
  from base_orders
  where period_group is not null
  group by stat_month
),
final_result as (
  select
    '销售额' as `数据类型`,
    stat_month as `年月`,
    member_7d_month_nonzero_revenue as `【会员】7天_月（首付非0）`,
    member_month_revenue as `【会员】月`,
    member_quarter_revenue as `【会员】季`,
    member_half_month_revenue as `【会员】半月（14d）`,
    member_half_year_revenue as `【会员】半年（168d）`,
    extra1_zero_month_revenue as `【一级增值】首月0元`,
    extra1_month_revenue as `【一级增值】月`,
    extra1_quarter_revenue as `【一级增值】季`,
    extra1_zero_7d_month_revenue as `【一级增值】7天_月（首付0元）`,
    extra1_zero_7d_quarter_revenue as `【一级增值】7天_季（首付0元）`,
    extra2_month_revenue as `【二级增值】月`,
    extra2_quarter_revenue as `【二级增值】季`
  from agg
  union all
  select
    '订单数' as `数据类型`,
    stat_month as `年月`,
    member_7d_month_nonzero_orders as `【会员】7天_月（首付非0）`,
    member_month_orders as `【会员】月`,
    member_quarter_orders as `【会员】季`,
    member_half_month_orders as `【会员】半月（14d）`,
    member_half_year_orders as `【会员】半年（168d）`,
    extra1_zero_month_orders as `【一级增值】首月0元`,
    extra1_month_orders as `【一级增值】月`,
    extra1_quarter_orders as `【一级增值】季`,
    extra1_zero_7d_month_orders as `【一级增值】7天_月（首付0元）`,
    extra1_zero_7d_quarter_orders as `【一级增值】7天_季（首付0元）`,
    extra2_month_orders as `【二级增值】月`,
    extra2_quarter_orders as `【二级增值】季`
  from agg
)
select *
from final_result
order by `年月` asc, `数据类型` desc;
