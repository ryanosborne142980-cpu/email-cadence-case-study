"""Generator settings. Same SEED, same files. Change it for a new draw."""
from datetime import date

SEED = 42
OUTPUT_DIR = "landing"

# ---------------------------------------------------------------------
# Campaign
# ---------------------------------------------------------------------
N_PROSPECTS = 90_000
LIST_DATE = date(2026, 8, 31)           # marketing list exported the day before the first send
END_DATE = date(2026, 10, 19)           # last CRM snapshot; opps still open then stay open

# Email number -> send date. Control (odd email_key) gets all 8, test (even) gets 4.
SEND_DATES = {
    1: date(2026, 9, 1), 2: date(2026, 9, 4), 3: date(2026, 9, 7), 4: date(2026, 9, 10),
    5: date(2026, 9, 13), 6: date(2026, 9, 16), 7: date(2026, 9, 19), 8: date(2026, 9, 22),
}
TEST_EMAILS = {1, 4, 5, 8}

# Chance a recipient clicks through from a given email.
CLICK_RATE = {1: .0110, 2: .0055, 3: .0035, 4: .0105, 5: .0030, 6: .0035, 7: .0030, 8: .0060}
REPEAT_VISIT_RATE = .30     # a click is followed by another page view a few days later
OPT_IN_RATE = .40           # a page view ends in an opt-in to agent contact (creates a lead)
PHONE_LEAD_RATE = .004      # prospect becomes a lead by phone / transfer, without visiting
CRM_MISSING_RATE = .01      # lead never reaches the CRM
CLOSE_RATE = .17            # lead buys a policy before END_DATE
LOST_SHARE = .75            # unsold leads marked lost (the rest stay in contact_attempt)

N_ORPHAN_OPPS = 2_200       # CRM opps from the partner's other channels, not on the list
ORPHAN_CLOSE_RATE = .15

# ---------------------------------------------------------------------
# Prospect attributes (shares and lognormal fits from the original data's aggregates)
# ---------------------------------------------------------------------
SAVINGS_SHARE = .217
ALL_FUNNEL_PREMIUM_SHARE = .551   # all_funnel prospects with a known current premium

PROPERTY_TYPES = {
    "single_family_detached": 70148, "pud": 13829, "duplex": 2552, "townhouse": 1245, "mobile_home": 894,
    "triplex": 420, "condominium": 275, "four_plex": 251, "other": 119, "rowhome": 44,
}
RESIDENCY_TYPES = {"primary_residence": 83828, "investment": 4410, "second_home": 1102, "unknown": 437}
DEDUCTIBLES = {1000: 22567, 500: 8645, 2500: 3220, 2000: 1406, 250: 1105, 1500: 1024, 5000: 862}

# state: (weight, first ZIP3, last ZIP3)
STATES = {
    "FL": (480, 320, 349), "CA": (456, 900, 961), "GA": (319, 300, 319), "TX": (312, 750, 799),
    "NY": (280, 100, 149), "NJ": (181, 70, 89), "MD": (147, 206, 219), "AZ": (142, 850, 865),
    "PA": (129, 150, 196), "NC": (114, 270, 289), "CO": (110, 800, 816), "OH": (106, 430, 458),
    "MA": (102, 10, 27), "AL": (101, 350, 369), "TN": (99, 370, 385),
    "VA": (32, 220, 246), "WA": (32, 980, 994), "IL": (32, 600, 629), "MI": (32, 480, 499),
    "IN": (32, 460, 479), "MO": (32, 630, 658), "SC": (32, 290, 299), "WI": (32, 530, 549),
    "MN": (32, 550, 567), "KY": (32, 400, 427), "LA": (32, 700, 714), "OK": (32, 730, 749),
    "OR": (32, 970, 979), "NV": (32, 889, 898), "UT": (32, 840, 847), "CT": (32, 60, 69),
    "IA": (32, 500, 528), "KS": (32, 660, 679), "AR": (32, 716, 729), "MS": (32, 386, 397),
    "NM": (32, 870, 884), "NE": (32, 680, 693), "ID": (32, 832, 838), "WV": (32, 247, 268),
    "NH": (32, 30, 38), "ME": (32, 39, 49), "HI": (32, 967, 968), "RI": (32, 28, 29),
    "DE": (32, 197, 199), "MT": (32, 590, 599), "SD": (32, 570, 577), "DC": (32, 200, 205),
}

# ---------------------------------------------------------------------
# CRM
# ---------------------------------------------------------------------
N_AGENTS = 15
LOST_REASONS = {
    "price": 540, "not_interested": 206, "contact_never_made": 174, "contact_made_but_never_heard_from": 58,
    "underwriting_other": 58, "underwriting_claims": 29, "other": 14, "ko_questions": 10,
    "underwriting_coastal": 7, "underwriting_age_of_home": 6, "do_not_contact": 5, "duplicate_entry": 4, "timing": 3,
}
PHONE_CHANNELS = {"warm_transfer": 205, "inbound_call": 151, "email": 4, "outbound_call": 3,
                  "cold_transfer": 2, "direct_mail": 2, "banner": 1}
ORPHAN_SOURCES = {   # (source, marketing_channel): weight
    ("partner", "email"): 1655, ("partner_import", "inbound_call"): 200, ("partner_import", "warm_transfer"): 155,
    ("partner_agent", "warm_transfer"): 119, ("partner_agent", "inbound_call"): 84, ("partner", "direct_mail"): 21,
    ("partner_agent", "cold_transfer"): 10, ("partner_import", "outbound_call"): 7, ("partner_import", "email"): 3,
}
POLICY_COUNTS = {1: 562, 2: 82, 3: 4, 4: 2, 5: 1}
HOME_POLICY_SHARE = .92     # sales that include a home policy

# ---------------------------------------------------------------------
# Dirt: problems injected into the files, as a rate per row (counts land in the manifest)
# ---------------------------------------------------------------------
DIRT = {
    # prospects.csv
    "prospect_exact_duplicate": .004,   # same row twice
    "prospect_stale_version": .002,     # an older version of the row with different values; latest updated_at wins
    "messy_category": .01,              # ' Single_Family_Detached ', 'PUD', 'single family detached'
    "zip_lost_leading_zero": .5,        # of ZIPs starting with 0 (file was opened in Excel)
    "iso_date": .05,                    # 2006-03-08 instead of 3/8/2006
    "null_token": .03,                  # 'NULL' or 'N/A' instead of blank
    "invalid_fico": .0005,              # 0 or 999
    # email_sends.csv
    "send_duplicate": .002,             # ESP retried and logged the send twice
    "send_contamination": .001,         # test prospect sent a control-only email (a real test error to detect)
    # web_events.csv
    "event_double_fire": .01,           # tracking pixel fired twice: same event_id
    "event_unknown_email_key": .005,    # bot / forwarded-email traffic, key not on the list
    "event_bad_utm": .003,              # utm_content 'undefined' or blank
    "event_utc_timestamp": .2,          # '2026-09-01T14:22:33Z' (UTC) instead of local '2026-09-01 10:22:33'
    # opportunities.csv
    "opp_source_variant": .03,          # 'Partner', 'PARTNER', ' partner'
    "opp_bool_variant": .05,            # true / 1 / Y instead of TRUE
    "opp_money_text": .05,              # '$1,234.50'
    "opp_file_duplicate": .01,          # same row twice in one file
    "opp_late_arrival": .005,           # an old snapshot re-sent in a later file (must not overwrite newer state)
    "opp_corrupt_row": .001,            # truncated line, too few columns
    "opp_sale_before_create": .002,     # policy_sale_date earlier than opportunity_create_date
}
MISSING_OPP_FILE = date(2026, 9, 25)    # CRM export failed; that day's changes arrive the next day
