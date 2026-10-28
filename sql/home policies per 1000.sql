SELECT arm,
       count(*)                                   AS prospects,
       count(*) FILTER (WHERE bought_home)        AS home_sales,   -- 165 / 122
       1000.0 * count(*) FILTER (WHERE bought_home) / count(*) AS per_1000
FROM prospect_arm
GROUP BY arm;
-- bought_home = coalesce(o.sold_home_policy_premium, 0) > 0