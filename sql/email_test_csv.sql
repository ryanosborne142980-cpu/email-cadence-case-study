-- =====================================================================
-- Dec 2018 email test: control (8 emails) vs test (4 emails)
-- Source: the two raw CSVs in reference_docs/ only. No other tables.
-- Arm rule (case brief p4, 1c): odd email_key = 8 emails, even = 4 emails.
-- Run from the repo root in DuckDB. Run STEP 0 first, then any step.
-- =====================================================================


-- =====================================================================
-- STEP 0. SETUP: one row per prospect with its arm and funnel outcome
-- =====================================================================

-- Two-sided p-value from a z-score (DuckDB has no normal CDF built in).
CREATE OR REPLACE TEMP MACRO p_value(z) AS
    (1 / (1 + 0.3275911 * abs(z) / sqrt(2)))
  * (0.254829592 + (1 / (1 + 0.3275911 * abs(z) / sqrt(2)))
  * (-0.284496736 + (1 / (1 + 0.3275911 * abs(z) / sqrt(2)))
  * (1.421413741 + (1 / (1 + 0.3275911 * abs(z) / sqrt(2)))
  * (-1.453152027 + (1 / (1 + 0.3275911 * abs(z) / sqrt(2))) * 1.061405429))))
  * exp(-(z * z) / 2);

CREATE OR REPLACE TEMP VIEW funnel AS
SELECT
    p.candidate_id,
    CASE email_key % 2 WHEN 1 THEN 'control_8' WHEN 0 THEN 'test_4' END AS arm,
    p.utm_content,
    p.utm_source IS NOT NULL                 AS visited,  -- reached landing page
    p.amp_lead_uid IS NOT NULL               AS opp,      -- consented to agent contact
    coalesce(o.has_any_policy, false)        AS sold,     -- bought any policy
    CASE WHEN o.has_any_policy THEN o.total_sold_premium ELSE 0 END AS premium
FROM 'reference_docs/prospects.csv' p
LEFT JOIN 'reference_docs/sales_opportunities.csv' o USING (amp_lead_uid);


-- =====================================================================
-- STEP 1. DATA CHECKS: is the data clean enough to trust?
-- =====================================================================

-- 1a. Keys are unique, so the join cannot duplicate prospects.
--     Expect: 89,777 = 89,777 and 4,102 = 4,102.
SELECT 'prospects'            AS file, count(*) AS rows, count(DISTINCT candidate_id) AS unique_ids
FROM 'reference_docs/prospects.csv'
UNION ALL
SELECT 'sales_opportunities', count(*), count(DISTINCT amp_lead_uid)
FROM 'reference_docs/sales_opportunities.csv';

-- 1b. Every prospect has an arm.  Expect: 0.
SELECT count(*) AS prospects_without_arm FROM funnel WHERE arm IS NULL;

-- 1c. How well the two files match.
--     Expect: 1,859 prospect opps; 1,841 found in CRM; 18 not found (count as unsold);
--     2,261 CRM opps belong to no December prospect (out of scope).
SELECT
    (SELECT count(*) FROM funnel WHERE opp)                                    AS prospect_opps,
    (SELECT count(*) FROM 'reference_docs/prospects.csv' p
       JOIN 'reference_docs/sales_opportunities.csv' o USING (amp_lead_uid))   AS found_in_crm,
    (SELECT count(*) FROM funnel WHERE opp) -
    (SELECT count(*) FROM 'reference_docs/prospects.csv' p
       JOIN 'reference_docs/sales_opportunities.csv' o USING (amp_lead_uid))   AS not_found_in_crm,
    (SELECT count(*) FROM 'reference_docs/sales_opportunities.csv'
       WHERE amp_lead_uid NOT IN (SELECT amp_lead_uid FROM 'reference_docs/prospects.csv'
                                  WHERE amp_lead_uid IS NOT NULL))             AS crm_opps_not_in_cohort;


-- =====================================================================
-- STEP 2. WAS THE TEST RUN CORRECTLY?
-- =====================================================================

-- 2a. Split is ~50/50.  p_value > 0.05 means the gap is just chance.
SELECT
    count(*) FILTER (WHERE arm = 'control_8') AS control,
    count(*) FILTER (WHERE arm = 'test_4')    AS test,
    round(p_value((control - test) / sqrt(control + test)), 3) AS p_value
FROM funnel;

-- 2b. Test arm only visited from emails 01, 04, 05, 08 (the 4 it was sent).
--     Expect: control shows 01-08; test shows only 01, 04, 05, 08.
SELECT arm, right(utm_content, 2) AS email_no, count(*) AS visits
FROM funnel
WHERE utm_content LIKE '%\_0_' ESCAPE '\'
GROUP BY arm, email_no
ORDER BY arm, email_no;


-- =====================================================================
-- STEP 3. RESULTS: the funnel by arm
-- =====================================================================

SELECT
    arm,
    count(*)                                   AS prospects,
    count(*) FILTER (WHERE visited)            AS visited,
    count(*) FILTER (WHERE opp)                AS opps,
    count(*) FILTER (WHERE sold)               AS sold,
    round(100 * avg(visited::INT), 2)          AS visit_pct,
    round(100 * avg(opp::INT), 2)              AS opp_pct,
    round(100 * avg(sold::INT), 3)             AS sold_pct,
    round(100 * count(*) FILTER (WHERE sold) / count(*) FILTER (WHERE opp), 1) AS close_rate_pct,
    round(sum(premium))                        AS sold_premium,
    round(sum(premium) / count(*), 2)          AS premium_per_prospect
FROM funnel
GROUP BY arm
ORDER BY arm;


-- =====================================================================
-- STEP 4. IS THE DIFFERENCE REAL?  Two-proportion z-test, test minus control.
--   Headline metric: sold / prospect (everyone assigned counts).
--   p_value < 0.05 = significant.
-- =====================================================================

WITH counts AS (
    SELECT
        count(*) FILTER (WHERE arm = 'control_8')               AS n_c,
        count(*) FILTER (WHERE arm = 'test_4')                  AS n_t,
        count(*) FILTER (WHERE arm = 'control_8' AND visited)   AS visited_c,
        count(*) FILTER (WHERE arm = 'test_4'    AND visited)   AS visited_t,
        count(*) FILTER (WHERE arm = 'control_8' AND opp)       AS opp_c,
        count(*) FILTER (WHERE arm = 'test_4'    AND opp)       AS opp_t,
        count(*) FILTER (WHERE arm = 'control_8' AND sold)      AS sold_c,
        count(*) FILTER (WHERE arm = 'test_4'    AND sold)      AS sold_t
    FROM funnel
),
metrics AS (
    SELECT 'sold / prospect (headline)' AS metric, sold_c AS x_c, n_c, sold_t AS x_t, n_t FROM counts
    UNION ALL SELECT 'visited / prospect', visited_c, n_c, visited_t, n_t FROM counts
    UNION ALL SELECT 'opp / prospect',     opp_c,     n_c, opp_t,     n_t FROM counts
),
z AS (
    SELECT *,
        x_c / n_c AS rate_c,
        x_t / n_t AS rate_t,
        (x_t / n_t - x_c / n_c)
          / sqrt((x_c + x_t) / (n_c + n_t) * (1 - (x_c + x_t) / (n_c + n_t)) * (1 / n_c + 1 / n_t)) AS z
    FROM metrics
)
SELECT
    metric,
    round(100 * rate_c, 3)               AS control_pct,
    round(100 * rate_t, 3)               AS test_pct,
    round(100 * (rate_t / rate_c - 1), 1) AS relative_change_pct,
    round(z, 2)                          AS z,
    round(p_value(z), 4)                 AS p_value
FROM z;


-- =====================================================================
-- STEP 5. WHERE WAS THE LOSS?  Visits by email, per arm.
--   Emails 01/04/05/08 went to both arms; 02/03/06/07 went to control only.
--   If shared-email visits are similar, the loss comes from the 4 dropped emails.
-- =====================================================================

SELECT
    arm,
    count(*) FILTER (WHERE right(utm_content, 2) IN ('01', '04', '05', '08')) AS visits_shared_emails,
    count(*) FILTER (WHERE right(utm_content, 2) IN ('02', '03', '06', '07')) AS visits_control_only_emails
FROM funnel
GROUP BY arm
ORDER BY arm;
