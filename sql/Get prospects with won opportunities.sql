WITH sales_by_lead AS (
    SELECT
        amp_lead_uid,
        count(*) AS opportunity_count,
        bool_or(coalesce(has_any_policy, false)) AS has_sold_policy
    FROM sales_opportunities
    WHERE amp_lead_uid IS NOT NULL
    GROUP BY amp_lead_uid
),
prospect_funnel AS (
    SELECT
        CASE
            WHEN p.email_key % 2 = 0 THEN 'test_4'
            WHEN p.email_key % 2 = 1 THEN 'control_8'
        END AS arm,
        NULLIF(trim(p.utm_content), '') IS NOT NULL AS visited,
        coalesce(s.opportunity_count, 0) > 0 AS has_opp,
        coalesce(s.has_sold_policy, false) AS is_customer
    FROM prospects p
    LEFT JOIN sales_by_lead s
        ON s.amp_lead_uid = p.amp_lead_uid
)
SELECT
    arm,
    count(*) AS prospects,
    count(*) FILTER (WHERE visited) AS visits,
    count(*) FILTER (WHERE has_opp) AS prospects_with_opportunities,
    count(*) FILTER (WHERE visited AND has_opp) AS opted_in,
    count(*) FILTER (WHERE is_customer) AS customers
FROM prospect_funnel
GROUP BY arm
ORDER BY arm;