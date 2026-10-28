# Dec 2018 Email Test: Analysis and Method

**Question (case brief, p2):** What effect did cutting email volume from 8 to 4 have on the efficacy of our marketing efforts?

**Answer:** Sending 4 emails instead of 8 reduced sales by 25%: 0.294% of prospects bought a policy vs 0.392% (p = 0.012). The loss happened at the top of the funnel: fewer prospects visited the landing page and fewer opted in. Agents closed opted-in prospects at a similar rate in both arms.

All numbers come from `sql/email_test_csv.sql`, which reads only `reference_docs/prospects.csv` and `reference_docs/sales_opportunities.csv`.

---

## Definitions

| Term | Definition | Source |
|---|---|---|
| Arm | Odd `email_key` = control (8 emails); even = test (4 emails) | Brief p4, 1c |
| Visited | `utm_source` is not null (the prospect reached a landing page) | Brief p4, 1d |
| Opportunity | `amp_lead_uid` is not null on the prospect (they consented to agent contact) | Brief p4, 1e |
| Sold | `has_any_policy = true` on the matching CRM opportunity | Brief p4, 2b |
| Denominator | Every prospect assigned to an arm (intent-to-treat) | |
| p-value | If email volume truly had no effect, the probability of seeing a gap between the arms at least this large through random chance alone. Below 0.05 = statistically significant (the gap is unlikely to be chance). Example: p = 0.012 means about a 1.2% chance of a sales gap this large if both arms really performed the same. It is not the probability that the result is wrong, and it does not measure how big the effect is. | Two-sided, two-proportion z-test |

## Step 1: Data checks

| Check | Result |
|---|---|
| Prospects: rows vs unique `candidate_id` | 89,777 = 89,777 (no duplicates) |
| Opportunities: rows vs unique `amp_lead_uid` | 4,102 = 4,102 (one-to-one join) |
| Prospects without an arm | 0 |
| Prospect opportunities | 1,859 |
| Prospect opportunities found in the CRM file | 1,841 |
| Not found in the CRM file (counted as unsold) | 18 |
| CRM opportunities outside the December cohort (out of scope) | 2,261 |

## Step 2: Was the test run correctly? 

- **Split:** control 45,158 vs test 44,619. The difference is consistent with chance (p = 0.072).
- **Test integrity:** test-arm visits came only from emails 01, 04, 05 and 08. No test-arm visits came from 02, 03, 06 or 07, so test prospects received only their 4 emails.

| Email | 01 | 02 | 03 | 04 | 05 | 06 | 07 | 08 |
|---|---|---|---|---|---|---|---|---|
| Control visits | 376 | 244 | 146 | 449 | 109 | 138 | 109 | 228 |
| Test visits | 505 | – | – | 501 | 140 | – | – | 279 |

## Step 3: Funnel by arm

| Arm | Prospects | Visited | Opps | Sold | Visit % | Opp % | Sold % | Close rate | Sold premium | Premium / prospect |
|---|---|---|---|---|---|---|---|---|---|---|
| Control (8) | 45,158 | 1,803 | 1,020 | 177 | 3.99% | 2.26% | 0.392% | 17.4% | $238,628 | $5.28 |
| Test (4) | 44,619 | 1,430 | 839 | 131 | 3.20% | 1.88% | 0.294% | 15.6% | $177,866 | $3.99 |

## Step 4: Is the difference real?

Two-proportion z-tests comparing test with control. The headline metric is sold / prospect.

| Metric | Control | Test | Relative change | z | p-value |
|---|---|---|---|---|---|
| **Sold / prospect (headline)** | 0.392% | 0.294% | **−25.1%** | −2.52 | **0.012** |
| Visited / prospect | 3.993% | 3.205% | −19.7% | −6.33 | < 0.001 |
| Opp / prospect | 2.259% | 1.880% | −16.8% | −3.98 | < 0.001 |

Close rate (sold / opp) is shown in Step 3 only, without a significance test. It counts only prospects who opted in, and the arm itself changed who opted in, so the two arms' close rates aren't directly comparable.

## Step 5: Where was the loss?

| Arm | Visits from shared emails (01/04/05/08) | Visits from control-only emails (02/03/06/07) |
|---|---|---|
| Control (8) | 1,162 | 637 |
| Test (4) | 1,425 | 0 |

The 4 dropped emails added about 375 visits overall (1,799 vs 1,425).

**Caveat:** `utm_content` records only the prospect's most recent visit (brief p4, 1d). A control prospect who clicked email 01 and later email 06 is credited to 06. That is why the test arm shows *more* visits from the shared emails. This does not mean the shared emails performed better in the test arm.

## Limitations and follow-ups

- **Last-visit attribution:** with visit-level data, measure the incremental reach of each dropped email.
- **Open opportunities:** sales are recorded through 2019-01-18. Check whether opportunities still open would change the sales gap.
- **The 18 opportunities not found in the CRM file:** confirm with the data owner why they are missing.
- **Unsubscribes and complaints:** the test was motivated by email fatigue, which this data can't measure. Weigh the 25% sales loss against unsubscribe and complaint rates if they are available.
- **Segments:** check whether the effect differs by `flow_type`, state or FICO band.
