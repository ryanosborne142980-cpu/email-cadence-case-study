-- =====================================================================
-- Synthetic data generator (SQL Server 2025)
-- Builds fake prospects and sales_opportunities for the Sep 2026 email
-- cadence test. Built only from aggregate counts and fitted distributions
-- of the original data; no original rows are used.
--
-- What is exact (so every funnel, z-test and premium result matches the deck):
--   arm sizes, the visited / opp / in-CRM / sold mix per arm, flow_type
--   per arm, last-visit email per arm, disposition counts per arm,
--   home-policy sales per arm, total sold premium per arm.
-- What is sampled (so medians, the bootstrap CI and loss-reason mix
--   outside the cohort move a little): FICO, loan, premium, property
--   fields, dates, states, agents, policy counts.
--
-- HOW TO RUN (from the repo root)
--   1. sqlcmd -S .\ROSBO_SQL -E -C -i sql\00_generate_synthetic.sql
--   2. bcp "SELECT line FROM email_cadence_synth.syn.prospects_csv ORDER BY ord" queryout reference_docs\prospects.csv -c -T -u -S .\ROSBO_SQL
--   3. bcp "SELECT line FROM email_cadence_synth.syn.sales_opportunities_csv ORDER BY ord" queryout reference_docs\sales_opportunities.csv -c -T -u -S .\ROSBO_SQL
--   Then run sql\create_tables.sql to load the CSVs, and the analysis scripts.
-- Same seed, same data on every run. Change the seed in syn.h for a new draw.
-- =====================================================================

IF DB_ID('email_cadence_synth') IS NULL CREATE DATABASE email_cadence_synth;
GO
USE email_cadence_synth;
GO
IF SCHEMA_ID('syn') IS NULL EXEC('CREATE SCHEMA syn');
GO


-- =====================================================================
-- STEP 0. RANDOM NUMBER HELPERS
--   RAND() repeats one value per query and NEWID() can't be reproduced,
--   so every random number is a hash of (seed, purpose, row key).
-- =====================================================================

-- SCHEMABINDING marks the helpers as pure (no data access), so SQL Server can
-- inline them. Bound functions can't be altered while others depend on them,
-- so drop them in dependency order and recreate.
DROP FUNCTION IF EXISTS syn.lead_uid, syn.z, syn.u, syn.h;
GO

-- 0a. Seeded hash: the only place the seed lives.
CREATE FUNCTION syn.h(@key VARCHAR(100)) RETURNS VARBINARY(32) WITH SCHEMABINDING AS
BEGIN
    RETURN HASHBYTES('SHA2_256', CONCAT('seed42|', @key));
END;
GO

-- 0b. Uniform in (0, 1).
CREATE FUNCTION syn.u(@key VARCHAR(100)) RETURNS FLOAT WITH SCHEMABINDING AS
BEGIN
    RETURN (CAST(CAST(SUBSTRING(syn.h(@key), 1, 6) AS BIGINT) AS FLOAT) + 0.5) / 281474976710656.0;  -- 2^48
END;
GO

-- 0c. Standard normal (Box-Muller).
CREATE FUNCTION syn.z(@key VARCHAR(100)) RETURNS FLOAT WITH SCHEMABINDING AS
BEGIN
    RETURN SQRT(-2 * LOG(syn.u(CONCAT(@key, '|a')))) * COS(2 * PI() * syn.u(CONCAT(@key, '|b')));
END;
GO

-- 0d. 24-char hex lead ID (joins prospects to opportunities).
CREATE FUNCTION syn.lead_uid(@key VARCHAR(100)) RETURNS CHAR(24) WITH SCHEMABINDING AS
BEGIN
    RETURN LOWER(LEFT(CONVERT(VARCHAR(64), syn.h(@key), 2), 24));
END;
GO


-- =====================================================================
-- STEP 1. TARGETS
--   quota  = exact counts. Rows are shuffled within grp and dealt out in order.
--   weight = sampling shares. Each row draws a value in proportion to w.
-- =====================================================================

DROP TABLE IF EXISTS syn.quota;
CREATE TABLE syn.quota (dim VARCHAR(20), grp CHAR(1), val VARCHAR(60), n INT);
INSERT syn.quota VALUES
-- Funnel cell per arm. val = visited | opp | in_crm | sold. 18 opps are missing from the CRM file.
('cell', 'C', '0000', 43183), ('cell', 'C', '0100', 6), ('cell', 'C', '0110', 119), ('cell', 'C', '0111', 47),
('cell', 'C', '1000',   955), ('cell', 'C', '1100', 4), ('cell', 'C', '1110', 714), ('cell', 'C', '1111', 130),
('cell', 'T', '0000', 43025), ('cell', 'T', '0100', 6), ('cell', 'T', '0110', 125), ('cell', 'T', '0111', 33),
('cell', 'T', '1000',   755), ('cell', 'T', '1100', 2), ('cell', 'T', '1110', 575), ('cell', 'T', '1111', 98),
-- Flow per arm.
('flow', 'C', 'all_funnel', 35372), ('flow', 'C', 'savings', 9786),
('flow', 'T', 'all_funnel', 34955), ('flow', 'T', 'savings', 9664),
-- Email of last visit, per arm. Test got only 01, 04, 05, 08. 'undefined' and '' (no utm_content) are real quirks.
('email', 'C', '01', 376), ('email', 'C', '02', 244), ('email', 'C', '03', 146), ('email', 'C', '04', 449),
('email', 'C', '05', 109), ('email', 'C', '06', 138), ('email', 'C', '07', 109), ('email', 'C', '08', 228),
('email', 'C', 'undefined', 1), ('email', 'C', '', 3),
('email', 'T', '01', 505), ('email', 'T', '04', 501), ('email', 'T', '05', 140), ('email', 'T', '08', 279),
('email', 'T', 'undefined', 1), ('email', 'T', '', 4),
-- Unsold opportunity outcomes. val = disposition_type | disposition_reason. X = opps outside the cohort.
('disp', 'C', 'lost|price', 290), ('disp', 'C', 'contact_attempt|', 182), ('disp', 'C', 'lost|not_interested', 106),
('disp', 'C', 'lost|contact_never_made', 98), ('disp', 'C', 'pipeline|', 55), ('disp', 'C', 'lost|contact_made_but_never_heard_from', 32),
('disp', 'C', 'lost|underwriting_other', 25), ('disp', 'C', 'lost|underwriting_claims', 17), ('disp', 'C', 'lost|other', 6),
('disp', 'C', 'lost|ko_questions', 5), ('disp', 'C', 'lost|duplicate_entry', 3), ('disp', 'C', 'lost|do_not_contact', 3),
('disp', 'C', 'lost|underwriting_coastal', 2), ('disp', 'C', 'lost|timing', 2), ('disp', 'C', 'lost|underwriting_age_of_home', 2),
('disp', 'C', 'lost|relationship_with_agent', 2), ('disp', 'C', 'lost|underwriting_rural', 1), ('disp', 'C', 'new_request|', 1),
('disp', 'C', 'lost|never_bought_a_home', 1),
('disp', 'T', 'lost|price', 250), ('disp', 'T', 'contact_attempt|', 130), ('disp', 'T', 'lost|not_interested', 100),
('disp', 'T', 'lost|contact_never_made', 76), ('disp', 'T', 'pipeline|', 42), ('disp', 'T', 'lost|underwriting_other', 33),
('disp', 'T', 'lost|contact_made_but_never_heard_from', 26), ('disp', 'T', 'lost|underwriting_claims', 12), ('disp', 'T', 'lost|other', 8),
('disp', 'T', 'lost|ko_questions', 5), ('disp', 'T', 'lost|underwriting_coastal', 5), ('disp', 'T', 'lost|underwriting_age_of_home', 4),
('disp', 'T', 'lost|do_not_contact', 2), ('disp', 'T', 'new_request|', 2), ('disp', 'T', 'lost|underwriting_rural', 1),
('disp', 'T', 'pre_approval|', 1), ('disp', 'T', 'lost|duplicate_entry', 1), ('disp', 'T', 'lost|not_in_state', 1),
('disp', 'T', 'lost|timing', 1),
('disp', 'X', 'contact_attempt|', 578), ('disp', 'X', 'lost|price', 546), ('disp', 'X', 'new_request|', 222),
('disp', 'X', 'lost|not_interested', 159), ('disp', 'X', 'pipeline|', 156), ('disp', 'X', 'lost|contact_never_made', 63),
('disp', 'X', 'lost|underwriting_other', 58), ('disp', 'X', 'lost|underwriting_claims', 44), ('disp', 'X', 'lost|contact_made_but_never_heard_from', 29),
('disp', 'X', 'lost|other', 13), ('disp', 'X', 'lost|underwriting_coastal', 11), ('disp', 'X', 'lost|do_not_contact', 9),
('disp', 'X', 'lost|ko_questions', 7), ('disp', 'X', 'lost|underwriting_age_of_home', 6), ('disp', 'X', 'lost|timing', 5),
('disp', 'X', 'lost|duplicate_entry', 5), ('disp', 'X', 'self_processed|', 3), ('disp', 'X', 'lost|unknown', 2),
('disp', 'X', 'lost|relationship_with_agent', 1), ('disp', 'X', 'lost|underwriting_rural', 1),
-- Sold opportunity outcomes. The 'lost' rows with a policy are real quirks.
('disp_sold', 'C', 'policy_sold|', 176), ('disp_sold', 'C', 'lost|price', 1),
('disp_sold', 'T', 'policy_sold|', 131),
('disp_sold', 'X', 'policy_sold|', 342), ('disp_sold', 'X', 'lost|do_not_contact', 1),
-- Sales that include a home policy.
('home', 'C', '1', 165), ('home', 'C', '0', 12),
('home', 'T', '1', 122), ('home', 'T', '0', 9),
('home', 'X', '1', 311), ('home', 'X', '0', 32),
-- Orphan opps (outside the cohort) that sold.
('orphan_sold', 'X', '1', 343), ('orphan_sold', 'X', '0', 1918),
-- Source | channel. I = in cohort, X = outside it.
('src', 'I', 'partner|email', 1470), ('src', 'I', 'partner_import|warm_transfer', 205), ('src', 'I', 'partner_import|inbound_call', 151),
('src', 'I', 'partner_import|email', 4), ('src', 'I', 'partner_import|outbound_call', 3), ('src', 'I', 'partner_import|undefined', 3),
('src', 'I', 'partner_import|cold_transfer', 2), ('src', 'I', 'partner_import|direct_mail', 2), ('src', 'I', 'partner_import|banner', 1),
('src', 'X', 'partner|email', 1655), ('src', 'X', 'partner_import|inbound_call', 200), ('src', 'X', 'partner_import|warm_transfer', 155),
('src', 'X', 'partner_agent|warm_transfer', 119), ('src', 'X', 'partner_agent|inbound_call', 84), ('src', 'X', 'Partner|direct_mail', 21),
('src', 'X', 'partner_agent|cold_transfer', 10), ('src', 'X', 'partner_import|outbound_call', 7), ('src', 'X', 'partner_import|email', 3),
('src', 'X', 'partner_agent|outbound_call', 2), ('src', 'X', 'partner_import|cold_transfer', 2), ('src', 'X', 'partner_import|undefined', 2),
('src', 'X', 'partner_agent|email', 1);

DROP TABLE IF EXISTS syn.weight;
CREATE TABLE syn.weight (dim VARCHAR(20), val VARCHAR(40), w FLOAT);
INSERT syn.weight VALUES
('property_type', 'single_family_detached', 70148), ('property_type', 'pud', 13829), ('property_type', 'duplex', 2552),
('property_type', 'townhouse', 1245), ('property_type', 'mobile_home', 894), ('property_type', 'triplex', 420),
('property_type', 'condominium', 275), ('property_type', 'four_plex', 251), ('property_type', 'other', 119), ('property_type', 'rowhome', 44),
('residency', 'primary_residence', 83828), ('residency', 'investment', 4410), ('residency', 'second_home', 1102), ('residency', 'unknown', 437),
('deductible', '1000', 22567), ('deductible', '500', 8645), ('deductible', '2500', 3220), ('deductible', '2000', 1406),
('deductible', '250', 1105), ('deductible', '1500', 1024), ('deductible', '5000', 862),
('pc_home', '1', 517), ('pc_home', '2', 77), ('pc_home', '3', 3), ('pc_home', '4', 1),
('pc_nohome', '1', 45), ('pc_nohome', '2', 5), ('pc_nohome', '3', 1), ('pc_nohome', '4', 1), ('pc_nohome', '5', 1),
('state', 'FL', 480), ('state', 'CA', 456), ('state', 'GA', 319), ('state', 'TX', 312), ('state', 'NY', 280),
('state', 'NJ', 181), ('state', 'MD', 147), ('state', 'AZ', 142), ('state', 'PA', 129), ('state', 'NC', 114),
('state', 'CO', 110), ('state', 'OH', 106), ('state', 'MA', 102), ('state', 'AL', 101), ('state', 'TN', 99),
('state', 'VA', 32), ('state', 'WA', 32), ('state', 'IL', 32), ('state', 'MI', 32), ('state', 'IN', 32), ('state', 'MO', 32),
('state', 'SC', 32), ('state', 'WI', 32), ('state', 'MN', 32), ('state', 'KY', 32), ('state', 'LA', 32), ('state', 'OK', 32),
('state', 'OR', 32), ('state', 'NV', 32), ('state', 'UT', 32), ('state', 'CT', 32), ('state', 'IA', 32), ('state', 'KS', 32),
('state', 'AR', 32), ('state', 'MS', 32), ('state', 'NM', 32), ('state', 'NE', 32), ('state', 'ID', 32), ('state', 'WV', 32),
('state', 'NH', 32), ('state', 'ME', 32), ('state', 'HI', 32), ('state', 'RI', 32), ('state', 'DE', 32), ('state', 'MT', 32),
('state', 'SD', 32), ('state', 'DC', 32);
GO

-- Row-number ranges for quotas, probability ranges for weights.
CREATE OR ALTER VIEW syn.quota_range AS
SELECT dim, grp, val,
       SUM(n) OVER (PARTITION BY dim, grp ORDER BY val ROWS UNBOUNDED PRECEDING) - n + 1 AS lo,
       SUM(n) OVER (PARTITION BY dim, grp ORDER BY val ROWS UNBOUNDED PRECEDING)         AS hi
FROM syn.quota;
GO
CREATE OR ALTER VIEW syn.weight_range AS
SELECT dim, val,
       (SUM(w) OVER (PARTITION BY dim ORDER BY val ROWS UNBOUNDED PRECEDING) - w) / SUM(w) OVER (PARTITION BY dim) AS lo,
        SUM(w) OVER (PARTITION BY dim ORDER BY val ROWS UNBOUNDED PRECEDING)      / SUM(w) OVER (PARTITION BY dim) AS hi
FROM syn.weight;
GO


-- =====================================================================
-- STEP 2. PROSPECTS
-- =====================================================================

-- 2a. Arm, funnel cell and flow for each of 89,777 prospects.
DROP TABLE IF EXISTS syn.prospect_cell;
WITH arm AS (
    SELECT value AS n,
           IIF(ROW_NUMBER() OVER (ORDER BY syn.u(CONCAT('arm|', value)), value) <= 45158, 'C', 'T') AS arm
    FROM GENERATE_SERIES(1, 89777)
),
ranked AS (
    SELECT n, arm,
           ROW_NUMBER() OVER (PARTITION BY arm ORDER BY syn.u(CONCAT('cell|', n)), n) AS cell_rn,
           ROW_NUMBER() OVER (PARTITION BY arm ORDER BY syn.u(CONCAT('flow|', n)), n) AS flow_rn
    FROM arm
)
SELECT r.n, r.arm,
       CAST(SUBSTRING(c.val, 1, 1) AS INT) AS visited,
       CAST(SUBSTRING(c.val, 2, 1) AS INT) AS opp,
       CAST(SUBSTRING(c.val, 3, 1) AS INT) AS in_crm,
       CAST(SUBSTRING(c.val, 4, 1) AS INT) AS sold,
       f.val AS flow_type
INTO syn.prospect_cell
FROM ranked r
JOIN syn.quota_range c ON c.dim = 'cell' AND c.grp = r.arm AND r.cell_rn BETWEEN c.lo AND c.hi
JOIN syn.quota_range f ON f.dim = 'flow' AND f.grp = r.arm AND r.flow_rn BETWEEN f.lo AND f.hi;

-- 2b. All prospect columns. Distribution parameters are fitted to the original data
--     (lognormal = mean and sd of ln(value)).
DROP TABLE IF EXISTS syn.prospect;
WITH v AS (
    SELECT p.*,
           ROW_NUMBER() OVER (PARTITION BY p.arm, p.visited ORDER BY syn.u(CONCAT('email|', p.n)), p.n) AS email_rn,
           -- savings prospects always have a current premium; 55% of all_funnel do
           IIF(p.flow_type = 'savings' OR syn.u(CONCAT('has_premium|', p.n)) < 38774.0 / 70327, 1, 0) AS has_premium,
           syn.u(CONCAT('property_type|', p.n)) AS u_property_type,
           syn.u(CONCAT('residency|', p.n))     AS u_residency,
           syn.u(CONCAT('deductible|', p.n))    AS u_deductible
    FROM syn.prospect_cell p
)
SELECT
    1000000 + v.n                                       AS candidate_id,
    3000000 + 2 * v.n + IIF(v.arm = 'C', 1, 0)          AS email_key,      -- odd = control (8 emails), even = test (4)
    IIF(syn.u(CONCAT('fico_null|', v.n)) < 4.0 / 89777, NULL,
        CAST(LEAST(850, GREATEST(350, ROUND(731.06 + 59.32 * syn.z(CONCAT('fico|', v.n)), 0))) AS INT)) AS fico_score,
    CAST(GREATEST(5000, ROUND(EXP(11.966 + 0.6705 * syn.z(CONCAT('loan|', v.n))), 0)) AS INT)         AS loan_amount,
    IIF(v.has_premium = 1,
        CAST(ROUND(EXP(6.934 + 0.5155 * syn.z(CONCAT('premium|', v.n))), 2) AS DECIMAL(10, 2)), NULL)  AS premium,
    IIF(v.has_premium = 1,
        DATEADD(DAY, CAST(syn.u(CONCAT('expiration|', v.n)) * 431 AS INT), CAST('2026-06-07' AS DATE)), NULL) AS expiration_date,
    IIF(v.has_premium = 1,
        CONCAT('{"deductible": ', ded.val, ', "dwelling_coverage": ',
               CAST(ROUND(EXP(12.455 + 0.5565 * syn.z(CONCAT('dwelling|', v.n))), -3) AS BIGINT), '}'),
        '{"deductible": null, "dwelling_coverage": null}')                                          AS coverages,
    pt.val                                              AS property_type,
    res.val                                             AS residency_type,
    IIF(syn.u(CONCAT('year_built_null|', v.n)) < 7832.0 / 89777, NULL,
        CAST(LEAST(2026, GREATEST(1900, ROUND(1974 + 30 * syn.z(CONCAT('year_built|', v.n)), 0))) AS INT)) AS year_built,
    IIF(syn.u(CONCAT('purchase_null|', v.n)) < 26215.0 / 89777, NULL,
        LEAST(CAST('2026-08-31' AS DATE),
              DATEADD(DAY, CAST(syn.u(CONCAT('purchase_day|', v.n)) * 365 AS INT),
                      DATEFROMPARTS(CAST(LEAST(2026, GREATEST(1989, ROUND(2015 + 6 * syn.z(CONCAT('purchase_year|', v.n)), 0))) AS INT), 1, 1)))) AS purchase_date,
    IIF(syn.u(CONCAT('sqft_null|', v.n)) < 6125.0 / 89777, NULL,
        CAST(ROUND(EXP(7.4297 + 0.3973 * syn.z(CONCAT('sqft|', v.n))), 0) AS INT))                    AS square_feet,
    CAST(NULL AS VARCHAR(2))                            AS state,          -- empty in the original too
    CAST(NULL AS VARCHAR(5))                            AS zip,
    IIF(v.visited = 1, 'servicing', NULL)               AS utm_source,
    CASE WHEN v.visited = 0 OR em.val = '' THEN NULL
         WHEN em.val = 'undefined'          THEN 'undefined'
         ELSE CONCAT('3P_EM_',
                     CASE WHEN v.flow_type = 'savings' THEN 'PS' WHEN v.has_premium = 1 THEN 'AFP' ELSE 'AFNP' END,
                     '_0926_INS_', em.val)
    END                                                 AS utm_content,
    CASE WHEN v.visited = 0              THEN NULL
         WHEN v.flow_type = 'savings'    THEN 'sav082826'
         WHEN v.has_premium = 1          THEN 'allfpi082826'
         ELSE 'allfnpi082826'
    END                                                 AS utm_campaign,
    CAST(NULL AS VARCHAR(20))                           AS utm_medium,
    IIF(v.opp = 1, syn.lead_uid(CONCAT('lead|', v.n)), NULL) AS amp_lead_uid,
    v.flow_type,
    v.n, v.arm, v.in_crm, v.sold                        -- used to build opportunities; not exported
INTO syn.prospect
FROM v
LEFT JOIN syn.quota_range em  ON em.dim = 'email' AND em.grp = v.arm AND v.visited = 1 AND v.email_rn BETWEEN em.lo AND em.hi
JOIN syn.weight_range     pt  ON pt.dim  = 'property_type' AND v.u_property_type >= pt.lo  AND v.u_property_type < pt.hi
JOIN syn.weight_range     res ON res.dim = 'residency'     AND v.u_residency     >= res.lo AND v.u_residency     < res.hi
JOIN syn.weight_range     ded ON ded.dim = 'deductible'    AND v.u_deductible    >= ded.lo AND v.u_deductible    < ded.hi;


-- =====================================================================
-- STEP 3. SALES OPPORTUNITIES
-- =====================================================================

-- 3a. One row per opportunity: prospect opps found in the CRM, plus 2,261 orphans.
DROP TABLE IF EXISTS syn.opp_base;
WITH orphan AS (
    SELECT value AS n, ROW_NUMBER() OVER (ORDER BY syn.u(CONCAT('orphan_sold|', value)), value) AS sold_rn
    FROM GENERATE_SERIES(1, 2261)
)
SELECT amp_lead_uid, arm AS grp, sold, CONCAT('in|', n) AS k
INTO syn.opp_base
FROM syn.prospect
WHERE in_crm = 1
UNION ALL
SELECT syn.lead_uid(CONCAT('orphan|', o.n)), 'X', CAST(q.val AS INT), CONCAT('orphan|', o.n)
FROM orphan o
JOIN syn.quota_range q ON q.dim = 'orphan_sold' AND o.sold_rn BETWEEN q.lo AND q.hi;

-- 3b. Disposition, source / channel and home policy (exact counts).
DROP TABLE IF EXISTS syn.opp_outcome;
WITH r AS (
    SELECT b.*,
           IIF(b.grp = 'X', 'X', 'I') AS src_grp,
           ROW_NUMBER() OVER (PARTITION BY b.grp, b.sold           ORDER BY syn.u(CONCAT('disp|', b.k)), b.k) AS disp_rn,
           ROW_NUMBER() OVER (PARTITION BY IIF(b.grp = 'X', 'X', 'I') ORDER BY syn.u(CONCAT('src|', b.k)), b.k)  AS src_rn,
           ROW_NUMBER() OVER (PARTITION BY b.grp, b.sold           ORDER BY syn.u(CONCAT('home|', b.k)), b.k) AS home_rn
    FROM syn.opp_base b
)
SELECT r.amp_lead_uid, r.grp, r.sold, r.k,
       -- CONCAT(val, '|'): SQL Server may evaluate these on other dims' rows (no '|') before the join filters them
       LEFT(d.val, CHARINDEX('|', CONCAT(d.val, '|')) - 1)                       AS disposition_type,
       NULLIF(SUBSTRING(d.val, CHARINDEX('|', CONCAT(d.val, '|')) + 1, 60), '')  AS disposition_reason,
       LEFT(s.val, CHARINDEX('|', CONCAT(s.val, '|')) - 1)                       AS source,
       SUBSTRING(s.val, CHARINDEX('|', CONCAT(s.val, '|')) + 1, 60)              AS marketing_channel,
       IIF(h.val = '1', 1, 0)                                          AS home
INTO syn.opp_outcome
FROM r
JOIN syn.quota_range d      ON d.dim = IIF(r.sold = 1, 'disp_sold', 'disp') AND d.grp = r.grp AND r.disp_rn BETWEEN d.lo AND d.hi
JOIN syn.quota_range s      ON s.dim = 'src' AND s.grp = r.src_grp AND r.src_rn BETWEEN s.lo AND s.hi
LEFT JOIN syn.quota_range h ON h.dim = 'home' AND h.grp = r.grp AND r.sold = 1 AND r.home_rn BETWEEN h.lo AND h.hi;

-- 3c. Premiums. Each arm's sold premium is scaled to its exact original total,
--     and the last sale in each arm absorbs the rounding cents.
DROP TABLE IF EXISTS syn.opp_premium;
WITH target AS (
    SELECT * FROM (VALUES ('C', 238628.49), ('T', 177865.58)) t(grp, total)
),
raw AS (
    SELECT o.k, o.grp, EXP(7.045 + 0.538 * syn.z(CONCAT('sold_premium|', o.k))) AS raw_premium,
           ROW_NUMBER() OVER (PARTITION BY o.grp ORDER BY o.k DESC) AS rn_last
    FROM syn.opp_outcome o
    WHERE o.sold = 1
),
scaled AS (
    SELECT raw.k, raw.grp, raw.rn_last, t.total,
           CAST(ROUND(raw.raw_premium * COALESCE(t.total / SUM(raw.raw_premium) OVER (PARTITION BY raw.grp), 1), 2) AS DECIMAL(10, 2)) AS premium
    FROM raw
    LEFT JOIN target t ON t.grp = raw.grp
)
SELECT k,
       premium + IIF(rn_last = 1 AND total IS NOT NULL, total - SUM(premium) OVER (PARTITION BY grp), 0) AS total_sold_premium
INTO syn.opp_premium
FROM scaled;

-- 3d. All opportunity columns.
DROP TABLE IF EXISTS syn.opportunity;
WITH v AS (
    SELECT o.*, p.total_sold_premium,
           DATEADD(MINUTE, CAST(syn.u(CONCAT('created|', o.k)) * 70135 AS INT), CAST('2026-09-01T02:40:00' AS DATETIME2(0))) AS created,
           syn.u(CONCAT('state|', o.k))        AS u_state,
           syn.u(CONCAT('policy_count|', o.k)) AS u_policy_count
    FROM syn.opp_outcome o
    LEFT JOIN syn.opp_premium p ON p.k = o.k
)
SELECT
    v.amp_lead_uid,
    st.val                                                        AS property_state,
    RIGHT(CONCAT('0000', CAST(syn.u(CONCAT('zip|', v.k)) * 99999 AS INT)), 5) AS property_zip,  -- random, not tied to state
    v.created                                                     AS opportunity_create_date,
    v.source,
    v.marketing_channel,
    IIF(v.sold = 1, 'TRUE', 'FALSE')                              AS has_any_policy,
    IIF(v.sold = 1, CAST(pc.val AS INT), 0)                       AS policy_count,
    CONCAT('agent_', RIGHT(CONCAT('0', 1 + CAST(syn.u(CONCAT('agent|', v.k)) * 15 AS INT)), 2)) AS agent_login,
    v.disposition_type,
    v.disposition_reason,
    IIF(v.sold = 1,
        LEAST(CAST('2026-10-19' AS DATE),
              CAST(DATEADD(DAY, CAST(-LOG(syn.u(CONCAT('sale_lag|', v.k))) * 3.3 AS INT), v.created) AS DATE)), NULL) AS policy_sale_date,
    IIF(syn.u(CONCAT('prev_null|', v.k)) < IIF(v.sold = 1, 142.0 / 651, 907.0 / 3451), NULL,
        CAST(ROUND(EXP(IIF(v.sold = 1, 7.221, 7.004) + IIF(v.sold = 1, 0.498, 0.515) * syn.z(CONCAT('prev_premium|', v.k))), 0) AS INT)) AS prev_policy_premium,
    CASE WHEN v.home = 0 THEN NULL
         WHEN pc.val = '1' THEN v.total_sold_premium
         ELSE CAST(ROUND(v.total_sold_premium * 0.8, 2) AS DECIMAL(10, 2))   -- multi-policy: home is most of it
    END                                                           AS sold_home_policy_premium,
    COALESCE(v.total_sold_premium, 0)                             AS total_sold_premium,
    v.k
INTO syn.opportunity
FROM v
JOIN syn.weight_range st      ON st.dim = 'state' AND v.u_state >= st.lo AND v.u_state < st.hi
LEFT JOIN syn.weight_range pc ON pc.dim = IIF(v.home = 1, 'pc_home', 'pc_nohome') AND v.sold = 1
                             AND v.u_policy_count >= pc.lo AND v.u_policy_count < pc.hi;
GO


-- =====================================================================
-- STEP 4. CSV VIEWS (read by bcp; one text line per row, header first)
--   bcp does not quote fields, so the views build the CSV text themselves.
-- =====================================================================

CREATE OR ALTER VIEW syn.prospects_csv AS
SELECT 0 AS ord,
       'candidate_id,email_key,fico_score,loan_amount,premium,expiration_date,coverages,property_type,residency_type,year_built,purchase_date,square_feet,state,zip,utm_source,utm_content,utm_campaign,utm_medium,amp_lead_uid,flow_type' AS line
UNION ALL
SELECT ROW_NUMBER() OVER (ORDER BY syn.u(CONCAT('prospect_row|', n)), n),
       CONCAT(candidate_id, ',', email_key, ',', fico_score, ',', loan_amount, ',', premium, ',',
              FORMAT(expiration_date, 'M/d/yyyy', 'en-US'), ',',
              '"', REPLACE(coverages, '"', '""'), '"', ',',
              property_type, ',', residency_type, ',', year_built, ',',
              FORMAT(purchase_date, 'M/d/yyyy', 'en-US'), ',',
              square_feet, ',', state, ',', zip, ',', utm_source, ',', utm_content, ',', utm_campaign, ',',
              utm_medium, ',', amp_lead_uid, ',', flow_type)
FROM syn.prospect;
GO

CREATE OR ALTER VIEW syn.sales_opportunities_csv AS
SELECT 0 AS ord,
       'amp_lead_uid,property_state,property_zip,opportunity_create_date,source,marketing_channel,has_any_policy,policy_count,agent_login,disposition_type,disposition_reason,policy_sale_date,prev_policy_premium,sold_home_policy_premium,total_sold_premium' AS line
UNION ALL
SELECT ROW_NUMBER() OVER (ORDER BY syn.u(CONCAT('opp_row|', k)), k),
       CONCAT(amp_lead_uid, ',', property_state, ',', property_zip, ',',
              FORMAT(opportunity_create_date, 'M/d/yyyy H:mm', 'en-US'), ',',
              source, ',', marketing_channel, ',', has_any_policy, ',', policy_count, ',', agent_login, ',',
              disposition_type, ',', disposition_reason, ',',
              FORMAT(policy_sale_date, 'M/d/yyyy', 'en-US'), ',',
              prev_policy_premium, ',', sold_home_policy_premium, ',', total_sold_premium)
FROM syn.opportunity;
GO


-- =====================================================================
-- STEP 5. CHECK: should match the deck exactly.
--   Expect control 45,158 / 1,803 / 1,020 / 177 / $238,628.49
--          test   44,619 / 1,430 /   839 / 131 / $177,865.58
-- =====================================================================

SELECT p.arm,
       COUNT(*)                                                      AS prospects,
       SUM(IIF(p.utm_source IS NOT NULL, 1, 0))                      AS visited,
       SUM(IIF(p.amp_lead_uid IS NOT NULL, 1, 0))                    AS opps,
       SUM(IIF(o.has_any_policy = 'TRUE', 1, 0))                     AS sold,
       SUM(IIF(o.has_any_policy = 'TRUE', o.total_sold_premium, 0))  AS sold_premium
FROM syn.prospect p
LEFT JOIN syn.opportunity o ON o.amp_lead_uid = p.amp_lead_uid
GROUP BY p.arm
ORDER BY p.arm;
GO
