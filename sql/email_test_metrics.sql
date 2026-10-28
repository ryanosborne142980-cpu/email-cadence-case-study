-- =====================================================================
-- Dec 2018 email test: control (8 emails) vs test (4 emails)
-- Every number in the results table comes from this file.
--
-- HOW TO RUN (DuckDB extension in VS Code)
--   1. Select all of STEP 0 and press Ctrl+Enter. Do this once.
--   2. Click inside any later query and press Ctrl+Shift+Enter.
-- =====================================================================


-- =====================================================================
-- STEP 0. SETUP (run once)
-- =====================================================================

-- 0a. Stats helper: turns a z-score into a two-sided p-value.
--     DuckDB has no built-in for this. You don't need to read the math.
CREATE OR REPLACE MACRO erfc_poly(t, x) AS
  t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429)))) * exp(-x * x);
CREATE OR REPLACE MACRO p_value(z) AS
  erfc_poly(1 / (1 + 0.3275911 * abs(z) / sqrt(2)), abs(z) / sqrt(2));

-- 0b. One row per prospect: its arm and what happened to it.
CREATE OR REPLACE VIEW prospect_arm AS
SELECT
    p.candidate_id,
    CASE WHEN p.email_key % 2 = 0 THEN 'test_4' ELSE 'control_8' END AS arm,  -- even key = test
    p.fico_score,
    p.loan_amount,
    p.premium                                AS current_premium,
    p.flow_type,
    p.utm_content,
    p.utm_source IS NOT NULL                 AS is_engaged,   -- came to the site from an email
    o.amp_lead_uid IS NOT NULL               AS is_opp,       -- opted in to agent contact
    coalesce(o.has_any_policy, false)        AS is_sold,
    CASE WHEN o.has_any_policy THEN o.total_sold_premium ELSE 0 END AS sold_premium,
    o.disposition_type IN ('pipeline', 'new_request', 'contact_attempt', 'pre_approval') AS is_open,
    o.disposition_reason
FROM (SELECT DISTINCT ON (candidate_id) * FROM prospects) p   -- dedupe: 1 row per prospect
LEFT JOIN sales_opportunities o ON o.amp_lead_uid = p.amp_lead_uid;

-- 0c. One row per arm with all the counts. Most queries below read this.
CREATE OR REPLACE VIEW arm_summary AS
SELECT
    arm,
    count(*)                                 AS prospects,
    count(*) FILTER (WHERE is_engaged)       AS engaged,
    count(*) FILTER (WHERE is_opp)           AS opps,
    count(*) FILTER (WHERE is_sold)          AS sold,
    count(*) FILTER (WHERE is_open)          AS open_opps,
    sum(sold_premium)                        AS sold_premium
FROM prospect_arm
GROUP BY arm;


-- =====================================================================
-- STEP 1. IS THE TEST SET UP CORRECTLY?
-- =====================================================================

-- 1a. Which emails did each arm come in from?
--     Expect: test only shows 01, 04, 05, 08 (proves the parity split).
SELECT arm, right(utm_content, 2) AS email_no, count(*) AS prospects
FROM prospect_arm
WHERE regexp_full_match(utm_content, '.*_\d{2}')   -- skips 2 rows where utm_content = 'undefined'
GROUP BY arm, email_no
ORDER BY arm, email_no;

-- 1b. Did the list split ~50/50?  p_value > 0.05 = fine.
SELECT
    c.prospects                                                          AS control,
    t.prospects                                                          AS test,
    (c.prospects - t.prospects) ^ 2 / (c.prospects + t.prospects)        AS chi_sq,
    p_value((c.prospects - t.prospects) / sqrt(c.prospects + t.prospects)) AS p_value
FROM arm_summary c, arm_summary t
WHERE c.arm = 'control_8' AND t.arm = 'test_4';

-- 1c. Do the arms look alike before the emails?  Expect near-identical values.
SELECT
    arm,
    median(fico_score)                                   AS median_fico,
    median(loan_amount)                                  AS median_loan,
    median(current_premium)                              AS median_current_premium,
    round(100 * avg((flow_type = 'savings')::INT), 2)    AS pct_savings_flow
FROM prospect_arm
GROUP BY arm
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
    round(100 * engaged / prospects, 2)     AS engaged_pct,
    round(100 * opps / prospects, 2)        AS opp_pct,
    round(100 * sold / opps, 2)             AS close_rate_pct,
    round(100 * sold / prospects, 3)        AS sold_per_prospect_pct,
    round(sold_premium, 0)                  AS total_sold_premium,
    round(sold_premium / prospects, 2)      AS premium_per_prospect,
    round(sold_premium / sold, 0)           AS avg_premium_per_sale
FROM arm_summary
ORDER BY arm;


-- =====================================================================
-- STEP 3. ARE THE DIFFERENCES REAL?  (two-proportion z-tests)
--   p_value < 0.05 = significant.  CI = 95% range for test minus control.
-- =====================================================================

WITH c AS (SELECT * FROM arm_summary WHERE arm = 'control_8'),
     t AS (SELECT * FROM arm_summary WHERE arm = 'test_4'),
     -- one row per metric: hits and base for control (x_c of n_c) and test (x_t of n_t)
     metrics AS (
         SELECT 'engaged / prospect'      AS metric, c.engaged AS x_c, c.prospects AS n_c, t.engaged AS x_t, t.prospects AS n_t FROM c, t
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
                sqrt(rate_c * (1 - rate_c) / n_c + rate_t * (1 - rate_t) / n_t) AS se_for_ci,
                sqrt(rate_both * (1 - rate_both) * (1 / n_c + 1 / n_t))          AS se_for_z
         FROM rates
     )
SELECT
    metric,
    round(100 * rate_c, 3)                     AS control_pct,
    round(100 * rate_t, 3)                     AS test_pct,
    round(100 * diff, 3)                       AS diff_pp,
    round(100 * (rate_t / rate_c - 1), 1)      AS rel_change_pct,
    round(100 * (diff - 1.96 * se_for_ci), 3)  AS ci_low_pp,
    round(100 * (diff + 1.96 * se_for_ci), 3)  AS ci_high_pp,
    round(diff / se_for_z, 2)                  AS z,
    round(p_value(diff / se_for_z), 4)         AS p_value
FROM tests;


-- =====================================================================
-- STEP 4. IS THE DROP IN PREMIUM PER PROSPECT REAL?  (bootstrap)
--   Premium is mostly $0 with a few large sales, so a z-test doesn't fit.
--   Instead: resample each arm 1,000 times and look at the spread of
--   (test - control). The middle 95% is the CI. Observed diff is in STEP 2.
--   Run the setseed line first; bounds still move a few cents per run.
-- =====================================================================

SELECT setseed(0.42);

WITH numbered AS (        -- number each prospect within its arm
         SELECT arm, sold_premium,
                row_number() OVER (PARTITION BY arm ORDER BY candidate_id) AS rn,
                count(*)     OVER (PARTITION BY arm)                       AS n
         FROM prospect_arm
     ),
     picks AS (           -- 1,000 resamples: draw n random prospects (with replacement) per arm
         SELECT r.rep, x.arm, (floor(random() * x.n) + 1)::BIGINT AS rn
         FROM numbered x, range(1000) r(rep)
     ),
     resample_means AS (  -- premium per prospect in each resample
         SELECT p.rep, p.arm, avg(x.sold_premium) AS prem_per_prospect
         FROM picks p
         JOIN numbered x USING (arm, rn)
         GROUP BY p.rep, p.arm
     ),
     diffs AS (           -- test minus control, per resample
         SELECT t.rep, t.prem_per_prospect - c.prem_per_prospect AS diff
         FROM resample_means t
         JOIN resample_means c USING (rep)
         WHERE t.arm = 'test_4' AND c.arm = 'control_8'
     )
SELECT
    round(quantile_cont(diff, 0.025), 2)  AS ci_low,
    round(quantile_cont(diff, 0.975), 2)  AS ci_high,
    round(avg((diff >= 0)::INT), 4)       AS share_of_resamples_at_or_above_0
FROM diffs;


-- =====================================================================
-- STEP 5. WHY DID OPPORTUNITIES NOT BUY?  (loss reasons, % of arm's opps)
-- =====================================================================

SELECT
    arm,
    disposition_reason,
    count(*)                                                          AS opps,
    round(100 * count(*) / sum(count(*)) OVER (PARTITION BY arm), 1)  AS pct_of_arm_opps
FROM prospect_arm
WHERE is_opp
GROUP BY arm, disposition_reason
ORDER BY arm, opps DESC;






