-- 目的：
-- 这段 SQL 用来一次性计算某个业务 event 的多周期续订情况。
--
-- 输出两类指标：
-- 1. 续订率：续订人数 / 续订基数
-- 2. 续订基数：符合条件的首笔/基准订阅用户数
--
-- 动态参数：
-- ${s_date}：漏斗开始日期，比如 '2025-01-01'
-- ${e_date}：漏斗结束日期，比如 '2025-01-31'
-- ${event_name}：业务中文名，可填 健走 / 瑜伽 / 舞蹈 / 健身 / 拉伸
--
-- 注意：
-- 这里的“续订基数发生月份”，指的是基准订单发生的月份。
-- 比如用户在 2025-01-15 买了月订阅，那么这笔基准订单归到 2025-01-01 这个月。

with event_map as (

  -- 第一步：建立 event 和中文业务名的对应关系
  --
  -- 因为你想在动态输入框里输入中文，比如“健走”
  -- 但数据表里真正存的是 event，比如 purchase_vip_order_wup_h2o
  -- 所以这里先做一张小映射表。
  --
  -- 后面用 m.event_cn = '${event_name}' 来筛选你输入的业务。

  select 'purchase_vip_order_wup_h2o' as event, '健走' as event_cn
  union all select 'purchase_vip_order_h2o', '瑜伽'
  union all select 'purchase_vip_order_df_h2o', '舞蹈'
  union all select 'purchase_vip_order_mm_h2o', '健身'
  union all select 'purchase_vip_order_db_h2o', '拉伸'
),

base_events as (

  -- 第二步：从 events 大表里，先筛出“可能用得上的订单事件”
  --
  -- 这里同时包含：
  -- 1. 漏斗时间区间内的基准订单
  -- 2. 漏斗结束后最长 380 天内的续订订单
  --
  -- 为什么要取到 date_add('${e_date}', 380)？
  -- 因为年订阅的续订观察窗口最长，是 380 天。
  -- 比如漏斗结束日期是 2025-01-31，那么年订阅要观察到 2026-02-15 左右。
  --
  -- 这一步相当于先把大表 events 缩小成一张中间表，后面都从这里算。

  select distinct

    -- 原始支付事件名，比如 purchase_vip_order_h2o
    e.event,

    -- 中文业务名，比如 瑜伽
    m.event_cn,

    -- 订单发生日期
    e.date,

    -- 用户 ID
    e.user_id,

    -- 商品 ID，用来判断用户后面是不是买了同一个商品
    e.product_id_all_product,

    -- 是否首付：
    -- 1 = 首付
    -- 0 = 非首付
    e.is_first_purchase_withmoney,

    -- 设备类型：
    -- IOS / Android
    -- 年订阅会按这个字段拆 ios 和 and
    e.device_type,

    -- 判断商品属于哪个订阅周期
    --
    -- 这里通过商品 ID 的关键词来识别：
    -- 年 / 半年 / 季 / 月
    --
    -- regexp '(?i)...' 里的 (?i) 表示忽略大小写。
    case
      when e.product_id_all_product regexp '(?i)1_year|12_month|goldyear|yearly|auto\\.year|silveryear|365_day|d365|silveryearsale|salesyear' then '年'
      when e.product_id_all_product regexp '(?i)6_month|180_day|d180' then '半年'
      when e.product_id_all_product regexp '(?i)3_month|90_day|d90' then '季'
      when e.product_id_all_product regexp '(?i)1_month|monthly|goldmonth|auto\\.month|silvermonth|30_day|d30' then '月'
    end as period_type,

    -- 给每个订阅周期绑定自己的续订观察窗口
    --
    -- 年：380 天
    -- 半年：190 天
    -- 季度：100 天
    -- 月：40 天
    --
    -- 后面判断续订时，会用：
    -- 续订日期 <= 基准订单日期 + diff_days
    case
      when e.product_id_all_product regexp '(?i)1_year|12_month|goldyear|yearly|auto\\.year|silveryear|365_day|d365|silveryearsale|salesyear' then 380
      when e.product_id_all_product regexp '(?i)6_month|180_day|d180' then 190
      when e.product_id_all_product regexp '(?i)3_month|90_day|d90' then 100
      when e.product_id_all_product regexp '(?i)1_month|monthly|goldmonth|auto\\.month|silvermonth|30_day|d30' then 40
    end as diff_days

  from events e

  -- 把 events 表里的 event 和上面的 event_map 映射起来
  -- 这样就能通过中文 event_name 筛选具体业务。
  join event_map m
    on e.event = m.event

  where m.event_cn = '${event_name}'

    -- 这里不是只取 ${s_date} 到 ${e_date}
    -- 而是取到 ${e_date} 后 380 天。
    --
    -- 原因：
    -- 基准订单只看 ${s_date} 到 ${e_date}
    -- 但续订订单要往后看最多 380 天。
    and e.date >= '${s_date}'
    and e.date <= date_add('${e_date}', 380)

    -- 排除 web 相关商品，只保留 in-app 商品
    and e.product_id_all_product not like '%webob%'

    -- 只保留真实付费订单
    -- 金额大于 0，避免 0 元订单影响续订判断。
    and e.origin_money > 0

    -- 只保留订阅商品
    and e.product_is_subscribe = 1

    -- 排除测试或异常用户
    and e.distinct_id != '90451406'

    -- 只保留 IOS 和 Android
    -- 其他 device_type 不参与统计。
    and e.device_type in ('IOS', 'Android')
),

first_pay as (

  -- 第三步：从 base_events 里取出“续订基数”
  --
  -- 什么叫续订基数？
  -- 就是漏斗所选时间区间 ${s_date} 到 ${e_date} 内，
  -- 符合条件的订阅付费用户。
  --
  -- 后续续订率的分母，就是这里的人。

  select

    -- event 原样保留，后面要求“续订必须是同一个 event”
    event,

    -- 把订单日期转成“这个月的月初日期”
    --
    -- 举例：
    -- 2025-01-15 -> 2025-01-01
    -- 2025-01-31 -> 2025-01-01
    --
    -- 这样最后就可以按真实日期月份排序。
    date_trunc('month', date) as first_month,

    -- 基准用户 ID，也就是续订率分母里的用户
    user_id as first_user_id,

    -- 商品 ID
    -- 后面判断续订时，必须是同一个用户买同一个商品。
    product_id_all_product,

    -- 是否首付：
    -- 1 = 首付
    -- 0 = 非首付
    is_first_purchase_withmoney,

    -- 设备类型
    device_type,

    -- 基准订单日期
    -- 后面要用它判断续订是否发生在 diff_days 天内。
    date as first_date,

    -- 订阅周期：年 / 半年 / 季 / 月
    period_type,

    -- 该周期对应的续订观察窗口
    diff_days

  from base_events

  where date >= '${s_date}'
    and date <= '${e_date}'

    -- 只保留能识别出周期的商品
    -- 如果商品 ID 不符合年/月/季/半年任何规则，就不参与统计。
    and period_type is not null
),

repay as (

  -- 第四步：从 base_events 里取出“可能的续订订单”
  --
  -- 这里的数据范围比 first_pay 更长，
  -- 因为续订订单可能发生在漏斗结束日期之后。

  select

    -- event
    -- 后面会要求续订订单和基准订单是同一个 event。
    event,

    -- 用户 ID
    user_id,

    -- 商品 ID
    product_id_all_product,

    -- 续订订单日期
    date as repay_date

  from base_events

  where date >= '${s_date}'
    and date <= date_add('${e_date}', 380)
),

first_with_repay as (

  -- 第五步：判断每个基准用户是否发生续订
  --
  -- 这一步是整段 SQL 的核心。
  --
  -- 它会把 first_pay 里的每个基准用户，
  -- 去匹配 repay 里的后续订单。
  --
  -- 如果找到了符合条件的后续订单，has_repay = 1
  -- 如果没找到，has_repay = 0

  select

    -- 基准订单发生月份
    f.first_month,

    -- 基准用户
    f.first_user_id,

    -- 周期
    f.period_type,

    -- 是否首付
    f.is_first_purchase_withmoney,

    -- 设备类型
    f.device_type,

    -- 是否发生续订
    --
    -- 因为一个用户可能有多笔后续订单，
    -- 所以用 max()：
    -- 只要有一笔符合条件，就记为 1。
    max(case when r.user_id is not null then 1 else 0 end) as has_repay

  from first_pay f

  left join repay r

    -- 必须是同一个 event
    -- 这是你确认过的口径：续订必须发生在同一个支付事件下。
    on f.event = r.event

   -- 必须是同一个用户
   and f.first_user_id = r.user_id

   -- 必须是同一个商品
   -- 如果用户从月订阅换成年订阅，或者商品 ID 变了，这里不会算续订。
   and f.product_id_all_product = r.product_id_all_product

   -- 续订订单必须发生在基准订单之后
   -- 同一天不算续订。
   and r.repay_date > f.first_date

   -- 续订订单必须发生在该周期对应的观察窗口内
   --
   -- 月：基准日期后 40 天内
   -- 季：基准日期后 100 天内
   -- 半年：基准日期后 190 天内
   -- 年：基准日期后 380 天内
   and r.repay_date <= date_add(f.first_date, f.diff_days)

  -- 这里的 group by 是为了把多笔续订订单压成一个 has_repay 标记。
  --
  -- 举例：
  -- 用户 A 在 1 月买了基准订单，
  -- 后面 2 月、3 月都买了同商品。
  -- join 后可能出现多行。
  -- 但我们只关心“有没有续订”，所以最后压成一行 has_repay = 1。
  group by
    f.first_month,
    f.first_user_id,
    f.period_type,
    f.is_first_purchase_withmoney,
    f.device_type
),

agg as (

  -- 第六步：按月份聚合，算出每个指标的分母和分子
  --
  -- base_xxx 表示续订基数，也就是分母
  -- repay_xxx 表示续订人数，也就是分子
  --
  -- 最终：
  -- 续订率 = repay_xxx / base_xxx
  -- 续订基数 = base_xxx

  select

    -- 按基准订单发生月份聚合
    first_month,

    -- 年_首付_and 的续订基数
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 1 and device_type = 'Android' then first_user_id end) as base_year_first_and,

    -- 年_首付_ios 的续订基数
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 1 and device_type = 'IOS' then first_user_id end) as base_year_first_ios,

    -- 年_非首付_and 的续订基数
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 0 and device_type = 'Android' then first_user_id end) as base_year_not_first_and,

    -- 年_非首付_ios 的续订基数
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 0 and device_type = 'IOS' then first_user_id end) as base_year_not_first_ios,

    -- 月_首付 的续订基数
    -- 月、季、半年不拆 IOS / Android，所以这里不加 device_type 条件。
    count(distinct case when period_type = '月' and is_first_purchase_withmoney = 1 then first_user_id end) as base_month_first,

    -- 月_非首付 的续订基数
    count(distinct case when period_type = '月' and is_first_purchase_withmoney = 0 then first_user_id end) as base_month_not_first,

    -- 季_首付 的续订基数
    count(distinct case when period_type = '季' and is_first_purchase_withmoney = 1 then first_user_id end) as base_quarter_first,

    -- 季_非首付 的续订基数
    count(distinct case when period_type = '季' and is_first_purchase_withmoney = 0 then first_user_id end) as base_quarter_not_first,

    -- 半年_首付 的续订基数
    count(distinct case when period_type = '半年' and is_first_purchase_withmoney = 1 then first_user_id end) as base_half_first,

    -- 半年_非首付 的续订基数
    count(distinct case when period_type = '半年' and is_first_purchase_withmoney = 0 then first_user_id end) as base_half_not_first,

    -- 年_首付_and 的续订人数
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 1 and device_type = 'Android' and has_repay = 1 then first_user_id end) as repay_year_first_and,

    -- 年_首付_ios 的续订人数
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 1 and device_type = 'IOS' and has_repay = 1 then first_user_id end) as repay_year_first_ios,

    -- 年_非首付_and 的续订人数
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 0 and device_type = 'Android' and has_repay = 1 then first_user_id end) as repay_year_not_first_and,

    -- 年_非首付_ios 的续订人数
    count(distinct case when period_type = '年' and is_first_purchase_withmoney = 0 and device_type = 'IOS' and has_repay = 1 then first_user_id end) as repay_year_not_first_ios,

    -- 月_首付 的续订人数
    count(distinct case when period_type = '月' and is_first_purchase_withmoney = 1 and has_repay = 1 then first_user_id end) as repay_month_first,

    -- 月_非首付 的续订人数
    count(distinct case when period_type = '月' and is_first_purchase_withmoney = 0 and has_repay = 1 then first_user_id end) as repay_month_not_first,

    -- 季_首付 的续订人数
    count(distinct case when period_type = '季' and is_first_purchase_withmoney = 1 and has_repay = 1 then first_user_id end) as repay_quarter_first,

    -- 季_非首付 的续订人数
    count(distinct case when period_type = '季' and is_first_purchase_withmoney = 0 and has_repay = 1 then first_user_id end) as repay_quarter_not_first,

    -- 半年_首付 的续订人数
    count(distinct case when period_type = '半年' and is_first_purchase_withmoney = 1 and has_repay = 1 then first_user_id end) as repay_half_first,

    -- 半年_非首付 的续订人数
    count(distinct case when period_type = '半年' and is_first_purchase_withmoney = 0 and has_repay = 1 then first_user_id end) as repay_half_not_first

  from first_with_repay

  group by first_month
),

final_result as (

-- 第七步：输出第一类指标：续订率
--
-- 续订率 = 续订人数 / 续订基数
--
-- 比如：
-- 年_首付_and = repay_year_first_and / base_year_first_and
--
-- 这里用 round(..., 2) 保留 2 位小数，四舍五入。

select

  -- 用这个字段区分当前行是“续订率”
  '续订率' as `指标类型`,

  -- 月份，是真实日期类型的月初日期
  first_month as `续订基数发生月份`,

  -- 年_首付_and 续订率
  round(repay_year_first_and * 1.0 / base_year_first_and, 2) as `年_首付_and`,

  -- 年_首付_ios 续订率
  round(repay_year_first_ios * 1.0 / base_year_first_ios, 2) as `年_首付_ios`,

  -- 年_非首付_and 续订率
  round(repay_year_not_first_and * 1.0 / base_year_not_first_and, 2) as `年_非首付_and`,

  -- 年_非首付_ios 续订率
  round(repay_year_not_first_ios * 1.0 / base_year_not_first_ios, 2) as `年_非首付_ios`,

  -- 月_首付 续订率
  round(repay_month_first * 1.0 / base_month_first, 2) as `月_首付`,

  -- 月_非首付 续订率
  round(repay_month_not_first * 1.0 / base_month_not_first, 2) as `月_非首付`,

  -- 季_首付 续订率
  round(repay_quarter_first * 1.0 / base_quarter_first, 2) as `季_首付`,

  -- 季_非首付 续订率
  round(repay_quarter_not_first * 1.0 / base_quarter_not_first, 2) as `季_非首付`,

  -- 半年_首付 续订率
  round(repay_half_first * 1.0 / base_half_first, 2) as `半年_首付`,

  -- 半年_非首付 续订率
  round(repay_half_not_first * 1.0 / base_half_not_first, 2) as `半年_非首付`

from agg

union all

-- 第八步：输出第二类指标：续订基数
--
-- 这里不再做除法，直接输出 base_xxx。
-- base_xxx 来自 count(distinct ...)，本身就是整数。
--
-- 你后面如果想算续订人数：
-- 续订人数 = 续订基数 * 续订率

select

  -- 用这个字段区分当前行是“续订基数”
  '续订基数' as `指标类型`,

  -- 月份
  first_month as `续订基数发生月份`,

  -- 年_首付_and 续订基数
  base_year_first_and as `年_首付_and`,

  -- 年_首付_ios 续订基数
  base_year_first_ios as `年_首付_ios`,

  -- 年_非首付_and 续订基数
  base_year_not_first_and as `年_非首付_and`,

  -- 年_非首付_ios 续订基数
  base_year_not_first_ios as `年_非首付_ios`,

  -- 月_首付 续订基数
  base_month_first as `月_首付`,

  -- 月_非首付 续订基数
  base_month_not_first as `月_非首付`,

  -- 季_首付 续订基数
  base_quarter_first as `季_首付`,

  -- 季_非首付 续订基数
  base_quarter_not_first as `季_非首付`,

  -- 半年_首付 续订基数
  base_half_first as `半年_首付`,

  -- 半年_非首付 续订基数
  base_half_not_first as `半年_非首付`

from agg

)

-- 最后排序：
-- 先按指标类型排序，让“续订率”排在“续订基数”前面
-- 再按月份升序排列
select *
from final_result
order by
  case when `指标类型` = '续订率' then 1 else 2 end asc,
  `续订基数发生月份` asc;
