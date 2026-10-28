"""
Synthetic source systems for the email cadence case study.

Simulates four upstream systems dropping files into landing/<date>/:
  prospects.csv       marketing list, once (LIST_DATE)
  email_sends.csv     email service: one row per send
  web_events.csv      website: page views and opt-ins
  opportunities.csv   CRM: every opportunity that changed that day, in its latest state

The files are deliberately messy (config.DIRT). landing/_manifest.json holds the
clean truth so the pipeline's quality checks can prove the cleanup worked.

Run from the repo root:  py -3 generator/generate.py
"""
import csv
import json
import random
from collections import Counter, defaultdict
from datetime import date, datetime, time, timedelta
from pathlib import Path

import config as cfg

# Shared state for one run. main() resets all three at the start, so a run is
# always reproducible from cfg.SEED.
rng = random.Random(cfg.SEED)
dirt = Counter()                    # injected problems, by type
files = defaultdict(list)           # (day, file name) -> rows

# Column headers for each output file, in the order the rows are written.
PROSPECT_COLS = ["candidate_id", "email_key", "fico_score", "loan_amount", "premium", "expiration_date",
                 "coverages", "property_type", "residency_type", "year_built", "purchase_date", "square_feet",
                 "state", "zip", "flow_type", "updated_at"]
SEND_COLS = ["send_id", "email_key", "email_no", "utm_campaign", "sent_at"]
EVENT_COLS = ["event_id", "event_ts", "email_key", "event_type", "utm_source", "utm_medium",
              "utm_campaign", "utm_content", "lead_uid"]
OPP_COLS = ["amp_lead_uid", "candidate_id", "updated_at", "property_state", "property_zip",
            "opportunity_create_date", "source", "marketing_channel", "has_any_policy", "policy_count",
            "agent_login", "disposition_type", "disposition_reason", "policy_sale_date",
            "prev_policy_premium", "sold_home_policy_premium", "total_sold_premium"]

# CRM statuses that mean the opportunity is still being worked (not sold, not lost).
OPEN_STATUSES = {"new_request", "contact_attempt", "pipeline"}

# Tracking codes built from the config dates, so moving the campaign only needs config changes.
CAMPAIGN_CODE = f"{cfg.CAMPAIGN_DATE:%m%d%y}"   # utm_campaign suffix, e.g. 082826
CONTENT_TAG = f"{cfg.SEND_DATES[1]:%m%y}"       # utm_content month tag, e.g. 0926


# ---------------------------------------------------------------------
# Helpers
#   Small building blocks for random draws, IDs, timestamps and codes.
#   Every random value comes from `rng`, so the same seed gives the same files.
# ---------------------------------------------------------------------

def chance(p):
    """True with probability p."""
    return rng.random() < p


def pick(weights):
    """One key from a {value: weight} dict, chosen in proportion to its weight."""
    return rng.choices(list(weights), weights=list(weights.values()))[0]


def clamp(x, lo, hi):
    """x limited to the range lo..hi."""
    return max(lo, min(hi, x))


def hex_id(chars):
    """A random lowercase hex ID of the given length (send, event and lead IDs)."""
    return f"{rng.getrandbits(chars * 4):0{chars}x}"


def at(day, seconds=None):
    """A timestamp on `day`, at a random second unless given."""
    return datetime.combine(day, time()) + timedelta(seconds=rng.randrange(86_400) if seconds is None else seconds)


def zip_for(state):
    """A random 5-digit ZIP inside the state's ZIP3 range from config.STATES."""
    _, lo, hi = cfg.STATES[state]
    return f"{rng.randint(lo, hi):03d}{rng.randrange(100):02d}"


def segment(p):
    """Email segment, which sets the campaign code: savings, all-funnel with premium, without."""
    if p["flow_type"] == "savings":
        return "PS", f"sav{CAMPAIGN_CODE}"
    return ("AFP", f"allfpi{CAMPAIGN_CODE}") if p["premium"] is not None else ("AFNP", f"allfnpi{CAMPAIGN_CODE}")


def eastern_utc_offset(ts):
    """Hours from US Eastern local time to UTC: 4 in daylight time, 5 otherwise."""
    # US rule: daylight time runs from 2 am on the second Sunday in March
    # to 2 am on the first Sunday in November.
    march, november = date(ts.year, 3, 8), date(ts.year, 11, 1)
    dst_start = march + timedelta(days=(6 - march.weekday()) % 7)            # second Sunday in March
    dst_end = november + timedelta(days=(6 - november.weekday()) % 7)        # first Sunday in November
    in_dst = datetime.combine(dst_start, time(2)) <= ts < datetime.combine(dst_end, time(2))
    return 4 if in_dst else 5


# ---------------------------------------------------------------------
# 1. Simulate the clean world
#   Build the true, error-free records: who is on the list, which emails
#   they got, who clicked and opted in, and what happened in the CRM.
#   Nothing here is dirty; dirt is added in section 2 when rows are written.
# ---------------------------------------------------------------------

def make_prospects():
    """The marketing list: one clean record per prospect, with attributes drawn from config."""
    # Unique email keys. Odd keys go to the control arm (8 emails), even keys to test (4 emails).
    keys = rng.sample(range(3_000_000, 3_400_000), cfg.N_PROSPECTS)   # parity of email_key sets the arm
    states = {s: w for s, (w, _, _) in cfg.STATES.items()}
    prospects = []
    for i, key in enumerate(keys):
        # Segment: savings prospects always have a current premium; some all-funnel prospects do.
        flow = "savings" if chance(cfg.SAVINGS_SHARE) else "all_funnel"
        has_premium = flow == "savings" or chance(cfg.ALL_FUNNEL_PREMIUM_SHARE)
        state = pick(states)
        purchase_year = round(clamp(rng.gauss(2015, 6), 1989, 2026))
        # Property and policy attributes. Policy fields (premium, expiration, coverages)
        # exist only for prospects with a current premium; some fields are left blank at
        # rates seen in the original data.
        prospects.append({
            "candidate_id": 1_000_000 + i,
            "email_key": key,
            "arm": "control_8" if key % 2 else "test_4",
            "fico_score": None if chance(.0001) else round(clamp(rng.gauss(731, 59), 350, 850)),
            "loan_amount": round(max(5_000, rng.lognormvariate(11.97, .67))),
            "premium": round(rng.lognormvariate(6.93, .52), 2) if has_premium else None,
            "expiration_date": cfg.LIST_DATE + timedelta(days=rng.randrange(-80, 350)) if has_premium else None,
            "deductible": pick(cfg.DEDUCTIBLES) if has_premium else None,
            "dwelling_coverage": int(round(rng.lognormvariate(12.46, .56), -3)) if has_premium else None,
            "property_type": pick(cfg.PROPERTY_TYPES),
            "residency_type": pick(cfg.RESIDENCY_TYPES),
            "year_built": None if chance(.087) else round(clamp(rng.gauss(1974, 30), 1900, 2026)),
            "purchase_date": None if chance(.29) else min(date(purchase_year, 1, 1) + timedelta(days=rng.randrange(365)),
                                                         cfg.LIST_DATE),
            "square_feet": None if chance(.068) else round(rng.lognormvariate(7.43, .40)),
            "state": state,
            "zip": zip_for(state),
            "flow_type": flow,
            "updated_at": at(cfg.LIST_DATE - timedelta(days=rng.randrange(30))),
        })
    return prospects


def simulate_campaign(prospects):
    """Sends, clean web events and leads for every prospect."""
    sends, events, leads = [], [], []
    for p in prospects:
        # Which emails this prospect receives: all 8 for control, emails 1, 4, 5, 8 for test.
        # A few test prospects are wrongly sent one extra control-only email (contamination),
        # a real test error the pipeline should detect.
        emails = cfg.TEST_EMAILS if p["arm"] == "test_4" else set(cfg.SEND_DATES)
        if p["arm"] == "test_4" and chance(cfg.DIRT["send_contamination"]):
            emails = emails | {rng.choice(sorted(set(cfg.SEND_DATES) - cfg.TEST_EMAILS))}
            p["contaminated"] = True
            dirt["send_contamination"] += 1
        seg, campaign = segment(p)
        lead = None
        for e in sorted(emails):
            # Send the email in the morning batch on its send date.
            sent_at = at(cfg.SEND_DATES[e], seconds=6 * 3600 + rng.randrange(3 * 3600))   # 6-9 am batch
            sends.append({"send_id": hex_id(16), "email_key": p["email_key"], "email_no": e,
                          "utm_campaign": campaign, "sent_at": sent_at})
            # Most recipients never click. A click becomes a page view within ~10 days,
            # sometimes followed by a repeat visit a few days later.
            if not chance(cfg.CLICK_RATE[e]):
                continue
            visit_times = [sent_at + timedelta(days=min(int(rng.expovariate(1 / 1.5)), 10), seconds=rng.randrange(43_200))]
            if chance(cfg.REPEAT_VISIT_RATE):
                visit_times.append(visit_times[0] + timedelta(days=rng.randint(1, 4), seconds=rng.randrange(43_200)))
            for ts in visit_times:
                if ts.date() > cfg.END_DATE:        # after the last snapshot: never recorded
                    continue
                # Log the page view, tagged with the email it came from.
                utm = {"email_key": p["email_key"], "utm_source": "servicing", "utm_medium": "email",
                       "utm_campaign": campaign, "utm_content": f"3P_EM_{seg}_{CONTENT_TAG}_INS_{e:02d}"}
                events.append({"event_id": hex_id(16), "event_ts": ts, "event_type": "page_view", "lead_uid": None, **utm})
                # The first opt-in on a visit creates the prospect's lead (one lead per prospect).
                if lead is None and chance(cfg.OPT_IN_RATE):
                    lead = {"lead_uid": hex_id(24), "prospect": p, "created": ts + timedelta(minutes=rng.randint(1, 15)),
                            "source": "partner", "channel": "email"}
                    events.append({"event_id": hex_id(16), "event_ts": lead["created"], "event_type": "opt_in",
                                   "lead_uid": lead["lead_uid"], **utm})
        # Prospects who never opted in online can still become leads by phone or transfer.
        if lead is None and chance(cfg.PHONE_LEAD_RATE):
            lead = {"lead_uid": hex_id(24), "prospect": p, "source": "partner_import", "channel": pick(cfg.PHONE_CHANNELS),
                    "created": at(cfg.SEND_DATES[1] + timedelta(days=rng.randrange((cfg.END_DATE - cfg.SEND_DATES[1]).days)))}
        # A small share of leads never reach the CRM.
        if lead:
            lead["in_crm"] = not chance(cfg.CRM_MISSING_RATE)
            leads.append(lead)
    return sends, events, leads


def opportunity_history(lead, close_rate):
    """Every state the opportunity passes through up to END_DATE, as (timestamp, state)."""
    # Starting state: a new request, with property details from the prospect
    # (or from the lead itself for orphans, which are not on the list).
    p = lead.get("prospect")
    state = {
        "amp_lead_uid": lead["lead_uid"],
        "candidate_id": p["candidate_id"] if p else lead["candidate_id"],
        "property_state": p["state"] if p else lead["state"],
        "property_zip": p["zip"] if p else zip_for(lead["state"]),
        "opportunity_create_date": lead["created"],
        "source": lead["source"],
        "marketing_channel": lead["channel"],
        "has_any_policy": False,
        "policy_count": 0,
        "agent_login": f"agent_{rng.randint(1, cfg.N_AGENTS):02d}",
        "disposition_type": "new_request",
        "disposition_reason": None,
        "policy_sale_date": None,
        "prev_policy_premium": None if chance(.25) else round(rng.lognormvariate(7.0, .51)),
        "sold_home_policy_premium": None,
        "total_sold_premium": 0,
    }
    history = [(lead["created"], state)]

    def step(days, **changes):
        """Move to a new state `days` later. False (and no change) if that is past END_DATE."""
        ts = history[-1][0] + timedelta(days=days, seconds=rng.randrange(8 * 3600))
        if ts.date() > cfg.END_DATE:
            return False
        history.append((ts, {**history[-1][1], **changes}))
        return True

    # An agent tries to make contact within 2 days. If time runs out first, it stays a new request.
    if not step(rng.uniform(0, 2), disposition_type="contact_attempt"):
        return history
    # Winning path: pipeline, then a sale with premium, policy count and maybe a home policy.
    if chance(close_rate):
        if step(rng.uniform(0, 3), disposition_type="pipeline"):
            total = round(rng.lognormvariate(7.05, .54), 2)
            count = pick(cfg.POLICY_COUNTS)
            home = None
            if chance(cfg.HOME_POLICY_SHARE):
                home = total if count == 1 else round(total * rng.uniform(.75, .95), 2)
            sold_at = history[-1][0] + timedelta(days=rng.expovariate(1 / 5))
            sale_date = sold_at.date()
            # Dirt: occasionally record a sale date before the opportunity was created.
            bad_sale_date = chance(cfg.DIRT["opp_sale_before_create"])
            if bad_sale_date:
                sale_date = lead["created"].date() - timedelta(days=rng.randint(1, 5))
            sold = step((sold_at - history[-1][0]).total_seconds() / 86_400, disposition_type="policy_sold",
                        has_any_policy=True, policy_count=count, policy_sale_date=sale_date,
                        sold_home_policy_premium=home, total_sold_premium=total)
            if sold and bad_sale_date:      # count it only if the sale reaches the files
                dirt["opp_sale_before_create"] += 1
    # Losing path: most unsold leads are marked lost with a reason; the rest stay open.
    elif chance(cfg.LOST_SHARE):
        step(rng.expovariate(1 / 6), disposition_type="lost", disposition_reason=pick(cfg.LOST_REASONS))
    return history


def make_orphans():
    """CRM opportunities from the partner's other channels: not on the list, out of the test's scope."""
    states = {s: w for s, (w, _, _) in cfg.STATES.items()}
    span = (cfg.END_DATE - cfg.SEND_DATES[1]).days
    orphans = []
    for _ in range(cfg.N_ORPHAN_OPPS):
        # Random source and channel, a candidate ID outside the list's range, created during the campaign.
        source, channel = pick(cfg.ORPHAN_SOURCES)
        orphans.append({"lead_uid": hex_id(24), "candidate_id": rng.randrange(2_000_000, 2_500_000),
                        "state": pick(states), "source": source, "channel": channel, "in_crm": True,
                        "created": at(cfg.SEND_DATES[1] + timedelta(days=rng.randrange(span)))})
    return orphans


# ---------------------------------------------------------------------
# 2. Write the files, injecting dirt
#   Turn the clean records into CSV rows grouped by file and day, adding
#   the problems listed in config.DIRT at their configured rates. Every
#   injected problem is counted in `dirt` for the manifest.
# ---------------------------------------------------------------------

def blank():
    """An empty value: usually '', sometimes a 'NULL' / 'N/A' token (dirt)."""
    if chance(cfg.DIRT["null_token"]):
        dirt["null_token"] += 1
        return rng.choice(["NULL", "N/A"])
    return ""


def fmt_date(d):
    """A date as M/D/YYYY, sometimes ISO YYYY-MM-DD instead (dirt); blank if missing."""
    if d is None:
        return blank()
    if chance(cfg.DIRT["iso_date"]):
        dirt["iso_date"] += 1
        return d.isoformat()
    return f"{d.month}/{d.day}/{d.year}"


def fmt(v):
    """Any value as text; blank if missing."""
    return blank() if v is None else str(v)


def prospect_row(p):
    """One prospects.csv row, with messy categories, lost ZIP zeros and invalid FICOs mixed in."""
    # Dirt: property type in the wrong case, padded with spaces, or with spaces for underscores.
    category = p["property_type"]
    if chance(cfg.DIRT["messy_category"]):
        category = rng.choice([category.upper(), f" {category.title()} ", category.replace("_", " ")])
        dirt["messy_category"] += 1
    # Dirt: a ZIP starting with 0 loses it, as if the file had been opened in Excel.
    zip_code = p["zip"]
    if zip_code.startswith("0") and chance(cfg.DIRT["zip_lost_leading_zero"]):
        zip_code = str(int(zip_code))
        dirt["zip_lost_leading_zero"] += 1
    # Dirt: an impossible FICO score (0 or 999).
    fico = p["fico_score"]
    if fico is not None and chance(cfg.DIRT["invalid_fico"]):
        fico = rng.choice([0, 999])
        dirt["invalid_fico"] += 1
    # Coverages go out as a JSON text field, as in the source system.
    coverages = json.dumps({"deductible": p["deductible"], "dwelling_coverage": p["dwelling_coverage"]})
    return [p["candidate_id"], p["email_key"], fmt(fico), p["loan_amount"], fmt(p["premium"]),
            fmt_date(p["expiration_date"]), coverages, category, p["residency_type"], fmt(p["year_built"]),
            fmt_date(p["purchase_date"]), fmt(p["square_feet"]), p["state"], zip_code, p["flow_type"],
            p["updated_at"].strftime("%Y-%m-%d %H:%M:%S")]


def write_prospects(prospects):
    """prospects.csv on LIST_DATE, with duplicate and stale rows added and the order shuffled."""
    rows = []
    for p in prospects:
        rows.append(prospect_row(p))
        # Dirt: the same row twice.
        if chance(cfg.DIRT["prospect_exact_duplicate"]):
            rows.append(list(rows[-1]))
            dirt["prospect_exact_duplicate"] += 1
        # Dirt: an older version of the prospect with different values. The row with
        # the latest updated_at is the correct one.
        if chance(cfg.DIRT["prospect_stale_version"]):
            stale = {**p, "fico_score": round(clamp(rng.gauss(731, 59), 350, 850)),
                     "loan_amount": round(p["loan_amount"] * rng.uniform(.9, 1.1)),
                     "updated_at": p["updated_at"] - timedelta(days=rng.randint(30, 400))}
            rows.append(prospect_row(stale))
            dirt["prospect_stale_version"] += 1
    # Shuffle so duplicates and stale versions are not next to the originals.
    rng.shuffle(rows)
    files[(cfg.LIST_DATE, "prospects.csv")] = rows


def write_sends(sends):
    """email_sends.csv, one file per send date, with some sends logged twice."""
    for s in sends:
        row = [s["send_id"], s["email_key"], s["email_no"], s["utm_campaign"], s["sent_at"].strftime("%Y-%m-%d %H:%M:%S")]
        files[(s["sent_at"].date(), "email_sends.csv")].append(row)
        # Dirt: the email service retried and logged the same send twice.
        if chance(cfg.DIRT["send_duplicate"]):
            files[(s["sent_at"].date(), "email_sends.csv")].append(list(row))
            dirt["send_duplicate"] += 1


def fmt_event_ts(ts):
    """An event time as local 'YYYY-MM-DD HH:MM:SS', sometimes as UTC ISO with a Z instead (dirt)."""
    if chance(cfg.DIRT["event_utc_timestamp"]):
        dirt["event_utc_timestamp"] += 1
        return (ts + timedelta(hours=eastern_utc_offset(ts))).strftime("%Y-%m-%dT%H:%M:%SZ")   # local time is US Eastern
    return ts.strftime("%Y-%m-%d %H:%M:%S")


def write_events(events):
    """web_events.csv, one file per day, with bot traffic, bad UTM tags and double-fired pixels."""
    # Dirt: bot or forwarded-email page views from email keys that are not on the list.
    n_bots = round(len(events) * cfg.DIRT["event_unknown_email_key"])
    bots = [{"event_id": hex_id(16), "event_type": "page_view", "lead_uid": None,
             "event_ts": at(cfg.SEND_DATES[1] + timedelta(days=rng.randrange(30))),
             "email_key": rng.randrange(4_000_000, 4_100_000), "utm_source": "servicing", "utm_medium": "email",
             "utm_campaign": f"allfpi{CAMPAIGN_CODE}", "utm_content": f"3P_EM_AFP_{CONTENT_TAG}_INS_{rng.randint(1, 8):02d}"}
            for _ in range(n_bots)]
    dirt["event_unknown_email_key"] += n_bots
    for e in events + bots:
        # Dirt: utm_content lost ('undefined' or blank).
        content = e["utm_content"]
        if chance(cfg.DIRT["event_bad_utm"]):
            content = rng.choice(["undefined", ""])
            dirt["event_bad_utm"] += 1
        row = [e["event_id"], fmt_event_ts(e["event_ts"]), e["email_key"], e["event_type"], e["utm_source"],
               e["utm_medium"], e["utm_campaign"], content, e["lead_uid"] or ""]
        day = e["event_ts"].date()
        files[(day, "web_events.csv")].append(row)
        # Dirt: the tracking pixel fired twice (same event_id).
        if chance(cfg.DIRT["event_double_fire"]):
            files[(day, "web_events.csv")].append(list(row))
            dirt["event_double_fire"] += 1


def money(v):
    """An amount as '1234.50', sometimes as text like '$1,234.50' (dirt); blank if missing."""
    if v is None:
        return ""
    if chance(cfg.DIRT["opp_money_text"]):
        dirt["opp_money_text"] += 1
        return f"${v:,.2f}"
    return f"{v:.2f}"


def opp_row(ts, s):
    """One opportunities.csv row for state `s` at time `ts`, with messy source and boolean values."""
    # Dirt: source in the wrong case or with stray spaces ('Partner', 'PARTNER', ' partner').
    source = s["source"]
    if chance(cfg.DIRT["opp_source_variant"]):
        source = rng.choice([source.capitalize(), source.upper(), f" {source}", f"{source} "])
        dirt["opp_source_variant"] += 1
    # Dirt: has_any_policy as true / 1 / Y instead of TRUE.
    sold = "TRUE" if s["has_any_policy"] else "FALSE"
    if chance(cfg.DIRT["opp_bool_variant"]):
        sold = rng.choice(["true", "1", "Y"] if s["has_any_policy"] else ["false", "0", "N"])
        dirt["opp_bool_variant"] += 1
    # Dates in the CRM's M/D/YYYY format; amounts through money().
    created = s["opportunity_create_date"]
    sale = s["policy_sale_date"]
    return [s["amp_lead_uid"], s["candidate_id"], ts.strftime("%Y-%m-%d %H:%M:%S"), s["property_state"],
            s["property_zip"], f"{created.month}/{created.day}/{created.year} {created.hour}:{created.minute:02d}",
            source, s["marketing_channel"], sold, s["policy_count"], s["agent_login"], s["disposition_type"],
            s["disposition_reason"] or "", f"{sale.month}/{sale.day}/{sale.year}" if sale else "",
            "" if s["prev_policy_premium"] is None else s["prev_policy_premium"],
            money(s["sold_home_policy_premium"]), money(s["total_sold_premium"])]


def write_opportunities(histories):
    """opportunities.csv: each day's file holds every opportunity that changed that day."""
    for history in histories:
        for ts, s in history:
            # The CRM export failed on MISSING_OPP_FILE; that day's changes arrive the next day.
            day = ts.date()
            if day == cfg.MISSING_OPP_FILE:
                day += timedelta(days=1)
            row = opp_row(ts, s)
            files[(day, "opportunities.csv")].append(row)
            # Dirt: the same row twice in one file.
            if chance(cfg.DIRT["opp_file_duplicate"]):
                files[(day, "opportunities.csv")].append(list(row))
                dirt["opp_file_duplicate"] += 1
            # Dirt: a truncated line with too few columns.
            if chance(cfg.DIRT["opp_corrupt_row"]):
                files[(day, "opportunities.csv")].append(row[:-3])
                dirt["opp_corrupt_row"] += 1
            # Dirt: an old snapshot re-sent 1-5 days later. It must not overwrite a newer state.
            late_day = day + timedelta(days=rng.randint(1, 5))
            if late_day <= cfg.END_DATE and late_day != cfg.MISSING_OPP_FILE and chance(cfg.DIRT["opp_late_arrival"]):
                files[(late_day, "opportunities.csv")].append(list(row))
                dirt["opp_late_arrival"] += 1


# ---------------------------------------------------------------------
# 3. Truth for the manifest
#   Count the correct answers from the clean records, before any dirt, so
#   the pipeline's results can be checked against them.
# ---------------------------------------------------------------------

def truth(prospects, sends, events, leads, histories_by_lead, orphans):
    """The clean funnel per arm (prospects to sold premium), plus orphan and CRM totals."""
    arms = {"control_8": Counter(), "test_4": Counter()}
    arm_of = {p["email_key"]: p["arm"] for p in prospects}
    # Prospects and contaminated prospects per arm.
    for p in prospects:
        arms[p["arm"]]["prospects"] += 1
        arms[p["arm"]]["contaminated_prospects"] += p.get("contaminated", False)
    # Emails sent per arm.
    for s in sends:
        arms[arm_of[s["email_key"]]]["emails_sent"] += 1
    # Visitors: list prospects with at least one page view (bots are not in `events`).
    visitors = {e["email_key"] for e in events if e["event_type"] == "page_view"}
    for key in visitors:
        arms[arm_of[key]]["visitors"] += 1
    # Leads and their final CRM state: sold, still open, and sold premium.
    premium = defaultdict(float)
    for lead in leads:
        arm = lead["prospect"]["arm"]
        arms[arm]["leads"] += 1
        if not lead["in_crm"]:
            arms[arm]["leads_missing_from_crm"] += 1
            continue
        final = histories_by_lead[lead["lead_uid"]][-1][1]
        arms[arm]["leads_in_crm"] += 1
        arms[arm]["sold"] += final["has_any_policy"]
        arms[arm]["open_opps"] += final["disposition_type"] in OPEN_STATUSES
        premium[arm] += final["total_sold_premium"]
    result = {arm: dict(sorted(c.items())) for arm, c in arms.items()}
    for arm in result:
        result[arm]["sold_premium"] = round(premium[arm], 2)
    # Orphans and the total number of distinct opportunities the CRM should hold.
    final_orphans = [histories_by_lead[o["lead_uid"]][-1][1] for o in orphans]
    return {
        "arms": result,
        "orphan_opps": len(orphans),
        "orphan_opps_sold": sum(s["has_any_policy"] for s in final_orphans),
        "unique_opportunities_in_crm": sum(lead["in_crm"] for lead in leads) + len(orphans),
    }


# ---------------------------------------------------------------------
# 4. Run
#   Reset, simulate, write the dirty files to landing/<date>/, then write
#   the manifest with the truth, the dirt counts and the row counts.
# ---------------------------------------------------------------------

def main():
    """Generate every landing file and the manifest from cfg.SEED."""
    # Reset shared state and clear the previous run's files.
    rng.seed(cfg.SEED)              # start clean, so calling main() twice gives the same files
    dirt.clear()
    files.clear()
    out = Path(__file__).resolve().parent.parent / cfg.OUTPUT_DIR   # repo root, wherever this runs from
    for old in out.rglob("*"):      # clear files only: sync tools (OneDrive) can lock the folders
        if old.is_file():
            old.unlink()

    # Simulate the clean world: list, campaign, CRM histories for list leads and orphans.
    prospects = make_prospects()
    sends, events, leads = simulate_campaign(prospects)
    orphans = make_orphans()
    histories = {lead["lead_uid"]: opportunity_history(lead, cfg.CLOSE_RATE) for lead in leads if lead["in_crm"]}
    histories.update({o["lead_uid"]: opportunity_history(o, cfg.ORPHAN_CLOSE_RATE) for o in orphans})

    # Turn the records into dirty rows, grouped by (day, file).
    write_prospects(prospects)
    write_sends(sends)
    write_events(events)
    write_opportunities(histories.values())

    # Write each (day, file) group to landing/<date>/<file>.csv with its header row.
    columns = {"prospects.csv": PROSPECT_COLS, "email_sends.csv": SEND_COLS,
               "web_events.csv": EVENT_COLS, "opportunities.csv": OPP_COLS}
    row_counts = {}
    for (day, name), rows in sorted(files.items()):
        path = out / day.isoformat() / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(columns[name])
            writer.writerows(rows)
        row_counts[f"{day.isoformat()}/{name}"] = len(rows)

    # Manifest: how to read the files, the clean truth, what dirt went in, and row counts.
    manifest = {
        "seed": cfg.SEED,
        "date_range": [cfg.LIST_DATE.isoformat(), cfg.END_DATE.isoformat()],
        "notes": {
            "arm": "odd email_key = control_8 (8 emails), even = test_4 (emails 1, 4, 5, 8)",
            "timestamps": "local US Eastern, except web_events ending in Z, which are UTC",
            "missing_file": f"no opportunities.csv for {cfg.MISSING_OPP_FILE}; its changes are in the next day's file",
            "visitors": "prospects on the list with at least one page_view (bot traffic excluded)",
            "sold": "final CRM state has_any_policy = true, for leads on the list",
        },
        "truth": truth(prospects, sends, events, leads, histories, orphans),
        "dirt": {kind: dirt[kind] for kind in sorted(cfg.DIRT)},    # every type, 0 if none landed
        "files": row_counts,
    }
    (out / "_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    # Print a summary for the console.
    print(json.dumps({"truth": manifest["truth"], "dirt": manifest["dirt"], "files": len(row_counts)}, indent=2))


if __name__ == "__main__":
    main()
