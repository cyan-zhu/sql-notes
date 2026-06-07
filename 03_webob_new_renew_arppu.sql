-- webob 新增 / 续订 ARPPU
-- ARPPU = sum(origin_money) / count(distinct order_id)
-- 动态参数：${s_date}, ${e_date}, ${event_name}
--
-- 续订口径：
-- 1. 只在所选 ${s_date} 至 ${e_date} 范围内寻找第一笔续订
-- 2. 同 event、同 user_id、同 product_id_all_product 只保留最早一笔续订
-- 3. 第一笔续订归入其实际发生月份；新增订单保留所选范围内的全部订单
-- 4. 不使用公共表表达式，兼容仅接受顶层 SELECT 的神策 SQL 查询入口

select
  order_type as `新增/续订`,
  stat_month as `年月`,
  member_7d_month_nonzero as `【会员】7天_月（首付非0）`,
  member_month as `【会员】月`,
  member_quarter as `【会员】季`,
  member_half_month as `【会员】半月（14d）`,
  member_half_year as `【会员】半年（168d）`,
  extra1_zero_month as `【一级增值】首月0元`,
  extra1_month as `【一级增值】月`,
  extra1_quarter as `【一级增值】季`,
  extra1_zero_7d_month as `【一级增值】7天_月（首付0元）`,
  extra1_zero_7d_quarter as `【一级增值】7天_季（首付0元）`,
  extra2_month as `【二级增值】月`,
  extra2_quarter as `【二级增值】季`
from (
  select
    order_type,
    stat_month,
    round(
      sum(case
        when product_type_group = '会员'
          and period_group = '7天-月_首付非0' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '会员'
          and period_group = '7天-月_首付非0' then order_id
      end),
      2
    ) as member_7d_month_nonzero,
    round(
      sum(case
        when product_type_group = '会员'
          and period_group = '月' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '会员'
          and period_group = '月' then order_id
      end),
      2
    ) as member_month,
    round(
      sum(case
        when product_type_group = '会员'
          and period_group = '季' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '会员'
          and period_group = '季' then order_id
      end),
      2
    ) as member_quarter,
    round(
      sum(case
        when product_type_group = '会员'
          and period_group = '半月' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '会员'
          and period_group = '半月' then order_id
      end),
      2
    ) as member_half_month,
    round(
      sum(case
        when product_type_group = '会员'
          and period_group = '半年' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '会员'
          and period_group = '半年' then order_id
      end),
      2
    ) as member_half_year,
    round(
      sum(case
        when product_type_group = '一级增值'
          and period_group = '首月0元' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '一级增值'
          and period_group = '首月0元' then order_id
      end),
      2
    ) as extra1_zero_month,
    round(
      sum(case
        when product_type_group = '一级增值'
          and period_group = '月' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '一级增值'
          and period_group = '月' then order_id
      end),
      2
    ) as extra1_month,
    round(
      sum(case
        when product_type_group = '一级增值'
          and period_group = '季' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '一级增值'
          and period_group = '季' then order_id
      end),
      2
    ) as extra1_quarter,
    round(
      sum(case
        when product_type_group = '一级增值'
          and period_group = '0元7天-月' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '一级增值'
          and period_group = '0元7天-月' then order_id
      end),
      2
    ) as extra1_zero_7d_month,
    round(
      sum(case
        when product_type_group = '一级增值'
          and period_group = '0元7天-季' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '一级增值'
          and period_group = '0元7天-季' then order_id
      end),
      2
    ) as extra1_zero_7d_quarter,
    round(
      sum(case
        when product_type_group = '二级增值'
          and period_group = '月' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '二级增值'
          and period_group = '月' then order_id
      end),
      2
    ) as extra2_month,
    round(
      sum(case
        when product_type_group = '二级增值'
          and period_group = '季' then origin_money
        else 0
      end) * 1.0
      / count(distinct case
        when product_type_group = '二级增值'
          and period_group = '季' then order_id
      end),
      2
    ) as extra2_quarter
  from (
    select
      order_id,
      all_product_order_type as order_type,
      date_trunc('month', date) as stat_month,
      origin_money,
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
        when first_days in (28, 30)
          and renew_days in (28, 30) then '月'
        when first_days in (84, 90)
          and renew_days in (84, 90) then '季'
        when first_days = 168 and renew_days = 168 then '半年'
      end as period_group
    from (
      select
        order_id,
        date,
        product_id_all_product,
        all_product_order_type,
        origin_money,
        case
          when webob_product_type_is_double_extra = '二级增值'
            then '二级增值'
          when webob_product_type_is_double_extra = '非二级增值'
            and webob_product_type = '增值' then '一级增值'
          when webob_product_type = '会员' then '会员'
        end as product_type_group,
        cast(
          regexp_extract(
            product_id_all_product,
            '([0-9]+\\.?[0-9]*)d([0-9]+)-([0-9]+\\.?[0-9]*)d([0-9]+)',
            1
          ) as double
        ) as first_price,
        cast(
          regexp_extract(
            product_id_all_product,
            '([0-9]+\\.?[0-9]*)d([0-9]+)-([0-9]+\\.?[0-9]*)d([0-9]+)',
            2
          ) as int
        ) as first_days,
        cast(
          regexp_extract(
            product_id_all_product,
            '([0-9]+\\.?[0-9]*)d([0-9]+)-([0-9]+\\.?[0-9]*)d([0-9]+)',
            4
          ) as int
        ) as renew_days
      from (
        select
          event,
          user_id,
          order_id,
          date,
          time,
          product_id_all_product,
          all_product_order_type,
          origin_money,
          webob_product_type_is_double_extra,
          webob_product_type
        from (
          select
            deduped.*,
            row_number() over (
              partition by
                event,
                user_id,
                product_id_all_product,
                all_product_order_type
              order by time asc, order_id asc
            ) as type_num
          from (
            select
              event,
              user_id,
              order_id,
              date,
              time,
              product_id_all_product,
              all_product_order_type,
              origin_money,
              webob_product_type_is_double_extra,
              webob_product_type
            from (
              select
                e.event,
                e.user_id,
                e.order_id,
                e.date,
                e.time,
                e.product_id_all_product,
                e.all_product_order_type,
                coalesce(e.origin_money, 0) as origin_money,
                e.webob_product_type_is_double_extra,
                e.webob_product_type,
                row_number() over (
                  partition by e.event, e.order_id
                  order by e.time asc
                ) as order_event_num
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
                  or e.purchase_entrance_all_product not in (
                    '75',
                    '10042',
                    '30033',
                    '100040',
                    '50024'
                  )
                )
            ) order_events
            where order_event_num = 1
          ) deduped
        ) ranked_orders
        where all_product_order_type = '新增'
          or (
            all_product_order_type = '续订'
            and type_num = 1
          )
      ) selected_orders
    ) classified_orders
    where product_type_group is not null
  ) base_orders
  where period_group is not null
  group by order_type, stat_month
) agg
order by
  case
    when order_type = '新增' then 1
    when order_type = '续订' then 2
    else 3
  end asc,
  stat_month asc;
