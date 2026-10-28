-- Home-policy sales per 1,000 prospects. Needs STEP 0 of sql/email_test_metrics.sql.
USE email_cadence_synth;

SELECT arm,
       COUNT(*)                                                                   AS prospects,
       SUM(CASE WHEN COALESCE(sold_home_policy_premium, 0) > 0 THEN 1 ELSE 0 END) AS home_sales,   -- 165 / 122
       1000.0 * SUM(CASE WHEN COALESCE(sold_home_policy_premium, 0) > 0 THEN 1 ELSE 0 END) / COUNT(*) AS per_1000
FROM dbo.prospect_arm
GROUP BY arm;
