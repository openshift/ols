---
name: estimate-epic
description: >
  Size OLS Jira Epics using t-shirt sizes (XS/S/M/L/XL) based on the total
  story points of their child issues. Can size specific Epics, or bulk-size
  all unsized Epics. Also invoked automatically after creating a new Epic.
argument-hint: "[OLS-1234 ...] (omit to size all unsized Epics)"
---

# Size Epics by Total Story Points

## Overview

Set the Size (t-shirt size) field on OLS Epics based on the sum of story
points across their child issues. This is a mechanical calculation, not a
judgment call — the mapping is fixed.

## Usage

```
/estimate-epic OLS-1234              # size one Epic
/estimate-epic OLS-1234 OLS-1235     # size multiple Epics
/estimate-epic                       # size ALL unsized open Epics
```

Also invoked automatically after creating a new Epic.

## Size Mapping

| Total SP | Size |
|----------|------|
| <= 10    | XS   |
| <= 20    | S    |
| <= 40    | M    |
| <= 60    | L    |
| > 60     | XL   |

## Jira Field Reference

- **Size field:** `customfield_10795` (dropdown)
- **Option IDs:** XS=12589, S=12588, M=12587, L=12586, XL=12585
- **Story Points field:** `customfield_10028` (on child issues)
- **Cloud ID:** `redhat.atlassian.net`
- **Epic Link field for JQL:** `"Epic Link"` or `parent`

## Workflow

### Step 1: Determine target Epics

**If arguments provided:** Extract all `OLS-XXXX` keys from the arguments.

**If no arguments:** Query Jira for all unsized open Epics:
```
project = OLS AND issuetype = Epic AND resolution = Unresolved AND "Size[Dropdown]" is EMPTY
```

### Step 2: For each Epic

#### 2a. Fetch child issues and their story points

Use `searchJiraIssuesUsingJql` with:
- `jql`: `"Epic Link" = OLS-XXXX OR parent = OLS-XXXX`
- `fields`: `["summary", "customfield_10028", "issuetype"]`
- `maxResults`: 100

If more than 100 children, paginate.

#### 2b. Sum story points

- Sum `customfield_10028` across all children
- Count children with null/missing SP separately (for warning)

#### 2c. Map to t-shirt size

Apply the mapping table above. Use this logic:
```
if total <= 10: XS (option 12589)
elif total <= 20: S (option 12588)
elif total <= 40: M (option 12587)
elif total <= 60: L (option 12586)
else: XL (option 12585)
```

#### 2d. Set Size on the Epic

Use `editJiraIssue` with:
- `cloudId`: `redhat.atlassian.net`
- `issueIdOrKey`: the Epic key
- `fields`: `{"customfield_10795": {"id": "<option_id>"}}`

### Step 3: Report to user

For each Epic, report one line:
- Epic key and summary
- Child count, total SP, and assigned size
- If any children lack SP: warn with count (e.g., "3 of 12 children unpointed")

For bulk operations, also report a summary line at the end
(e.g., "Sized 15 Epics: 3 XS, 5 S, 4 M, 2 L, 1 XL").
