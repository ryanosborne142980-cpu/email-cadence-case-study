-- =====================================================================
-- Sep 2026 email test: control (8 emails) vs test (4 emails)
-- Every number in the results table comes from this file.
--
-- HOW TO RUN (SQL Server 2025, after sql/create_tables.sql)
--   1. Run STEP 0 once (it creates the helper function and views).
--   2. Run any later query on its own.
--   Or all at once: sqlcmd -S .\ROSBO_SQL -E -C -i sql\email_test_metrics.sql
-- =====================================================================

USE email_cadence_synth;
GO


-- =====================================================================
-- STEP 0. SETUP (run once)
-- =====================================================================

-- 0a. Stats helper: turns a z-score into a two-sided p-value.
--     SQL Server has no built-in for this. You don't need to read the math.
CREATE OR ALTER FUNCTION dbo.p_value(@z FLOAT) RETURNS FLOAT AS
BEGIN
    DECLARE @x FLOAT = ABS(@z) / SQRT(2.0);
    DECLARE @t FLOAT = 1 / (1 + 0.3275911 * @x);
    RETURN @t * (0.254829592 + @t * (-0.284496736 + @t * (1.421413741 + @t * (-1.453152027 + @t * 1.061405429))))
         * EXP(-@x * @x);
END;
GO

-- 0b. One row per prospect: its arm and what happened to it.
CREATE OR ALTER VIEW dbo.prospect_arm AS
SELECT
    p.candidate_id,
    CASE WHEN p.email_key % 2 = 0 THEN 'test_4' ELSE 'control_8' END AS arm,  -- even key = test
    p.fico_score,
    p.loan_amount,
    p.premium                                                AS current_premium,
    p.flow_type,
    p.utm_content,
    CASE WHEN p.utm_source IS NOT NULL   THEN 1 ELSE 0 END   AS is_engaged,   -- came to the site from an email
    CASE WHEN o.amp_lead_uid IS NOT NULL THEN 1 ELSE 0 END   AS is_opp,       -- opted in to agent contact
    CASE WHEN o.has_any_policy = 1       THEN 1 ELSE 0 END   AS is_sold,
    CASE WHEN o.has_any_policy = 1 THEN o.total_sold_premium ELSE 0 END AS sold_premium,
    CASE WHEN o.disposition_type IN ('pipeline', 'new_request', 'contact_attempt', 'pre_approval')
         THEN 1 ELSE 0 END                                   AS is_open,
    o.disposition_reason,
    o.sold_home_policy_premium
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY candidate_id ORDER BY candidate_id) AS dup
      FROM dbo.prospects) p                                  -- dedupe: 1 row per prospect
LEFT JOIN dbo.sales_opportunities o ON o.amp_lead_uid = p.amp_lead_uid
WHERE p.dup = 1;
GO

-- 0c. One row per arm with all the counts. Most queries below read this.
CREATE OR ALTER VIEW dbo.arm_summary AS
SELECT
    arm,
    COUNT(*)          AS prospects,
    SUM(is_engaged)   AS engaged,
    SUM(is_opp)       AS opps,
    SUM(is_sold)      AS sold,
    SUM(is_open)      AS open_opps,
    SUM(sold_premium) AS sold_premium
FROM dbo.prospect_arm
GROUP BY arm;
GO


-- =====================================================================
-- STEP 1. IS THE TEST SET UP CORRECTLY?
-- =====================================================================

-- 1a. Which emails did each arm come in from?
--     Expect: test only shows 01, 04, 05, 08 (proves the parity split).
SELECT arm, RIGHT(utm_content, 2) AS email_no, COUNT(*) AS prospects
FROM dbo.prospect_arm
WHERE utm_content LIKE '%[_][0-9][0-9]'   -- skips 2 rows where utm_content = 'undefined'
GROUP BY arm, RIGHT(utm_content, 2)
ORDER BY arm, email_no;

-- 1b. Did the list split ~50/50?  p_value > 0.05 = fine.
SELECT
    c.prospects                                                                            AS control,
    t.prospects                                                                            AS test,
    POWER(c.prospects - t.prospects, 2) / CAST(c.prospects + t.prospects AS FLOAT)         AS chi_sq,
    dbo.p_value((c.prospects - t.prospects) / SQRT(CAST(c.prospects + t.prospects AS FLOAT))) AS p_value
FROM dbo.arm_summary c, dbo.arm_summary t
WHERE c.arm = 'control_8' AND t.arm = 'test_4';

-- 1c. Do the arms look alike before the emails?  Expect near-identical values.
SELECT DISTINCT
    arm,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fico_score)      OVER (PARTITION BY arm) AS median_fico,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY loan_amount)     OVER (PARTITION BY arm) AS median_loan,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY current_premium) OVER (PARTITION BY arm) AS median_current_premium,
    ROUND(100.0 * AVG(CASE WHEN flow_type = 'savings' THEN 1.0 ELSE 0 END) OVER (PARTITION BY arm), 2) AS pct_savings_flow
FROM dbo.prospect_arm
ORDER BY arm;


-- =====================================================================
-- STEP 2. WHAT HAPPENED IN EACH ARM?  (the results table)
-- =====================================================================

SELECT
    arm,
    prospects,
    engaged,
    opps,
    sold,
    open_opps,
    ROUND(100.0 * engaged / prospects, 2)   AS engaged_pct,
    ROUND(100.0 * opps / prospects, 2)      AS opp_pct,
    ROUND(100.0 * sold / opps, 2)           AS close_rate_pct,
    ROUND(100.0 * sold / prospects, 3)      AS sold_per_prospect_pct,
    ROUND(sold_premium, 0)                  AS total_sold_premium,
    ROUND(sold_premium / prospects, 2)      AS premium_per_prospect,
    ROUND(sold_premium / sold, 0)           AS avg_premium_per_sale
FROM dbo.arm_summary
ORDER BY arm;


-- =====================================================================
-- STEP 3. ARE THE DIFFERENCES REAL?  (two-proportion z-tests)
--   p_value < 0.05 = significant.  CI = 95% range for test minus control.
-- =====================================================================

WITH c AS (SELECT * FROM dbo.arm_summary WHERE arm = 'control_8'),
     t AS (SELECT * FROM dbo.arm_summary WHERE arm = 'test_4'),
     -- one row per metric: hits and base for control (x_c of n_c) and test (x_t of n_t)
     metrics AS (
         SELECT 'engaged / prospect' AS metric, CAST(c.engaged AS FLOAT) AS x_c, CAST(c.prospects AS FLOAT) AS n_c,
                                                CAST(t.engaged AS FLOAT) AS x_t, CAST(t.prospects AS FLOAT) AS n_t FROM c, t
         UNION ALL SELECT 'opp / prospect',          c.opps,  c.prospects, t.opps,  t.prospects FROM c, t
         UNION ALL SELECT 'sold / opp (close rate)', c.sold,  c.opps,      t.sold,  t.opps      FROM c, t
         UNION ALL SELECT 'sold / prospect',         c.sold,  c.prospects, t.sold,  t.prospects FROM c, t
     ),
     rates AS (
         SELECT metric, n_c, n_t,
                x_c / n_c                 AS rate_c,
                x_t / n_t                 AS rate_t,
                (x_c + x_t) / (n_c + n_t) AS rate_both
         FROM metrics
     ),
     tests AS (
         SELECT metric, rate_c, rate_t,
                rate_t - rate_c                                                 AS diff,
                SQRT(rate_c * (1 - rate_c) / n_c + rate_t * (1 - rate_t) / n_t) AS se_for_ci,
                SQRT(rate_both * (1 - rate_both) * (1 / n_c + 1 / n_t))          AS se_for_z
         FROM rates
     )
SELECT
    metric,
    ROUND(100 * rate_c, 3)                     AS control_pct,
    ROUND(100 * rate_t, 3)                     AS test_pct,
    ROUND(100 * diff, 3)                       AS diff_pp,
    ROUND(100 * (rate_t / rate_c - 1), 1)      AS rel_change_pct,
    ROUND(100 * (diff - 1.96 * se_for_ci), 3)  AS ci_low_pp,
    ROUND(100 * (diff + 1.96 * se_for_ci), 3)  AS ci_high_pp,
    ROUND(diff / se_for_z, 2)                  AS z,
    ROUND(dbo.p_value(diff / se_for_z), 4)     AS p_value
FROM tests;


-- =====================================================================
-- STEP 4. IS THE DROP IN PREMIUM PER PROSPECT REAL?  (bootstrap)
--   Premium is mostly $0 with a few large sales, so a z-test doesn't fit.
--   Instead: resample each arm 1,000 times and look at the spread of
--   (test - control). The middle 95% is the CI. Observed diff is in STEP 2.
--
--   Poisson bootstrap: instead of drawing n prospects with replacement,
--   each prospect appears w ~ Poisson(1) times in a resample (the standard
--   large-n stand-in for it). Unsold prospects add $0 however often they
--   appear, so only sold prospects are resampled: ~300 rows x 1,000, not
--   90 million. Draws are seeded hashes, so every run gives the same bounds.
-- =====================================================================

WITH arm_n AS (           -- prospects per arm: the fixed resample size
         SELECT arm, prospects AS n FROM dbo.arm_summary
     ),
     draws AS (           -- 1,000 resamples: a uniform (0, 1) draw per sold prospect
         SELECT r.value AS rep, x.arm, x.sold_premium,
                (CAST(CAST(SUBSTRING(HASHBYTES('SHA2_256', CONCAT('seed42|', r.value, '|', x.candidate_id)), 1, 6)
                      AS BIGINT) AS FLOAT) + 0.5) / 281474976710656.0 AS u   -- 2^48
         FROM dbo.prospect_arm x CROSS JOIN GENERATE_SERIES(0, 999) r
         WHERE x.is_sold = 1
     ),
     weights AS (         -- times the prospect appears in the resample: Poisson(1) by inverse CDF
         SELECT rep, arm, sold_premium,
                CASE WHEN u < 0.36788 THEN 0 WHEN u < 0.73576 THEN 1 WHEN u < 0.91970 THEN 2
                     WHEN u < 0.98101 THEN 3 WHEN u < 0.99634 THEN 4 WHEN u < 0.99941 THEN 5
                     WHEN u < 0.99992 THEN 6 WHEN u < 0.99999 THEN 7 ELSE 8 END AS w
         FROM draws
     ),
     resample_means AS (  -- premium per prospect in each resample
         SELECT w.rep, w.arm, SUM(w.w * w.sold_premium) / MAX(a.n) AS prem_per_prospect
         FROM weights w
         JOIN arm_n a ON a.arm = w.arm
         GROUP BY w.rep, w.arm
     ),
     diffs AS (           -- test minus control, per resample
         SELECT t.rep, t.prem_per_prospect - c.prem_per_prospect AS diff
         FROM resample_means t
         JOIN resample_means c ON c.rep = t.rep
         WHERE t.arm = 'test_4' AND c.arm = 'control_8'
     )
SELECT DISTINCT
    ROUND(PERCENTILE_CONT(0.025) WITHIN GROUP (ORDER BY diff) OVER (), 2)  AS ci_low,
    ROUND(PERCENTILE_CONT(0.975) WITHIN GROUP (ORDER BY diff) OVER (), 2)  AS ci_high,
    ROUND(AVG(CASE WHEN diff >= 0 THEN 1.0 ELSE 0 END) OVER (), 4)        AS share_of_resamples_at_or_above_0
FROM diffs;


-- =====================================================================
-- STEP 5. WHY DID OPPORTUNITIES NOT BUY?  (loss reasons, % of arm's opps)
-- =====================================================================

SELECT
    arm,
    disposition_reason,
    COUNT(*)                                                               AS opps,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY arm), 1)     AS pct_of_arm_opps
FROM dbo.prospect_arm
WHERE is_opp = 1
GROUP BY arm, disposition_reason
ORDER BY arm, opps DESC;
