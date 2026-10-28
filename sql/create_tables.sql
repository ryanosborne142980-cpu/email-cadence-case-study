-- Creates and loads prospects and sales_opportunities in SQL Server 2025.
-- Same schemas as default.sqlite, using native SQL Server types.
--
-- HOW TO RUN (from the repo root)
--   1. Set @repo below to this repo's folder.
--   2. sqlcmd -S .\ROSBO_SQL -E -C -i sql\create_tables.sql
--   The SQL Server service account needs read access to reference_docs\.

IF DB_ID('email_cadence_synth') IS NULL CREATE DATABASE email_cadence_synth;
GO
USE email_cadence_synth;
GO

-- ===== Schemas =====

DROP TABLE IF EXISTS dbo.prospects, dbo.sales_opportunities;

CREATE TABLE dbo.prospects (
  candidate_id    BIGINT,
  email_key       BIGINT,
  fico_score      INT,
  loan_amount     FLOAT,
  premium         FLOAT,
  expiration_date DATE,
  coverages       JSON,
  property_type   VARCHAR(50),
  residency_type  VARCHAR(50),
  year_built      INT,
  purchase_date   DATE,
  square_feet     INT,
  state           CHAR(2),
  zip             VARCHAR(10),
  utm_source      VARCHAR(100),
  utm_content     VARCHAR(100),
  utm_campaign    VARCHAR(100),
  utm_medium      VARCHAR(100),
  amp_lead_uid    VARCHAR(50),
  flow_type       VARCHAR(50)
);

CREATE TABLE dbo.sales_opportunities (
  amp_lead_uid             VARCHAR(50),
  property_state           CHAR(2),
  property_zip             VARCHAR(10),   -- zero-padded to 5 digits
  opportunity_create_date  DATETIME2(0),
  source                   VARCHAR(50),
  marketing_channel        VARCHAR(50),
  has_any_policy           BIT,
  policy_count             INT,
  agent_login              VARCHAR(50),
  disposition_type         VARCHAR(50),
  disposition_reason       VARCHAR(100),
  policy_sale_date         DATE,
  prev_policy_premium      FLOAT,
  sold_home_policy_premium FLOAT,
  total_sold_premium       FLOAT
);

-- ===== Raw text staging (every column as text, like the CSV) =====

DROP TABLE IF EXISTS #prospects_raw, #opps_raw;

CREATE TABLE #prospects_raw (
  candidate_id VARCHAR(50), email_key VARCHAR(50), fico_score VARCHAR(50), loan_amount VARCHAR(50),
  premium VARCHAR(50), expiration_date VARCHAR(50), coverages VARCHAR(4000), property_type VARCHAR(100),
  residency_type VARCHAR(100), year_built VARCHAR(50), purchase_date VARCHAR(50), square_feet VARCHAR(50),
  state VARCHAR(50), zip VARCHAR(50), utm_source VARCHAR(100), utm_content VARCHAR(100),
  utm_campaign VARCHAR(100), utm_medium VARCHAR(100), amp_lead_uid VARCHAR(100), flow_type VARCHAR(100)
);

CREATE TABLE #opps_raw (
  amp_lead_uid VARCHAR(100), property_state VARCHAR(50), property_zip VARCHAR(50),
  opportunity_create_date VARCHAR(50), source VARCHAR(100), marketing_channel VARCHAR(100),
  has_any_policy VARCHAR(50), policy_count VARCHAR(50), agent_login VARCHAR(100),
  disposition_type VARCHAR(100), disposition_reason VARCHAR(100), policy_sale_date VARCHAR(50),
  prev_policy_premium VARCHAR(50), sold_home_policy_premium VARCHAR(50), total_sold_premium VARCHAR(50)
);

-- BULK INSERT takes only a literal path, so build the statements as text.
DECLARE @repo NVARCHAR(400) = N'C:\Users\ryano\OneDrive\Documents\Portfolio\email-cadence-case-study';
DECLARE @with NVARCHAR(200) = N' WITH (FORMAT = ''CSV'', FIRSTROW = 2, ROWTERMINATOR = ''0x0d0a'', CODEPAGE = ''65001'');';

EXEC (N'BULK INSERT #prospects_raw FROM ''' + @repo + N'\reference_docs\prospects.csv''' + @with);
EXEC (N'BULK INSERT #opps_raw FROM ''' + @repo + N'\reference_docs\sales_opportunities.csv''' + @with);

-- ===== Load: blank -> NULL, text -> typed (bad values become NULL) =====

INSERT INTO dbo.prospects
SELECT
  TRY_CAST(candidate_id AS BIGINT),
  TRY_CAST(email_key AS BIGINT),
  TRY_CAST(fico_score AS INT),
  TRY_CAST(loan_amount AS FLOAT),
  TRY_CAST(premium AS FLOAT),
  TRY_CONVERT(DATE, NULLIF(expiration_date, ''), 101),
  CASE WHEN ISJSON(coverages) = 1 THEN CAST(coverages AS JSON) END,
  NULLIF(property_type, ''),
  NULLIF(residency_type, ''),
  TRY_CAST(year_built AS INT),
  TRY_CONVERT(DATE, NULLIF(purchase_date, ''), 101),
  TRY_CAST(square_feet AS INT),
  NULLIF(state, ''),
  CASE WHEN LEN(zip) BETWEEN 1 AND 4 AND zip NOT LIKE '%[^0-9]%' THEN RIGHT('0000' + zip, 5) ELSE NULLIF(zip, '') END,
  NULLIF(utm_source, ''),
  NULLIF(utm_content, ''),
  NULLIF(utm_campaign, ''),
  NULLIF(utm_medium, ''),
  NULLIF(amp_lead_uid, ''),
  NULLIF(flow_type, '')
FROM #prospects_raw;

INSERT INTO dbo.sales_opportunities
SELECT
  NULLIF(amp_lead_uid, ''),
  NULLIF(property_state, ''),
  CASE WHEN LEN(property_zip) BETWEEN 1 AND 4 AND property_zip NOT LIKE '%[^0-9]%'
       THEN RIGHT('0000' + property_zip, 5) ELSE NULLIF(property_zip, '') END,
  TRY_CONVERT(DATETIME2(0), NULLIF(opportunity_create_date, ''), 101),
  NULLIF(source, ''),
  NULLIF(marketing_channel, ''),
  TRY_CAST(has_any_policy AS BIT),
  TRY_CAST(policy_count AS INT),
  NULLIF(agent_login, ''),
  NULLIF(disposition_type, ''),
  NULLIF(disposition_reason, ''),
  TRY_CONVERT(DATE, NULLIF(policy_sale_date, ''), 101),
  TRY_CAST(prev_policy_premium AS FLOAT),
  TRY_CAST(sold_home_policy_premium AS FLOAT),
  TRY_CAST(total_sold_premium AS FLOAT)
FROM #opps_raw;

DROP TABLE #prospects_raw, #opps_raw;
GO
