-- =====================================================================
-- Sep 2026 email test: control (8 emails) vs test (4 emails)
-- Source: the two raw CSVs in reference_docs/ only, as loaded by
-- sql/create_tables.sql (prospects, sales_opportunities). No other tables.
-- Arm rule (case brief p4, 1c): odd email_key = 8 emails, even = 4 emails.
-- Runs on SQL Server 2025. Run sql/create_tables.sql, then STEP 0, then any step.
-- =====================================================================

USE email_cadence_synth;
GO


-- =====================================================================
-- STEP 0. SETUP: one row per prospect with its arm and funnel outcome
-- =====================================================================

-- Two-sided p-value from a z-score (SQL Server has no normal CDF built in).
CREATE OR ALTER FUNCTION dbo.p_value(@z FLOAT) RETURNS FLOAT AS
BEGIN
    DECLARE @x FLOAT = ABS(@z) / SQRT(2.0);
    DECLARE @t FLOAT = 1 / (1 + 0.3275911 * @x);
    RETURN @t * (0.254829592 + @t * (-0.284496736 + @t * (1.421413741 + @t * (-1.453152027 + @t * 1.061405429))))
         * EXP(-@x * @x);
END;
GO

CREATE OR ALTER VIEW dbo.funnel AS
SELECT
    p.candidate_id,
    CASE p.email_key % 2 WHEN 1 THEN 'control_8' WHEN 0 THEN 'test_4' END AS arm,
    p.utm_content,
    CASE WHEN p.utm_source IS NOT NULL   THEN 1 ELSE 0 END AS visited,  -- reached landing page
    CASE WHEN p.amp_lead_uid IS NOT NULL THEN 1 ELSE 0 END AS opp,      -- consented to agent contact
    CASE WHEN o.has_any_policy = 1       THEN 1 ELSE 0 END AS sold,     -- bought any policy
    CASE WHEN o.has_any_policy = 1 THEN o.total_sold_premium ELSE 0 END AS premium
FROM dbo.prospects p
LEFT JOIN dbo.sales_opportunities o ON o.amp_lead_uid = p.amp_lead_uid;
GO


-- =====================================================================
-- STEP 1. DATA CHECKS: is the data clean enough to trust?
-- =====================================================================

-- 1a. Keys are unique, so the join cannot duplicate prospects.
--     Expect: 89,777 = 89,777 and 4,102 = 4,102.
SELECT 'prospects'            AS [file], COUNT(*) AS [rows], COUNT(DISTINCT candidate_id) AS unique_ids
FROM dbo.prospects
UNION ALL
SELECT 'sales_opportunities', COUNT(*), COUNT(DISTINCT amp_lead_uid)
FROM dbo.sales_opportunities;

-- 1b. Every prospect has an arm.  Expect: 0.
SELECT COUNT(*) AS prospects_without_arm FROM dbo.funnel WHERE arm IS NULL;

-- 1c. How well the two files match.
--     Expect: 1,859 prospect opps; 1,841 found in CRM; 18 not found (count as unsold);
--     2,261 CRM opps belong to no September prospect (out of scope).
SELECT
    (SELECT COUNT(*) FROM dbo.funnel WHERE opp = 1)                            AS prospect_opps,
    (SELECT COUNT(*) FROM dbo.prospects p
       JOIN dbo.sales_opportunities o ON o.amp_lead_uid = p.amp_lead_uid)      AS found_in_crm,
    (SELECT COUNT(*) FROM dbo.funnel WHERE opp = 1) -
    (SELECT COUNT(*) FROM dbo.prospects p
       JOIN dbo.sales_opportunities o ON o.amp_lead_uid = p.amp_lead_uid)      AS not_found_in_crm,
    (SELECT COUNT(*) FROM dbo.sales_opportunities
       WHERE amp_lead_uid NOT IN (SELECT amp_lead_uid FROM dbo.prospects
                                  WHERE amp_lead_uid IS NOT NULL))             AS crm_opps_not_in_cohort;


-- =====================================================================
-- STEP 2. WAS THE TEST RUN CORRECTLY?
-- =====================================================================

-- 2a. Split is ~50/50.  p_value > 0.05 means the gap is just chance.
WITH n AS (
    SELECT
        SUM(CASE WHEN arm = 'control_8' THEN 1 ELSE 0 END) AS control,
        SUM(CASE WHEN arm = 'test_4'    THEN 1 ELSE 0 END) AS test
    FROM dbo.funnel
)
SELECT control, test,
       ROUND(dbo.p_value((control - test) / SQRT(CAST(control + test AS FLOAT))), 3) AS p_value
FROM n;

-- 2b. Test arm only visited from emails 01, 04, 05, 08 (the 4 it was sent).
--     Expect: control shows 01-08; test shows only 01, 04, 05, 08.
SELECT arm, RIGHT(utm_content, 2) AS email_no, COUNT(*) AS visits
FROM dbo.funnel
WHERE utm_content LIKE '%\_0_' ESCAPE '\'
GROUP BY arm, RIGHT(utm_content, 2)
ORDER BY arm, email_no;


-- =====================================================================
-- STEP 3. RESULTS: the funnel by arm
-- =====================================================================

SELECT
    arm,
    COUNT(*)                                   AS prospects,
    SUM(visited)                               AS visited,
    SUM(opp)                                   AS opps,
    SUM(sold)                                  AS sold,
    ROUND(100.0 * AVG(1.0 * visited), 2)       AS visit_pct,
    ROUND(100.0 * AVG(1.0 * opp), 2)           AS opp_pct,
    ROUND(100.0 * AVG(1.0 * sold), 3)          AS sold_pct,
    ROUND(100.0 * SUM(sold) / SUM(opp), 1)     AS close_rate_pct,
    ROUND(SUM(premium), 0)                     AS sold_premium,
    ROUND(SUM(premium) / COUNT(*), 2)          AS premium_per_prospect
FROM dbo.funnel
GROUP BY arm
ORDER BY arm;


-- =====================================================================
-- STEP 4. IS THE DIFFERENCE REAL?  Two-proportion z-test, test minus control.
--   Headline metric: sold / prospect (everyone assigned counts).
--   p_value < 0.05 = significant.
-- =====================================================================

WITH counts AS (
    SELECT
        SUM(CASE WHEN arm = 'control_8' THEN 1.0 ELSE 0 END)    AS n_c,
        SUM(CASE WHEN arm = 'test_4'    THEN 1.0 ELSE 0 END)    AS n_t,
        SUM(CASE WHEN arm = 'control_8' THEN visited END)       AS visited_c,
        SUM(CASE WHEN arm = 'test_4'    THEN visited END)       AS visited_t,
        SUM(CASE WHEN arm = 'control_8' THEN opp END)           AS opp_c,
        SUM(CASE WHEN arm = 'test_4'    THEN opp END)           AS opp_t,
        SUM(CASE WHEN arm = 'control_8' THEN sold END)          AS sold_c,
        SUM(CASE WHEN arm = 'test_4'    THEN sold END)          AS sold_t
    FROM dbo.funnel
),
metrics AS (
    SELECT 'sold / prospect (headline)' AS metric, CAST(sold_c AS FLOAT) AS x_c, CAST(n_c AS FLOAT) AS n_c,
           CAST(sold_t AS FLOAT) AS x_t, CAST(n_t AS FLOAT) AS n_t FROM counts
    UNION ALL SELECT 'visited / prospect', visited_c, n_c, visited_t, n_t FROM counts
    UNION ALL SELECT 'opp / prospect',     opp_c,     n_c, opp_t,     n_t FROM counts
),
z AS (
    SELECT *,
        x_c / n_c AS rate_c,
        x_t / n_t AS rate_t,
        (x_t / n_t - x_c / n_c)
          / SQRT((x_c + x_t) / (n_c + n_t) * (1 - (x_c + x_t) / (n_c + n_t)) * (1 / n_c + 1 / n_t)) AS z
    FROM metrics
)
SELECT
    metric,
    ROUND(100 * rate_c, 3)                AS control_pct,
    ROUND(100 * rate_t, 3)                AS test_pct,
    ROUND(100 * (rate_t / rate_c - 1), 1) AS relative_change_pct,
    ROUND(z, 2)                           AS z,
    ROUND(dbo.p_value(z), 4)              AS p_value
FROM z;


-- =====================================================================
-- STEP 5. WHERE WAS THE LOSS?  Visits by email, per arm.
--   Emails 01/04/05/08 went to both arms; 02/03/06/07 went to control only.
--   If shared-email visits are similar, the loss comes from the 4 dropped emails.
-- =====================================================================

SELECT
    arm,
    SUM(CASE WHEN RIGHT(utm_content, 2) IN ('01', '04', '05', '08') THEN 1 ELSE 0 END) AS visits_shared_emails,
    SUM(CASE WHEN RIGHT(utm_content, 2) IN ('02', '03', '06', '07') THEN 1 ELSE 0 END) AS visits_control_only_emails
FROM dbo.funnel
GROUP BY arm
ORDER BY arm;
