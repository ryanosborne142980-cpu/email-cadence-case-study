-- Creates and loads prospects and sales_opportunities in a local DuckDB database.
-- Same schemas as default.sqlite, using native DuckDB types.

-- ===== Schemas =====

CREATE OR REPLACE TABLE prospects (
  candidate_id    BIGINT,
  email_key       BIGINT,
  fico_score      INTEGER,
  loan_amount     DOUBLE,
  premium         DOUBLE,
  expiration_date DATE,
  coverages       JSON,
  property_type   VARCHAR,
  residency_type  VARCHAR,
  year_built      INTEGER,
  purchase_date   DATE,
  square_feet     INTEGER,
  state           VARCHAR,
  zip             VARCHAR,
  utm_source      VARCHAR,
  utm_content     VARCHAR,
  utm_campaign    VARCHAR,
  utm_medium      VARCHAR,
  amp_lead_uid    VARCHAR,
  flow_type       VARCHAR
);

CREATE OR REPLACE TABLE sales_opportunities (
  amp_lead_uid             VARCHAR,
  property_state           VARCHAR,
  property_zip             VARCHAR,   -- zero-padded to 5 digits
  opportunity_create_date  TIMESTAMP,
  source                   VARCHAR,
  marketing_channel        VARCHAR,
  has_any_policy           BOOLEAN,
  policy_count             INTEGER,
  agent_login              VARCHAR,
  disposition_type         VARCHAR,
  disposition_reason       VARCHAR,
  policy_sale_date         DATE,
  prev_policy_premium      DOUBLE,
  sold_home_policy_premium DOUBLE,
  total_sold_premium       DOUBLE
);

-- ===== Load from CSV =====

INSERT INTO prospects
SELECT
  TRY_CAST(candidate_id AS BIGINT),
  TRY_CAST(email_key AS BIGINT),
  TRY_CAST(fico_score AS INTEGER),
  TRY_CAST(loan_amount AS DOUBLE),
  TRY_CAST(premium AS DOUBLE),
  try_strptime(expiration_date, '%m/%d/%Y')::DATE,
  coverages::JSON,
  NULLIF(property_type, ''),
  NULLIF(residency_type, ''),
  TRY_CAST(year_built AS INTEGER),
  try_strptime(purchase_date, '%m/%d/%Y')::DATE,
  TRY_CAST(square_feet AS INTEGER),
  NULLIF(state, ''),
  CASE WHEN regexp_full_match(zip, '\d{1,4}') THEN lpad(zip, 5, '0') ELSE NULLIF(zip, '') END,
  NULLIF(utm_source, ''),
  NULLIF(utm_content, ''),
  NULLIF(utm_campaign, ''),
  NULLIF(utm_medium, ''),
  NULLIF(amp_lead_uid, ''),
  NULLIF(flow_type, '')
FROM read_csv('reference_docs/prospects.csv', header = true, all_varchar = true);

INSERT INTO sales_opportunities
SELECT
  NULLIF(amp_lead_uid, ''),
  NULLIF(property_state, ''),
  CASE WHEN regexp_full_match(property_zip, '\d{1,4}') THEN lpad(property_zip, 5, '0') ELSE NULLIF(property_zip, '') END,
  try_strptime(opportunity_create_date, '%m/%d/%Y %H:%M'),
  NULLIF(source, ''),
  NULLIF(marketing_channel, ''),
  TRY_CAST(has_any_policy AS BOOLEAN),
  TRY_CAST(policy_count AS INTEGER),
  NULLIF(agent_login, ''),
  NULLIF(disposition_type, ''),
  NULLIF(disposition_reason, ''),
  try_strptime(policy_sale_date, '%m/%d/%Y')::DATE,
  TRY_CAST(prev_policy_premium AS DOUBLE),
  TRY_CAST(sold_home_policy_premium AS DOUBLE),
  TRY_CAST(total_sold_premium AS DOUBLE)
FROM read_csv('reference_docs/sales_opportunities.csv', header = true, all_varchar = true);
