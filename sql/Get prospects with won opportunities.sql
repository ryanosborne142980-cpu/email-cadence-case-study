USE email_cadence_synth;

WITH sales_by_lead AS (
    SELECT
        amp_lead_uid,
        COUNT(*) AS opportunity_count,
        MAX(CASE WHEN has_any_policy = 1 THEN 1 ELSE 0 END) AS has_sold_policy
    FROM dbo.sales_opportunities
    WHERE amp_lead_uid IS NOT NULL
    GROUP BY amp_lead_uid
),
prospect_funnel AS (
    SELECT
        CASE
            WHEN p.email_key % 2 = 0 THEN 'test_4'
            WHEN p.email_key % 2 = 1 THEN 'control_8'
        END AS arm,
        CASE WHEN NULLIF(TRIM(p.utm_content), '') IS NOT NULL THEN 1 ELSE 0 END AS visited,
        CASE WHEN COALESCE(s.opportunity_count, 0) > 0 THEN 1 ELSE 0 END AS has_opp,
        COALESCE(s.has_sold_policy, 0) AS is_customer
    FROM dbo.prospects p
    LEFT JOIN sales_by_lead s
        ON s.amp_lead_uid = p.amp_lead_uid
)
SELECT
    arm,
    COUNT(*) AS prospects,
    SUM(visited) AS visits,
    SUM(has_opp) AS prospects_with_opportunities,
    SUM(visited * has_opp) AS opted_in,
    SUM(is_customer) AS customers
FROM prospect_funnel
GROUP BY arm
ORDER BY arm;
